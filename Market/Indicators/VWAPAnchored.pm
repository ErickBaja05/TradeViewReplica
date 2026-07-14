package Market::Indicators::VWAPAnchored;

use strict;
use warnings;

=head1 NOMBRE

Market::Indicators::VWAPAnchored - Motor de cálculo del VWAP Anclado
(Anchored VWAP) con bandas de desviación estándar, replicando la lógica del
indicador nativo de TradingView:

  src   = hlc3 (por defecto)
  vwap  = cumsum(src * volume) / cumsum(volume)          [desde el ancla]
  var   = cumsum(volume * src^2) / cumsum(volume) - vwap^2
  stdev = sqrt(max(var, 0))
  upper_N = vwap + N * stdev   (N = 1, 2, 3)
  lower_N = vwap - N * stdev   (N = 1, 2, 3)

El cálculo se reinicia ("ancla") en la vela seleccionada por el usuario
($anchor_index) y se acumula hacia adelante hasta $until_index.

Las bandas de 1, 2 y 3 sigma se calculan siempre (el costo extra es mínimo,
ya que sólo implica multiplicar la misma desviación estándar por 1, 2 y 3),
de forma que la capa visual (Overlay) pueda mostrar el rango que el usuario
haya seleccionado (1, 2 o 3 sigma) sin necesidad de recalcular el indicador.

=head1 PARÁMETROS

  std_mult => multiplicador base de la desviación estándar (def: 1).
              Se mantiene por compatibilidad; las claves upper/lower del
              resultado usan este multiplicador, mientras que upper1/lower1,
              upper2/lower2 y upper3/lower3 siempre usan 1, 2 y 3 respectivamente.

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        std_mult => $args{std_mult} // 1,
        values   => [],   # serie: [{ index, vwap, upper, lower, upper1, lower1, upper2, lower2, upper3, lower3 }, ...]
        anchor_index => undef,
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

sub set_anchor {
    my ($self, $anchor_index) = @_;
    $self->{anchor_index} = $anchor_index;
}

sub get_anchor {
    my ($self) = @_;
    return $self->{anchor_index};
}

=head2 calculate_until($candles, $anchor_index, $until_index)

Recalcula la serie de VWAP Anclado desde $anchor_index hasta $until_index
(ambos inclusive). $candles es un arrayref completo de velas
{open,high,low,close,volume}.

Devuelve un hashref { anchor_index => ..., values => [...] } donde cada
elemento de "values" contiene:
  index => índice global de la vela
  vwap  => línea central
  upper => banda superior (vwap + mult*stdev)
  lower => banda inferior (vwap - mult*stdev)

=cut

sub calculate_until {
    my ($self, $candles, $anchor_index, $until_index) = @_;

    $self->reset();
    $self->{anchor_index} = $anchor_index;

    return { anchor_index => $anchor_index, values => $self->{values} }
        if !defined $anchor_index || !defined $until_index
        || $anchor_index < 0 || $until_index < $anchor_index
        || !$candles;

    my $mult = $self->{std_mult};

    my ($cum_pv, $cum_vol, $cum_pv2) = (0, 0, 0);

    for my $i ($anchor_index .. $until_index) {
        my $c = $candles->[$i];
        next unless $c;

        my $tp = ($c->{high} + $c->{low} + $c->{close}) / 3;   # hlc3
        my $vol = $c->{volume} // 0;
        $vol = 0 if $vol eq '';

        $cum_pv  += $tp * $vol;
        $cum_vol += $vol;
        $cum_pv2 += $tp * $tp * $vol;

        my ($vwap, $upper, $lower, $stdev);
        my (%upper_n, %lower_n);

        if ($cum_vol > 0) {
            $vwap = $cum_pv / $cum_vol;
            my $variance = ($cum_pv2 / $cum_vol) - ($vwap * $vwap);
            $variance = 0 if $variance < 0;
            $stdev = sqrt($variance);
            $upper = $vwap + $mult * $stdev;
            $lower = $vwap - $mult * $stdev;

            for my $n (1, 2, 3) {
                $upper_n{$n} = $vwap + $n * $stdev;
                $lower_n{$n} = $vwap - $n * $stdev;
            }
        }
        else {
            # Sin volumen acumulado todavía: usamos el precio típico como
            # referencia y bandas planas para evitar divisiones por cero.
            $vwap  = $tp;
            $upper = $tp;
            $lower = $tp;
            $stdev = 0;

            for my $n (1, 2, 3) {
                $upper_n{$n} = $tp;
                $lower_n{$n} = $tp;
            }
        }

        push @{$self->{values}}, {
            index  => $i,
            vwap   => $vwap,
            upper  => $upper,
            lower  => $lower,
            upper1 => $upper_n{1},
            lower1 => $lower_n{1},
            upper2 => $upper_n{2},
            lower2 => $lower_n{2},
            upper3 => $upper_n{3},
            lower3 => $lower_n{3},
        };
    }

    return { anchor_index => $anchor_index, values => $self->{values} };
}

1;
