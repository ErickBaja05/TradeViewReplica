package Market::Indicators::MultiAnchoredVWAP;

use strict;
use warnings;

use Market::Indicators::VWAPAnchored;

=head1 NOMBRE

Market::Indicators::MultiAnchoredVWAP - Motor de cálculo de "Multi Anchored
VWAP": dibuja un VWAP Anclado (con bandas de desviación estándar) desde
CADA pivote detectado por Market::Indicators::Anchors (pivotes altos y
bajos, incluyendo los "perdidos"/missed), en lugar de un único ancla
elegida manualmente con click.

Reutiliza internamente Market::Indicators::VWAPAnchored (misma fórmula:
src = hlc3, vwap = cumsum(src*vol)/cumsum(vol), bandas = vwap ± N*stdev)
para cada uno de los pivotes.

=head1 PARÁMETROS

  std_mult   => multiplicador base de la desviación estándar (def: 1).
  max_anchors=> cantidad máxima de anclas (pivotes) más recientes a
                calcular, para evitar recalcular decenas de VWAPs
                superpuestos en historiales largos (def: 20).

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        std_mult    => $args{std_mult}    // 1,
        max_anchors => $args{max_anchors} // 20,
        series      => [],   # [{ anchor_index, type, values }, ...]
    };

    return bless $self, $class;
}

sub reset {
    my ($self) = @_;
    $self->{series} = [];
}

sub get_series {
    my ($self) = @_;
    return $self->{series};
}

=head2 calculate_until($candles, $anchors, $until_index)

$candles es el arrayref completo de velas. $anchors es el arrayref de
marcadores devuelto por Market::Indicators::Anchors::calculate_until()
(clave C<markers>: { index, price, type }).

Calcula, para cada uno de los C<max_anchors> pivotes más recientes (con
index <= $until_index), una serie de VWAP Anclado independiente desde ese
pivote hasta $until_index.

Devuelve un hashref { series => [ { anchor_index, type, values }, ... ] }.

=cut

sub calculate_until {
    my ($self, $candles, $anchors, $until_index) = @_;

    $self->reset();

    return { series => $self->{series} }
        unless $candles && $anchors && defined $until_index;

    # Sólo nos interesan los pivotes ya confirmados dentro del rango visible
    # de cálculo, ordenados de más antiguo a más reciente, y limitados a los
    # últimos $max_anchors para no acumular decenas de VWAPs superpuestos.
    my @valid = grep { defined $_->{index} && $_->{index} <= $until_index } @$anchors;
    @valid = sort { $a->{index} <=> $b->{index} } @valid;

    my $max_anchors = $self->{max_anchors};
    if (@valid > $max_anchors) {
        @valid = @valid[-$max_anchors .. -1];
    }

    for my $pivot (@valid) {
        my $engine = Market::Indicators::VWAPAnchored->new(std_mult => $self->{std_mult});

        my $result = $engine->calculate_until($candles, $pivot->{index}, $until_index);

        next unless $result && $result->{values} && @{$result->{values}};

        push @{$self->{series}}, {
            anchor_index => $pivot->{index},
            type         => $pivot->{type},
            values       => $result->{values},
        };
    }

    return { series => $self->{series} };
}

1;
