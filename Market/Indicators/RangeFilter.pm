package Market::Indicators::RangeFilter;

use strict;
use warnings;

=head1 NOMBRE

Market::Indicators::RangeFilter - Motor de cálculo del indicador Range
Filter, replicando fielmente la lógica PineScript de strategy.txt (sección
"Range Filter", líneas ~964-1015, variante "Default"):

  smoothrng(x, t, m) =>
      wper = t * 2 - 1
      avrng = ta.ema(math.abs(x - x[1]), t)
      smoothrng = ta.ema(avrng, wper) * m
      smoothrng
  smrng = smoothrng(src, per, mult)

  rngfilt(x, r) =>
      rngfilt = x
      rngfilt := x > nz(rngfilt[1])
                 ? (x - r < nz(rngfilt[1]) ? nz(rngfilt[1]) : x - r)
                 : (x + r > nz(rngfilt[1]) ? nz(rngfilt[1]) : x + r)
      rngfilt

  filt := rngfilt(src, smrng)

  upward   := filt > filt[1] ? nz(upward[1])   + 1 : filt < filt[1] ? 0 : nz(upward[1])
  downward := filt < filt[1] ? nz(downward[1]) + 1 : filt > filt[1] ? 0 : nz(downward[1])

  filtcolor = upward > 0 ? lime : downward > 0 ? red : orange

Donde src = close por defecto.

=head1 PARÁMETROS

  period      => período de muestreo "Period" (def: 100)
  multiplier  => "Range Multiplier" (def: 3.0)

=head1 CONTRATO

Sigue el mismo contrato incremental que Market::Indicators::FVG,
Liquidity, OrderBlocks, SMC_Structures y Structure:

  new()                                   -> instancia
  reset()                                 -> limpia el estado interno
  update_last($candles, $atr_values, $i)  -> procesa SÓLO la vela $i
  get_values()                            -> devuelve la serie completa

$atr_values (ATR genérico del gráfico) no se usa: el Range Filter no se
basa en ATR sino en dos EMA anidadas sobre |close - close[1]|, calculadas
de forma recursiva e incremental (avrng y smrng), fiel al PineScript
original.

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        period     => $args{period}     // 100,
        multiplier => $args{multiplier} // 3.0,
        values     => [],   # serie completa: [{ filt, hband, lband, upward, downward, trend, buy_signal, sell_signal }, ...]

        # --- Estado incremental ---
        prev_close     => undef,   # close[1], para |x - x[1]|
        avrng_prev     => undef,   # EMA(|diff|, period) corriendo
        smrng_ema_prev => undef,   # EMA(avrng, wper) corriendo
        prev_filt      => undef,
        prev_upward    => 0,
        prev_downward  => 0,
        prev_trend     => 0,
    };

    return bless $self, $class;
}

sub reset {
    my ($self) = @_;
    $self->{values}         = [];
    $self->{prev_close}     = undef;
    $self->{avrng_prev}     = undef;
    $self->{smrng_ema_prev} = undef;
    $self->{prev_filt}      = undef;
    $self->{prev_upward}    = 0;
    $self->{prev_downward}  = 0;
    $self->{prev_trend}     = 0;
}

sub get_values {
    my ($self) = @_;
    return $self->{values};
}

=head2 update_last($candles, $atr_values, $i)

Procesa incrementalmente la vela $i (en orden estrictamente creciente
desde 0 tras un reset()). Actualiza $self->{values} (alineado 1:1 con el
índice de vela) y devuelve C<{ values => [...] }>.

Cada elemento contiene:
  filt        => valor de la línea Range Filter (rngfilt) en esa barra
  hband       => banda superior (filt + smrng), sólo referencial
  lband       => banda inferior (filt - smrng), sólo referencial
  upward      => contador de barras consecutivas de "empuje alcista"
  downward    => contador de barras consecutivas de "empuje bajista"
  trend       => 1 (upward > 0) | -1 (downward > 0) | 0 (neutro, primera barra)
  buy_signal  => 1 si en esta barra el trend pasó a 1 (desde otro estado)
  sell_signal => 1 si en esta barra el trend pasó a -1 (desde otro estado)

=cut

sub update_last {
    my ($self, $candles, $atr_values, $i) = @_;

    return { values => $self->{values} } if !defined $i || $i < 0 || !$candles;

    my $c = $candles->[$i];
    return { values => $self->{values} } unless $c;

    my $period = $self->{period};
    my $mult   = $self->{multiplier};
    my $wper   = $period * 2 - 1;

    my $x = $c->{close};

    # --- avrng = ta.ema(|x - x[1]|, period), incremental ---
    my $abs_diff = defined $self->{prev_close} ? abs($x - $self->{prev_close}) : undef;

    my $avrng;
    if (defined $abs_diff) {
        my $alpha = 2 / ($period + 1);
        $avrng = defined $self->{avrng_prev}
               ? ($alpha * $abs_diff + (1 - $alpha) * $self->{avrng_prev})
               : $abs_diff;
        $self->{avrng_prev} = $avrng;
    }

    # --- smrng = ta.ema(avrng, wper) * mult, incremental ---
    my $smrng;
    if (defined $avrng) {
        my $alpha2 = 2 / ($wper + 1);
        my $smrng_ema = defined $self->{smrng_ema_prev}
                       ? ($alpha2 * $avrng + (1 - $alpha2) * $self->{smrng_ema_prev})
                       : $avrng;
        $self->{smrng_ema_prev} = $smrng_ema;
        $smrng = $smrng_ema * $mult;
    }

    my $r = $smrng // 0;

    # --- rngfilt recursivo ---
    my $filt;
    if (!defined $self->{prev_filt}) {
        $filt = $x;
    }
    elsif ($x > $self->{prev_filt}) {
        $filt = ($x - $r < $self->{prev_filt}) ? $self->{prev_filt} : $x - $r;
    }
    else {
        $filt = ($x + $r > $self->{prev_filt}) ? $self->{prev_filt} : $x + $r;
    }

    my ($upward, $downward);
    if (!defined $self->{prev_filt}) {
        $upward   = 0;
        $downward = 0;
    }
    elsif ($filt > $self->{prev_filt}) {
        $upward   = $self->{prev_upward} + 1;
        $downward = 0;
    }
    elsif ($filt < $self->{prev_filt}) {
        $upward   = 0;
        $downward = $self->{prev_downward} + 1;
    }
    else {
        $upward   = $self->{prev_upward};
        $downward = $self->{prev_downward};
    }

    my $trend = $upward > 0 ? 1 : $downward > 0 ? -1 : 0;

    my $buy_signal  = (defined $self->{prev_trend} && $self->{prev_trend} != 1  && $trend == 1)  ? 1 : 0;
    my $sell_signal = (defined $self->{prev_trend} && $self->{prev_trend} != -1 && $trend == -1) ? 1 : 0;

    $self->{values}->[$i] = {
        filt        => $filt,
        hband       => $filt + $r,
        lband       => $filt - $r,
        upward      => $upward,
        downward    => $downward,
        trend       => $trend,
        buy_signal  => $buy_signal,
        sell_signal => $sell_signal,
    };

    $self->{prev_close}    = $x;
    $self->{prev_filt}     = $filt;
    $self->{prev_upward}   = $upward;
    $self->{prev_downward} = $downward;
    $self->{prev_trend}    = $trend;

    return { values => $self->{values} };
}

1;
