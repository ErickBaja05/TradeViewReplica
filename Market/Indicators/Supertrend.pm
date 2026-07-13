package Market::Indicators::Supertrend;

use strict;
use warnings;

=head1 NOMBRE

Market::Indicators::Supertrend - Motor de cálculo del indicador SuperTrend,
replicando fielmente la lógica PineScript de strategy.txt (sección
"Super Trend", líneas ~1191-1230):

  statr    = changeATR ? ta.atr(Periods) : ta.sma(ta.tr, Periods)
  up       = src - Multiplier * atr
  up      := close[1] > up[1] ? max(up, up[1]) : up
  dn       = src + Multiplier * atr
  dn      := close[1] < dn[1] ? min(dn, dn[1]) : dn
  trend   := trend[1] == -1 and close > dn[1] ? 1
           : trend[1] ==  1 and close < up[1] ? -1
           : trend[1]

Donde src = hl2 por defecto (fielmente configurable).

=head1 PARÁMETROS

  period      => período del ATR (def: 10)
  multiplier  => multiplicador del ATR (def: 3.0)
  change_atr  => 1 = usa ta.atr (Wilder), 0 = usa SMA(TR) (def: 1)

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        period     => $args{period}     // 10,
        multiplier => $args{multiplier} // 3.0,
        change_atr => $args{change_atr} // 1,
        values     => [],   # serie completa: [{ up, dn, trend, line, buy_signal, sell_signal }, ...]
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

# Calcula el True Range clásico de la vela $i respecto a la vela $i-1
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

=head2 calculate_until($candles, $until_index)

Recalcula la serie completa de SuperTrend desde cero hasta $until_index
(inclusive). $candles es un arrayref de velas {open,high,low,close}.

Devuelve un hashref { values => [...] } donde cada elemento contiene:
  up          => línea "up" del período (banda inferior candidata)
  dn          => línea "dn" del período (banda superior candidata)
  trend       => 1 (alcista) | -1 (bajista)
  line        => valor a graficar (up si trend==1, dn si trend==-1)
  buy_signal  => 1 si en esta barra el trend pasó de -1 a 1
  sell_signal => 1 si en esta barra el trend pasó de 1 a -1

=cut

sub calculate_until {
    my ($self, $candles, $until_index) = @_;

    $self->reset();
    return { values => $self->{values} }
        if !defined $until_index || $until_index < 0 || !$candles;

    my $period     = $self->{period};
    my $mult       = $self->{multiplier};
    my $change_atr = $self->{change_atr};

    # --- Serie de ATR (Wilder, ta.atr) y de SMA(TR) para 'statr2' ---
    my (@tr_series, @atr_wilder, @sma_tr);
    my $tr_sum = 0;

    for my $i (0 .. $until_index) {
        my $tr = _true_range($candles, $i);
        push @tr_series, $tr;

        # SMA(TR, period) -- "statr2" en el PineScript
        my $win_start = $i - $period + 1;
        $win_start = 0 if $win_start < 0;
        my $sum = 0;
        my $n = 0;
        for my $j ($win_start .. $i) {
            $sum += $tr_series[$j];
            $n++;
        }
        push @sma_tr, ($n > 0 ? $sum / $n : undef);

        # ATR Wilder (ta.atr): primer valor = SMA de los primeros $period TR,
        # luego RMA incremental.
        if ($i < $period - 1) {
            push @atr_wilder, undef;
        }
        elsif ($i == $period - 1) {
            my $s = 0;
            $s += $tr_series[$_] for (0 .. $period - 1);
            push @atr_wilder, $s / $period;
        }
        else {
            my $prev = $atr_wilder[$i - 1];
            push @atr_wilder, ($prev * ($period - 1) + $tr) / $period;
        }
    }

    my ($prev_up, $prev_dn, $prev_close, $prev_trend);

    for my $i (0 .. $until_index) {
        my $c = $candles->[$i];
        my $src = ($c->{high} + $c->{low}) / 2;   # hl2

        my $atr = $change_atr ? $atr_wilder[$i] : $sma_tr[$i];
        $atr //= 0;

        my $up = $src - $mult * $atr;
        if (defined $prev_up) {
            $up = ($prev_close > $prev_up) ? ($up > $prev_up ? $up : $prev_up) : $up;
        }

        my $dn = $src + $mult * $atr;
        if (defined $prev_dn) {
            $dn = ($prev_close < $prev_dn) ? ($dn < $prev_dn ? $dn : $prev_dn) : $dn;
        }

        my $trend = $prev_trend // 1;
        if ($trend == -1 && defined $prev_dn && $c->{close} > $prev_dn) {
            $trend = 1;
        }
        elsif ($trend == 1 && defined $prev_up && $c->{close} < $prev_up) {
            $trend = -1;
        }

        my $buy_signal  = (defined $prev_trend && $prev_trend == -1 && $trend == 1) ? 1 : 0;
        my $sell_signal = (defined $prev_trend && $prev_trend == 1  && $trend == -1) ? 1 : 0;

        push @{$self->{values}}, {
            up          => $up,
            dn          => $dn,
            trend       => $trend,
            line        => ($trend == 1 ? $up : $dn),
            buy_signal  => $buy_signal,
            sell_signal => $sell_signal,
        };

        $prev_up     = $up;
        $prev_dn     = $dn;
        $prev_close  = $c->{close};
        $prev_trend  = $trend;
    }

    return { values => $self->{values} };
}

1;
