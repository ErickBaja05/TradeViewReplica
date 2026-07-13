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
  upper = vwap + mult * stdev
  lower = vwap - mult * stdev

El cálculo se reinicia ("ancla") en la vela seleccionada por el usuario
($anchor_index) y se acumula hacia adelante hasta $until_index.

=head1 PARÁMETROS

  std_mult => multiplicador de la desviación estándar para las bandas (def: 1)

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        std_mult => $args{std_mult} // 1,
        values   => [],   # serie: [{ index, vwap, upper, lower }, ...]
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

        my ($vwap, $upper, $lower);

        if ($cum_vol > 0) {
            $vwap = $cum_pv / $cum_vol;
            my $variance = ($cum_pv2 / $cum_vol) - ($vwap * $vwap);
            $variance = 0 if $variance < 0;
            my $stdev = sqrt($variance);
            $upper = $vwap + $mult * $stdev;
            $lower = $vwap - $mult * $stdev;
        }
        else {
            # Sin volumen acumulado todavía: usamos el precio típico como
            # referencia y bandas planas para evitar divisiones por cero.
            $vwap  = $tp;
            $upper = $tp;
            $lower = $tp;
        }

        push @{$self->{values}}, {
            index => $i,
            vwap  => $vwap,
            upper => $upper,
            lower => $lower,
        };
    }

    return { anchor_index => $anchor_index, values => $self->{values} };
}

1;
