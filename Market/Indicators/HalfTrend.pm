package Market::Indicators::HalfTrend;

use strict;
use warnings;

=head1 NOMBRE

Market::Indicators::HalfTrend - Motor de cálculo del indicador HalfTrend,
replicando fielmente la lógica PineScript de strategy.txt (sección
"Half Trend", líneas ~1239-1326).

Lógica original:

  atr2 = ta.atr(100) / 2
  dev  = channelDeviation * atr2

  highPrice = high[highestbars(amplitude)]
  lowPrice  = low[lowestbars(amplitude)]
  highma = sma(high, amplitude)
  lowma  = sma(low, amplitude)

  if nextTrend == 1
      maxLowPrice = max(lowPrice, maxLowPrice)
      if highma < maxLowPrice and close < low[1]
          trend = 1 ; nextTrend = 0 ; minHighPrice = highPrice
  else
      minHighPrice = min(highPrice, minHighPrice)
      if lowma > minHighPrice and close > high[1]
          trend = 0 ; nextTrend = 1 ; maxLowPrice = lowPrice

  if trend == 0
      if trend[1] != 0
          up = down[1] (o down si no existe)
      else
          up = max(maxLowPrice, up[1])
      atrHigh = up + dev ; atrLow = up - dev
  else
      if trend[1] != 1
          down = up[1] (o up si no existe)
      else
          down = min(minHighPrice, down[1])
      atrHigh = down + dev ; atrLow = down - dev

  ht = trend == 0 ? up : down

=head1 PARÁMETROS

  amplitude          => ventana para highest/lowest y SMA (def: 2)
  channel_deviation  => multiplicador del canal (def: 2)
  atr_period         => período del ATR base (def: 100, fijo en el original)

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        amplitude         => $args{amplitude}         // 2,
        channel_deviation => $args{channel_deviation} // 2,
        atr_period        => $args{atr_period}        // 100,
        values            => [],
    };

    return bless $self, $class;
}

sub reset {
    my ($self) = @_;
    $self->{values} = [];
}

sub get_values {
    my ($self) = @_;
    return $self->{values};
}

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

# max/min de high/low en la ventana [$i-$amplitude+1 .. $i] (incluye la
# barra actual), replicando highest(amplitude)/lowest(amplitude) de PineScript
# (que por defecto incluyen la barra actual).
sub _window_extreme {
    my ($candles, $i, $amplitude, $field, $is_max) = @_;
    my $start = $i - $amplitude + 1;
    $start = 0 if $start < 0;

    my $best;
    for my $j ($start .. $i) {
        my $v = $candles->[$j]->{$field};
        next unless defined $v;
        if (!defined $best) { $best = $v; next; }
        if ($is_max) { $best = $v if $v > $best; }
        else         { $best = $v if $v < $best; }
    }
    return $best;
}

sub _sma_window {
    my ($candles, $i, $amplitude, $field) = @_;
    my $start = $i - $amplitude + 1;
    $start = 0 if $start < 0;
    my ($sum, $n) = (0, 0);
    for my $j ($start .. $i) {
        $sum += $candles->[$j]->{$field};
        $n++;
    }
    return $n > 0 ? $sum / $n : undef;
}

=head2 calculate_until($candles, $until_index)

Recalcula la serie completa de HalfTrend desde cero hasta $until_index
(inclusive).

Devuelve un hashref { values => [...] } donde cada elemento contiene:
  trend        => 0 (alcista) | 1 (bajista)
  line         => valor de la línea HalfTrend (up si trend==0, down si trend==1)
  atr_high     => banda superior del canal
  atr_low      => banda inferior del canal
  arrow_up     => precio de flecha alcista si hubo cambio de trend a 0, si no undef
  arrow_down   => precio de flecha bajista si hubo cambio de trend a 1, si no undef

=cut

sub calculate_until {
    my ($self, $candles, $until_index) = @_;

    $self->reset();
    return { values => $self->{values} }
        if !defined $until_index || $until_index < 0 || !$candles;

    my $amplitude  = $self->{amplitude};
    my $chan_dev   = $self->{channel_deviation};
    my $atr_period = $self->{atr_period};

    # --- ATR Wilder de período fijo (100 por defecto) para todo el rango ---
    my (@tr_series, @atr_wilder);
    for my $i (0 .. $until_index) {
        my $tr = _true_range($candles, $i);
        push @tr_series, $tr;

        if ($i < $atr_period - 1) {
            push @atr_wilder, undef;
        }
        elsif ($i == $atr_period - 1) {
            my $s = 0;
            $s += $tr_series[$_] for (0 .. $atr_period - 1);
            push @atr_wilder, $s / $atr_period;
        }
        else {
            my $prev = $atr_wilder[$i - 1];
            push @atr_wilder, ($prev * ($atr_period - 1) + $tr) / $atr_period;
        }
    }

    my $trend         = 0;
    my $next_trend    = 0;
    my $max_low_price  = $candles->[0]->{low};
    my $min_high_price = $candles->[0]->{high};

    my ($up, $down);
    my $prev_trend;

    for my $i (0 .. $until_index) {
        my $c = $candles->[$i];

        # maxLowPrice/minHighPrice parten de low[1]/high[1] (barra anterior)
        if ($i == 0) {
            $max_low_price  = $c->{low};
            $min_high_price = $c->{high};
        }

        my $atr_raw = $atr_wilder[$i] // 0;
        my $atr2 = $atr_raw / 2;
        my $dev  = $chan_dev * $atr2;

        my $high_price = _window_extreme($candles, $i, $amplitude, 'high', 1);
        my $low_price  = _window_extreme($candles, $i, $amplitude, 'low',  0);
        my $highma     = _sma_window($candles, $i, $amplitude, 'high');
        my $lowma      = _sma_window($candles, $i, $amplitude, 'low');

        my $prev_close = ($i > 0) ? $candles->[$i - 1]->{close} : $c->{close};
        my $prev_low   = ($i > 0) ? $candles->[$i - 1]->{low}   : $c->{low};
        my $prev_high  = ($i > 0) ? $candles->[$i - 1]->{high}  : $c->{high};

        if ($next_trend == 1) {
            $max_low_price = $low_price if $low_price > $max_low_price;

            if (defined $highma && $highma < $max_low_price && $c->{close} < $prev_low) {
                $trend         = 1;
                $next_trend    = 0;
                $min_high_price = $high_price;
            }
        }
        else {
            $min_high_price = $high_price if $high_price < $min_high_price;

            if (defined $lowma && $lowma > $min_high_price && $c->{close} > $prev_high) {
                $trend         = 0;
                $next_trend    = 1;
                $max_low_price = $low_price;
            }
        }

        my ($atr_high, $atr_low, $arrow_up, $arrow_down);

        if ($trend == 0) {
            if (defined $prev_trend && $prev_trend != 0) {
                $up = defined $down ? $down : (defined $up ? $up : $c->{low});
                $arrow_up = $up - $atr2;
            }
            else {
                $up = defined $up ? ($max_low_price > $up ? $max_low_price : $up) : $max_low_price;
            }
            $atr_high = $up + $dev;
            $atr_low  = $up - $dev;
        }
        else {
            if (defined $prev_trend && $prev_trend != 1) {
                $down = defined $up ? $up : (defined $down ? $down : $c->{high});
                $arrow_down = $down + $atr2;
            }
            else {
                $down = defined $down ? ($min_high_price < $down ? $min_high_price : $down) : $min_high_price;
            }
            $atr_high = $down + $dev;
            $atr_low  = $down - $dev;
        }

        my $line = ($trend == 0) ? $up : $down;

        push @{$self->{values}}, {
            trend      => $trend,
            line       => $line,
            atr_high   => $atr_high,
            atr_low    => $atr_low,
            arrow_up   => $arrow_up,
            arrow_down => $arrow_down,
        };

        $prev_trend = $trend;
    }

    return { values => $self->{values} };
}

1;
