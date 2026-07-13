package Market::Indicators::Levels;

use strict;
use warnings;

=head1 NOMBRE

Market::Indicators::Levels - Niveles de Soporte y Resistencia calculados
sobre los pivotes estructurales del ZigZag Externo (la misma serie que usa
C<Market::Indicators::Fibonacci>, disponible en C<< $smc_result->{structure} >>).

=head1 DESCRIPCIÓN

Cada pivote de tipo C<HIGH> se traza como un nivel de Resistencia; cada
pivote C<LOW> como un nivel de Soporte. El nivel se extiende desde la barra
donde se originó hasta la barra donde el precio lo "rompe" (el cierre de
una vela posterior cruza el nivel): hacia arriba para una resistencia,
hacia abajo para un soporte. Si nunca se rompe, permanece vigente hasta la
última vela disponible (y el overlay lo extiende hasta el borde derecho
visible).

Parámetros:
  max_levels => cantidad máxima de niveles a mantener por lado, quedándonos
                con los más recientes (def: 6)

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        max_levels => $args{max_levels} // 6,
        levels     => [],
    };

    return bless $self, $class;
}

sub reset {
    my ($self) = @_;
    $self->{levels} = [];
}

=head2 calculate_until($structure, $candles, $until_index)

  $structure   => arrayref de pivotes { type => 'HIGH'|'LOW', price, index }
                  (p.ej. $smc_result->{structure})
  $candles     => arrayref completo de velas, usado para detectar rupturas
  $until_index => índice de la última vela disponible

Devuelve C<< { levels => [ { type, price, start_index, end_index, broken }, ... ] } >>
donde C<type> es C<'RESISTANCE'> o C<'SUPPORT'>.

=cut

sub calculate_until {
    my ($self, $structure, $candles, $until_index) = @_;

    $self->reset();
    return { levels => [] }
        unless $structure && ref($structure) eq 'ARRAY' && @$structure
        && defined $until_index;

    my (@resistances, @supports);

    for my $pivot (@$structure) {
        next unless defined $pivot->{price} && defined $pivot->{index};

        if ($pivot->{type} eq 'HIGH') {
            push @resistances, { price => $pivot->{price}, index => $pivot->{index} };
        }
        elsif ($pivot->{type} eq 'LOW') {
            push @supports, { price => $pivot->{price}, index => $pivot->{index} };
        }
    }

    # Nos quedamos sólo con los N más recientes de cada lado.
    my $max = $self->{max_levels};
    @resistances = splice(@resistances, -$max) if @resistances > $max;
    @supports    = splice(@supports, -$max)    if @supports > $max;

    my @out;

    for my $r (@resistances) {
        my $break_index = _find_break($candles, $r->{index}, $r->{price}, $until_index, 1);
        push @out, {
            type        => 'RESISTANCE',
            price       => $r->{price},
            start_index => $r->{index},
            end_index   => defined $break_index ? $break_index : $until_index,
            broken      => defined $break_index ? 1 : 0,
        };
    }

    for my $s (@supports) {
        my $break_index = _find_break($candles, $s->{index}, $s->{price}, $until_index, -1);
        push @out, {
            type        => 'SUPPORT',
            price       => $s->{price},
            start_index => $s->{index},
            end_index   => defined $break_index ? $break_index : $until_index,
            broken      => defined $break_index ? 1 : 0,
        };
    }

    $self->{levels} = \@out;
    return { levels => \@out };
}

# Busca la primera barra posterior a $start_index cuyo cierre rompa el
# nivel $price. $direction => 1 (resistencia: rota si close > price) o
# -1 (soporte: rota si close < price). Devuelve el índice de ruptura o
# undef si no se rompe dentro de [$start_index+1 .. $until_index].
sub _find_break {
    my ($candles, $start_index, $price, $until_index, $direction) = @_;

    for my $i (($start_index + 1) .. $until_index) {
        my $bar = $candles->[$i];
        next unless $bar;

        if ($direction == 1) {
            return $i if $bar->{close} > $price;
        }
        else {
            return $i if $bar->{close} < $price;
        }
    }

    return undef;
}

1;
