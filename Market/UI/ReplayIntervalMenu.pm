package Market::UI::ReplayIntervalMenu;
use strict;
use warnings;
use utf8;

use parent 'Market::UI::ReplayDropdown';

use Market::UI::Callbacks;

# Market::UI::ReplayIntervalMenu — dropdown UPDATE INTERVAL (task 0045).

sub interval_option_labels {
    return ('1 hour', '2 hours', '3 hours', '4 hours', '1 day');
}

sub new {
    my ($class, %args) = @_;
    my $chart     = $args{chart}     or die "ReplayIntervalMenu: requiere chart";
    my $panel_btn = $args{panel_btn} or die "ReplayIntervalMenu: requiere panel_btn";
    my $vars      = $args{ui_vars} || {};

    my $self = $class->SUPER::new(
        parent => $args{parent},
        root   => $args{root},
    );

    my $frame = $self->frame;
    $frame->Label(
        -text       => 'UPDATE INTERVAL',
        -font       => 'Helvetica 8',
        -foreground => '#888888',
        -background => '#ffffff',
    )->pack(-fill => 'x', -padx => 6, -pady => [4, 2]);

    $self->{chart}     = $chart;
    $self->{panel_btn} = $panel_btn;
    $self->{ui_vars}   = $vars;
    $self->{row_btns}  = [];

    my $rc = $chart->{replay_controller};
    $rc->set_auto_replay_interval(1) if $rc && $rc->can('set_auto_replay_interval');

    for my $label (interval_option_labels()) {
        my $btn = $frame->Button(
            -text             => $label,
            -relief           => 'flat',
            -anchor           => 'w',
            -padx             => 8,
            -pady             => 2,
            -background       => '#ffffff',
            -activebackground => '#e8e8e8',
            -width            => 22,
            -command          => sub { $self->_select_manual($label) },
        );
        $btn->pack(-fill => 'x');
        push @{ $self->{row_btns} }, { label => $label, widget => $btn };
    }

    my $auto_var = 1;
    $frame->Checkbutton(
        -text       => 'Auto select interval',
        -variable   => \$auto_var,
        -anchor     => 'w',
        -padx       => 6,
        -background => '#ffffff',
        -command    => sub { $self->_toggle_auto($auto_var) },
    )->pack(-fill => 'x', -pady => [4, 4]);
    $self->{auto_var} = \$auto_var;

    $frame->placeForget();
    $self->_sync_highlight();
    $self->_sync_button_text();
    return $self;
}

sub _select_manual {
    my ($self, $label) = @_;
    my $rc = $self->{chart}{replay_controller};
    return unless $rc;
    $rc->set_auto_replay_interval(0) if $rc->can('set_auto_replay_interval');
    $rc->set_interval_label($label)   if $rc->can('set_interval_label');
    ${ $self->{auto_var} } = 0 if $self->{auto_var};
    Market::UI::Callbacks::apply_replay_interval_selection($self->{chart});
    $self->_sync_highlight();
    $self->_sync_button_text();
    Market::UI::Callbacks::reschedule_replay_play($self->{chart}, $self->{ui_vars});
    $self->hide();
    return;
}

sub _toggle_auto {
    my ($self, $on) = @_;
    my $rc = $self->{chart}{replay_controller};
    return unless $rc;
    $rc->set_auto_replay_interval($on ? 1 : 0) if $rc->can('set_auto_replay_interval');
    Market::UI::Callbacks::apply_replay_interval_selection($self->{chart});
    $self->_sync_highlight();
    $self->_sync_button_text();
    Market::UI::Callbacks::reschedule_replay_play($self->{chart}, $self->{ui_vars});
    return;
}

sub _sync_highlight {
    my ($self) = @_;
    my $rc = $self->{chart}{replay_controller};
    my $auto = $rc && $rc->can('auto_replay_interval') ? $rc->auto_replay_interval() : 1;
    my $active = (!$auto && $rc && $rc->can('interval_label'))
        ? ($rc->interval_label() // '1 hour') : undef;
    for my $row (@{ $self->{row_btns} }) {
        my $btn = $row->{widget};
        next unless $btn && eval { $btn->exists };
        if (defined $active && $row->{label} eq $active) {
            $btn->configure(-background => '#363a45', -foreground => '#ffffff');
        } else {
            $btn->configure(-background => '#ffffff', -foreground => '#000000');
        }
    }
    return;
}

sub _sync_button_text {
    my ($self) = @_;
    my $rc = $self->{chart}{replay_controller};
    my $text = Market::UI::Callbacks::replay_interval_button_text($rc);
    eval { $self->{panel_btn}->configure(-text => $text) };
    return;
}

sub show {
    my ($self) = @_;
    $self->_sync_highlight();
    $self->_sync_button_text();
    return $self->SUPER::show();
}

1;