package Market::Indicators::Fibonacci;

use strict;
use warnings;

=head1 NOMBRE

Market::Indicators::Fibonacci - Calcula los niveles de retroceso de
Fibonacci usando la altura (rango de precio) del último tramo (leg) del
ZigZag Externo, es decir, entre el último pivote estructural y el
inmediatamente anterior.

=head1 DESCRIPCIÓN

El "zigzag externo" que se dibuja en la sección Structure se construye a
partir de los pivotes estructurales generados por
C<Market::Indicators::SMC_Structures> (motor C<smc_engine> en
C<ChartEngine>), disponibles en C<< $smc_result->{structure} >> como una
lista ordenada de hashrefs C<{ type => 'HIGH'|'LOW', price, index, ... }>.

El "último zigzag externo" es, por tanto, el tramo entre los dos últimos
pivotes de esa lista: el más reciente (anchor, donde se ancla el 0%) y el
inmediatamente anterior (origin, donde se ancla el 100%). Esto replica el
comportamiento estándar de la herramienta de Retroceso de Fibonacci: el
nivel 0% queda en el extremo más reciente del movimiento y el 100% en el
extremo de origen, de modo que los niveles intermedios (23.6%, 38.2%,
50%, 61.8%, 78.6%) representan zonas de retroceso hacia el precio actual.

  price(nivel) = anchor_price + nivel * (origin_price - anchor_price)

Parámetros:
  levels => arrayref de niveles a calcular (def: 0, 0.236, 0.382, 0.5,
            0.618, 0.786, 1)

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        levels => $args{levels} // [0, 0.236, 0.382, 0.5, 0.618, 0.786, 1],
    };

    return bless $self, $class;
}

=head2 calculate($structure)

Recibe la lista de pivotes del zigzag externo (C<< $smc_result->{structure} >>)
y devuelve un hashref con:

  anchor_index => índice del pivote más reciente (nivel 0%)
  anchor_price => precio del pivote más reciente
  origin_index => índice del pivote inmediatamente anterior (nivel 100%)
  origin_price => precio del pivote inmediatamente anterior
  levels       => arrayref de { level => 0.618, price => 123.45 }

Si no hay al menos dos pivotes disponibles, devuelve C<< { levels => [] } >>.

=cut

sub calculate {
    my ($self, $structure) = @_;

    return { levels => [] } unless $structure && ref($structure) eq 'ARRAY' && @$structure >= 2;

    my $last = $structure->[-1];
    my $prev = $structure->[-2];

    return { levels => [] } unless defined $last->{price} && defined $prev->{price};

    my $anchor_price = $last->{price};
    my $anchor_index = $last->{index};
    my $origin_price = $prev->{price};
    my $origin_index = $prev->{index};

    my $range = $origin_price - $anchor_price;

    my @levels;
    for my $lvl (@{ $self->{levels} }) {
        push @levels, {
            level => $lvl,
            price => $anchor_price + $lvl * $range,
        };
    }

    return {
        anchor_index => $anchor_index,
        anchor_price => $anchor_price,
        origin_index => $origin_index,
        origin_price => $origin_price,
        levels       => \@levels,
    };
}

1;
