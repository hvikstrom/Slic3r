package Slic3r::BedTilting;
use strict;
use warnings;

use Moo;
use Slic3r::Geometry qw(X Y Z MIN MAX scale unscale deg2rad rad2deg);
use Data::Dumper;
use List::MoreUtils qw(any);


require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(printMessage);

has '_model' => (is => 'rw', required => 1);
has '_config' => (is => 'rw', required => 1);
has '_preset' => (is => 'rw', required => 1);

our $print;
our $model;
our %preset;
our $view_model;
our %tilt_angles;
our @tilt_cuts_array;
our %tilt_levels;
our $retry;
our $BED_LENGTH;
our $BED_WIDTH;
our $BED_HEIGHT;
our $ORIGIN_OFFSET;
our $BED_DIM;
our $OBJECT_POS;
our $STRENGHT_TEST = 0;

sub clean_values {
    my ($self) = @_;
    undef $print;
    undef $model;
    undef %preset;
    undef $view_model;
    undef %tilt_angles;
    undef @tilt_cuts_array;
    undef %tilt_levels;
}

sub start_process {
    my ($self, $dlg) = @_;
    #my $frame = Slic3r::GUI::Tilt3DConsole->OnInit($self, $parent);
    print "PROCESS\n";
    $self->{dlg} = $dlg;
    $self->process_bed_tilt;
}

sub process_bed_tilt {
    my ($self) = @_;

    $self->{config} = $self->_config;

    $self->clean_values;

    $retry //= 0;
    if ($retry > 2){
        print "Too many retry\n";
        $retry = 0;
        $self->clean_values;
        return 0;
    }

    $ORIGIN_OFFSET = $self->{config}->get('origin_offset');
    $BED_DIM = $self->{config}->get('bed_total_dim');
    $OBJECT_POS = $self->{config}->get('stl_initial_position');


    $BED_LENGTH = $BED_DIM->x;
    $BED_WIDTH = $BED_DIM->y;
    $BED_HEIGHT = $BED_DIM->z;

    #Stores the model

    #MAKE SURE TO USE COPY

    $model = $self->_model->clone;

    $view_model = Slic3r::Model->new;
    $print = Slic3r::Print->new;

    my $original_model_object = $model->objects->[0];

    my $model_offset = Slic3r::Pointf->new($ORIGIN_OFFSET->x, $ORIGIN_OFFSET->y);
    my $dumper_x = $ORIGIN_OFFSET->x;
    $self->{dlg}->appendConsole("Setting offsets to X: $dumper_x");

    #Set the offset which will influence the viability of the tilting process

    $original_model_object->instances->[0]->set_offset($model_offset);

    #Scale the model just for the example
    #$original_model_object->scale_xyz(Slic3r::Pointf3->new(1.5,1.5,1.5));
    #$original_model_object->rotate(deg2rad(-180), Z);
    my $move_in_stl = Slic3r::Pointf3->new($OBJECT_POS->x - $ORIGIN_OFFSET->x, $OBJECT_POS->y - $ORIGIN_OFFSET->y, 0);
    $original_model_object->translate(@$move_in_stl);

    my $bb_mod = $original_model_object->bounding_box;

    print "ORIGINAL_OBJECT\n";
    $self->print_dumper(0, 0, $bb_mod);

    #Make sure the object dimensions are within the printer build space
    return 0 if (!$self->validate_dimensions($bb_mod));

    $print->add_model_object($original_model_object);

    #Apply config and validate print of the original model
    my $config = $self->{config};
    $config->set('support_material', 1);

    eval {
        # this will throw errors if config is not valid
        $config->validate;
        $print->apply_config($config);
        $print->validate;
        Slic3r::debugf "apply config ok\n";
    };

    if ($self->_preset){
        print "PRESET FOUND\n";
        print Dumper($self->_preset);
        %preset = %{$self->_preset};
    }
    else {
        print "No preset found\n";
        #Start tilt process with the original model
        %preset = %{$print->tilt_process};
        if ($preset{'cut'} == 0){
            return 0;
        }
    }
    my $iter_result = 0;
    $print->clear_objects;

    if (!$STRENGHT_TEST){

    while ($preset{'cut'} != 0 && $iter_result < 1){

        print "ITERATION NUMBER $iter_result\n";
        print Dumper($view_model->objects, $model->objects);
        #Should contain (TILT_LEVEL, ANGLEXZ, ANGLEYZ, ANGLEZX, ANGLEZY)
        print "RESULT PLATER %preset\n";

        #Index of last objects in both view_model and model
        my $last_id = scalar @{$model->objects} - 1;
        my $last_view_id = ( scalar @{$view_model->objects} == 0 ) ? 0 : scalar @{$view_model->objects} - 1;

        #Layer height for the cut
        my $tilt_cut = $preset{'cut'};

        my @angles = ($preset{'angles'}{'XZ'}, $preset{'angles'}{'YZ'}, $preset{'angles'}{'ZX'}, $preset{'angles'}{'ZY'});

        #$tilt_cut += 10;

        # $angles[1] -= 0.05;
        # $angles[1] -= $angles[1] if ($iter_result == 1);
        # $angles[2] -= $angles[2] if ($iter_result == 1 or $iter_result == 0);
        my ($anglexz, $angleyz, $anglezx, $anglezy) = @angles;

        #$tilt_cut = $self->rotate3D_z($OBJECT_POS->x, $OBJECT_POS->y + $dim_y, $tilt_cut, -$anglezy, 0);

        print "Angles for iteration $iter_result\n";
        print Dumper(@angles);

        #Last id should always contain the object that needs tilt processing
        my $current_model_object = $model->objects->[$last_id];

        my $random_model = Slic3r::Print->new;
        $random_model->add_model_object($current_model_object);

        #Translate to compensate the offset center of rotation / bed surface
        my $z_translation = Slic3r::Pointf3->new(0,0,-$ORIGIN_OFFSET->z);
        $current_model_object->translate(@$z_translation);

        $random_model->add_model_object($current_model_object);

        $bb_mod = $current_model_object->bounding_box;

        print "OBJECT AFTER Z TRANSLATION\n";
        $self->print_dumper(0,0,$bb_mod);

        #$tilt_cut = abs(abs($tilt_cut) - abs($bb_mod->z_min));

        #Rotate the object
        print "ROTATION YZ $angleyz -$anglezy ZX $anglezx -$anglexz\n";
        $current_model_object->rotate3D($angleyz - $anglezy, $anglezx - $anglexz, 0, 0);

        $bb_mod = $current_model_object->bounding_box;

        $random_model->add_model_object($current_model_object);

        print "OBJECT AFTER ROTATION\n";
        $self->print_dumper(0,0,$bb_mod);
        

        #Check that the new dimensions are still within the printer build space
        my @offsets = $self->check_viability(\@angles, $bb_mod, $tilt_cut);
        if (scalar @offsets == 1){
            print "Impossible tilt\n";
            $self->clean_values;
            return 0;
        }
        else {
            my ($xz_offset, $yz_offset, $zx_offset, $zy_offset) = @offsets;

            if (any { $_ != 0 } @offsets){
                $retry += 1;
                $OBJECT_POS = $self->_config->get('stl_initial_position');
                my $new_object_pos = Slic3r::Pointf3->new($OBJECT_POS->x + $xz_offset + $zx_offset, $OBJECT_POS->y + $yz_offset + $zy_offset, $OBJECT_POS->z);
                $self->_config->set('stl_initial_position', $new_object_pos);
                return $self->process_bed_tilt;
            }
        }

        $tilt_cut += $bb_mod->z_min;

        print "TILT CUT AFTER ADD Z_MIN\n";
        print Dumper($tilt_cut);

        push @tilt_cuts_array, $tilt_cut;

        $tilt_angles{$tilt_cut} = [ @angles ];


        #Compensate for the offset center of rotation / bed surface
        my $tilt_level = $tilt_cut + $ORIGIN_OFFSET->z;

        #Compute the levels needed
        my ($u_level, $z_level, $v_level) = $self->support_levels($tilt_level, \@angles);

        my @levels = ($u_level, $z_level, $v_level);

        #Check that the levels are achievable        
        @offsets = $self->check_levels(\@levels, \@angles);
        if (any {$_ != 0} @offsets){
            $retry += 1;
            $OBJECT_POS = $self->_config->get('stl_initial_position');
            my $new_object_pos = Slic3r::Pointf3->new($OBJECT_POS->x + $offsets[0], $OBJECT_POS->y + $offsets[1], $OBJECT_POS->z);
            $self->_config->set('stl_initial_position', $new_object_pos);
            return $self->process_bed_tilt;
        }

        #Cut the object while rotated
        my $new_model = $current_model_object->cut(Z, $tilt_cut);

        my ($upper_object, $lower_object) = @{$new_model->objects};

        print "LOWER OBJECT\n";
        $bb_mod = $lower_object->bounding_box;

        $self->print_dumper(0,0,$bb_mod);

        $random_model->add_model_object($lower_object);

        print "UPPER OBJECT\n";
        $bb_mod = $upper_object->bounding_box;

        $self->print_dumper(0,0,$bb_mod);

        $random_model->add_model_object($upper_object);


        #Treat the two new objects to display them correctly in the UI
        $self->viewmodel_treat($last_view_id, $lower_object, $upper_object);

        #Treat the two new objects to produce the right G-Code
        $self->model_treat($last_id, \@angles, \@levels, $lower_object, $upper_object, $tilt_cut);

        #Enable support material to detect further need of tilt on the upper part

        if (($iter_result + 1) < 1){
            $print->clear_objects;
            $print->add_model_object($model->objects->[$last_id + 1]);
            %preset = %{$print->tilt_process};
        }

        $iter_result += 1;
    }

    } #!$STRENGTH_TEST

    # else {
    #     while ($result[0] != 0 && $iter_result < 2){

    #     print "ITERATION NUMBER $iter_result\n";
    #     print Dumper($view_model->objects, $model->objects);
        
    #     #Should contain (TILT_LEVEL, ANGLEXZ, ANGLEYZ, ANGLEZX, ANGLEZY)
    #     print "RESULT PLATER @result\n";
        
    #     #Index of the last object in model and view_model
    #     my $last_id = scalar @{$model->objects} - 1;
    #     my $last_view_id = ( scalar @{$view_model->objects} == 0 ) ? 0 : scalar @{$view_model->objects} - 1;
        
        
    #     my @angles = @result;

    #     $angles[0] -= $angles[0];
    #     $angles[1] -= $angles[1] if ($iter_result == 1);
    #     $angles[2] -= $angles[2];
    #     $angles[3] -= $angles[3] if ($iter_result == 0);

    #     my ($anglexz, $angleyz, $anglezx, $anglezy) = @angles;

    #     print "Angles for iteration $iter_result\n";
    #     print Dumper(@angles);

    #     #Should be the item that needs tilt processing
    #     my $current_model_object = $model->objects->[$last_id];

    #     my $random_model = Slic3r::Print->new;
    #     $random_model->add_model_object($current_model_object);


    #     #Compensate the offset rotation center / bed surface
    #     my $z_translation = Slic3r::Pointf3->new(0,0,-$ORIGIN_OFFSET->z);
    #     $current_model_object->translate(@$z_translation);

    #     $random_model->add_model_object($current_model_object);

    #     $bb_mod = $current_model_object->bounding_box;

    #     print "OBJECT AFTER Z TRANSLATION\n";
    #     $self->print_dumper(0,0,$bb_mod);

    #     #Rotate the object
    #     print "ROTATION YZ $angleyz -$anglezy ZX $anglezx -$anglexz\n";
    #     $current_model_object->rotate3D($angleyz - $anglezy, $anglezx - $anglexz, 0, 0);

    #     $bb_mod = $current_model_object->bounding_box;

    #     #Since this is a specific test, we choose the layer height accordingly
    #     my $tilt_cut = ($bb_mod->z_max - 1);
        
    #     print "PYRAMID_TIP\n";
    #     print Dumper($tilt_cut);

    #     $random_model->add_model_object($current_model_object);

    #     print "OBJECT AFTER ROTATION\n";
    #     $self->print_dumper(0,0,$bb_mod);


    #     #Check that the object after rotation is still within the printer build space
    #     my @offsets = $self->check_viability(\@angles, $bb_mod, $tilt_cut);
    #     if (scalar @offsets == 1){
    #         print "Impossible tilt\n";
    #         $self->clean_values;
    #         return 0;
    #     }
    #     else {
    #         my ($xz_offset, $yz_offset, $zx_offset, $zy_offset) = @offsets;

    #         if (any { $_ != 0 } @offsets){
    #             $retry += 1;
    #             $OBJECT_POS = $self->_config->get('stl_initial_position');
    #             my $new_object_pos = Slic3r::Pointf3->new($OBJECT_POS->x + $xz_offset + $zx_offset, $OBJECT_POS->y + $yz_offset + $zy_offset, $OBJECT_POS->z);
    #             $self->_config->set('stl_initial_position', $new_object_pos);
    #             return $self->process_bed_tilt;
    #         }
    #     }

    #     push @tilt_cuts_array, $tilt_cut;

    #     $tilt_angles{$tilt_cut} = [ @angles ];

    #     #Adjust the tilt level according to the offset rotation center / bed surface
    #     my $tilt_level = $tilt_cut + $ORIGIN_OFFSET->z;

    #     #Compute the levels
    #     my ($u_level, $z_level, $v_level) = $self->support_levels($tilt_level, \@angles);

    #     my @levels = ($u_level, $z_level, $v_level);
        
    #     #Check the levels
    #     @offsets = $self->check_levels(\@levels, \@angles);
    #     if (any {$_ != 0} @offsets){
    #         $retry += 1;
    #         $OBJECT_POS = $self->_config->get('stl_initial_position');
    #         my $new_object_pos = Slic3r::Pointf3->new($OBJECT_POS->x + $offsets[0], $OBJECT_POS->y + $offsets[1], $OBJECT_POS->z);
    #         $self->_config->set('stl_initial_position', $new_object_pos);
    #         return $self->process_bed_tilt;
    #     }

    #     #Cut the object
    #     my $new_model = $current_model_object->cut(Z, $tilt_cut);

    #     my ($upper_object, $lower_object) = @{$new_model->objects};

    #     print "LOWER OBJECT\n";
    #     $bb_mod = $lower_object->bounding_box;

    #     $self->print_dumper(0,0,$bb_mod);

    #     $random_model->add_model_object($lower_object);

    #     print "UPPER OBJECT\n";
    #     $bb_mod = $upper_object->bounding_box;

    #     $self->print_dumper(0,0,$bb_mod);

    #     $random_model->add_model_object($upper_object);

    #     #Treat the new objects to display them correctly in the UI
    #     $self->viewmodel_treat($last_view_id, $lower_object, $upper_object, \@angles);

    #     #Treat the new objects to produce the correct G-Code
    #     $self->model_treat($last_id, \@angles, \@levels, $lower_object, $upper_object, $tilt_cut);

    #     #Enable support material to detect further need of tilt on the upper part

    #     if (($iter_result + 1) < 2){
    #         $last_id = scalar @{$model->objects} - 1;
    #         $print->clear_objects;
    #         $print->add_model_object($model->objects->[$last_id]);
    #         print "SUPPORT MATERIAL ?\n";
    #         $model->objects->[$last_id]->config->get('support_material');
    #         @result = $print->tilt_process;
    #     }

    #     $iter_result += 1;
    # }
    # }

    print "TILT FINISHED\n";
    $print->clear_objects;
    my $index = 0;

    #Final console display to show the final objects coordinates and levels
    for my $iter_object (@{$model->objects}){
        my $bb_mod = $iter_object->bounding_box;
        print "OBJECT $index\n";
        my @angle_tilt = $tilt_angles{$tilt_cuts_array[$index]} if (defined $tilt_cuts_array[$index]);
        print Dumper(@angle_tilt) if (defined $tilt_cuts_array[$index]);
        $self->print_dumper(0,0, $bb_mod);
        $self->add_print($iter_object, $index);
        $index += 1;
    }
    $retry = 0;
    # return $print;
    return ($model, $view_model);
}


#Properly add lower_object and upper_object in the model instance to produce the correct G-Code
sub model_treat {
    my ($self, $last_id, $angles_ref, $levels_ref, $lower_object, $upper_object, $tilt_cut) = @_;

    my ($anglexz, $angleyz, $anglezx, $anglezy) = @{$angles_ref};
    my @levels = @{$levels_ref};

    #Last object in the model instance is supposed to be the one that needs tilt process, hence that will be cut in two parts, so it needs to be deleted
    $model->delete_object($last_id);

    #Help to differentiate normal support material test and strength test
    my $upper_id;
    my $lower_id;

    if (!$STRENGHT_TEST){
        #Support material test, the upper part is always last
        $model->add_object($lower_object);
        $model->add_object($upper_object);
        $upper_id = $last_id + 1;
        $lower_id = $last_id;
    }
    else {
        #Strength test, the lower part is last, as the specific test demands the pyramid to be cut on top
        $model->add_object($upper_object);
        $model->add_object($lower_object);
        $upper_id = $last_id;
        $lower_id = $last_id + 1;
    }


    #Rotate back the lower part
    print "ROTATION YZ -$angleyz $anglezy ZX -$anglezx $anglexz\n";
    $model->objects->[$lower_id]->rotate3D(- $angleyz + $anglezy, - $anglezx + $anglexz, 0,1);

    my $z_translation = Slic3r::Pointf3->new(0, 0 , $ORIGIN_OFFSET->z);
    
    #Translate back the two parts
    $model->objects->[$lower_id]->translate(@$z_translation);
    $model->objects->[$upper_id]->translate(@$z_translation);
    $tilt_levels{$tilt_cut} = [ @levels ];

    #Compute the offset created by the tilt
    my $tilt_offset = $self->compute_tilts(\@levels);
    if (!$tilt_offset){
        $self->clean_values;
        return 0;
    }
    print "TILT OFFSET\n";
    print Dumper(@$tilt_offset);
    $model->objects->[$upper_id]->translate(@$tilt_offset);

}

#Properly add lower_object and upper_object in the view_model instance to display them correctly
sub viewmodel_treat {
    my ($self, $last_view_id, $lower_object, $upper_object, $angles_ref) = @_;


    #Delete the last object if it contains more than one model
    $view_model->delete_object($last_view_id) if $last_view_id > 0;

    #Help to differentiate normal support material test and strength test
    my $upper_id;
    my $lower_id;

    my $z_view_translation;
    my $z_translation;

    if (!$STRENGHT_TEST){
        #Lower first then the upper part, just like in model_treat
        $view_model->add_object($lower_object);
        $view_model->add_object($upper_object);
        $upper_id = $last_view_id + 1;
        $lower_id = $last_view_id;

        foreach my $tilt_level (reverse @tilt_cuts_array){
            my ($anglexz, $angleyz, $anglezx, $anglezy) = @{$tilt_angles{$tilt_level}};
            $view_model->objects->[$lower_id]->rotate3D(- $angleyz + $anglezy, - $anglezx + $anglexz, 0,1);
            $view_model->objects->[$upper_id]->rotate3D(- $angleyz + $anglezy, - $anglezx + $anglexz, 0,1);
        }
        $z_view_translation = Slic3r::Pointf3->new(0, 0 , $ORIGIN_OFFSET->z + (5 * ($last_view_id + 1)));
        $z_translation = Slic3r::Pointf3->new(0, 0 , $ORIGIN_OFFSET->z + (5 * $last_view_id));
    }
    else {
        #See model_treat
        $view_model->add_object($upper_object);
        $view_model->add_object($lower_object);
        $upper_id = $last_view_id;
        $lower_id = $last_view_id + 1;

        my ($anglexz, $angleyz, $anglezx, $anglezy) = @{$angles_ref};

        $view_model->objects->[$lower_id]->rotate3D(- $angleyz + $anglezy, - $anglezx + $anglexz, 0,1);
        $view_model->objects->[$upper_id]->rotate3D(- $angleyz + $anglezy, - $anglezx + $anglexz, 0,1);

        $z_view_translation = Slic3r::Pointf3->new(0, 0 , $ORIGIN_OFFSET->z + (5 * ($last_view_id + 1)));
        $z_translation = Slic3r::Pointf3->new(0, 0 , $ORIGIN_OFFSET->z);
    }

    $view_model->objects->[$lower_id]->translate(@$z_translation);
    $view_model->objects->[$upper_id]->translate(@$z_view_translation);

}

sub validate_dimensions {
    my ($self, $bb_mod) = @_;

    if (!($bb_mod->x_max < $BED_LENGTH && $bb_mod->x_min > 0) or 
        !($bb_mod->y_max < $BED_WIDTH && $bb_mod->y_min > 0)) {

        print Dumper($bb_mod->x_max, $bb_mod->x_min, $bb_mod->y_max, $bb_mod->y_min);
        print "Does not fit the dimensions\n";
        $self->clean_values;
        return 0;
    }

    return 1;
}

sub compute_tilts {
    my ($self, $levels_ref) = @_;

    my @levels = @{$levels_ref};

    my @cmd = qw(python nonlinear-solver.py);
    push @cmd, @levels;
    push @cmd, $BED_LENGTH;
    push @cmd, $BED_WIDTH;

    use IPC::Run3;

    run3 [@cmd], undef, \my @out, \my $err;

    my ($tilt_ux, $tilt_uy, $tilt_vx, $tilt_vy, $tilt_zy) = @out;

    $tilt_vx -= $BED_LENGTH;
    $tilt_zy -= $BED_WIDTH;

    my $max_angle = $self->{config}->get('max_angle');
    $max_angle = 47;
    #$max_angle = 46 if ($STRENGHT_TEST);

    my @max_tilt = (abs($tilt_ux), abs($tilt_uy), abs($tilt_vx), abs($tilt_vy), abs($tilt_zy));
    if (any {$_ > $max_angle} @max_tilt){
        print Dumper($BED_LENGTH, $BED_WIDTH);
        print Dumper(@out);
        print "ERROR ANGLE\n";
        print Dumper(@max_tilt);
        return 0;
    }

    my $tilt_offset = Slic3r::Pointf3->new($tilt_ux, $tilt_uy, 0);
    return $tilt_offset;
}

sub print_dumper {
    my ($self, $offset_x, $offset_y, $bb_mod) = @_;
    
    print Dumper($offset_x, $offset_y);
    print Dumper($bb_mod->x_min);
    print Dumper($bb_mod->x_max);
    print Dumper($bb_mod->y_min);
    print Dumper($bb_mod->y_max);
    print Dumper($bb_mod->z_min);
    print Dumper($bb_mod->z_max);
}

sub check_viability {
    my ($self, $angles_ref, $bb_mod, $tilt_cut) = @_;

    my ($anglexz, $angleyz, $anglezx, $anglezy) = @{$angles_ref};

    my $zy_offset = 0;
    my $zx_offset = 0;
    my $yz_offset = 0;
    my $xz_offset = 0;

    return (0) if ((abs($bb_mod->z_max - $bb_mod->z_min)) > $BED_HEIGHT);

    my $bb_min = $bb_mod->z_min;

    if ($STRENGHT_TEST){
        $bb_min = 0
    }

    if ($anglezy && (($bb_min + $tilt_cut) < 0)){
        # +0.5 for security
        $zy_offset = (- ($bb_min + $tilt_cut) + 0.5 ) / sin(-$anglezy);
        print "change y pos by $zy_offset\n";
        print Dumper($bb_mod->z_min, $tilt_cut);
    }
    if ($anglezx && (($bb_min + $tilt_cut) < 0)){
        # +0.5 so that u_level cannot be higher than 0.5
        $zx_offset = (- ($bb_mod->z_min + $tilt_cut) + 0.5) / sin(-$anglezx);
        print "change x pos by $zx_offset\n";
    }
    if ($angleyz && ($bb_mod->z_max > $BED_HEIGHT)){
        $yz_offset = (($bb_mod->z_max - $BED_HEIGHT) + 0.5 ) / sin(-$angleyz);
        print "change y pos by $yz_offset\n";
    }
    if ($anglexz && ($bb_mod->z_max > $BED_HEIGHT)){
        print Dumper($bb_mod->z_max, $BED_HEIGHT);
        $xz_offset = (($bb_mod->z_max - $BED_HEIGHT) + 0.5) / sin(-$anglexz);
        print "change x pos by $xz_offset\n";
    }

    print "VIABILITY FINISHED\n";

    return ($xz_offset, $yz_offset, $zx_offset, $zy_offset);
}

sub check_levels {
    my ($self, $levels_ref, $angles_ref) = @_;

    my ($anglexz, $angleyz, $anglezx, $anglezy) = @{$angles_ref};


    my ($u_level, $z_level, $v_level) = @{$levels_ref};

    my $xz_offset = 0;
    my $yz_offset = 0;

    if ($angleyz && $z_level < 0){
        # +0.5 so that v_level cannot be higher than 0.5
        $yz_offset = (-$z_level + 0.5 ) / sin($angleyz);
        print "change y pos by $yz_offset\n";
    }
    if ($anglexz && $v_level < 0){
        # +0.5 so that v_level cannot be higher than 0.5
        $xz_offset = (-$v_level + 0.5 ) / sin($anglexz);
        print "change x pos by $xz_offset\n";
    }
    if ($anglezy && ($u_level < 0 or $v_level < 0)){
        $v_level = ($u_level < $v_level) ? $u_level : $v_level;
        $yz_offset = (-$v_level + 0.5 ) / sin(-$anglezy);
        print "change y pos by $yz_offset\n";
    }
    if ($anglezx && $u_level <0){
        $xz_offset = (-$u_level + 0.5) / sin(-$anglezx);
        print "change x pos by $xz_offset\n";
    }
    return ($xz_offset, $yz_offset);
}

sub rotate3D_z {
    my ($self, $x, $y, $z, $n_A, $n_B) = @_;

    my $n_z = - ($x * sin($n_B)) + ($y * sin($n_A) * cos($n_B)) + ($z * cos($n_A) * cos($n_B));

    return $n_z;
}

sub support_levels {

    my ($self, $tilt_level, $angles_ref) = @_;
    
    my ($anglexz, $angleyz, $anglezx, $anglezy) = @{$angles_ref};

    #Can only manage one angle at a time

    #ANGLEXZ and ANGLEZX shouldn't be different from 0 at the same time, but careful

    my $u_level = $tilt_level;

    my $n_length = $BED_LENGTH / 2.0;
    my $z_level = $self->rotate3D_z($n_length, $BED_WIDTH, 0, -$anglezy + $angleyz, -$anglexz + $anglezx);

    my $v_level = $self->rotate3D_z($BED_LENGTH, 0, 0, -$anglezy + $angleyz, -$anglexz + $anglezx);
    my $uv_level = $u_level - $v_level;
    my $uz_level = $u_level - $z_level;

    print "SUPPORT LEVELS\n";
    print Dumper($u_level, $uv_level, $uz_level);

    return ($u_level, $uz_level, $uv_level);

}

sub add_print {
    my ($self, $object, $index) = @_;
    my $config_object = $object->config;
    if (!$STRENGHT_TEST){
        if ($index == 0){
            $config_object->set('tilt_enable', 1);
            $config_object->set('support_material', 0);
        }
        else {
            my $tilt_cut = $tilt_cuts_array[$index - 1];
            my @levels = @{$tilt_levels{$tilt_cut}};
            my ($u_level, $z_level, $v_level) = @levels;
            my $point_levels = Slic3r::Pointf3->new($u_level, $v_level, $z_level);

            $config_object->set('support_material', 0);
            $config_object->set('tilt_enable', 1);
            print "PRINT LEVELS\n";
            print Dumper(@levels);
            $config_object->set('tilt_levels', $point_levels);
            $config_object->set('sequential_print_priority', $index);
        }
    }
    else {
        if ($index == (scalar @{$model->objects} - 1)){
            $config_object->set('tilt_enable', 1);
            $config_object->set('support_material', 0);
        }
        else {
            my $tilt_cut = $tilt_cuts_array[$index];
            my @levels = @{$tilt_levels{$tilt_cut}};
            my ($u_level, $z_level, $v_level) = @levels;
            my $point_levels = Slic3r::Pointf3->new($u_level, $v_level, $z_level);

            $config_object->set('support_material', 0);
            $config_object->set('tilt_enable', 1);
            print "PRINT LEVELS\n";
            print Dumper(@levels);
            $config_object->set('tilt_levels', $point_levels);
            $config_object->set('sequential_print_priority', (scalar @{$model->objects} - 1) - $index);
        }
    }
}

1;