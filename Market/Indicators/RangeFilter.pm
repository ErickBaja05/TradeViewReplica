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

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        period     => $args{period}     // 100,
        multiplier => $args{multiplier} // 3.0,
        values     => [],   # serie completa: [{ filt, hband, lband, upward, downward, trend, buy_signal, sell_signal }, ...]
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

# EMA clásica (ta.ema): seed = primer valor de la serie, luego recursiva.
# Devuelve un arrayref alineado 1:1 con @$series (undef antes del primer
# valor definido de entrada, ya que math.abs(x - x[1]) no existe en la
# primera barra).
sub _ema_series {
    my ($series, $period) = @_;

    my $alpha = 2 / ($period + 1);
    my @out;
    my $prev;

    for my $i (0 .. $#$series) {
        my $x = $series->[$i];

        if (!defined $x) {
            push @out, undef;
            next;
        }

        if (!defined $prev) {
            $prev = $x;
        }
        else {
            $prev = $alpha * $x + (1 - $alpha) * $prev;
        }

        push @out, $prev;
    }

    return \@out;
}

=head2 calculate_until($candles, $until_index)

Recalcula la serie completa de Range Filter desde cero hasta $until_index
(inclusive). $candles es un arrayref de velas {open,high,low,close}.

Devuelve un hashref { values => [...] } donde cada elemento contiene:
  filt        => valor de la línea Range Filter (rngfilt) en esa barra
  hband       => banda superior (filt + smrng), sólo referencial
  lband       => banda inferior (filt - smrng), sólo referencial
  upward      => contador de barras consecutivas de "empuje alcista"
  downward    => contador de barras consecutivas de "empuje bajista"
  trend       => 1 (upward > 0) | -1 (downward > 0) | 0 (neutro, primera barra)
  buy_signal  => 1 si en esta barra el trend pasó a 1 (desde otro estado)
  sell_signal => 1 si en esta barra el trend pasó a -1 (desde otro estado)

=cut

sub calculate_until {
    my ($self, $candles, $until_index) = @_;

    $self->reset();
    return { values => $self->{values} }
        if !defined $until_index || $until_index < 0 || !$candles;

    my $period = $self->{period};
    my $mult   = $self->{multiplier};
    my $wper   = $period * 2 - 1;

    # --- src = close, para las barras 0..$until_index ---
    my @src;
    for my $i (0 .. $until_index) {
        push @src, $candles->[$i]->{close};
    }

    # --- avrng = ta.ema(|x - x[1]|, period) ---
    my @abs_diff;
    for my $i (0 .. $#src) {
        if ($i == 0) {
            push @abs_diff, undef;   # x[1] no existe en la primera barra
        }
        else {
            push @abs_diff, abs($src[$i] - $src[$i - 1]);
        }
    }
    my $avrng = _ema_series(\@abs_diff, $period);

    # --- smrng = ta.ema(avrng, wper) * mult ---
    my $smrng_ema = _ema_series($avrng, $wper);
    my @smrng = map { defined $_ ? $_ * $mult : undef } @$smrng_ema;

    # --- rngfilt recursivo ---
    my ($prev_filt, $prev_upward, $prev_downward, $prev_trend) = (undef, 0, 0, 0);

    for my $i (0 .. $#src) {
        my $x = $src[$i];
        my $r = $smrng[$i] // 0;

        my $filt;
        if (!defined $prev_filt) {
            $filt = $x;
        }
        elsif ($x > $prev_filt) {
            $filt = ($x - $r < $prev_filt) ? $prev_filt : $x - $r;
        }
        else {
            $filt = ($x + $r > $prev_filt) ? $prev_filt : $x + $r;
        }

        my $upward;
        my $downward;

        if (!defined $prev_filt) {
            $upward   = 0;
            $downward = 0;
        }
        elsif ($filt > $prev_filt) {
            $upward   = $prev_upward + 1;
            $downward = 0;
        }
        elsif ($filt < $prev_filt) {
            $upward   = 0;
            $downward = $prev_downward + 1;
        }
        else {
            $upward   = $prev_upward;
            $downward = $prev_downward;
        }

        my $trend = $upward > 0 ? 1 : $downward > 0 ? -1 : 0;

        my $buy_signal  = (defined $prev_trend && $prev_trend != 1  && $trend == 1)  ? 1 : 0;
        my $sell_signal = (defined $prev_trend && $prev_trend != -1 && $trend == -1) ? 1 : 0;

        push @{$self->{values}}, {
            filt        => $filt,
            hband       => $filt + $r,
            lband       => $filt - $r,
            upward      => $upward,
            downward    => $downward,
            trend       => $trend,
            buy_signal  => $buy_signal,
            sell_signal => $sell_signal,
        };

        $prev_filt     = $filt;
        $prev_upward   = $upward;
        $prev_downward = $downward;
        $prev_trend    = $trend;
    }

    return { values => $self->{values} };
}

1;
