package Market::UI::ReplaySpeedMenu;
use strict;
use warnings;
use utf8;

use parent 'Market::UI::ReplayDropdown';

use Market::ReplayController;
use Market::UI::Callbacks;

my %SPEED_DESC = (
    '10x'  => '10 upd per 1 sec',
    '7x'   => '7 upd per 1 sec',
    '5x'   => '5 upd per 1 sec',
    '3x'   => '3 upd per 1 sec',
    '1x'   => '1 upd per 1 sec',
    '0.5x' => '1 upd per 2 sec',
    '0.3x' => '1 upd per 3 sec',
    '0.2x' => '1 upd per 5 sec',
    '0.1x' => '1 upd per 10 sec',
);

sub speed_row_labels {
    my @rows;
    for my $opt (Market::ReplayController::speed_options()) {
        my $desc = $SPEED_DESC{ $opt->{label} } // '';
        push @rows, "$opt->{label}  $desc";
    }
    return @rows;
}

sub new {
    my ($class, %args) = @_;
    my $chart     = $args{chart}     or die "ReplaySpeedMenu: requiere chart";
    my $panel_btn = $args{panel_btn} or die "ReplaySpeedMenu: requiere panel_btn";
    my $vars      = $args{ui_vars} || {};

    my $self = $class->SUPER::new(
        parent => $args{parent},
        root   => $args{root},
    );

    my $frame = $self->frame;
    $frame->Label(
        -text       => 'REPLAY SPEED',
        -font       => 'Helvetica 8',
        -foreground => '#888888',
        -background => '#ffffff',
    )->pack(-fill => 'x', -padx => 6, -pady => [4, 2]);

    $self->{chart}     = $chart;
    $self->{panel_btn} = $panel_btn;
    $self->{ui_vars}   = $vars;
    $self->{row_btns}  = [];

    for my $opt (Market::ReplayController::speed_options()) {
        my $label = $opt->{label};
        my $text  = "$label  " . ($SPEED_DESC{$label} // '');
        my $btn = $frame->Button(
            -text             => $text,
            -relief           => 'flat',
            -anchor           => 'w',
            -padx             => 8,
            -pady             => 2,
            -background       => '#ffffff',
            -activebackground => '#e8e8e8',
            -width            => 28,
            -command          => sub { $self->_select($label) },
        );
        $btn->pack(-fill => 'x');
        push @{ $self->{row_btns} }, { label => $label, widget => $btn };
    }

    $frame->placeForget();
    $self->_sync_highlight();
    return $self;
}

sub _select {
    my ($self, $label) = @_;
    my $rc = $self->{chart}{replay_controller};
    return unless $rc;
    $rc->set_speed_label($label);
    eval { $self->{panel_btn}->configure(-text => $label) };
    $self->_sync_highlight();
    Market::UI::Callbacks::reschedule_replay_play($self->{chart}, $self->{ui_vars});
    $self->hide();
    return;
}

sub _sync_highlight {
    my ($self) = @_;
    my $rc = $self->{chart}{replay_controller};
    my $active = $rc ? ($rc->{speed_label} // '1x') : '1x';
    for my $row (@{ $self->{row_btns} }) {
        my $btn = $row->{widget};
        next unless $btn && eval { $btn->exists };
        if ($row->{label} eq $active) {
            $btn->configure(-background => '#363a45', -foreground => '#ffffff');
        } else {
            $btn->configure(-background => '#ffffff', -foreground => '#000000');
        }
    }
    return;
}

sub show {
    my ($self) = @_;
    $self->_sync_highlight();
    return $self->SUPER::show();
}

1;