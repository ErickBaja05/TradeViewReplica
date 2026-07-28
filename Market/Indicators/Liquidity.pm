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
        recent_highs     => [],
        recent_lows      => [],
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
    $self->{recent_highs}   = [];
    $self->{recent_lows}    = [];
}

sub update_last {
    my ($self, $candles, $atr_values, $i) = @_;
    
    my $bar = $candles->[$i];
    return unless $bar;
    
    my $atr = $atr_values->[$i] // 0;
    return if $atr <= 0;

    $self->_process_minor_pivot($bar, $atr, $i);
    $self->_process_structural_pivot($bar, $atr, $i);
    $self->_update_liquidity_states($bar, $i);

    return {
        pivots            => $self->{pivots},
        structural_pivots => $self->{pivots},
        minor_pivots      => $self->{minor_pivots},
        liquidity         => $self->{liquidity},
        events            => $self->{events},
        equal_levels      => $self->{equal_levels},
        candles           => $candles,
    };
}

# ─── Pivotes ESTRUCTURALES (mayores) ──────────────────────────────────────
# Misma máquina de estados que _process_minor_pivot, pero usando el umbral
# atr_mult (más amplio) y alimentando $self->{pivots}, que es lo que
# Market::Indicators::SMC_Structures consume vela a vela (ver ChartEngine::
# update_smc_overlay). Cada pivote confirmado genera además un nivel de
# liquidez (BSL para un HIGH, SSL para un LOW).
sub _process_structural_pivot {
    my ($self, $bar, $atr, $i) = @_;
    my $threshold = $atr * $self->{atr_mult};
    my $high  = $bar->{high};
    my $low   = $bar->{low};
    my $close = $bar->{close};

    if ($self->{state} eq 'BUSCANDO_MAXIMO') {
        if (!defined $self->{candidate_high} || $high > $self->{candidate_high}->{price}) {
            $self->{candidate_high} = { type => 'HIGH', index => $i, price => $high, atr => $atr, tier => 'structural' };
        }
        if (defined $self->{candidate_high} && ($self->{candidate_high}->{price} - $close) >= $threshold) {
            push @{$self->{pivots}}, $self->{candidate_high};
            $self->_create_liquidity_level($self->{candidate_high});
            $self->{candidate_low}  = { type => 'LOW', index => $i, price => $low, atr => $atr, tier => 'structural' };
            $self->{candidate_high} = undef;
            $self->{state} = 'BUSCANDO_MINIMO';
        }
    } elsif ($self->{state} eq 'BUSCANDO_MINIMO') {
        if (!defined $self->{candidate_low} || $low < $self->{candidate_low}->{price}) {
            $self->{candidate_low} = { type => 'LOW', index => $i, price => $low, atr => $atr, tier => 'structural' };
        }
        if (defined $self->{candidate_low} && ($close - $self->{candidate_low}->{price}) >= $threshold) {
            push @{$self->{pivots}}, $self->{candidate_low};
            $self->_create_liquidity_level($self->{candidate_low});
            $self->{candidate_high} = { type => 'HIGH', index => $i, price => $high, atr => $atr, tier => 'structural' };
            $self->{candidate_low}  = undef;
            $self->{state} = 'BUSCANDO_MAXIMO';
        }
    }
}

# Crea un nivel de liquidez (BSL/SSL) a partir de un pivote estructural
# recién confirmado. Nace en estado 'Detected' (línea punteada visible)
# hasta que _update_liquidity_states lo resuelva como Sweep/Grab/Run.
sub _create_liquidity_level {
    my ($self, $pivot) = @_;
    my $type = ($pivot->{type} eq 'HIGH') ? 'BSL' : 'SSL';

    push @{$self->{liquidity}}, {
        type           => $type,
        price          => $pivot->{price},
        index          => $pivot->{index},
        created_index  => $pivot->{index},
        state          => 'Detected',   # Detected -> Pending -> Resolved
        classification => undef,        # Sweep | Grab | Run (una vez Resolved)
        swept_index    => undef,
        resolved_index => undef,
        pending_since  => undef,
    };
}

# ─── Resolución de niveles de liquidez ────────────────────────────────────
# Recorre los niveles BSL/SSL activos y los clasifica al ser barridos:
#   - Sweep: la vela mecha más allá del nivel pero cierra de vuelta del
#            mismo lado (rechazo inmediato, en la misma vela).
#   - Grab:  la vela CIERRA más allá del nivel, pero el precio revierte
#            dentro de las siguientes confirm_bars velas (falso breakout).
#   - Run:   el precio permanece cerrando más allá del nivel durante al
#            menos confirm_bars velas (breakout genuino / continuación).
sub _update_liquidity_states {
    my ($self, $bar, $i) = @_;
    my $high  = $bar->{high};
    my $low   = $bar->{low};
    my $close = $bar->{close};
    my $confirm_bars = $self->{confirm_bars};

    for my $lvl (@{$self->{liquidity}}) {
        next if $lvl->{state} eq 'Resolved';

        if ($lvl->{state} eq 'Detected') {
            if ($lvl->{type} eq 'BSL' && $high >= $lvl->{price}) {
                if ($close < $lvl->{price}) {
                    # Rechazo inmediato: mechó por encima y cerró por debajo
                    $lvl->{state}          = 'Resolved';
                    $lvl->{classification} = 'Sweep';
                    $lvl->{swept_index}    = $i;
                    $lvl->{resolved_index} = $i;
                } else {
                    # Cerró por encima: posible Grab (reversión) o Run (continuación)
                    $lvl->{state}         = 'Pending';
                    $lvl->{swept_index}   = $i;
                    $lvl->{pending_since} = $i;
                }
            } elsif ($lvl->{type} eq 'SSL' && $low <= $lvl->{price}) {
                if ($close > $lvl->{price}) {
                    $lvl->{state}          = 'Resolved';
                    $lvl->{classification} = 'Sweep';
                    $lvl->{swept_index}    = $i;
                    $lvl->{resolved_index} = $i;
                } else {
                    $lvl->{state}         = 'Pending';
                    $lvl->{swept_index}   = $i;
                    $lvl->{pending_since} = $i;
                }
            }
        } elsif ($lvl->{state} eq 'Pending') {
            my $elapsed = $i - $lvl->{pending_since};

            if ($lvl->{type} eq 'BSL') {
                if ($close < $lvl->{price}) {
                    # Revirtió antes de completar confirm_bars => falso breakout
                    $lvl->{state}          = 'Resolved';
                    $lvl->{classification} = 'Grab';
                    $lvl->{resolved_index} = $i;
                } elsif ($elapsed >= $confirm_bars) {
                    $lvl->{state}          = 'Resolved';
                    $lvl->{classification} = 'Run';
                    $lvl->{resolved_index} = $i;
                }
            } else {
                if ($close > $lvl->{price}) {
                    $lvl->{state}          = 'Resolved';
                    $lvl->{classification} = 'Grab';
                    $lvl->{resolved_index} = $i;
                } elsif ($elapsed >= $confirm_bars) {
                    $lvl->{state}          = 'Resolved';
                    $lvl->{classification} = 'Run';
                    $lvl->{resolved_index} = $i;
                }
            }
        }
    }
}

sub _process_minor_pivot {
    my ($self, $bar, $atr, $i) = @_;
    my $threshold = $atr * $self->{minor_atr_mult};
    my $high  = $bar->{high};
    my $low   = $bar->{low};
    my $close = $bar->{close};

    if ($self->{minor_state} eq 'BUSCANDO_MAXIMO') {
        if (!defined $self->{minor_high} || $high > $self->{minor_high}->{price}) {
            $self->{minor_high} = { type => 'HIGH', index => $i, price => $high, atr => $atr, tier => 'minor' };
        }
        if (defined $self->{minor_high} && ($self->{minor_high}->{price} - $close) >= $threshold) {
            push @{$self->{minor_pivots}}, $self->{minor_high};
            $self->_check_equal_levels($self->{minor_high});
            $self->{minor_low} = { type => 'LOW', index => $i, price => $low, atr => $atr, tier => 'minor' };
            $self->{minor_high}  = undef;
            $self->{minor_state} = 'BUSCANDO_MINIMO';
        }
    } elsif ($self->{minor_state} eq 'BUSCANDO_MINIMO') {
        if (!defined $self->{minor_low} || $low < $self->{minor_low}->{price}) {
            $self->{minor_low} = { type => 'LOW', index => $i, price => $low, atr => $atr, tier => 'minor' };
        }
        if (defined $self->{minor_low} && ($close - $self->{minor_low}->{price}) >= $threshold) {
            push @{$self->{minor_pivots}}, $self->{minor_low};
            $self->_check_equal_levels($self->{minor_low});
            $self->{minor_high} = { type => 'HIGH', index => $i, price => $high, atr => $atr, tier => 'minor' };
            $self->{minor_low}   = undef;
            $self->{minor_state} = 'BUSCANDO_MAXIMO';
        }
    }
}

sub _check_equal_levels {
    my ($self, $p) = @_;
    my $atr = $p->{atr} // 0;
    return if $atr <= 0;
    
    my $tolerance = $atr * $self->{eq_tolerance};
    my $lookback_pivots = 20;

    if ($p->{type} eq 'HIGH') {
        for my $prev (@{$self->{recent_highs}}) {
            if (abs($p->{price} - $prev->{price}) <= $tolerance) {
                push @{$self->{equal_levels}}, { type => 'EQH', state => 'Detected', index1 => $prev->{index}, index2 => $p->{index}, price1 => $prev->{price}, price2 => $p->{price}, price => ($prev->{price} + $p->{price}) / 2, tolerance => $tolerance, source => 'MinorPivotHigh' };
                last;
            }
        }
        push @{$self->{recent_highs}}, $p;
        shift @{$self->{recent_highs}} while @{$self->{recent_highs}} > $lookback_pivots;
    } elsif ($p->{type} eq 'LOW') {
        for my $prev (@{$self->{recent_lows}}) {
            if (abs($p->{price} - $prev->{price}) <= $tolerance) {
                push @{$self->{equal_levels}}, { type => 'EQL', state => 'Detected', index1 => $prev->{index}, index2 => $p->{index}, price1 => $prev->{price}, price2 => $p->{price}, price => ($prev->{price} + $p->{price}) / 2, tolerance => $tolerance, source => 'MinorPivotLow' };
                last;
            }
        }
        push @{$self->{recent_lows}}, $p;
        shift @{$self->{recent_lows}} while @{$self->{recent_lows}} > $lookback_pivots;
    }
}
1;