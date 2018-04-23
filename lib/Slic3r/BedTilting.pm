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
our @prints;
our @models;
our @configs;
our %tilt_angles;
our @tilt_cuts_array;
our %tilt_levels;

sub clean_values {
    my ($self) = @_;
    undef %origin;
    undef @prints;
    undef @models;
    undef @configs;
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
    $model->scale_xyz(Slic3r::Pointf3->new(2.0,2.0,2.0));
    $model->rotate(deg2rad(-180), Z);
    my $transl = Slic3r::Pointf3->new($object_pos_x - $bed_offset_x, $object_pos_y - $bed_offset_y, 0);
    $model->translate(@$transl);

    my $bb_mod = $model->bounding_box;

    if (!($bb_mod->x_max < $BED_LENGTH && $bb_mod->x_min > 0) or !($bb_mod->y_max < $BED_WIDTH && $bb_mod->y_min > 0)){
        print "IMPOSSIBLE OFFSET\n";
        return;
    }

    #Print instance of the original model
    my $print = Slic3r::Print->new;
    push @prints, $print;
    $prints[0]->add_model_object($model);

    #Apply config and validate print of the original model
    my $config = $self->{config};
    $config->set('support_material', 1);
    eval {
        # this will throw errors if config is not valid
        $config->validate;
        $prints[0]->apply_config($config);
        $prints[0]->validate;
        Slic3r::debugf "apply config ok\n";
    };

    #Start tilt process in the print instance
    my @result = $prints[0]->tilt_process;
    if ($result[0] == 0){
        $self->support_material_print(0,0);
    }

    my $iter_result = 0;

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

        # print "TEST\n";
        # print Dumper($offset_x, $offset_y);
        # print Dumper($bb_mod->x_min);
        # print Dumper($bb_mod->x_max);
        # print Dumper($bb_mod->y_min);
        # print Dumper($bb_mod->y_max);
        # print Dumper($bb_mod->z_min);
        # print Dumper($bb_mod->z_max);
        # my $print_test = Slic3r::Print->new;
        # $print_test->add_model_object($model);

        my $offset_z = 0;
        my @vector;

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

        # my $ball_translation = Slic3r::Pointf3->new(4.428, 2.16 ,0);
        # $model->translate(@$ball_translation);


        $bb_mod = $model->bounding_box;



        $var_offset = $model->instances->[0]->offset->arrayref;
        $offset_x = $var_offset->[0];
        $offset_y = $var_offset->[1];
        $bb_mod = $model->bounding_box;

        $tilt_cut = $tilt_cuts_array[$iter_result];

        if ($bb_mod->z_min + $tilt_cut < 0){
            print "BBMOD + TILTCUT <0\n";
            if ($anglezy){
                # +0.5 for security
                my $zy_offset = (- ($bb_mod->z_min + $tilt_cut) + 0.5 ) / sin(-$anglezy);
                print "change y pos by $zy_offset\n";
                return $self->process_bed_tilt($offset_x, $offset_y + $zy_offset);
            }
            if ($anglezx){
                # +0.5 so that u_level cannot be higher than 0.5
                my $zx_offset = (- ($bb_mod->z_min + $tilt_cut) + 0.5) / sin(-$anglezx);
                print "change x pos by $zx_offset\n";
                return $self->process_bed_tilt($zx_offset + $offset_x, $offset_y);
            }
        }

        my $new_model = $model->cut(Z, $tilt_cut + $bb_mod->z_min);

        $tilt_cuts_array[$iter_result] += $bb_mod->z_min;

        $tilt_angles{$tilt_cuts_array[$iter_result]} = delete $tilt_angles{$tilt_cut};

        my ($upper_object, $lower_object) = @{$new_model->objects};

        $model = Slic3r::Model->new;
        push @models, $model;
        $models[$iter_result + 1]->add_object($lower_object);
        my $lower_obj = $models[$iter_result + 1]->objects->[0];
        $bb_mod = $lower_obj->bounding_box;

        $var_offset = $lower_obj->instances->[0]->offset->arrayref;
        $offset_x = $var_offset->[0];
        $offset_y = $var_offset->[1];
        #$offset_z = $z_origin;


        # $ball_translation = Slic3r::Pointf3->new(-4.428, -2.16 ,0);
        # $lower_obj->translate(@$ball_translation);

        $lower_obj->rotate($anglexz, Y);
        $lower_obj->rotate(-$anglezx, Y);
        $lower_obj->rotate($anglezy, X);
        $lower_obj->rotate(-$angleyz, X);


        $bb_mod = $lower_obj->bounding_box;
        $var_offset = $lower_obj->instances->[0]->offset->arrayref;
        $offset_x = $var_offset->[0];
        $offset_y = $var_offset->[1];
      

        $model = Slic3r::Model->new;
        push @models, $model;



        $models[$iter_result + 2]->add_object($upper_object);
        my $upper_obj = $models[$iter_result + 2]->objects->[0];
        $bb_mod = $upper_obj->bounding_box;


        my ($u_level, $z_level, $v_level) = $self->support_levels($tilt_cuts_array[$iter_result], $BED_LENGTH, $BED_WIDTH, $BED_HEIGHT);

        my @levels;

        push @levels, $u_level;
        push @levels, $z_level;
        push @levels, $v_level;

        if ($anglexz){
            if ($v_level < 0){
                # +0.5 so that v_level cannot be higher than 0.5
                my $xz_offset = - (-$v_level + 0.5 ) / sin(-$anglexz);
                print "change x pos by $xz_offset\n";
                return $self->process_bed_tilt($xz_offset + $offset_x, $offset_y);
            }
        }
        if ($angleyz){
            if ($z_level < 0){
                # +0.5 so that v_level cannot be higher than 0.5
                my $yz_offset = (-$z_level + 0.5 ) / sin($angleyz);
                print "change y pos by $yz_offset\n";
                return $self->process_bed_tilt($offset_x, $offset_y + $yz_offset);
            }
        }

        $tilt_levels{$tilt_cuts_array[$iter_result]} = [ @levels ];

        #Add models in the print array

        if ($iter_result == 0){
            $self->add_print($models[$iter_result + 1]->objects->[0], $iter_result + 1);
        }

        my $py_bin = "nonlinear-solver.py";
        my $tilt_offset_x = 0;
        my $tilt_offset_y = 0;

        open(my $py, "|-", "python", $py_bin, @levels) or die "Cannot run Python script: $!";
        while (<$py>){
            $tilt_offset_x = $py;
            $tilt_offset_y = $py;
        }
        close($py);

        my $tilt_offset = Slic3r::Pointf3->new($tilt_offset_x, $tilt_offset_y, 0);
        $models[$iter_result + 2]->objects->[0]->translate(@$tilt_offset);
        $self->add_print($models[$iter_result + 2]->objects->[0], $iter_result + 2);

        #Enable support material to detect further need of tilt on the upper part

        #$self->support_material_print($iter_result + 2, 1);
        #@result = $prints[$iter_result + 2]->tilt_process;

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
    return @prints;
}

sub rotate3D {
    my ($self, $x, $y, $z, $n_A, $n_B) = @_;


    my $n_x = ($x * cos($n_B)) + ($z * sin($n_B));
    my $n_y = ($x * sin($n_A) * sin($n_B)) + ($y * cos($n_A)) - ($z * sin($n_A) * cos($n_B));
    my $n_z = - ($x * cos($n_A) * sin($n_B)) + ($y * sin($n_A)) + ($z * cos($n_A) * cos($n_B));

    print Dumper($n_x, $n_y, $n_z);

    return ($n_x, $n_y, $n_z);
}

sub support_levels {

    my ($self, $tilt_level, $length, $width, $height, $bed_offset_x, $bed_offset_y) = @_;

    my @angles = @{$tilt_angles{$tilt_level}};
    
    my $anglexz = shift @angles;
    my $angleyz = shift @angles;
    my $anglezx = shift @angles;
    my $anglezy = shift @angles;

    #Can only manage one angle at a time

    #ANGLEXZ and ANGLEZX shouldn't be different from 0 at the same time, but careful

    #The first operation is useful since the extruder (0,0) is (16,40) of the bed

    my @levels = $self->rotate3D(0, 0, 0, -$anglezy + $angleyz, -$anglexz + $anglezx);
    my $u_level = pop @levels;
    print Dumper($u_level);
    $u_level += $tilt_level;

    my $n_length = $length / 2.0;
    @levels = $self->rotate3D($n_length, $width, 0, -$anglezy + $angleyz, -$anglexz + $anglezx);
    my $z_level = pop @levels;

    @levels = $self->rotate3D($length, 0, 0, -$anglezy + $angleyz, -$anglexz + $anglezx);
    my $v_level = pop @levels;
    my $uv_level = $u_level - $v_level;
    my $uz_level = $u_level - $z_level;

    print "SUPPORT LEVELS\n";
    print Dumper($tilt_level, $u_level, $uv_level, $uz_level);

    return ($u_level, $uz_level, $uv_level);

}

sub add_print {
    my ($self, $object, $index) = @_;

    my $print = Slic3r::Print->new;
    push @prints, $print;

    my $config = $self->{config};
    if ($index == 1){
        $config->set('skirts', 1);
        $config->set('tilt_enable', 0);
        $config->set('support_material', 0);
    }
    else {
        my $tilt_cut = $tilt_cuts_array[$index - 2];

        my @levels = @{$tilt_levels{$tilt_cut}};

        my $u_level = shift @levels;
        my $z_level = shift @levels;
        my $v_level = shift @levels;

        my $point_levels = Slic3r::Pointf3->new($u_level, $v_level, $z_level);

        my $config = $self->{config};

        $config->set('skirts', 0);
        $config->set('support_material', 0);
        $config->set('tilt_enable', $tilt_cut);
        $config->set('tilt_levels', $point_levels);
    }

    $prints[$index]->add_model_object($object);

    eval {
        # this will throw errors if config is not valid
        $config->validate;
        $prints[$index]->apply_config($config);
        $prints[$index]->validate;
    };
}

sub support_material_print {
    my ($self, $index, $val) = @_;

    my $config = $models[$index]->objects->[0]->config;
    $config->set('support_material', $val);

    eval {
        # this will throw errors if config is not valid
        $config->validate;
        $prints[$index]->apply_config($config);
        $prints[$index]->validate;
    };

}


1;