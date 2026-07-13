package Market::Indicators::Channel;

use strict;
use warnings;

=head1 NOMBRE

Market::Indicators::Channel - Motor de cálculo del indicador "Channel",
puerto de la lógica PineScript de channel.txt ("Channels With Patterns
[ChartPrime]", secciones predictive_channels / get_points / deltas).

Sólo se conserva la parte necesaria para dibujar la FRANJA INTERNA del
canal (la banda entre mid_top y mid_bottom, alrededor de la línea center),
que en el script original no se rellena. Las etiquetas de ruptura, patrones
de vela y alertas del original no se replican: este puerto está pensado
únicamente para overlay visual.

=head1 PARÁMETROS

  atr_length    => período de ATR usado para el tamaño del canal (def: 10)
  atr_multiplier=> multiplicador del tamaño del canal respecto al ATR (def: 4)
  offset        => desplazamiento vertical del canal, en "octavos" de ATR (def: 5 * 0.125)
  padding       => % de la banda ocupado por la franja interna (def: 50)
  pivot_length  => longitud hacia atrás para detectar pivotes (def: 10)
  look_forward  => longitud hacia adelante para confirmar pivotes (def: 15)
  avg_length    => longitud de suavizado SMA de máximos/mínimos (def: 18)
  history       => nº de canales históricos a conservar (def: 5)

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        atr_length     => $args{atr_length}     // 10,
        atr_multiplier => $args{atr_multiplier} // 4,
        offset         => ($args{offset}        // 5) * 0.125,
        padding        => $args{padding}        // 50,
        pivot_length   => $args{pivot_length}   // 10,
        look_forward   => $args{look_forward}   // 15,
        avg_length     => $args{avg_length}     // 18,
        history        => $args{history}        // 5,
        channels       => [],
    };

    return bless $self, $class;
}

sub reset {
    my ($self) = @_;
    $self->{channels} = [];
}

sub get_values {
    my ($self) = @_;
    return $self->{channels};
}

# --- True Range / ATR Wilder --------------------------------------------

sub _true_range {
    my ($candles, $i) = @_;
    my $c = $candles->[$i];
    if ($i == 0 || !$candles->[$i - 1]) {
        return $c->{high} - $c->{low};
    }
    my $prev_close = $candles->[$i - 1]->{close};
    my $hl = $c->{high} - $c->{low};
    my $hc = abs($c->{high} - $prev_close);
    my $lc = abs($c->{low}  - $prev_close);
    my $tr = $hl;
    $tr = $hc if $hc > $tr;
    $tr = $lc if $lc > $tr;
    return $tr;
}

sub _sma_window {
    my ($series, $i, $length) = @_;
    my $start = $i - $length + 1;
    $start = 0 if $start < 0;
    my ($sum, $n) = (0, 0);
    for my $j ($start .. $i) {
        next unless defined $series->[$j];
        $sum += $series->[$j];
        $n++;
    }
    return $n > 0 ? $sum / $n : undef;
}

# Replica ta.pivothigh/ta.pivotlow: el bar $i es pivote si su valor es el
# extremo estricto dentro de la ventana [$i-$length .. $i+$look_forward].
# Sólo puede confirmarse cuando existen $look_forward barras posteriores.
sub _is_pivot {
    my ($series, $i, $length, $look_forward, $is_high) = @_;
    my $n = scalar(@$series);
    return 0 if $i - $length < 0;
    return 0 if $i + $look_forward >= $n;

    my $v = $series->[$i];
    return 0 unless defined $v;

    for my $j ($i - $length .. $i + $look_forward) {
        next if $j == $i;
        next unless defined $series->[$j];
        if ($is_high) {
            return 0 if $series->[$j] >= $v;
        }
        else {
            return 0 if $series->[$j] <= $v;
        }
    }
    return 1;
}

=head2 calculate_until($candles, $until_index)

Recalcula desde cero la lista de canales (historial acotado por "history")
visibles hasta $until_index. Devuelve { channels => [ {...}, ... ] } donde
cada canal trae únicamente lo necesario para dibujar la franja interna:

  start, end          => índices de barra (inicio/fin del segmento dibujado)
  mid_top_y1/y2        => valores de precio de la línea superior de la franja
  mid_bottom_y1/y2      => valores de precio de la línea inferior de la franja
  polarity             => 1 (alcista) | 0 (bajista)
  seq                   => índice secuencial de creación (para alternar color)

=cut

sub calculate_until {
    my ($self, $candles, $until_index) = @_;

    $self->reset();
    return { channels => $self->{channels} }
        if !defined $until_index || $until_index < 0 || !$candles || $until_index >= scalar(@$candles);

    my $atr_length     = $self->{atr_length};
    my $atr_multiplier = $self->{atr_multiplier};
    my $offset_in      = $self->{offset};
    my $padding_pct    = $self->{padding};
    my $pivot_length   = $self->{pivot_length};
    my $look_forward   = $self->{look_forward};
    my $avg_length     = $self->{avg_length};

    # --- Series base: top = high, bottom = low (estilo "Wick") ---
    my (@top_series, @bottom_series, @tr_series, @atr_wilder, @catr_series);
    my ($catr, $catr_count) = (0, 0);

    for my $i (0 .. $until_index) {
        my $c = $candles->[$i];
        $top_series[$i]    = $c->{high};
        $bottom_series[$i] = $c->{low};

        my $tr = _true_range($candles, $i);
        $tr_series[$i] = $tr;

        if ($i < $atr_length - 1) {
            $atr_wilder[$i] = undef;
        }
        elsif ($i == $atr_length - 1) {
            my $s = 0;
            $s += $tr_series[$_] for (0 .. $atr_length - 1);
            $atr_wilder[$i] = $s / $atr_length;
        }
        else {
            $atr_wilder[$i] = ($atr_wilder[$i - 1] * ($atr_length - 1) + $tr) / $atr_length;
        }

        # cema(tr) / 8.71875, según channel.txt
        $catr_count++;
        my $alpha = 2.0 / ($catr_count + 1.0);
        $catr = (1.0 - $alpha) * $catr + $alpha * $tr;
        $catr_series[$i] = $catr / 8.71875;
    }

    my (@avg_high, @avg_low);
    for my $i (0 .. $until_index) {
        $avg_high[$i] = _sma_window(\@top_series, $i, $avg_length);
        $avg_low[$i]  = _sma_window(\@bottom_series, $i, $avg_length);
    }

    # --- Pivotes (con confirmación diferida look_forward barras) ---
    my (@pivot_high_flag, @pivot_low_flag);
    for my $i (0 .. $until_index) {
        $pivot_high_flag[$i] = _is_pivot(\@top_series, $i, $pivot_length, $look_forward, 1);
        $pivot_low_flag[$i]  = _is_pivot(\@bottom_series, $i, $pivot_length, $look_forward, 0);
    }

    my $history_len = $self->{history};
    my @history;      # canales cerrados/activos conservados (orden cronológico)
    my $active       = 0;
    my $last_up      = undef; # 1 = último canal fue alcista, 0 = bajista
    my $seq          = 0;

    my ($high_price, $low_price, $high_index, $low_index) = (undef, undef, undef, undef);
    my ($since_high_flag, $since_low_flag) = (0, 0);

    for my $i (0 .. $until_index) {
        # Actualiza estado de pivotes "conocido hasta ahora" (confirmado en i)
        if ($pivot_high_flag[$i]) {
            $high_price = $top_series[$i];
            $high_index = $i;
            $since_high_flag = 0;
        }
        else {
            $since_high_flag++;
        }

        if ($pivot_low_flag[$i]) {
            $low_price = $bottom_series[$i];
            $low_index = $i;
            $since_low_flag = 0;
        }
        else {
            $since_low_flag++;
        }

        next unless defined $high_price && defined $low_price;

        my $atr_now  = $atr_wilder[$i] // 0;
        my $catr_now = $catr_series[$i] // 0;
        my $avg_h    = $avg_high[$i];
        my $avg_l    = $avg_low[$i];
        next unless defined $avg_h && defined $avg_l;

        my $up_delta   = ($avg_l - $catr_now - $low_price)  / ($pivot_length + $since_low_flag  || 1);
        my $down_delta = ($avg_h + $catr_now - $high_price) / ($pivot_length + $since_high_flag || 1);

        my $going_up   = $low_price  < $bottom_series[$i];
        my $going_down = $high_price > $top_series[$i];

        my $not_active = !$active;

        # Modo "instant" del original: si el pivote contrario aún no fue
        # confirmado pero el precio ya invirtió, se inicia el canal antes.
        my $instant_up   = defined $low_index && defined $high_index && $low_index > $high_index && !$last_up;
        my $instant_down = defined $low_index && defined $high_index && $low_index < $high_index && $last_up;

        my $new_up   = $pivot_low_flag[$i];
        my $new_down = $pivot_high_flag[$i];

        if (($new_up || $instant_up) && $not_active && $going_up) {
            $active = 1;
            $last_up = 1;
            push @history, _init_channel(
                1, $up_delta, $atr_now, $atr_multiplier, $offset_in, $padding_pct,
                $low_price, undef, $avg_l, $catr_now,
                $i - $pivot_length - $since_low_flag, $i, $seq++
            );
        }
        elsif (($new_down || $instant_down) && $not_active && $going_down) {
            $active = 1;
            $last_up = 0;
            push @history, _init_channel(
                0, $down_delta, $atr_now, $atr_multiplier, $offset_in, $padding_pct,
                undef, $high_price, $avg_h, $catr_now,
                $i - $pivot_length - $since_high_flag, $i, $seq++
            );
        }
        elsif ($active && @history) {
            my $ch = $history[-1];
            $ch->{end} = $i;
            $ch->{mid_top_y2}    += $ch->{delta};
            $ch->{mid_bottom_y2} += $ch->{delta};
            $ch->{top_y2}        += $ch->{delta};
            $ch->{bottom_y2}     += $ch->{delta};

            my $break_up   = $top_series[$i]    > $ch->{top_y2};
            my $break_down = $bottom_series[$i] < $ch->{bottom_y2};
            if ($break_up || $break_down) {
                $active = 0;
            }
        }

        # Poda del historial al tamaño configurado
        shift @history while @history > $history_len;
    }

    $self->{channels} = \@history;
    return { channels => $self->{channels} };
}

# Construye un canal nuevo replicando get_points()/constructor() del
# original (líneas top/mid_top/center/mid_bottom/bottom), quedándonos sólo
# con lo necesario para dibujar la franja interna (mid_top/mid_bottom) y
# detectar la ruptura del canal (top/bottom, no se dibujan).
#
# $low_price/$high_price = precio del pivote que originó el canal
# $avg      = SMA de low (canal alcista) o de high (canal bajista)
# $catr     = rango medio suavizado (cema(tr)/8.71875) en el bar actual
# $start/$now = índices de barra (inicio del segmento / bar de creación)
sub _init_channel {
    my ($polarity, $delta, $atr, $atr_multiplier, $offset_in, $padding_pct,
        $low_price, $high_price, $avg, $catr, $start, $now, $seq) = @_;

    my $size    = $atr * $atr_multiplier;
    my $buffer  = $size / 7;
    my $offset  = $atr * 4 / 7 * $offset_in;
    my $padding = $padding_pct / 100 * 4;

    my ($top_y1, $top_y2, $bottom_y1, $bottom_y2);
    if ($polarity) {
        $top_y1    = $low_price + $size + $buffer - $offset;
        $top_y2    = $avg - $catr + $size + $buffer - $offset;
        $bottom_y1 = $low_price - $buffer - $offset;
        $bottom_y2 = $avg - $catr - $buffer - $offset;
    }
    else {
        $top_y1    = $high_price + $buffer + $offset;
        $top_y2    = $avg + $catr + $buffer + $offset;
        $bottom_y1 = $high_price - $size - $buffer + $offset;
        $bottom_y2 = $avg + $catr - $size - $buffer + $offset;
    }

    my $mid_top_y1    = $top_y1 - $buffer * $padding;
    my $mid_top_y2    = $top_y2 - $buffer * $padding;
    my $mid_bottom_y1 = $bottom_y1 + $buffer * $padding;
    my $mid_bottom_y2 = $bottom_y2 + $buffer * $padding;

    return {
        polarity      => $polarity,
        start         => $start >= 0 ? $start : 0,
        end           => $now,
        delta         => $delta,
        top_y2        => $top_y2,
        bottom_y2     => $bottom_y2,
        mid_top_y1    => $mid_top_y1,
        mid_top_y2    => $mid_top_y2,
        mid_bottom_y1 => $mid_bottom_y1,
        mid_bottom_y2 => $mid_bottom_y2,
        seq           => $seq,
    };
}

1;
