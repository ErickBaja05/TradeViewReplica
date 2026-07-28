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

=head1 CONTRATO

Sigue el mismo contrato incremental que Market::Indicators::FVG,
Liquidity, OrderBlocks, SMC_Structures y Structure:

  new()                                   -> instancia
  reset()                                 -> limpia el estado interno
  update_last($candles, $atr_values, $i)  -> procesa SÓLO la vela $i
  get_values()                            -> devuelve la serie completa

$candles debe ser el arrayref COMPLETO de velas (no sólo hasta $i), ya
que las ventanas de highest/lowest/SMA miran hacia atrás usando índices
absolutos sobre ese arrayref, igual que en el resto de indicadores
incrementales. $atr_values (ATR genérico del gráfico) no se usa: el
HalfTrend calcula su propio ATR Wilder interno de período fijo
('atr_period'), fiel al PineScript original.

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        amplitude         => $args{amplitude}         // 2,
        channel_deviation => $args{channel_deviation} // 2,
        atr_period        => $args{atr_period}        // 100,
        values            => [],

        # --- Estado incremental ---
        tr_history      => [],      # ventana de TR (tamaño <= atr_period), seed del RMA
        atr_wilder      => undef,   # ATR Wilder (RMA) corriendo
        bar_count       => 0,

        trend           => 0,
        next_trend      => 0,
        max_low_price   => undef,
        min_high_price  => undef,
        up              => undef,
        down            => undef,
        prev_trend      => undef,
    };

    return bless $self, $class;
}

sub reset {
    my ($self) = @_;
    $self->{values}          = [];
    $self->{tr_history}      = [];
    $self->{atr_wilder}      = undef;
    $self->{bar_count}       = 0;
    $self->{trend}           = 0;
    $self->{next_trend}      = 0;
    $self->{max_low_price}   = undef;
    $self->{min_high_price}  = undef;
    $self->{up}              = undef;
    $self->{down}            = undef;
    $self->{prev_trend}      = undef;
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

=head2 update_last($candles, $atr_values, $i)

Procesa incrementalmente la vela $i (en orden estrictamente creciente
desde 0 tras un reset()). Actualiza $self->{values} (alineado 1:1 con el
índice de vela) y devuelve C<{ values => [...] }>.

Cada elemento contiene:
  trend        => 0 (alcista) | 1 (bajista)
  line         => valor de la línea HalfTrend (up si trend==0, down si trend==1)
  atr_high     => banda superior del canal
  atr_low      => banda inferior del canal
  arrow_up     => precio de flecha alcista si hubo cambio de trend a 0, si no undef
  arrow_down   => precio de flecha bajista si hubo cambio de trend a 1, si no undef

=cut

sub update_last {
    my ($self, $candles, $atr_values, $i) = @_;

    return { values => $self->{values} } if !defined $i || $i < 0 || !$candles;

    my $c = $candles->[$i];
    return { values => $self->{values} } unless $c;

    my $amplitude  = $self->{amplitude};
    my $chan_dev   = $self->{channel_deviation};
    my $atr_period = $self->{atr_period};

    # --- ATR Wilder incremental de período fijo (atr_period) ---
    my $tr = _true_range($candles, $i);
    push @{$self->{tr_history}}, $tr;
    shift @{$self->{tr_history}} while scalar(@{$self->{tr_history}}) > $atr_period;

    $self->{bar_count}++;
    my $atr_wilder;
    if ($self->{bar_count} < $atr_period) {
        $atr_wilder = undef;
    }
    elsif ($self->{bar_count} == $atr_period) {
        my $sum = 0;
        $sum += $_ for @{$self->{tr_history}};
        $atr_wilder = $sum / $atr_period;
    }
    else {
        $atr_wilder = ($self->{atr_wilder} * ($atr_period - 1) + $tr) / $atr_period;
    }
    $self->{atr_wilder} = $atr_wilder if defined $atr_wilder;

    # maxLowPrice/minHighPrice parten de low[0]/high[0] en la primera barra
    if ($i == 0) {
        $self->{max_low_price}  = $c->{low};
        $self->{min_high_price} = $c->{high};
    }

    my $atr_raw = $self->{atr_wilder} // 0;
    my $atr2 = $atr_raw / 2;
    my $dev  = $chan_dev * $atr2;

    my $high_price = _window_extreme($candles, $i, $amplitude, 'high', 1);
    my $low_price  = _window_extreme($candles, $i, $amplitude, 'low',  0);
    my $highma     = _sma_window($candles, $i, $amplitude, 'high');
    my $lowma      = _sma_window($candles, $i, $amplitude, 'low');

    my $prev_low   = ($i > 0) ? $candles->[$i - 1]->{low}   : $c->{low};
    my $prev_high  = ($i > 0) ? $candles->[$i - 1]->{high}  : $c->{high};

    if ($self->{next_trend} == 1) {
        $self->{max_low_price} = $low_price if $low_price > $self->{max_low_price};

        if (defined $highma && $highma < $self->{max_low_price} && $c->{close} < $prev_low) {
            $self->{trend}          = 1;
            $self->{next_trend}     = 0;
            $self->{min_high_price} = $high_price;
        }
    }
    else {
        $self->{min_high_price} = $high_price if $high_price < $self->{min_high_price};

        if (defined $lowma && $lowma > $self->{min_high_price} && $c->{close} > $prev_high) {
            $self->{trend}          = 0;
            $self->{next_trend}     = 1;
            $self->{max_low_price}  = $low_price;
        }
    }

    my ($atr_high, $atr_low, $arrow_up, $arrow_down);
    my $prev_trend = $self->{prev_trend};

    if ($self->{trend} == 0) {
        if (defined $prev_trend && $prev_trend != 0) {
            $self->{up} = defined $self->{down} ? $self->{down} : (defined $self->{up} ? $self->{up} : $c->{low});
            $arrow_up = $self->{up} - $atr2;
        }
        else {
            $self->{up} = defined $self->{up} ? ($self->{max_low_price} > $self->{up} ? $self->{max_low_price} : $self->{up}) : $self->{max_low_price};
        }
        $atr_high = $self->{up} + $dev;
        $atr_low  = $self->{up} - $dev;
    }
    else {
        if (defined $prev_trend && $prev_trend != 1) {
            $self->{down} = defined $self->{up} ? $self->{up} : (defined $self->{down} ? $self->{down} : $c->{high});
            $arrow_down = $self->{down} + $atr2;
        }
        else {
            $self->{down} = defined $self->{down} ? ($self->{min_high_price} < $self->{down} ? $self->{min_high_price} : $self->{down}) : $self->{min_high_price};
        }
        $atr_high = $self->{down} + $dev;
        $atr_low  = $self->{down} - $dev;
    }

    my $line = ($self->{trend} == 0) ? $self->{up} : $self->{down};

    $self->{values}->[$i] = {
        trend      => $self->{trend},
        line       => $line,
        atr_high   => $atr_high,
        atr_low    => $atr_low,
        arrow_up   => $arrow_up,
        arrow_down => $arrow_down,
    };

    $self->{prev_trend} = $self->{trend};

    return { values => $self->{values} };
}

1;
