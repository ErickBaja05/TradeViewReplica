package Market::Indicators::FVG;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        fvg_history_nbr  => $args{fvg_history_nbr}  // 5,
        min_gap_atr_mult => $args{min_gap_atr_mult} // 0.0,
        reduce_mitigated => $args{reduce_mitigated} // 0,
        zones            => [],
        open_zones       => [],
        visible_queue    => [],
    };
    return bless $self, $class;
}

sub reset {
    my ($self) = @_;
    $self->{zones}         = [];
    $self->{open_zones}    = [];
    $self->{visible_queue} = [];
}

sub update_last {
    my ($self, $candles, $atr_values, $i) = @_;

    return { zones => $self->{zones} } if !defined $i || $i < 3;

    my $bar = $candles->[$i];
    return { zones => $self->{zones} } unless $bar;

    my $bar_high = $bar->{high};
    my $bar_low  = $bar->{low};

    # 1. Actualizar mitigación de zonas abiertas con la vela actual
    my @still_open;
    for my $z (@{$self->{open_zones}}) {
        if ($z->{type} eq 'BULLISH') {
            if ($bar_low <= $z->{bottom}) {
                $z->{state}        = 'Filled';
                $z->{filled_index} = $i;
            } else {
                if ($bar_low < $z->{top}) {
                    $z->{state} = 'Mitigated' unless $z->{state} eq 'Mitigated';
                    if ($self->{reduce_mitigated}) {
                        $z->{top} = $bar_low if $bar_low < $z->{top};
                    }
                }
                $z->{right_index} = $i;
                push @still_open, $z;
            }
        } else {
            if ($bar_high >= $z->{top}) {
                $z->{state}        = 'Filled';
                $z->{filled_index} = $i;
            } else {
                if ($bar_high > $z->{bottom}) {
                    $z->{state} = 'Mitigated' unless $z->{state} eq 'Mitigated';
                    if ($self->{reduce_mitigated}) {
                        $z->{bottom} = $bar_high if $bar_high > $z->{bottom};
                    }
                }
                $z->{right_index} = $i;
                push @still_open, $z;
            }
        }
    }
    $self->{open_zones} = \@still_open;

    # 2. Detectar nuevo FVG
    my $c_prev3 = $candles->[$i - 3];
    my $c_prev1 = $candles->[$i - 1];
    return { zones => $self->{zones} } unless $c_prev3 && $c_prev1;

    my $atr     = $atr_values->[$i] // 0;
    my $min_gap = $atr * $self->{min_gap_atr_mult};

    if ($c_prev3->{high} < $c_prev1->{low}) {
        my $gap = $c_prev1->{low} - $c_prev3->{high};
        if ($gap > $min_gap) {
            my $zone = { type => 'BULLISH', top => $c_prev1->{low}, bottom => $c_prev3->{high}, left_index => $i - 3, created_index => $i, right_index => $i, state => 'Open', filled_index => undef };
            $self->_add_zone($zone);
        }
    } elsif ($c_prev3->{low} > $c_prev1->{high}) {
        my $gap = $c_prev3->{low} - $c_prev1->{high};
        if ($gap > $min_gap) {
            my $zone = { type => 'BEARISH', top => $c_prev3->{low}, bottom => $c_prev1->{high}, left_index => $i - 3, created_index => $i, right_index => $i, state => 'Open', filled_index => undef };
            $self->_add_zone($zone);
        }
    }

    return { zones => $self->{zones} };
}

sub _add_zone {
    my ($self, $zone) = @_;
    push @{$self->{zones}}, $zone;
    push @{$self->{open_zones}}, $zone;
    push @{$self->{visible_queue}}, $zone;
    if (scalar(@{$self->{visible_queue}}) > $self->{fvg_history_nbr} + 1) {
        my $oldest = shift @{$self->{visible_queue}};
        $oldest->{evicted} = 1;
    }
}
1;