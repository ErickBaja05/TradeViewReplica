package Market::Overlays::EQH;

use strict;
use warnings;

=head1 NOMBRE

Market::Overlays::EQH - Capa visual que resalta los eventos de Equal Highs
(EQH) detectados por Market::Indicators::Structure sobre el tier "external"
(pivotes swing).

Un EQH ocurre cuando dos pivotes HIGH swing consecutivos quedan a una
distancia (en precio) menor o igual que C<eq_threshold * ATR>, indicando un
posible pool de liquidez por igualdad de máximos.

Características visuales (réplica del PineScript LuxAlgo):
  * Línea PUNTEADA horizontal que conecta ambos pivotes.
  * Color gris/neutro (#B2B5BE).
  * Etiqueta "EQH" centrada, ligeramente por encima de la línea.

=cut

sub new {
    my ($class, %args) = @_;
    return bless {
        result => $args{result},
        show   => $args{show} // 1,
    }, $class;
}

=head2 set_result($result)

Actualiza el resultado calculado por Market::Indicators::Structure
(calculate_until).

=cut

sub set_result {
    my ($self, $result) = @_;
    $self->{result} = $result;
}

=head2 draw($canvas, $scale, $start, $end)

Dibuja los eventos EQH visibles entre los índices [$start, $end].

=cut

sub draw {
    my ($self, $canvas, $scale, $start, $end) = @_;

    return unless $self->{show};
    return unless $self->{result} && $self->{result}->{events};
    return unless $canvas && $scale;

    my $right_limit = ($canvas->Width() || 0) - 2;
    $right_limit = 0 if $right_limit < 0;

    my $color = '#26a69a';

    for my $ev (@{$self->{result}->{events}}) {

        next unless $ev->{tier} eq 'external';
        next unless $ev->{type} eq 'EQH';
        next if $ev->{index} < $start;
        next if defined $ev->{level_index} && $ev->{level_index} > $end;

        my $x2 = $scale->index_to_center_x($ev->{index});
        $x2 = $right_limit if $x2 > $right_limit;

        my $li = defined $ev->{level_index} ? $ev->{level_index} : $ev->{index};
        $li = $start if $li < $start;
        my $x1 = $scale->index_to_center_x($li);

        next if $x2 <= $x1;

        my $price1 = $ev->{price1} // $ev->{level_price};
        my $price2 = $ev->{price2} // $ev->{level_price};
        my $level_price = defined $price1 && defined $price2
            ? ($price1 + $price2) / 2
            : $ev->{level_price};

        my $y = $scale->value_to_y($level_price);

        $canvas->createLine(
            $x1, $y, $x2, $y,
            -fill  => $color,
            -width => 1,
            -dash  => [3, 3],
        );

        $canvas->createText(
            ($x1 + $x2) / 2,
            $y - 10,
            -text   => 'EQH',
            -fill   => $color,
            -font   => ['Arial', 8, 'bold'],
            -anchor => 'center',
        );
    }
}

1;
