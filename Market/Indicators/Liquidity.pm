package Market::Indicators::Liquidity;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;

    my $self = {
        atr_mult         => $args{atr_mult}         // 4.0,
        minor_atr_mult   => $args{minor_atr_mult}   // 1.5,
        eq_tolerance     => $args{eq_tolerance}     // 0.10,
        confirm_bars     => $args{confirm_bars}     // 3,

        state            => 'BUSCANDO_MAXIMO',
        minor_state      => 'BUSCANDO_MAXIMO',

        candidate_high   => undef,
        candidate_low    => undef,

        minor_high       => undef,
        minor_low        => undef,

        pivots           => [],
        minor_pivots     => [],
        liquidity        => [],
        events           => [],
        equal_levels     => [],
    };

    return bless $self, $class;
}

sub reset {
    my ($self) = @_;

    $self->{state}          = 'BUSCANDO_MAXIMO';
    $self->{minor_state}    = 'BUSCANDO_MAXIMO';

    $self->{candidate_high} = undef;
    $self->{candidate_low}  = undef;

    $self->{minor_high}     = undef;
    $self->{minor_low}      = undef;

    $self->{pivots}         = [];
    $self->{minor_pivots}   = [];
    $self->{liquidity}      = [];
    $self->{events}         = [];
    $self->{equal_levels}   = [];
}

sub calculate_until {
    my ($self, $candles, $atr_values, $until_index) = @_;

    $self->reset();

    for my $i (0 .. $until_index) {
        $self->process_bar($candles, $atr_values, $i);
    }
    $self->_detect_equal_levels();

    return {
        pivots            => $self->{pivots},
        structural_pivots => $self->{pivots},
        minor_pivots      => $self->{minor_pivots},
        liquidity         => $self->{liquidity},
        events            => $self->{events},
        equal_levels      => $self->{equal_levels},
        candles           => $candles,   # pasamos las velas para el overlay
    };
}

sub process_bar {
    my ($self, $candles, $atr_values, $i) = @_;

    my $bar = $candles->[$i];
    return if !$bar;

    my $atr = $atr_values->[$i] // 0;
    return if $atr <= 0;

    $self->_process_minor_pivot($bar, $atr, $i);
    $self->_process_structural_pivot($bar, $atr, $i);
    $self->_update_liquidity_states($bar, $i);
}

sub _process_minor_pivot {
    my ($self, $bar, $atr, $i) = @_;

    my $threshold = $atr * $self->{minor_atr_mult};

    my $high  = $bar->{high};
    my $low   = $bar->{low};
    my $close = $bar->{close};

    if ($self->{minor_state} eq 'BUSCANDO_MAXIMO') {

        if (!defined $self->{minor_high} || $high > $self->{minor_high}->{price}) {
            $self->{minor_high} = {
                type  => 'HIGH',
                index => $i,
                price => $high,
                atr   => $atr,
                tier  => 'minor',
            };
        }

        if (defined $self->{minor_high} && ($self->{minor_high}->{price} - $close) >= $threshold) {
            push @{$self->{minor_pivots}}, $self->{minor_high};

            $self->{minor_low} = {
                type  => 'LOW',
                index => $i,
                price => $low,
                atr   => $atr,
                tier  => 'minor',
            };

            $self->{minor_high}  = undef;
            $self->{minor_state} = 'BUSCANDO_MINIMO';
        }

    } elsif ($self->{minor_state} eq 'BUSCANDO_MINIMO') {

        if (!defined $self->{minor_low} || $low < $self->{minor_low}->{price}) {
            $self->{minor_low} = {
                type  => 'LOW',
                index => $i,
                price => $low,
                atr   => $atr,
                tier  => 'minor',
            };
        }

        if (defined $self->{minor_low} && ($close - $self->{minor_low}->{price}) >= $threshold) {
            push @{$self->{minor_pivots}}, $self->{minor_low};

            $self->{minor_high} = {
                type  => 'HIGH',
                index => $i,
                price => $high,
                atr   => $atr,
                tier  => 'minor',
            };

            $self->{minor_low}   = undef;
            $self->{minor_state} = 'BUSCANDO_MAXIMO';
        }
    }
}

sub _process_structural_pivot {
    my ($self, $bar, $atr, $i) = @_;

    my $threshold = $atr * $self->{atr_mult};

    my $high  = $bar->{high};
    my $low   = $bar->{low};
    my $close = $bar->{close};

    if ($self->{state} eq 'BUSCANDO_MAXIMO') {

        if (!defined $self->{candidate_high} || $high > $self->{candidate_high}->{price}) {
            $self->{candidate_high} = {
                type  => 'HIGH',
                index => $i,
                price => $high,
                atr   => $atr,
                tier  => 'structural',
            };
        }

        if (defined $self->{candidate_high} && ($self->{candidate_high}->{price} - $close) >= $threshold) {
            push @{$self->{pivots}}, $self->{candidate_high};

            push @{$self->{liquidity}}, {
                type   => 'BSL',
                state  => 'Detected',
                index  => $self->{candidate_high}->{index},
                price  => $self->{candidate_high}->{price},
                source => 'StructuralPivotHigh',
                tier   => 'structural',
                created_index  => $self->{candidate_high}->{index},
                swept_index    => undef,
                resolved_index => undef,
                classification => undef,
                outside_count  => 0,
            };

            $self->{candidate_low} = {
                type  => 'LOW',
                index => $i,
                price => $low,
                atr   => $atr,
                tier  => 'structural',
            };

            $self->{candidate_high} = undef;
            $self->{state} = 'BUSCANDO_MINIMO';
        }

    } elsif ($self->{state} eq 'BUSCANDO_MINIMO') {

        if (!defined $self->{candidate_low} || $low < $self->{candidate_low}->{price}) {
            $self->{candidate_low} = {
                type  => 'LOW',
                index => $i,
                price => $low,
                atr   => $atr,
                tier  => 'structural',
            };
        }

        if (defined $self->{candidate_low} && ($close - $self->{candidate_low}->{price}) >= $threshold) {
            push @{$self->{pivots}}, $self->{candidate_low};

            push @{$self->{liquidity}}, {
                type           => 'SSL',
                state          => 'Detected',
                index          => $self->{candidate_low}->{index},
                created_index  => $self->{candidate_low}->{index},
                swept_index    => undef,
                resolved_index => undef,
                price          => $self->{candidate_low}->{price},
                source         => 'StructuralPivotLow',
                tier           => 'structural',
                classification => undef,
                outside_count  => 0,
            };

            $self->{candidate_high} = {
                type  => 'HIGH',
                index => $i,
                price => $high,
                atr   => $atr,
                tier  => 'structural',
            };

            $self->{candidate_low} = undef;
            $self->{state} = 'BUSCANDO_MAXIMO';
        }
    }
}

sub _detect_equal_levels {
    my ($self) = @_;

    my @recent_highs;
    my @recent_lows;

    my $lookback_pivots = 20;

    for my $p (@{$self->{minor_pivots}}) {

        my $atr = $p->{atr} // 0;
        next if $atr <= 0;

        my $tolerance = $atr * $self->{eq_tolerance};

        if ($p->{type} eq 'HIGH') {

            for my $prev (@recent_highs) {
                my $diff = abs($p->{price} - $prev->{price});

                if ($diff <= $tolerance) {
                    push @{$self->{equal_levels}}, {
                        type       => 'EQH',
                        state      => 'Detected',
                        index1     => $prev->{index},
                        index2     => $p->{index},
                        price1     => $prev->{price},
                        price2     => $p->{price},
                        price      => ($prev->{price} + $p->{price}) / 2,
                        tolerance  => $tolerance,
                        source     => 'MinorPivotHigh',
                    };
                    last;
                }
            }

            push @recent_highs, $p;
            shift @recent_highs while @recent_highs > $lookback_pivots;
        }

        elsif ($p->{type} eq 'LOW') {

            for my $prev (@recent_lows) {
                my $diff = abs($p->{price} - $prev->{price});

                if ($diff <= $tolerance) {
                    push @{$self->{equal_levels}}, {
                        type       => 'EQL',
                        state      => 'Detected',
                        index1     => $prev->{index},
                        index2     => $p->{index},
                        price1     => $prev->{price},
                        price2     => $p->{price},
                        price      => ($prev->{price} + $p->{price}) / 2,
                        tolerance  => $tolerance,
                        source     => 'MinorPivotLow',
                    };
                    last;
                }
            }

            push @recent_lows, $p;
            shift @recent_lows while @recent_lows > $lookback_pivots;
        }
    }
}

sub _update_liquidity_states {
    my ($self, $bar, $i) = @_;

    for my $lvl (@{$self->{liquidity}}) {

        next if $lvl->{state} eq 'Resolved';

        my $price = $lvl->{price};

        if ($lvl->{state} eq 'Detected') {

            if ($lvl->{type} eq 'BSL' && $bar->{high} > $price) {
                $lvl->{state}         = 'Swept';
                $lvl->{swept_index}   = $i;
                $lvl->{outside_count} = 0;
            }

            elsif ($lvl->{type} eq 'SSL' && $bar->{low} < $price) {
                $lvl->{state}         = 'Swept';
                $lvl->{swept_index}   = $i;
                $lvl->{outside_count} = 0;
            }
        }

        next if $lvl->{state} eq 'Detected';

        my $bars_after_sweep = $i - $lvl->{swept_index};

        if ($lvl->{type} eq 'BSL') {

            if ($bar->{close} < $price) {
                # Precio regresó al rango previo:
                # - Grab: rechazo muy rápido (regreso en <= confirm_bars velas)
                # - Sweep: barrido estándar (regreso posterior o misma vela)
                $lvl->{state}          = 'Reclaimed';
                $lvl->{resolved_index} = $i;
                $lvl->{classification} = ($bars_after_sweep > 0 && $bars_after_sweep <= $self->{confirm_bars})
                    ? 'Grab'
                    : 'Sweep';

                $lvl->{state} = 'Resolved';
                next;
            }

            if ($bar->{close} > $price) {
                $lvl->{state} = 'Acceptance';
                $lvl->{outside_count}++;

                if ($lvl->{outside_count} >= $self->{confirm_bars}) {
                    $lvl->{resolved_index} = $i;
                    $lvl->{classification} = 'Run';
                    $lvl->{state}          = 'Resolved';
                    next;
                }
            }
        }

        elsif ($lvl->{type} eq 'SSL') {

            if ($bar->{close} > $price) {
                $lvl->{state}          = 'Reclaimed';
                $lvl->{resolved_index} = $i;
                $lvl->{classification} = ($bars_after_sweep > 0 && $bars_after_sweep <= $self->{confirm_bars})
                    ? 'Grab'
                    : 'Sweep';

                $lvl->{state} = 'Resolved';
                next;
            }

            if ($bar->{close} < $price) {
                $lvl->{state} = 'Acceptance';
                $lvl->{outside_count}++;

                if ($lvl->{outside_count} >= $self->{confirm_bars}) {
                    $lvl->{resolved_index} = $i;
                    $lvl->{classification} = 'Run';
                    $lvl->{state}          = 'Resolved';
                    next;
                }
            }
        }
    }
}

1;