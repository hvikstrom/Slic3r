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
        'Tilt console',
        [-1, -1],
        [500, 250],
    );

    use Wx qw( wxTE_MULTILINE wxTE_READONLY wxTE_RICH wxSYS_DEFAULT_GUI_FONT wxFONTWEIGHT_BOLD); #WxTE_RICH is for Windows
    $self->{text} = Wx::TextCtrl->new(
        $frame,
        -1,
        "",
        [-1,-1],
        [100,100],
        wxTE_MULTILINE | wxTE_READONLY | wxTE_RICH
    );

    my $bold_font = Wx::SystemSettings::GetFont(wxSYS_DEFAULT_GUI_FONT);
    $bold_font->SetWeight(wxFONTWEIGHT_BOLD);

    my $normal_font = Wx::SystemSettings::GetFont(wxSYS_DEFAULT_GUI_FONT);

    $self->{bold_font} = $bold_font;
    $self->{normal_font} = $normal_font;

    # $textBox->SetDefaultStyle(Wx::TextAttr->new(Wx::wxRED()));
    # $textBox->AppendText("Red text\n");
    # $textBox->SetDefaultStyle(Wx::TextAttr->new(Wx::wxNullColour(), Wx::wxLIGHT_GREY()));
    # $textBox->AppendText("Red on grey text\n");
    # $textBox->SetDefaultStyle(Wx::TextAttr->new(Wx::wxBLUE()));
    # $textBox->AppendText("Blue on grey text\n");

    # $bold_font->SetPointSize(14);
    # $textBox->SetDefaultStyle(Wx::TextAttr->new(Wx::wxGREEN(), Wx::Colour->new(255,255,0), $bold_font));
    # $textBox->AppendText("Red on grey text\n");
    $frame->Show(1);
    return $self;
}


sub appendConsole {
    my ($self, $origin, $line) = @_;

    my $style = Wx::TextAttr->new(Wx::wxBLACK(), Wx::wxWHITE(), $self->{bold_font});
    $self->{text}->SetDefaultStyle($style);
    $self->{text}->AppendText($origin);
    $self->{text}->AppendText(": ");

    $style = Wx::TextAttr->new(Wx::wxBLACK(), Wx::wxWHITE(), $self->{normal_font});
    $self->{text}->SetDefaultStyle($style);
    $self->{text}->AppendText($line);
    $self->{text}->AppendText("\n");    
}

sub appendBoldConsole {
    my ($self, $origin, $line) = @_;

    my $style = Wx::TextAttr->new(Wx::wxBLACK(), Wx::wxWHITE(), $self->{bold_font});
    $self->{text}->SetDefaultStyle($style);
    $self->{text}->AppendText($origin);
    $self->{text}->AppendText(": ");
    
    $self->{text}->AppendText($line);
    $self->{text}->AppendText("\n");    
}

sub appendPreset {
    my ($self, $preset) = @_;

    my $style = Wx::TextAttr->new(Wx::wxBLACK(), Wx::wxWHITE(), $self->{normal_font});
    $self->{text}->SetDefaultStyle($style);
    my %data = %$preset;
    my $line = "a";
    foreach my $key (keys %data) {
        if (ref($data{$key}) eq 'HASH'){
            my %angle_data = %{$data{$key}};
            foreach my $angle_key (keys %angle_data) {
                $line = "   $angle_key: $angle_data{$angle_key}\n";
                $self->{text}->AppendText($line);
            }
        }
        else {
            $line = "   $key: $data{$key}\n";
            $self->{text}->AppendText($line);
        }

    } 
}

sub appendTestName {
    my ($self, $origin, $line) = @_;

    my $style = Wx::TextAttr->new(Wx::wxBLACK(), Wx::wxWHITE(), $self->{bold_font});
    $self->{text}->SetDefaultStyle($style);
    $origin .= "::Test: ";
    $self->{text}->AppendText($origin);
    $line .= "...";
    $self->{text}->AppendText($line);
}

sub appendTestResult {
    my ($self, $result) = @_;
    my $line = "";
    if ($result) {
        my $style = Wx::TextAttr->new(Wx::wxGREEN(), Wx::wxWHITE(), $self->{normal_font});
        $self->{text}->SetDefaultStyle($style);
        $line = "PASS\n";
    }
    else {
        my $style = Wx::TextAttr->new(Wx::wxRED(), Wx::wxWHITE(), $self->{normal_font});
        $self->{text}->SetDefaultStyle($style);
        $line = "FAIL\n";
    }
    $self->{text}->AppendText($line);
}

sub appendSolution {
    my ($self, $origin, $line, $data_label_ref, $data_ref) = @_;

    my $style = Wx::TextAttr->new(Wx::wxBLACK(), Wx::wxWHITE(), $self->{bold_font});
    $self->{text}->SetDefaultStyle($style);
    $origin .= "::Solution: ";
    $origin .= $line;
    $origin .= "\n";
    $self->{text}->AppendText($origin);
    $self->appendData($data_label_ref, $data_ref);
}

sub appendData {
    my ($self, $data_label_ref, $data_ref) = @_;

    my $style = Wx::TextAttr->new(Wx::wxBLACK(), Wx::wxWHITE(), $self->{normal_font});
    $self->{text}->SetDefaultStyle($style);

    my @data_label = @{$data_label_ref};
    my @data = @{$data_ref};

    foreach my $index (0..(scalar @data - 1)){
        my $line = $data_label[$index];
        $line .= ": ";
        $line .= $data[$index];
        $self->{text}->AppendText($line);
        $self->{text}->AppendText("\n");
    }


}

1;