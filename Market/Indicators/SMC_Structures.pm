package Market::Indicators::SMC_Structures;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        pivots         => [],
        structure      => [],
        events         => [],
        choch_atr_mult => $args{choch_atr_mult} // 2.0,
        
        last_high      => undef,
        last_low       => undef,
        trend          => 'UNKNOWN',
        external_high  => undef,
        external_low   => undef,
        pending_choch  => undef,
    };
    return bless $self, $class;
}

sub update_last {
    my ($self, $pivot) = @_;
    
    return unless $pivot;
    push @{$self->{pivots}}, $pivot;

    my $label;
    if ($pivot->{type} eq 'HIGH') {
        $label = !defined $self->{last_high} ? 'H' : ($pivot->{price} > $self->{last_high}->{price} ? 'HH' : 'LH');
        $self->{last_high} = $pivot;
    } elsif ($pivot->{type} eq 'LOW') {
        $label = !defined $self->{last_low} ? 'L' : ($pivot->{price} > $self->{last_low}->{price} ? 'HL' : 'LL');
        $self->{last_low} = $pivot;
    }

    my $event;
    my $break_size = 0;
    my ($choch_level, $bos_level);

    my $atr = $pivot->{atr} // 0;
    my $min_break = $atr * $self->{choch_atr_mult};

    if ($self->{trend} eq 'UNKNOWN') {
        if ($label eq 'HH') {
            $self->{trend} = 'UP';
            $self->{external_high} = $pivot;
        } elsif ($label eq 'LL') {
            $self->{trend} = 'DOWN';
            $self->{external_low} = $pivot;
        }
    } elsif ($self->{trend} eq 'UP') {
        if ($label eq 'HH') {
            $event = defined $self->{pending_choch} && $self->{pending_choch}->{direction} eq 'UP' ? 'BOS_UP_CONFIRM' : 'BOS_UP';
            $bos_level = $self->{external_high};
            $self->{pending_choch} = undef;
            $self->{external_high} = $pivot;
        } elsif ($label eq 'HL') {
            $self->{external_low} = $pivot;
        } elsif ($label eq 'LL' && defined $self->{external_low}) {
            $break_size = $self->{external_low}->{price} - $pivot->{price};
            if ($break_size >= $min_break && !defined $self->{pending_choch}) {
                $event = 'CHoCH_DOWN';
                $choch_level = $self->{external_low};
                $self->{pending_choch} = { direction => 'DOWN', pivot => $pivot };
                $self->{trend} = 'DOWN';
                $self->{external_low} = $pivot;
            }
        }
    } elsif ($self->{trend} eq 'DOWN') {
        if ($label eq 'LL') {
            $event = defined $self->{pending_choch} && $self->{pending_choch}->{direction} eq 'DOWN' ? 'BOS_DOWN_CONFIRM' : 'BOS_DOWN';
            $bos_level = $self->{external_low};
            $self->{pending_choch} = undef;
            $self->{external_low} = $pivot;
        } elsif ($label eq 'LH') {
            $self->{external_high} = $pivot;
        } elsif ($label eq 'HH' && defined $self->{external_high}) {
            $break_size = $pivot->{price} - $self->{external_high}->{price};
            if ($break_size >= $min_break && !defined $self->{pending_choch}) {
                $event = 'CHoCH_UP';
                $choch_level = $self->{external_high};
                $self->{pending_choch} = { direction => 'UP', pivot => $pivot };
                $self->{trend} = 'UP';
                $self->{external_high} = $pivot;
            }
        }
    }

    if (defined $event) {
        my %evento = (
            type        => $event,
            index       => $pivot->{index},
            price       => $pivot->{price},
            pivot       => $label,
            trend_after => $self->{trend},
            break_size  => $break_size,
        );
        if (defined $choch_level) {
            $evento{level_index} = $choch_level->{index};
            $evento{level_price} = $choch_level->{price};
        }
        if (defined $bos_level) {
            $evento{level_index} = $bos_level->{index};
            $evento{level_price} = $bos_level->{price};
        }
        push @{$self->{events}}, \%evento;
    }

    push @{$self->{structure}}, { %$pivot, label => $label, event => $event };

    return { structure => $self->{structure}, events => $self->{events} };
}

sub reset {
    my ($self) = @_;
    
    $self->{pivots}        = [];
    $self->{structure}     = [];
    $self->{events}        = [];
    
    $self->{last_high}     = undef;
    $self->{last_low}      = undef;
    $self->{trend}         = 'UNKNOWN';
    $self->{external_high} = undef;
    $self->{external_low}  = undef;
    $self->{pending_choch} = undef;
}

1;