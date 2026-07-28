package Market::Indicators::Anchors;

use strict;
use warnings;

=head1 NOMBRE

Market::Indicators::Anchors - Motor de cálculo de "Dynamic Swing Anchored VWAP"

=cut

use constant TYPE_HIGH => 'high';
use constant TYPE_LOW  => 'low';

sub new {
    my ($class, %args) = @_;

    my $self = {
        length   => $args{length}   // 50,
        std_mult => $args{std_mult} // 1,
    };

    bless $self, $class;
    $self->reset();
    return $self;
}

sub reset {
    my ($self) = @_;

    # Estado de la máquina de extracción de pivotes
    $self->{max}            = 0.0;
    $self->{min}            = 0.0;
    $self->{max_x1}         = 0;
    $self->{min_x1}         = 0;
    $self->{follow_max}     = 0.0;
    $self->{follow_min}     = 0.0;
    $self->{follow_max_x1}  = 0;
    $self->{follow_min_x1}  = 0;
    $self->{os}             = 0;
    $self->{px1}            = 0;
    $self->{py1}            = 0.0;

    # Salidas acumuladas
    $self->{markers}              = [];
    $self->{ghost_lines}          = [];
    $self->{ghost_level_segments} = [];
    $self->{ghost_level_open}     = undef;

    # Estado del Ghost VWAP (Pivote Fantasma / Missed)
    $self->{live_ghost}      = undef;
    $self->{ghost_vwap}      = undef;

    # Cache incremental de _update_live_ghost: evita re-escanear
    # [px1+1 .. i] entero en cada vela (ver comentario en el método).
    $self->{lg_anchor_px1}  = undef;
    $self->{lg_anchor_os}   = undef;
    $self->{lg_last_index}  = undef;
    $self->{lg_best_price}  = undef;
    $self->{lg_best_idx}    = undef;
    $self->{gv_anchor_index} = undef;
    $self->{gv_last_index}   = undef;
    $self->{gv_cum_vol}      = 0.0;
    $self->{gv_cum_pv}       = 0.0;
    $self->{gv_cum_pv2}      = 0.0;
    $self->{gv_values}       = [];

    # Estado del Regular VWAP (Último Pivote Confirmado)
    $self->{last_reg_anchor_index} = undef;
    $self->{regular_vwap}          = undef;
    $self->{rv_anchor_index}       = undef;
    $self->{rv_last_index}         = undef;
    $self->{rv_cum_vol}            = 0.0;
    $self->{rv_cum_pv}             = 0.0;
    $self->{rv_cum_pv2}            = 0.0;
    $self->{rv_values}             = [];

    return;
}

sub update_last {
    my ($self, $candles, $atr_values, $i) = @_;

    return $self->_snapshot($candles) unless defined $i && $candles && @$candles;

    my $length = $self->{length};
    my $c      = $i - $length;

    if ($c >= 0 && $c + $length <= $#$candles) {
        $self->_process_bar($candles, $c, $length);
    }

    # Recalcular Ghost VWAP (Pivote Fantasma Vivo)
    $self->_update_live_ghost($candles, $i);

    # Recalcular Regular VWAP (Último Pivote Confirmado)
    if (defined $self->{last_reg_anchor_index}) {
        $self->_update_regular_vwap($candles, $self->{last_reg_anchor_index}, $i);
    }

    return $self->_snapshot($candles);
}

sub _process_bar {
    my ($self, $candles, $c, $length) = @_;

    my $bar = $candles->[$c];
    return unless $bar;

    my $h = $bar->{high};
    my $l = $bar->{low};

    my $orig_max = $self->{max};
    my $orig_min = $self->{min};
    my $orig_os  = $self->{os};

    my $prev_max = $self->{max};
    my $prev_min = $self->{min};

    $self->{max} = $h if $h > $self->{max};
    $self->{min} = $l if $l < $self->{min};

    my $prev_follow_max = $self->{follow_max};
    my $prev_follow_min = $self->{follow_min};

    $self->{follow_max} = $h if $h > $self->{follow_max};
    $self->{follow_min} = $l if $l < $self->{follow_min};

    if ($self->{max} > $prev_max) {
        $self->{max_x1}     = $c;
        $self->{follow_min} = $l;
    }
    if ($self->{min} < $prev_min) {
        $self->{min_x1}     = $c;
        $self->{follow_max} = $h;
    }
    if ($self->{follow_min} < $prev_follow_min) {
        $self->{follow_min_x1} = $c;
    }
    if ($self->{follow_max} > $prev_follow_max) {
        $self->{follow_max_x1} = $c;
    }

    my $is_ph = _is_pivot_high($candles, $c, $length);
    my $is_pl = _is_pivot_low($candles, $c, $length);

    return unless $is_ph || $is_pl;

    if ($is_ph) {
        my $ph = $h;

        if ($orig_os == 1) {
            push @{$self->{markers}}, { index => $self->{min_x1}, price => $self->{min}, type => 'missed_low' };
            $self->_push_ghost_line($self->{min_x1}, $self->{min}, TYPE_LOW);
            $self->_open_ghost_level($self->{min_x1}, $self->{min}, TYPE_LOW);
        }
        elsif ($ph < $orig_max) {
            push @{$self->{markers}}, { index => $self->{max_x1}, price => $self->{max}, type => 'missed_high' };
            push @{$self->{markers}}, { index => $self->{follow_min_x1}, price => $self->{follow_min}, type => 'missed_low' };

            $self->_push_ghost_line($self->{max_x1}, $self->{max}, TYPE_HIGH);
            $self->_open_ghost_level($self->{max_x1}, $self->{max}, TYPE_HIGH);

            $self->_push_ghost_line($self->{follow_min_x1}, $self->{follow_min}, TYPE_LOW);
            $self->_open_ghost_level($self->{follow_min_x1}, $self->{follow_min}, TYPE_LOW);
        }

        # Pivote regular
        push @{$self->{markers}}, { index => $c, price => $ph, type => 'reg_high' };
        $self->{last_reg_anchor_index} = $c; # <-- Guardar índice del pivote regular

        my $dashed = ($ph < $orig_max) || ($orig_os == 1);
        $self->_push_ghost_line($c, $ph, TYPE_HIGH, $dashed, 1);

        $self->{os}  = 1;
        $self->{max} = $ph;
        $self->{min} = $ph;
    }

    if ($is_pl) {
        my $pl = $l;

        if ($orig_os == 0) {
            push @{$self->{markers}}, { index => $self->{max_x1}, price => $self->{max}, type => 'missed_high' };
            $self->_push_ghost_line($self->{max_x1}, $self->{max}, TYPE_HIGH);
            $self->_open_ghost_level($self->{max_x1}, $self->{max}, TYPE_HIGH);
        }
        elsif ($pl > $orig_min) {
            push @{$self->{markers}}, { index => $self->{follow_max_x1}, price => $self->{follow_max}, type => 'missed_high' };
            push @{$self->{markers}}, { index => $self->{min_x1}, price => $self->{min}, type => 'missed_low' };

            $self->_push_ghost_line($self->{min_x1}, $self->{min}, TYPE_LOW);
            $self->_open_ghost_level($self->{min_x1}, $self->{min}, TYPE_LOW);

            $self->_push_ghost_line($self->{follow_max_x1}, $self->{follow_max}, TYPE_HIGH);
            $self->_open_ghost_level($self->{follow_max_x1}, $self->{follow_max}, TYPE_HIGH);
        }

        # Pivote regular
        push @{$self->{markers}}, { index => $c, price => $pl, type => 'reg_low' };
        $self->{last_reg_anchor_index} = $c; # <-- Guardar índice del pivote regular

        my $dashed = ($pl > $orig_min) || ($orig_os == 0);
        $self->_push_ghost_line($c, $pl, TYPE_LOW, $dashed, 1);

        $self->{os}  = 0;
        $self->{max} = $pl;
        $self->{min} = $pl;
    }
}

sub _push_ghost_line {
    my ($self, $x, $y, $color_type, $dashed, $explicit) = @_;

    $dashed = 1 unless defined $dashed && $explicit;

    push @{$self->{ghost_lines}}, {
        x1         => $self->{px1},
        y1         => $self->{py1},
        x2         => $x,
        y2         => $y,
        color_type => $color_type,
        dashed     => $dashed ? 1 : 0,
    };

    $self->{px1} = $x;
    $self->{py1} = $y;
}

sub _open_ghost_level {
    my ($self, $x, $y, $color_type) = @_;

    if (my $open = $self->{ghost_level_open}) {
        push @{$self->{ghost_level_segments}}, {
            x1         => $open->{x1},
            y          => $open->{y},
            x2         => $x,
            color_type => $open->{color_type},
        };
    }

    $self->{ghost_level_open} = { x1 => $x, y => $y, color_type => $color_type };
}

# ─── Cálculo Ghost VWAP ───────────────────────────────────────────────────

sub _update_live_ghost {
    my ($self, $candles, $i) = @_;

    my $px1 = $self->{px1};
    my $os  = $self->{os};

    return if $i <= $px1;

    # El "pivote fantasma vivo" es el mejor low/high visto desde el último
    # pivote confirmado ($px1). Antes esto re-escaneaba [px1+1 .. i] entero
    # en CADA vela -> O(rango) por vela, O(rango^2) acumulado entre dos
    # pivotes confirmados (con length=50 el rango puede ser de cientos de
    # velas). Ahora se mantiene el mejor valor en caché y sólo se
    # reconstruye desde cero cuando cambia el ancla (px1/os) o cuando la
    # secuencia no es contigua (saltos de Modo Replay / reset), igual que
    # ya hacen _update_ghost_vwap y _update_regular_vwap.
    my $same_anchor = defined $self->{lg_anchor_px1}
        && $self->{lg_anchor_px1} == $px1
        && defined $self->{lg_anchor_os}
        && $self->{lg_anchor_os} == $os;
    my $contiguous = defined $self->{lg_last_index}
        && $self->{lg_last_index} == $i - 1;

    my ($best_price, $best_idx);

    if ($same_anchor && $contiguous) {
        # Caso común: sólo comparar la vela nueva contra el mejor ya visto.
        $best_price = $self->{lg_best_price};
        $best_idx   = $self->{lg_best_idx};

        my $bar = $candles->[$i];
        if ($bar) {
            my $val = ($os == 1) ? $bar->{low} : $bar->{high};
            if (!defined $best_price
                || ($os == 1 ? ($val < $best_price) : ($val > $best_price))) {
                $best_price = $val;
                $best_idx   = $i;
            }
        }
    }
    else {
        # Ancla nueva o secuencia discontinua: reconstruir una sola vez.
        for my $j (($px1 + 1) .. $i) {
            my $bar = $candles->[$j];
            next unless $bar;
            my $val = ($os == 1) ? $bar->{low} : $bar->{high};
            if (!defined $best_price
                || ($os == 1 ? ($val < $best_price) : ($val > $best_price))) {
                $best_price = $val;
                $best_idx   = $j;
            }
        }
    }

    $self->{lg_anchor_px1} = $px1;
    $self->{lg_anchor_os}  = $os;
    $self->{lg_last_index} = $i;
    $self->{lg_best_price} = $best_price;
    $self->{lg_best_idx}   = $best_idx;

    return unless defined $best_price;

    $self->{live_ghost} = { index => $best_idx, price => $best_price, dir => $os };

    $self->_update_ghost_vwap($candles, $best_idx, $i);
}

sub _update_ghost_vwap {
    my ($self, $candles, $anchor_idx, $i) = @_;

    my $same_anchor = defined $self->{gv_anchor_index} && $self->{gv_anchor_index} == $anchor_idx;
    my $contiguous  = defined $self->{gv_last_index} && $self->{gv_last_index} == $i - 1;

    if (!$same_anchor || !$contiguous) {
        $self->{gv_anchor_index} = $anchor_idx;
        $self->{gv_cum_vol}      = 0.0;
        $self->{gv_cum_pv}       = 0.0;
        $self->{gv_cum_pv2}      = 0.0;
        $self->{gv_values}       = [];

        for my $j ($anchor_idx .. $i) {
            $self->_accumulate_ghost_vwap($candles, $j);
        }
    }
    else {
        $self->_accumulate_ghost_vwap($candles, $i);
    }

    $self->{gv_last_index} = $i;
    $self->{ghost_vwap} = {
        anchor_index => $self->{gv_anchor_index},
        values       => $self->{gv_values},
    };
}

sub _accumulate_ghost_vwap {
    my ($self, $candles, $j) = @_;

    my $c = $candles->[$j];
    return unless $c;

    my $tp  = ($c->{high} + $c->{low} + $c->{close}) / 3;
    my $vol = $c->{volume} // 0;
    $vol = 0 if $vol eq '';

    $self->{gv_cum_vol} += $vol;
    $self->{gv_cum_pv}  += $tp * $vol;
    $self->{gv_cum_pv2} += $tp * $tp * $vol;

    my $mult = $self->{std_mult};
    my ($vwap, $stdev, %upper_n, %lower_n);

    if ($self->{gv_cum_vol} > 0) {
        $vwap = $self->{gv_cum_pv} / $self->{gv_cum_vol};
        my $variance = ($self->{gv_cum_pv2} / $self->{gv_cum_vol}) - ($vwap * $vwap);
        $variance = 0 if $variance < 0;
        $stdev = sqrt($variance);
    }
    else {
        $vwap  = $tp;
        $stdev = 0;
    }

    for my $n (1, 2, 3) {
        $upper_n{$n} = $vwap + $n * $stdev;
        $lower_n{$n} = $vwap - $n * $stdev;
    }

    push @{$self->{gv_values}}, {
        index  => $j,
        vwap   => $vwap,
        upper  => $vwap + $mult * $stdev,
        lower  => $vwap - $mult * $stdev,
        upper1 => $upper_n{1}, lower1 => $lower_n{1},
        upper2 => $upper_n{2}, lower2 => $lower_n{2},
        upper3 => $upper_n{3}, lower3 => $lower_n{3},
    };
}

# ─── Cálculo Regular VWAP ─────────────────────────────────────────────────

sub _update_regular_vwap {
    my ($self, $candles, $anchor_idx, $i) = @_;

    my $same_anchor = defined $self->{rv_anchor_index} && $self->{rv_anchor_index} == $anchor_idx;
    my $contiguous  = defined $self->{rv_last_index} && $self->{rv_last_index} == $i - 1;

    if (!$same_anchor || !$contiguous) {
        $self->{rv_anchor_index} = $anchor_idx;
        $self->{rv_cum_vol}      = 0.0;
        $self->{rv_cum_pv}       = 0.0;
        $self->{rv_cum_pv2}      = 0.0;
        $self->{rv_values}       = [];

        for my $j ($anchor_idx .. $i) {
            $self->_accumulate_regular_vwap($candles, $j);
        }
    }
    else {
        $self->_accumulate_regular_vwap($candles, $i);
    }

    $self->{rv_last_index} = $i;
    $self->{regular_vwap} = {
        anchor_index => $self->{rv_anchor_index},
        values       => $self->{rv_values},
    };
}

sub _accumulate_regular_vwap {
    my ($self, $candles, $j) = @_;

    my $c = $candles->[$j];
    return unless $c;

    my $tp  = ($c->{high} + $c->{low} + $c->{close}) / 3;
    my $vol = $c->{volume} // 0;
    $vol = 0 if $vol eq '';

    $self->{rv_cum_vol} += $vol;
    $self->{rv_cum_pv}  += $tp * $vol;
    $self->{rv_cum_pv2} += $tp * $tp * $vol;

    my $mult = $self->{std_mult};
    my ($vwap, $stdev, %upper_n, %lower_n);

    if ($self->{rv_cum_vol} > 0) {
        $vwap = $self->{rv_cum_pv} / $self->{rv_cum_vol};
        my $variance = ($self->{rv_cum_pv2} / $self->{rv_cum_vol}) - ($vwap * $vwap);
        $variance = 0 if $variance < 0;
        $stdev = sqrt($variance);
    }
    else {
        $vwap  = $tp;
        $stdev = 0;
    }

    for my $n (1, 2, 3) {
        $upper_n{$n} = $vwap + $n * $stdev;
        $lower_n{$n} = $vwap - $n * $stdev;
    }

    push @{$self->{rv_values}}, {
        index  => $j,
        vwap   => $vwap,
        upper  => $vwap + $mult * $stdev,
        lower  => $vwap - $mult * $stdev,
        upper1 => $upper_n{1}, lower1 => $lower_n{1},
        upper2 => $upper_n{2}, lower2 => $lower_n{2},
        upper3 => $upper_n{3}, lower3 => $lower_n{3},
    };
}

# ─── Snapshot de salida ────────────────────────────────────────────────

sub _snapshot {
    my ($self, $candles) = @_;

    my @level_segments = @{$self->{ghost_level_segments}};
    if (my $open = $self->{ghost_level_open}) {
        push @level_segments, {
            x1         => $open->{x1},
            y          => $open->{y},
            x2         => undef,
            color_type => $open->{color_type},
            open       => 1,
        };
    }

    return {
        markers              => $self->{markers},
        ghost_lines          => $self->{ghost_lines},
        ghost_level_segments => \@level_segments,
        live_ghost           => $self->{live_ghost},
        ghost_vwap           => $self->{ghost_vwap},
        regular_vwap         => $self->{regular_vwap}, # <-- Ahora expuesto a la capa visual
        candles              => $candles,
    };
}

sub _is_pivot_high {
    my ($candles, $c, $length) = @_;

    return 0 if $c - $length < 0;
    return 0 if $c + $length > $#$candles;

    my $hi = $candles->[$c]{high};

    for my $i ($c - $length .. $c + $length) {
        next if $i == $c;
        return 0 if $candles->[$i]{high} >= $hi;
    }

    return 1;
}

sub _is_pivot_low {
    my ($candles, $c, $length) = @_;

    return 0 if $c - $length < 0;
    return 0 if $c + $length > $#$candles;

    my $lo = $candles->[$c]{low};

    for my $i ($c - $length .. $c + $length) {
        next if $i == $c;
        return 0 if $candles->[$i]{low} <= $lo;
    }

    return 1;
}

1;
