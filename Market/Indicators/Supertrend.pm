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

=head1 CONTRATO

Sigue el mismo contrato incremental que Market::Indicators::FVG,
Liquidity, OrderBlocks, SMC_Structures y Structure:

  new()                                   -> instancia
  reset()                                 -> limpia el estado interno
  update_last($candles, $atr_values, $i)  -> procesa SÓLO la vela $i
                                              (incremental, O(1) por vela)
  get_values()                            -> devuelve la serie completa

El parámetro $atr_values (ATR genérico del gráfico) no se usa aquí: el
SuperTrend calcula su propio ATR interno (Wilder o SMA(TR), según
'change_atr') con su propio período configurable, fiel al PineScript
original. Se recibe igualmente para mantener la firma uniforme con el
resto de indicadores y permitir que ChartEngine los invoque desde el
mismo bucle incremental.

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        period     => $args{period}     // 10,
        multiplier => $args{multiplier} // 3.0,
        change_atr => $args{change_atr} // 1,
        values     => [],   # serie completa: [{ up, dn, trend, line, buy_signal, sell_signal }, ...]

        # --- Estado incremental ---
        tr_history  => [],      # ventana de TR (tamaño <= period), para SMA(TR)
        atr_wilder  => undef,   # ATR Wilder (RMA) corriendo
        bar_count   => 0,       # nº de velas procesadas (para el "seed" del RMA)
        prev_up     => undef,
        prev_dn     => undef,
        prev_close  => undef,
        prev_trend  => undef,
    };

    return bless $self, $class;
}

sub reset {
    my ($self) = @_;
    $self->{values}     = [];
    $self->{tr_history} = [];
    $self->{atr_wilder} = undef;
    $self->{bar_count}  = 0;
    $self->{prev_up}    = undef;
    $self->{prev_dn}    = undef;
    $self->{prev_close} = undef;
    $self->{prev_trend} = undef;
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

=head2 update_last($candles, $atr_values, $i)

Procesa incrementalmente la vela $i (debe llamarse en orden estrictamente
creciente desde 0, igual que el resto de indicadores incrementales; tras
un C<reset()> el primer índice válido es 0). Actualiza $self->{values}
(alineado 1:1 con el índice de vela, values->[$i] == resultado de la
vela $i) y devuelve C<{ values => [...] }>.

Cada elemento de la serie contiene:
  up          => línea "up" del período (banda inferior candidata)
  dn          => línea "dn" del período (banda superior candidata)
  trend       => 1 (alcista) | -1 (bajista)
  line        => valor a graficar (up si trend==1, dn si trend==-1)
  buy_signal  => 1 si en esta barra el trend pasó de -1 a 1
  sell_signal => 1 si en esta barra el trend pasó de 1 a -1

=cut

sub update_last {
    my ($self, $candles, $atr_values, $i) = @_;

    return { values => $self->{values} } if !defined $i || $i < 0 || !$candles;

    my $c = $candles->[$i];
    return { values => $self->{values} } unless $c;

    my $period     = $self->{period};
    my $mult       = $self->{multiplier};
    my $change_atr = $self->{change_atr};

    # --- TR de la vela actual, ventana deslizante para SMA(TR) ---
    my $tr = _true_range($candles, $i);
    push @{$self->{tr_history}}, $tr;
    shift @{$self->{tr_history}} while scalar(@{$self->{tr_history}}) > $period;

    my $sma_tr;
    {
        my $n = scalar @{$self->{tr_history}};
        my $sum = 0;
        $sum += $_ for @{$self->{tr_history}};
        $sma_tr = $n > 0 ? $sum / $n : undef;
    }

    # --- ATR Wilder (RMA) incremental: seed = SMA de los primeros $period TR ---
    $self->{bar_count}++;
    my $atr_wilder;
    if ($self->{bar_count} < $period) {
        $atr_wilder = undef;
    }
    elsif ($self->{bar_count} == $period) {
        my $sum = 0;
        $sum += $_ for @{$self->{tr_history}};   # exactamente $period valores
        $atr_wilder = $sum / $period;
    }
    else {
        $atr_wilder = ($self->{atr_wilder} * ($period - 1) + $tr) / $period;
    }
    $self->{atr_wilder} = $atr_wilder if defined $atr_wilder;

    my $atr = $change_atr ? $atr_wilder : $sma_tr;
    $atr //= 0;

    my $src = ($c->{high} + $c->{low}) / 2;   # hl2

    my $up = $src - $mult * $atr;
    if (defined $self->{prev_up}) {
        $up = ($self->{prev_close} > $self->{prev_up}) ? ($up > $self->{prev_up} ? $up : $self->{prev_up}) : $up;
    }

    my $dn = $src + $mult * $atr;
    if (defined $self->{prev_dn}) {
        $dn = ($self->{prev_close} < $self->{prev_dn}) ? ($dn < $self->{prev_dn} ? $dn : $self->{prev_dn}) : $dn;
    }

    my $trend = $self->{prev_trend} // 1;
    if ($trend == -1 && defined $self->{prev_dn} && $c->{close} > $self->{prev_dn}) {
        $trend = 1;
    }
    elsif ($trend == 1 && defined $self->{prev_up} && $c->{close} < $self->{prev_up}) {
        $trend = -1;
    }

    my $buy_signal  = (defined $self->{prev_trend} && $self->{prev_trend} == -1 && $trend == 1) ? 1 : 0;
    my $sell_signal = (defined $self->{prev_trend} && $self->{prev_trend} == 1  && $trend == -1) ? 1 : 0;

    $self->{values}->[$i] = {
        up          => $up,
        dn          => $dn,
        trend       => $trend,
        line        => ($trend == 1 ? $up : $dn),
        buy_signal  => $buy_signal,
        sell_signal => $sell_signal,
    };

    $self->{prev_up}    = $up;
    $self->{prev_dn}    = $dn;
    $self->{prev_close} = $c->{close};
    $self->{prev_trend} = $trend;

    return { values => $self->{values} };
}

1;
