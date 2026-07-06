package Market::Indicators::Liquidity;
use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        atr_period     => $args{atr_period}     // 14,
        atr_mult       => $args{atr_mult}       // 3.0,
        eq_tolerance   => $args{eq_tolerance}   // 0.12,
        confirm_bars   => $args{confirm_bars}   // 3,
        max_open_lines => $args{max_open_lines} // 180,
        state          => 'BUSCANDO_MAXIMO',
        candidate_high => undef,
        candidate_low  => undef,
        pivots         => [],
        liquidity      => [],
        equal_levels   => [],
        internal_zigzag => [],
        external_zigzag => [],
        internal_tf     => $args{internal_tf}     // '30m',
        internal_period => $args{internal_period} // 2,
        external_length => $args{external_length} // 150,
        external_amount => $args{external_amount} // 20,
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{state}          = 'BUSCANDO_MAXIMO';
    $self->{candidate_high} = undef;
    $self->{candidate_low}  = undef;
    $self->{pivots}         = [];
    $self->{liquidity}      = [];
    $self->{equal_levels}   = [];
    $self->{internal_zigzag} = [];
    $self->{external_zigzag} = [];
}

# Recalcula todo el historial visible de la temporalidad activa. Es más estable que
# acumular pivotes duplicados al cambiar timeframe o al volver desde Replay.
sub recalculate {
    my ($self, $market_data) = @_;
    $self->reset();
    return unless $market_data;

    my $size = $market_data->size();
    return if $size < 3;

    my $atr_values = $self->_build_atr_series($market_data);

    # Nuevo enfoque solicitado por el profesor:
    # 1) ZigZag interno: pivotes de una temporalidad superior configurable
    #    (por defecto 30m, periodo 2), similar al ZZMTF.
    # 2) ZigZag externo: pivotes más amplios filtrados por longitud/volumen,
    #    aproximando el ZigZag Volume Profile para eliminar ruido.
    $self->_build_professor_zigzags($market_data, $atr_values);

    # La liquidez se genera desde el zigzag externo para evitar demasiados
    # BSL/SSL sobre micro-oscilaciones. Si no hay suficiente data externa,
    # usamos el interno como respaldo.
    my $liquidity_pivots = @{$self->{external_zigzag}} >= 2
        ? $self->{external_zigzag}
        : $self->{internal_zigzag};

    for my $pivot (@$liquidity_pivots) {
        my $type = ($pivot->{type} || '') eq 'HIGH' ? 'BSL' : 'SSL';
        $self->_create_liquidity_level($pivot, $type);
    }

    for my $i (0 .. $size - 1) {
        my $bar = $market_data->get_candle($i);
        next unless $bar;
        $self->_update_liquidity_states($bar, $i);
    }

    # Para EQH/EQL usamos el zigzag interno, porque ahí se ven mejor las
    # igualdades de máximos/mínimos sin mezclar todas las velas de 1m.
    $self->{pivots} = [ @{$self->{internal_zigzag}} ];
    $self->_detect_equal_levels();
    $self->_limit_old_open_levels($size - 1);
}

sub _build_professor_zigzags {
    my ($self, $market_data, $atr_values) = @_;

    my $base = $self->_base_candles_visible($market_data);
    return unless @$base >= 10;

    my $internal_tf = $self->{internal_tf} || '30m';
    my $internal_period = $self->{internal_period} || 2;

    # Si la temporalidad activa es mayor que 30m, no tiene sentido dibujar
    # un zigzag interno de 30m encima de velas de 2h/4h/D, porque se amontona.
    # En ese caso subimos la resolución interna a la temporalidad activa.
    my $active_tf = $market_data->{timeframe} || '1m';
    my $active_seconds = _tf_seconds_ext($active_tf);
    my $internal_seconds = _tf_seconds_ext($internal_tf);
    $internal_tf = $active_tf if defined $active_seconds && defined $internal_seconds && $active_seconds > $internal_seconds;

    my $internal_candles = $self->_aggregate_candles($base, $internal_tf);
    my $internal_raw = $self->_build_fractal_zigzag($internal_candles, $internal_period);
    my $internal = $self->_map_pivots_to_active($market_data, $internal_raw);
    $internal = $self->_label_pivots($internal);

    my $external_length = $self->{external_length} || 150;
    my $external_depth = int($external_length / 2);
    $external_depth = 8 if $external_depth < 8;

    my $external_raw = $self->_build_fractal_zigzag($base, $external_depth);
    $external_raw = $self->_filter_external_by_move_and_volume($external_raw, $base);
    my $external = $self->_map_pivots_to_active($market_data, $external_raw);
    $external = $self->_keep_last_zigzag_points($external, ($self->{external_amount} || 20) + 1);
    $external = $self->_label_pivots($external);

    $self->{internal_zigzag} = $internal;
    $self->{external_zigzag} = $external;
}

sub _base_candles_visible {
    my ($self, $market_data) = @_;
    my $base = $market_data->{candles} || $market_data->{data}{'1m'} || [];
    return [] unless @$base;

    my $last_active = $market_data->get_candle($market_data->last_index());
    my $end_epoch = $last_active ? $last_active->{epoch} : undef;
    return [ @$base ] unless defined $end_epoch;

    my @visible = grep { defined $_->{epoch} && $_->{epoch} <= $end_epoch } @$base;
    return \@visible;
}

sub _tf_seconds_ext {
    my ($tf) = @_;
    return 60 if $tf eq '1m';
    return 5 * 60 if $tf eq '5m';
    return 15 * 60 if $tf eq '15m';
    return 30 * 60 if $tf eq '30m';
    return 60 * 60 if $tf eq '60m' || $tf eq '1h';
    return 2 * 3600 if $tf eq '2h';
    return 4 * 3600 if $tf eq '4h';
    return 24 * 3600 if $tf eq 'D';
    return 7 * 24 * 3600 if $tf eq 'W';
    return 30 * 60;
}

sub _aggregate_candles {
    my ($self, $candles, $tf) = @_;
    my $seconds = _tf_seconds_ext($tf);
    my @out;
    my ($current, $bucket);

    for my $c (@$candles) {
        next unless $c && defined $c->{epoch};
        my $b = int($c->{epoch} / $seconds) * $seconds;
        if (!defined $current || $b != $bucket) {
            push @out, $current if $current;
            $bucket = $b;
            $current = {
                time => $c->{time}, epoch => $b,
                open => 0.0 + $c->{open}, high => 0.0 + $c->{high},
                low => 0.0 + $c->{low}, close => 0.0 + $c->{close},
                volume => 0.0 + ($c->{volume} // 0),
            };
        } else {
            $current->{high} = $c->{high} if $c->{high} > $current->{high};
            $current->{low} = $c->{low} if $c->{low} < $current->{low};
            $current->{close} = 0.0 + $c->{close};
            $current->{volume} += 0.0 + ($c->{volume} // 0);
        }
    }
    push @out, $current if $current;
    return \@out;
}

sub _build_fractal_zigzag {
    my ($self, $candles, $period) = @_;
    $period ||= 2;
    return [] unless $candles && @$candles > ($period * 2 + 1);

    my @candidates;
    for my $i ($period .. $#$candles - $period) {
        my $c = $candles->[$i];
        next unless $c;
        my ($is_high, $is_low) = (1, 1);
        for my $j ($i - $period .. $i + $period) {
            next if $j == $i;
            $is_high = 0 if ($candles->[$j]{high} // 0) > ($c->{high} // 0);
            $is_low  = 0 if ($candles->[$j]{low}  // 0) < ($c->{low}  // 0);
        }
        push @candidates, { %$c, type => 'HIGH', price => $c->{high}, source_index => $i } if $is_high;
        push @candidates, { %$c, type => 'LOW',  price => $c->{low},  source_index => $i } if $is_low;
    }

    @candidates = sort { ($a->{epoch} // 0) <=> ($b->{epoch} // 0) || (($a->{type}||'') cmp ($b->{type}||'')) } @candidates;
    return $self->_normalize_alternating_pivots(\@candidates);
}

sub _normalize_alternating_pivots {
    my ($self, $pivots) = @_;
    my @out;
    for my $p (@$pivots) {
        next unless $p && defined $p->{type} && defined $p->{price};
        if (!@out) { push @out, $p; next; }
        my $last = $out[-1];
        if ($p->{type} eq $last->{type}) {
            my $replace = 0;
            $replace = 1 if $p->{type} eq 'HIGH' && $p->{price} > $last->{price};
            $replace = 1 if $p->{type} eq 'LOW'  && $p->{price} < $last->{price};
            $out[-1] = $p if $replace;
        } else {
            push @out, $p;
        }
    }
    return \@out;
}

sub _filter_external_by_move_and_volume {
    my ($self, $pivots, $base) = @_;
    return [] unless $pivots && @$pivots;

    my $avg_vol = 0;
    $avg_vol += ($_->{volume} // 0) for @$base;
    $avg_vol = @$base ? $avg_vol / @$base : 0;

    my @out;
    for my $p (@$pivots) {
        if (!@out) { push @out, $p; next; }
        my $last = $out[-1];
        my $move = abs(($p->{price} // 0) - ($last->{price} // 0));
        my $vol_bonus = (($p->{volume} // 0) >= $avg_vol * 1.15) ? 0.85 : 1.0;
        my $min_move = (($last->{price} // $p->{price}) * 0.0018) * $vol_bonus;

        if (($p->{type} || '') eq ($last->{type} || '')) {
            my $replace = 0;
            $replace = 1 if $p->{type} eq 'HIGH' && $p->{price} > $last->{price};
            $replace = 1 if $p->{type} eq 'LOW'  && $p->{price} < $last->{price};
            $out[-1] = $p if $replace;
        } elsif ($move >= $min_move) {
            push @out, $p;
        }
    }
    return \@out;
}

sub _map_pivots_to_active {
    my ($self, $market_data, $pivots) = @_;
    return [] unless $pivots && @$pivots;

    my $active = $market_data->_active_array();
    my $last_visible = $market_data->last_index();
    my @mapped;

    for my $p (@$pivots) {
        my $epoch = $p->{epoch};
        next unless defined $epoch;
        my $idx = $self->_find_active_index_by_epoch($active, $last_visible, $epoch);
        next unless defined $idx;
        next if $idx > $last_visible;
        my $active_candle = $market_data->get_candle($idx);
        my $atr = $active_candle ? (($active_candle->{high} // 0) - ($active_candle->{low} // 0)) : 0;
        push @mapped, {
            type => $p->{type}, index => $idx, price => $p->{price},
            timestamp => $p->{time}, epoch => $epoch, volume => $p->{volume}, atr => $atr,
        };
    }

    @mapped = sort { ($a->{index} // 0) <=> ($b->{index} // 0) } @mapped;
    @mapped = @{$self->_dedupe_same_index(\@mapped)};
    return $self->_normalize_alternating_pivots(\@mapped);
}

sub _find_active_index_by_epoch {
    my ($self, $active, $last_visible, $epoch) = @_;
    return undef unless $active && @$active;
    $last_visible = $#$active if !defined($last_visible) || $last_visible > $#$active;

    my ($lo, $hi) = (0, $last_visible);
    my $best = 0;
    while ($lo <= $hi) {
        my $mid = int(($lo + $hi) / 2);
        my $e = $active->[$mid]{epoch};
        if (!defined $e || $e <= $epoch) { $best = $mid; $lo = $mid + 1; }
        else { $hi = $mid - 1; }
    }
    return $best;
}


sub _dedupe_same_index {
    my ($self, $pivots) = @_;
    my @out;
    for my $p (@$pivots) {
        next unless $p;
        if (@out && defined $p->{index} && defined $out[-1]{index} && $p->{index} == $out[-1]{index}) {
            my $last = $out[-1];
            if (($p->{type} || '') eq ($last->{type} || '')) {
                my $replace = 0;
                $replace = 1 if $p->{type} eq 'HIGH' && $p->{price} > $last->{price};
                $replace = 1 if $p->{type} eq 'LOW'  && $p->{price} < $last->{price};
                $out[-1] = $p if $replace;
            }
            # Si son tipos distintos dentro de la misma vela comprimida, dejamos
            # solo uno para no dibujar dos giros imposibles en la misma coordenada.
            next;
        }
        push @out, $p;
    }
    return \@out;
}

sub _label_pivots {
    my ($self, $pivots) = @_;
    my ($last_high, $last_low);
    my @out;
    for my $p (@$pivots) {
        my %q = %$p;
        if (($q{type} || '') eq 'HIGH') {
            $q{label} = !defined $last_high ? 'H' : ($q{price} > $last_high->{price} ? 'HH' : 'LH');
            $last_high = \%q;
        } elsif (($q{type} || '') eq 'LOW') {
            $q{label} = !defined $last_low ? 'L' : ($q{price} > $last_low->{price} ? 'HL' : 'LL');
            $last_low = \%q;
        }
        push @out, \%q;
    }
    return \@out;
}

sub _keep_last_zigzag_points {
    my ($self, $pivots, $max_points) = @_;
    return $pivots unless $pivots && @$pivots > $max_points;
    my @slice = @$pivots[-$max_points .. -1];
    return \@slice;
}

sub update_last {
    my ($self, $market_data) = @_;
    # Para el tamaño del proyecto y la presentación, recalcular elimina estados viejos
    # que antes quedaban vivos y ensuciaban la vista.
    $self->recalculate($market_data);
}

sub _build_atr_series {
    my ($self, $market_data) = @_;
    my $period = $self->{atr_period} || 14;
    my $size   = $market_data->size();
    my @atr = (0) x $size;
    my @tr;

    for my $i (0 .. $size - 1) {
        my $c = $market_data->get_candle($i);
        next unless $c;
        my $range = ($c->{high} // 0) - ($c->{low} // 0);
        if ($i == 0) {
            $tr[$i] = $range;
        } else {
            my $p = $market_data->get_candle($i - 1);
            my $hc = abs(($c->{high} // 0) - ($p->{close} // 0));
            my $lc = abs(($c->{low}  // 0) - ($p->{close} // 0));
            $tr[$i] = _max($range, $hc, $lc);
        }

        my $from = $i - $period + 1;
        $from = 0 if $from < 0;
        my ($sum, $count) = (0, 0);
        for my $j ($from .. $i) {
            next unless defined $tr[$j];
            $sum += $tr[$j];
            $count++;
        }
        $atr[$i] = $count ? $sum / $count : 0;
    }
    return \@atr;
}

sub _process_structural_pivot {
    my ($self, $bar, $atr, $i, $market_data) = @_;
    my $threshold = $atr * ($self->{atr_mult} || 3.0);
    my $confirm_bars = $self->{confirm_bars} || 1;

    my $high  = $bar->{high};
    my $low   = $bar->{low};
    my $close = $bar->{close};

    if ($self->{state} eq 'BUSCANDO_MAXIMO') {
        if (!defined $self->{candidate_high} || $high > $self->{candidate_high}->{price}) {
            $self->{candidate_high} = {
                type  => 'HIGH', index => $i, price => $high, atr => $atr,
                timestamp => $market_data->get_timestamp($i),
            };
        }

        if (defined $self->{candidate_high}
            && ($self->{candidate_high}->{price} - $close) >= $threshold
            && ($i - $self->{candidate_high}->{index}) >= $confirm_bars) {
            my $pivot = $self->{candidate_high};
            push @{$self->{pivots}}, $pivot;
            $self->_create_liquidity_level($pivot, 'BSL');
            $self->{candidate_low} = {
                type => 'LOW', index => $i, price => $low, atr => $atr,
                timestamp => $market_data->get_timestamp($i),
            };
            $self->{candidate_high} = undef;
            $self->{state} = 'BUSCANDO_MINIMO';
        }
    }
    else {
        if (!defined $self->{candidate_low} || $low < $self->{candidate_low}->{price}) {
            $self->{candidate_low} = {
                type  => 'LOW', index => $i, price => $low, atr => $atr,
                timestamp => $market_data->get_timestamp($i),
            };
        }

        if (defined $self->{candidate_low}
            && ($close - $self->{candidate_low}->{price}) >= $threshold
            && ($i - $self->{candidate_low}->{index}) >= $confirm_bars) {
            my $pivot = $self->{candidate_low};
            push @{$self->{pivots}}, $pivot;
            $self->_create_liquidity_level($pivot, 'SSL');
            $self->{candidate_high} = {
                type => 'HIGH', index => $i, price => $high, atr => $atr,
                timestamp => $market_data->get_timestamp($i),
            };
            $self->{candidate_low} = undef;
            $self->{state} = 'BUSCANDO_MAXIMO';
        }
    }
}

sub _create_liquidity_level {
    my ($self, $pivot, $type) = @_;
    return unless $pivot;
    push @{$self->{liquidity}}, {
        index         => $pivot->{index},
        created_index => $pivot->{index},
        price         => $pivot->{price},
        type          => $type,
        state         => 'DETECTED',
        detected_at   => $pivot->{timestamp},
        atr           => $pivot->{atr},
        bar_count     => 0,
    };
}

sub _update_liquidity_states {
    my ($self, $bar, $i) = @_;
    for my $lvl (@{$self->{liquidity}}) {
        next if defined $lvl->{resolved_index};
        next if $i <= ($lvl->{created_index} // $lvl->{index});

        my $tol = (($lvl->{atr} // 0) > 0 ? $lvl->{atr} : 0.0001) * 0.10;

        if ($lvl->{type} eq 'BSL' && $bar->{high} >= $lvl->{price}) {
            $lvl->{bar_count}++;
            if (($bar->{close} // 0) > $lvl->{price} + $tol) {
                $self->_resolve_level($lvl, 'RUN', $i);
            } elsif (($bar->{close} // 0) < $lvl->{price} - $tol) {
                $self->_resolve_level($lvl, 'SWEEP', $i);
            } elsif (($bar->{low} // 0) <= $lvl->{price}) {
                $self->_resolve_level($lvl, 'GRAB', $i);
            }
        }
        elsif ($lvl->{type} eq 'SSL' && $bar->{low} <= $lvl->{price}) {
            $lvl->{bar_count}++;
            if (($bar->{close} // 0) < $lvl->{price} - $tol) {
                $self->_resolve_level($lvl, 'RUN', $i);
            } elsif (($bar->{close} // 0) > $lvl->{price} + $tol) {
                $self->_resolve_level($lvl, 'SWEEP', $i);
            } elsif (($bar->{high} // 0) >= $lvl->{price}) {
                $self->_resolve_level($lvl, 'GRAB', $i);
            }
        }
    }
}

sub _resolve_level {
    my ($self, $lvl, $state, $i) = @_;
    $lvl->{state}          = $state;
    $lvl->{resolved_index} = $i;
    $lvl->{resolved_at}    = $i;
}

sub _detect_equal_levels {
    my ($self) = @_;
    my @pivots = @{$self->{pivots}};
    return if @pivots < 2;

    for my $i (1 .. $#pivots) {
        my $a = $pivots[$i - 1];
        my $b = $pivots[$i];
        next unless $a->{type} eq $b->{type};
        my $atr = (($a->{atr} // 0) + ($b->{atr} // 0)) / 2;
        $atr = 0.0001 if $atr <= 0;
        next if abs($a->{price} - $b->{price}) > $atr * ($self->{eq_tolerance} || 0.12);

        push @{$self->{equal_levels}}, {
            type   => $a->{type} eq 'HIGH' ? 'EQH' : 'EQL',
            index1 => $a->{index},
            index2 => $b->{index},
            price  => ($a->{price} + $b->{price}) / 2,
        };
    }
}

sub _limit_old_open_levels {
    my ($self, $last_index) = @_;
    my $max = $self->{max_open_lines} || 180;
    return if @{$self->{liquidity}} <= $max;
    my @sorted = sort { ($a->{created_index} // $a->{index}) <=> ($b->{created_index} // $b->{index}) } @{$self->{liquidity}};
    @sorted = @sorted[-$max .. -1] if @sorted > $max;
    $self->{liquidity} = \@sorted;
}

sub get_values       { return $_[0]->{liquidity}; }
sub get_internal_zigzag { return $_[0]->{internal_zigzag}; }
sub get_external_zigzag { return $_[0]->{external_zigzag}; }
sub get_pivots       { return $_[0]->{pivots}; }
sub get_equal_levels { return $_[0]->{equal_levels}; }

sub get_resolved_events {
    my ($self) = @_;
    my @resolved = grep { defined $_->{resolved_index} } @{$self->{liquidity}};
    return \@resolved;
}

sub calculate_eq_tolerance {
    my ($self, $atr_value) = @_;
    return $atr_value && $atr_value > 0 ? $atr_value * ($self->{eq_tolerance} || 0.12) : 0.0001;
}

sub compute_atr {
    my ($self, $market_data) = @_;
    my $atr = $self->_build_atr_series($market_data);
    return $atr->[-1] // 0;
}

sub _max {
    my $m = shift;
    for my $v (@_) { $m = $v if $v > $m; }
    return $m;
}

1;
