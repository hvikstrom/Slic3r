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
our $model;
our %tilt_angles;
our @tilt_cuts_array;
our %tilt_levels;
our $retry;

sub clean_values {
    my ($self) = @_;
    undef %origin;
    undef $print;
    undef $model;
    undef %tilt_angles;
    undef @tilt_cuts_array;
    undef %tilt_levels;
}

sub process_bed_tilt {
    my ($self) = @_;

    $self->{config} = $self->_config;

    $self->clean_values;

    $print = Slic3r::Print->new;
    $retry //= 0;
    if ($retry > 2){
        print "Too many retry\n";
        $retry = 0;
        return 0;
    }

    my $origin_offset = $self->{config}->get('origin_offset');#Slic3r::Pointf3->new(-16.1,-37.3,0);#
    #Stores the model

    #MAKE SURE TO USE COPY

    $model = Slic3r::Model->new;
    $model->add_object($self->_model->objects->[0]);
    my $original_model_object = $model->objects->[0];
    my $object_pos = $self->{config}->get('stl_initial_position');#Slic3r::Pointf3->new(616.1,87.3,0);#
    #print Dumper(@array_pos);
    my $model_offset = Slic3r::Pointf->new(0 + $origin_offset->x, 0 + $origin_offset->y);
    #print Dumper($object_pos.x);

    $TILT_GCODE = 1;

    #Set the offset which will influence the viability of the tilting process

    $original_model_object->instances->[0]->set_offset($model_offset);

    #Scale the model just for the example
    #$original_model_object->scale_xyz(Slic3r::Pointf3->new(1.5,1.5,1.5));
    $original_model_object->rotate(deg2rad(45), Z);
    my $move_in_stl = Slic3r::Pointf3->new($object_pos->x - $origin_offset->x, $object_pos->y - $origin_offset->y, 0);
    $original_model_object->translate(@$move_in_stl);

    my $bb_mod = $original_model_object->bounding_box;

    if (!($bb_mod->x_max < $BED_LENGTH && $bb_mod->x_min > 0) or !($bb_mod->y_max < $BED_WIDTH && $bb_mod->y_min > 0)){
        print Dumper($bb_mod->x_max, $bb_mod->x_min, $bb_mod->y_max, $bb_mod->y_min);
        print "IMPOSSIBLE OFFSET\n";
        return 0;
    }

    #Print instance of the original model
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

    #Start tilt process in the print instance
    my @result = $print->tilt_process;
    if ($result[0] == 0){
        return $print;
    }

    my $iter_result = 0;
    $print->clear_objects;

    while ($result[0] != 0 && $result[0] != -1 && $iter_result < 1){

        print "ITERATION NUMBER $iter_result\n";
        #Should contain (TILT_LEVEL, ANGLEXZ, ANGLEYZ, ANGLEZX, ANGLEZY)
        print "RESULT PLATER @result\n";
        my $index = 0;
        my $tilt_cut = 0;
        my @angles;
        my $current_model_object;
        my $last_id = scalar @{$model->objects} - 1;


        $tilt_cut = shift @result;
        push @tilt_cuts_array, $tilt_cut;
        @angles = @result;
        $angles[0] -= 0.2;
        $angles[3] -= 0.2;
        $tilt_angles{$tilt_cut} = [ @angles ];

        my $anglexz = shift @angles;
        my $angleyz = shift @angles;
        my $anglezx = shift @angles;
        my $anglezy = shift @angles;

        $current_model_object = $model->objects->[$last_id];


        my $var_offset = $current_model_object->instances->[0]->offset->arrayref;
        my $offset_x = $var_offset->[0];
        my $offset_y = $var_offset->[1];

        $bb_mod = $current_model_object->bounding_box;

        print "TEST MODEL\n";
        $self->print_dumper($offset_x, $offset_y, $bb_mod);

        my $z_translation = Slic3r::Pointf3->new(0,0,-$origin_offset->z);
        $current_model_object->translate(@$z_translation);

        print "Z TRANSLATION\n";

        $var_offset = $current_model_object->instances->[0]->offset->arrayref;
        $offset_x = $var_offset->[0];
        $offset_y = $var_offset->[1];
        $bb_mod = $current_model_object->bounding_box;

        #$self->print_dumper($offset_x, $offset_y, $bb_mod);

        #IDEALLY ROTATE HAS TO DO MULTIPLE ROTATION AT THE SAME TIME


        print "ROTATION YZ $angleyz -$anglezy ZX $anglezx -$anglexz\n";
        $current_model_object->rotate3D($angleyz - $anglezy, $anglezx - $anglexz, 0,0);

        $bb_mod = $current_model_object->bounding_box;



        $var_offset = $current_model_object->instances->[0]->offset->arrayref;
        $offset_x = $var_offset->[0];
        $offset_y = $var_offset->[1];
        $bb_mod = $current_model_object->bounding_box;

        #$self->print_dumper($offset_x, $offset_y, $bb_mod);

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
                $object_pos = $self->_config->get('stl_initial_position');
                my $new_object_pos = Slic3r::Pointf3->new($object_pos->x + $xz_offset + $zx_offset, $object_pos->y + $yz_offset + $zy_offset, $object_pos->z);
                $self->_config->set('stl_initial_position', $new_object_pos);
                return $self->process_bed_tilt;
            }
        }

        $tilt_cuts_array[$iter_result] += $bb_mod->z_min;

        $tilt_angles{$tilt_cuts_array[$iter_result]} = delete $tilt_angles{$tilt_cut};

        $tilt_cut = $tilt_cuts_array[$iter_result];

        print Dumper($tilt_cut);

        my ($u_level, $z_level, $v_level) = $self->support_levels($tilt_cuts_array[$iter_result]);

        my @levels;

        push @levels, $u_level;
        push @levels, $z_level;
        push @levels, $v_level;
        
        @offsets = $self->check_levels(\@levels, \@{$tilt_angles{$tilt_cut}});
        if ($offsets[0] or $offsets[1]){
            $retry += 1;
            $object_pos = $self->_config->get('stl_initial_position');
            my $new_object_pos = Slic3r::Pointf3->new($object_pos->x + $offsets[0], $object_pos->y + $offsets[1], $object_pos->z);
            $self->_config->set('stl_initial_position', $new_object_pos);
            return $self->process_bed_tilt;
        }

        my $new_model = $current_model_object->cut(Z, $tilt_cut);

        my ($upper_object, $lower_object) = @{$new_model->objects};

        $model->delete_object($last_id);

        $model->add_object($lower_object);
        $lower_object = $model->objects->[$last_id];
        $bb_mod = $lower_object->bounding_box;

        $var_offset = $lower_object->instances->[0]->offset->arrayref;
        $offset_x = $var_offset->[0];
        $offset_y = $var_offset->[1];

        print "ROTATION YZ -$angleyz $anglezy ZX -$anglezx $anglexz\n";
        $lower_object->rotate3D(- $angleyz + $anglezy, - $anglezx + $anglexz, 0,1);

        $bb_mod = $lower_object->bounding_box;
        $var_offset = $lower_object->instances->[0]->offset->arrayref;
        $offset_x = $var_offset->[0];
        $offset_y = $var_offset->[1];

        #$self->print_dumper($offset_x, $offset_y, $bb_mod);

        $model->add_object($upper_object);
        $upper_object = $model->objects->[$last_id + 1];
        $bb_mod = $upper_object->bounding_box;



        $z_translation = Slic3r::Pointf3->new(0, 0 , $origin_offset->z);
        $model->objects->[$last_id + 1]->translate(@$z_translation);
        $model->objects->[$last_id]->translate(@$z_translation);
        $tilt_levels{$tilt_cuts_array[$iter_result]} = [ @levels ];

        my $tilt_offset_x = 0;
        my $tilt_offset_y = 0;

        #print Dumper(@levels);

        my @cmd = qw(python nonlinear-solver.py);
        push @cmd, @levels;

        use IPC::Run3;

        run3 [@cmd], undef, \my @out, \my $err;

        $tilt_offset_x = shift @out;
        $tilt_offset_y = shift @out;

        my $tilt_offset = Slic3r::Pointf3->new($tilt_offset_x, $tilt_offset_y, 0);
        #print Dumper(@$tilt_offset);
        $model->objects->[$last_id + 1]->translate(@$tilt_offset);

        #Enable support material to detect further need of tilt on the upper part

        $self->support_material_print($last_id + 1, 1,$model);
        print Dumper($model->objects->[$last_id + 1]->config->get('support_material'));
        $print->add_model_object($model->objects->[$last_id + 1]);
        @result = $print->tilt_process;

        $iter_result += 1;
    }

    print "TILT FINISHED\n";
    $print->clear_objects;
    my $index = 0;
    for my $iter_object (@{$model->objects}){
        my $bb_mod = $iter_object->bounding_box;
        my $var_offset = $iter_object->instances->[0]->offset->arrayref;
        my $offset_x = $var_offset->[0];
        my $offset_y = $var_offset->[1];
        print "OBJECT $index\n";
        my @angle_tilt = $tilt_angles{$tilt_cuts_array[$index]} if (defined $tilt_cuts_array[$index]);
        print Dumper(@angle_tilt) if (defined $tilt_cuts_array[$index]);
        $self->print_dumper($offset_x, $offset_y, $bb_mod);
        $self->add_print($iter_object, $index);
        $index += 1;
    }
    $retry = 0;
    return $print;
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
        print Dumper($bb_mod->z_min, $tilt_cut);
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
        print Dumper($bb_mod->z_max, $BED_HEIGHT);
        $xz_offset = (($bb_mod->z_max - $BED_HEIGHT) + 0.5) / sin(-$anglexz);
        print "change x pos by $xz_offset\n";
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
    my $config = $self->{config};
    my $config_object = $object->config;
    if ($index == 0){
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
        my $tilt_cut = $tilt_cuts_array[$index - 1];

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
    my ($self, $index, $val, $model) = @_;
    my $config = $model->objects->[$index]->config;
    $config->set('support_material', $val);
}


1;