package Market::Indicators::MultiAnchoredVWAP;

use strict;
use warnings;

use Market::Indicators::VWAPAnchored;

=head1 NOMBRE

Market::Indicators::MultiAnchoredVWAP - Motor de cálculo de "Multi Anchored VWAP".

Dibuja un VWAP Anclado (con bandas de desviación estándar) desde CADA pivote
detectado por L<Market::Indicators::Anchors> (pivotes regulares ▼/▲ y pivotes
"missed"/fantasma 👻), en lugar de una única ancla elegida manualmente.

Reutiliza internamente L<Market::Indicators::VWAPAnchored> para cada uno de los pivotes.

=head1 PARÁMETROS

  std_mult   => multiplicador base de la desviación estándar (def: 1).
  max_anchors=> cantidad máxima de anclas (pivotes) más recientes a
                calcular (def: 20).

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

=head2 update_last($candles, $anchors, $until_index)

Alias e interfaz compatible con el contrato incremental del motor gráfico[cite: 4].
Invoca a C<calculate_until>.

=cut

sub update_last {
    my ($self, $candles, $anchors, $until_index) = @_;
    return $self->calculate_until($candles, $anchors, $until_index);
}

=head2 calculate_until($candles, $anchors, $until_index)

C<$candles> es el arrayref completo de velas[cite: 7]. 
C<$anchors> puede ser el hashref de resultado completo devuelto por C<Anchors.pm>
(clave C<markers>: C<[{ index, price, type }, ...]>)[cite: 4, 7] o el arrayref directo de pivotes[cite: 7].

Calcula, para cada uno de los C<max_anchors> pivotes más recientes de C<Anchors.pm>,
una serie de VWAP Anclado independiente desde ese pivote hasta C<$until_index>[cite: 7].

Devuelve un hashref C<{ series => [ { anchor_index, type, values }, ... ] }>[cite: 7].

=cut

sub calculate_until {
    my ($self, $candles, $anchors, $until_index) = @_;

    $self->reset();

    return { series => $self->{series} }
        unless $candles && $anchors && defined $until_index;

    # Extrae los pivotes tanto si se pasa el resultado completo de Anchors.pm
    # ($anchors_result) como si se pasa directamente la lista de marcadores
    my $markers = (ref($anchors) eq 'HASH' && exists $anchors->{markers})
        ? $anchors->{markers}
        : (ref($anchors) eq 'ARRAY' ? $anchors : []);

    return { series => $self->{series} } unless @$markers;

    # Filtrar pivotes válidos cuyo índice no supere $until_index
    my @valid = grep { defined $_->{index} && $_->{index} <= $until_index } @$markers;

    # Ordenar cronológicamente por índice
    @valid = sort { $a->{index} <=> $b->{index} } @valid;

    # Tomar los últimos $max_anchors pivotes para no saturar el rendimiento
    my $max_anchors = $self->{max_anchors};
    if (@valid > $max_anchors) {
        @valid = @valid[-$max_anchors .. -1];
    }

    # Recorrer cada pivote detectado por Anchors.pm
    for my $pivot (@valid) {
        my $engine = Market::Indicators::VWAPAnchored->new(std_mult => $self->{std_mult});

        my $result = $engine->calculate_until($candles, $pivot->{index}, $until_index);

        next unless $result && $result->{values} && @{$result->{values}};

        push @{$self->{series}}, {
            anchor_index => $pivot->{index},
            type         => $pivot->{type}, # reg_high, reg_low, missed_high, missed_low
            values       => $result->{values},
        };
    }

    return { series => $self->{series} };
}

1;
