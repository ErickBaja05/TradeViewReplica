package Market::UI::ReplayGotoMenu;
use strict;
use warnings;
use utf8;

use parent 'Market::UI::ReplayDropdown';

use Market::UI::Callbacks;

# Market::UI::ReplayGotoMenu — dropdown "SELECT STARTING POINT" (task 0044).
# Hereda place/toggle/click-fuera de ReplayDropdown (0045 fix race Fedora35).

sub expected_menu_labels {
    return (
        'SELECT STARTING POINT',
        '|< Bar',
        'Date...',
        'First available date',
        'Random bar',
    );
}

sub new {
    my ($class, %args) = @_;
    my $chart  = $args{chart}  or die "ReplayGotoMenu: requiere chart";
    my $vars   = $args{ui_vars} || {};
    my $mw     = $args{mw};
    my $root   = $args{root} || $mw || $args{parent};

    my $self = $class->SUPER::new(
        parent => $args{parent},
        root   => $root,
    );

    my $frame = $self->frame;
    $frame->Label(
        -text       => 'SELECT STARTING POINT',
        -font       => 'Helvetica 8',
        -foreground => '#888888',
        -background => '#ffffff',
    )->pack(-fill => 'x', -padx => 6, -pady => [4, 2]);

    $self->{chart}   = $chart;
    $self->{mw}      = $mw;
    $self->{ui_vars} = $vars;

    my $row_opts = sub {
        my ($label, $cb) = @_;
        return $frame->Button(
            -text             => $label,
            -command          => sub { $cb->(); $self->hide() },
            -relief           => 'flat',
            -anchor           => 'w',
            -padx             => 8,
            -pady             => 2,
            -background       => '#ffffff',
            -activebackground => '#e8e8e8',
            -width            => 22,
        );
    };

    $row_opts->('|< Bar', Market::UI::Callbacks->make_replay_goto_bar($chart, $vars))
        ->pack(-fill => 'x');
    $row_opts->('Date...', Market::UI::Callbacks->make_replay_goto_date($chart, $mw, $vars))
        ->pack(-fill => 'x');
    $row_opts->('First available date', Market::UI::Callbacks->make_replay_goto_first($chart, $vars))
        ->pack(-fill => 'x');
    $row_opts->('Random bar', Market::UI::Callbacks->make_replay_goto_random($chart, $vars))
        ->pack(-fill => 'x');

    $frame->placeForget();
    return $self;
}

1;