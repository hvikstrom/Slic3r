package Slic3r::BedTilting;
use strict;
use warnings;

use Moo;
use Slic3r::Geometry qw(X Y Z MIN MAX scale unscale deg2rad rad2deg);
use Data::Dumper;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(printMessage);

has '_model' => (is => 'rw', required => 1);
has '_config' => (is => 'rw', required => 1);


our $BED_LENGTH = 770.0;
our $BED_WIDTH = 505.0;
our $BED_HEIGHT = 200.0;
our $TILT_GCODE = 1;
our %origin;
our $print;
our @models;
our %tilt_angles;
our @tilt_cuts_array;
our %tilt_levels;
our $retry;

sub clean_values {
    my ($self) = @_;
    undef %origin;
    undef $print;
    undef @models;
    undef %tilt_angles;
    undef @tilt_cuts_array;
    undef %tilt_levels;
}

sub process_bed_tilt {
    my ($self, $n_offset_x, $n_offset_y) = @_;

    $self->{config} = $self->_config;

    $self->clean_values;

    my $model;
    my $model_offset;

    $print = Slic3r::Print->new;
    $retry //= 0;
    if ($retry > 2){
        print "Too many retry\n";
        return 0;
    }
    my $bed_offset_x = -16.1;
    my $bed_offset_y = -37.3;
    my $object_pos_x = 616.1;
    my $object_pos_y = 87.3;

    #Stores the model

    $model = Slic3r::Model->new;
    push @models, $model;
    $models[0]->add_object($self->_model->objects->[0]);
    $model = $models[0]->objects->[0];
    $model_offset = Slic3r::Pointf->new(0 + $bed_offset_x, 0 + $bed_offset_y);

    if (defined $n_offset_x and defined $n_offset_y){
        $object_pos_x = -($bed_offset_x - $n_offset_x) + $object_pos_x;
        $object_pos_y = -($bed_offset_y - $n_offset_y) + $object_pos_y;
    }
    
    $TILT_GCODE = 1;

    #Set the offset which will influence the viability of the tilting process

    $model->instances->[0]->set_offset($model_offset);

    #Scale the model just for the example
    #$model->scale_xyz(Slic3r::Pointf3->new(1.5,1.5,1.5));
    #$model->rotate(deg2rad(45), Z);
    my $transl = Slic3r::Pointf3->new($object_pos_x - $bed_offset_x, $object_pos_y - $bed_offset_y, 0);
    $model->translate(@$transl);

    my $bb_mod = $model->bounding_box;

    if (!($bb_mod->x_max < $BED_LENGTH && $bb_mod->x_min > 0) or !($bb_mod->y_max < $BED_WIDTH && $bb_mod->y_min > 0)){
        print "IMPOSSIBLE OFFSET\n";
        return 0;
    }

    #Print instance of the original model
    $print->add_model_object($model);

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

    #Start tilt process in the print instance
    my @result = $print->tilt_process;
    if ($result[0] == 0){
        $self->support_material_print(0,0);
    }

    my $iter_result = 0;
    $print->clear_objects;

    while ($result[0] != 0 && $iter_result < 1){

        print "ITERATION NUMBER $iter_result\n";
        #Should contain (TILT_LEVEL, ANGLEXZ, ANGLEYZ, ANGLEZX, ANGLEZY)
        print "RESULT PLATER @result\n";
        my $index = 0;
        my $tilt_cut = 0;
        my @angles;

        $tilt_cut = shift @result;
        push @tilt_cuts_array, $tilt_cut;
        @angles = @result;
        $tilt_angles{$tilt_cut} = [ @angles ];

        my $anglexz = shift @angles;
        my $angleyz = shift @angles;
        my $anglezx = shift @angles;
        my $anglezy = shift @angles;

        if ($iter_result == 0){
            $model = $models[$iter_result]->objects->[0];
        }
        else {
            $model = $models[$iter_result + 1]->objects->[0];
        }

        my $var_offset = $model->instances->[0]->offset->arrayref;
        my $offset_x = $var_offset->[0];
        my $offset_y = $var_offset->[1];

        $bb_mod = $model->bounding_box;

        print "TEST MODEL\n";
        print Dumper($offset_x, $offset_y);
        print Dumper($bb_mod->x_min);
        print Dumper($bb_mod->x_max);
        print Dumper($bb_mod->y_min);
        print Dumper($bb_mod->y_max);
        print Dumper($bb_mod->z_min);
        print Dumper($bb_mod->z_max);
        # my $print_test = Slic3r::Print->new;
        # $print_test->add_model_object($model);

        my $offset_z = 0;
        my @vector;


        my $ball_translation = Slic3r::Pointf3->new(0,0,19);
        $model->translate(@$ball_translation);

        #IDEALLY ROTATE HAS TO DO MULTIPLE ROTATION AT THE SAME TIME

        if ($anglexz != 0){
            print "ROTATION AROUND Y BY -$anglexz\n";
            $model->rotate(-$anglexz, Y);
        }
        if ($angleyz != 0){
            print "ROTATION AROUND X BY $angleyz\n";
            $model->rotate($angleyz, X);
        }
        if ($anglezx != 0){
            print "ROTATION AROUND Y BY $anglezx\n";
            $model->rotate($anglezx, Y);
        }
        if ($anglezy != 0){
            print "ROTATION AROUND X BY -$anglezy\n";
            $model->rotate(-$anglezy, X);
        }

        $bb_mod = $model->bounding_box;



        $var_offset = $model->instances->[0]->offset->arrayref;
        $offset_x = $var_offset->[0];
        $offset_y = $var_offset->[1];
        $bb_mod = $model->bounding_box;

        $tilt_cut = $tilt_cuts_array[$iter_result];

        my @offsets = $self->check_viability(\@{$tilt_angles{$tilt_cut}}, $bb_mod, $tilt_cut);
        if (scalar @offsets == 1){
            print "Impossible tilt\n";
            return 0;
        }
        else {
            my $xz_offset = shift @offsets;
            my $yz_offset = shift @offsets;
            my $zx_offset = shift @offsets;
            my $zy_offset = shift @offsets;

            if ($xz_offset or $yz_offset or $zx_offset or $zy_offset){
                $retry += 1;
                return $self->process_bed_tilt($offset_x + $xz_offset + $zx_offset, $offset_y + $yz_offset + $zy_offset);
            }
        }

        $tilt_cuts_array[$iter_result] += $bb_mod->z_min - 19;

        $tilt_angles{$tilt_cuts_array[$iter_result]} = delete $tilt_angles{$tilt_cut};

        $tilt_cut = $tilt_cuts_array[$iter_result];

        my ($u_level, $z_level, $v_level) = $self->support_levels($tilt_cuts_array[$iter_result]);

        my @levels;

        push @levels, $u_level;
        push @levels, $z_level;
        push @levels, $v_level;
        
        @offsets = $self->check_levels(\@levels, \@{$tilt_angles{$tilt_cut}});
        if ($offsets[0] or $offsets[1]){
            $retry += 1;
            return $self->process_bed_tilt($offset_x + $offsets[0], $offset_y + $offsets[1]);
        }

        my $new_model = $model->cut(Z, $tilt_cut + 19);

        my ($upper_object, $lower_object) = @{$new_model->objects};

        $model = Slic3r::Model->new;
        push @models, $model;
        $models[$iter_result + 1]->add_object($lower_object);
        my $lower_obj = $models[$iter_result + 1]->objects->[0];
        $bb_mod = $lower_obj->bounding_box;

        $var_offset = $lower_obj->instances->[0]->offset->arrayref;
        $offset_x = $var_offset->[0];
        $offset_y = $var_offset->[1];


        if ($anglezy != 0){
            print "ROTATION AROUND X BY $anglezy\n";
            $lower_obj->rotate($anglezy, X);
        }
        if ($anglezx != 0){
            print "ROTATION AROUND Y BY -$anglezx\n";
            $lower_obj->rotate(-$anglezx, Y);
        }
        if ($angleyz != 0){
            print "ROTATION AROUND X BY -$angleyz\n";
            $lower_obj->rotate(-$angleyz, X);
        }
        if ($anglexz != 0){
            print "ROTATION AROUND Y BY $anglexz\n";
            $lower_obj->rotate($anglexz, Y);
        }

        $bb_mod = $lower_obj->bounding_box;
        $var_offset = $lower_obj->instances->[0]->offset->arrayref;
        $offset_x = $var_offset->[0];
        $offset_y = $var_offset->[1];
      

        $model = Slic3r::Model->new;
        push @models, $model;



        $models[$iter_result + 2]->add_object($upper_object);
        my $upper_obj = $models[$iter_result + 2]->objects->[0];
        $bb_mod = $upper_obj->bounding_box;



        $ball_translation = Slic3r::Pointf3->new(0, 0 ,-19);
        print Dumper(@$ball_translation);
        $models[$iter_result + 2]->objects->[0]->translate(@$ball_translation);
        $models[$iter_result + 1]->objects->[0]->translate(@$ball_translation);
        $tilt_levels{$tilt_cuts_array[$iter_result]} = [ @levels ];

        #Add models in the print array

        if ($iter_result == 0){

            $self->add_print($models[$iter_result + 1]->objects->[0], $iter_result + 1);
        }
        my $tilt_offset_x = 0;
        my $tilt_offset_y = 0;

        print Dumper(@levels);

        my @cmd = qw(python nonlinear-solver.py);
        push @cmd, @levels;

        use IPC::Run3;

        run3 [@cmd], undef, \my @out, \my $err;

        $tilt_offset_x = shift @out;
        $tilt_offset_y = shift @out;

        my $tilt_offset = Slic3r::Pointf3->new($tilt_offset_x, $tilt_offset_y, 0);
        print Dumper(@$tilt_offset);
        $models[$iter_result + 2]->objects->[0]->translate(@$tilt_offset);

        #Enable support material to detect further need of tilt on the upper part

        # $self->support_material_print($iter_result + 2, 1);
        $self->add_print($models[$iter_result + 2]->objects->[0], $iter_result + 2);
        # @result = $prints[$iter_result + 2]->tilt_process;

        print "LOWER TEST\n";
        $bb_mod = $models[$iter_result + 1]->objects->[0]->bounding_box;
        $var_offset = $models[$iter_result + 1]->objects->[0]->instances->[0]->offset->arrayref;
        $offset_x = $var_offset->[0];
        $offset_y = $var_offset->[1];
        print Dumper($offset_x, $offset_y);
        print Dumper($bb_mod->x_min);
        print Dumper($bb_mod->x_max);
        print Dumper($bb_mod->y_min);
        print Dumper($bb_mod->y_max);
        print Dumper($bb_mod->z_min);
        print Dumper($bb_mod->z_max);


        print "UPPER TEST\n";
        $bb_mod = $models[$iter_result + 2]->objects->[0]->bounding_box;
        $var_offset = $models[$iter_result + 2]->objects->[0]->instances->[0]->offset->arrayref;
        $offset_x = $var_offset->[0];
        $offset_y = $var_offset->[1];
        print Dumper($offset_x, $offset_y);
        print Dumper($bb_mod->x_min);
        print Dumper($bb_mod->x_max);
        print Dumper($bb_mod->y_min);
        print Dumper($bb_mod->y_max);
        print Dumper($bb_mod->z_min);
        print Dumper($bb_mod->z_max);

        $iter_result += 1;
    }

    print "TILT FINISHED\n";
    return $print;
}

sub check_viability {
    my ($self, $angles_ref, $bb_mod, $tilt_cut) = @_;
    my @angles = @{$angles_ref};

    my $anglexz = shift @angles;
    my $angleyz = shift @angles;
    my $anglezx = shift @angles;
    my $anglezy = shift @angles;

    my $zy_offset = 0;
    my $zx_offset = 0;
    my $yz_offset = 0;
    my $xz_offset = 0;

    return (0) if ((abs($bb_mod->z_max - $bb_mod->z_min)) > $BED_HEIGHT);

    if ($anglezy && (($bb_mod->z_min + $tilt_cut) < 0)){
        # +0.5 for security
        $zy_offset = (- ($bb_mod->z_min + $tilt_cut) + 0.5 ) / sin(-$anglezy);
        print "change y pos by $zy_offset\n";
    }
    if ($anglezx && (($bb_mod->z_min + $tilt_cut) < 0)){
        # +0.5 so that u_level cannot be higher than 0.5
        $zx_offset = (- ($bb_mod->z_min + $tilt_cut) + 0.5) / sin(-$anglezx);
        print "change x pos by $zx_offset\n";
    }
    if ($angleyz && ($bb_mod->z_max > $BED_HEIGHT)){
        $yz_offset = (($bb_mod->z_max - $BED_HEIGHT) + 0.5 ) / sin(-$angleyz);
        print "change y pos by $yz_offset\n";
    }
    if ($anglexz && ($bb_mod->z_max > $BED_HEIGHT)){
        $xz_offset = (($bb_mod->z_max - $BED_HEIGHT) + 0.5) / sin(-$anglezx);
        print "change x pos by $zx_offset\n";
    }

    return ($xz_offset, $yz_offset, $zx_offset, $zy_offset);
}

sub check_levels {
    my ($self, $levels_ref, $angles_ref) = @_;

    my @levels = @{$levels_ref};
    my @angles = @{$angles_ref};

    my $anglexz = shift @angles;
    my $angleyz = shift @angles;
    my $anglezx = shift @angles;
    my $anglezy = shift @angles;


    my $u_level = shift @levels;
    my $z_level = shift @levels;
    my $v_level = shift @levels;

    my $xz_offset = 0;
    my $yz_offset = 0;

    if ($angleyz && $z_level < 0){
        # +0.5 so that v_level cannot be higher than 0.5
        $yz_offset = (-$z_level + 0.5 ) / sin($angleyz);
        print "change y pos by $yz_offset\n";
    }
    if ($anglexz && $v_level < 0){
        # +0.5 so that v_level cannot be higher than 0.5
        $xz_offset = - (-$v_level + 0.5 ) / sin(-$anglexz);
        print "change x pos by $xz_offset\n";
    }

    return ($xz_offset, $yz_offset);
}

sub rotate3D {
    my ($self, $x, $y, $z, $n_A, $n_B) = @_;


    my $n_x = ($x * cos($n_B)) + ($z * sin($n_B));
    my $n_y = ($x * sin($n_A) * sin($n_B)) + ($y * cos($n_A)) - ($z * sin($n_A) * cos($n_B));
    my $n_z = - ($x * cos($n_A) * sin($n_B)) + ($y * sin($n_A)) + ($z * cos($n_A) * cos($n_B));

    return ($n_x, $n_y, $n_z);
}

sub support_levels {

    my ($self, $tilt_level) = @_;

    my @angles = @{$tilt_angles{$tilt_level}};
    
    my $anglexz = shift @angles;
    my $angleyz = shift @angles;
    my $anglezx = shift @angles;
    my $anglezy = shift @angles;

    #Can only manage one angle at a time

    #ANGLEXZ and ANGLEZX shouldn't be different from 0 at the same time, but careful

    my $u_level = $tilt_level;

    my $n_length = $BED_LENGTH / 2.0;
    my @levels = $self->rotate3D($n_length, $BED_WIDTH, 0, -$anglezy + $angleyz, -$anglexz + $anglezx);
    my $z_level = pop @levels;

    @levels = $self->rotate3D($BED_LENGTH, 0, 0, -$anglezy + $angleyz, -$anglexz + $anglezx);
    my $v_level = pop @levels;
    my $uv_level = $u_level - $v_level;
    my $uz_level = $u_level - $z_level;

    print "SUPPORT LEVELS\n";
    print Dumper($u_level, $uv_level, $uz_level);

    return ($u_level, $uz_level, $uv_level);

}

sub add_print {
    my ($self, $object, $index) = @_;
    my $config = $self->{config};
    my $config_object = $object->config;
    if ($index == 1){
        $config->set('skirts', 1);
        $config->set('print_tilt', 1);
        $config->set('initial_z_tilt', 10.0);
        $config_object->set('tilt_enable', 1);
        $config_object->set('support_material', 0);

        eval {
            # this will throw errors if config is not valid
            $config->validate;
            $print->apply_config($config);
            $print->validate;
        };
    }
    else {
        my $tilt_cut = $tilt_cuts_array[$index - 2];

        my @levels = @{$tilt_levels{$tilt_cut}};

        my $u_level = shift @levels;
        my $z_level = shift @levels;
        my $v_level = shift @levels;

        my $point_levels = Slic3r::Pointf3->new($u_level, $v_level, $z_level);

        $config_object->set('support_material', 0);
        $config_object->set('tilt_enable', 1);
        $config_object->set('tilt_levels', $point_levels);
        $config_object->set('sequential_print_priority', $index);
    }

    $print->add_model_object($object);
}

sub support_material_print {
    my ($self, $index, $val) = @_;
    my $config = $models[$index]->objects->[0]->config;
    $config->set('support_material', $val);
}


1;