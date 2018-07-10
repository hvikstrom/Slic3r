package Slic3r::GUI::Tilt3DConsole;

use strict;
use warnings;
use utf8;

use List::Util qw(min max);
use Slic3r::Geometry qw(PI X Y unscale);
use Wx qw(:dialog :id :misc :sizer :choicebook wxTAB_TRAVERSAL);
use Wx::Event qw(EVT_CLOSE);
use base 'Wx::Dialog';

sub new {
    my $class = shift;
    my ($parent) = @_;
    use Data::Dumper;
    my $self = $class->SUPER::new($parent, -1, "obj_name", wxDefaultPosition, [500,500], wxDEFAULT_DIALOG_STYLE | wxRESIZE_BORDER);

    my $frame = $self->{frame} = Wx::Frame->new(
        undef,
        -1,
        'Hello World',
        [-1, -1],
        [250, 150],
    );

    my $string_text = "BONJOUR\n";

    use Wx qw( wxTE_MULTILINE wxTE_READONLY);
    my $textBox = $self->{text} = Wx::TextCtrl->new(
        $frame,
        -1,
        $string_text,
        [-1,-1],
        [100,100],
        wxTE_MULTILINE | wxTE_READONLY
    );

    $textBox->AppendText("another line\n");
    print "ON INIT\n";
    $frame->Show(1);
    return $self;
}


sub appendConsole {
    my ($self, $line) = @_;
    $self->{text}->AppendText($line);
    $self->{text}->AppendText("\n");    
}

1;