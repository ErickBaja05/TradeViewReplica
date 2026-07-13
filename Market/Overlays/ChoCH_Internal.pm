package Market::Overlays::ChoCH_Internal;

use strict;
use warnings;

=head1 NOMBRE

Market::Overlays::ChoCH_Internal - Dibuja los eventos de Change of Character
INTERNOS generados por Market::Indicators::Structure.

Características visuales (réplica del PineScript LuxAlgo — internal tier):
  * Línea PUNTEADA fina desde el nivel roto hasta la barra de ruptura.
  * CHoCH alcista (CHoCH_UP)   => verde (#26a69a, tono ligeramente más claro).
  * CHoCH bajista (CHoCH_DOWN) => rojo  (#ef5350, tono ligeramente más claro).
  * Grosor: 1 px, guion corto [2,2] para distinguirlo del externo.
  * Etiqueta "CHoCH" con fuente tiny.

=cut

sub new {
    my ($class, %args) = @_;
    return bless {
        result => $args{result},
        show   => $args{show} // 1,
    }, $class;
}

sub set_result {
    my ($self, $result) = @_;
    $self->{result} = $result;
}

sub draw {
    my ($self, $canvas, $scale, $start, $end) = @_;

    return unless $self->{show};
    return unless $self->{result} && $self->{result}->{events};
    return unless $canvas && $scale;

    my $right_limit = ($canvas->Width() || 0) - 2;
    $right_limit = 0 if $right_limit < 0;

    for my $ev (@{$self->{result}->{events}}) {

        next unless $ev->{tier} eq 'internal';
        next unless $ev->{type} eq 'CHoCH_UP' || $ev->{type} eq 'CHoCH_DOWN';
        next if $ev->{index} < $start;
        next if defined $ev->{level_index} && $ev->{level_index} > $end;

        my $bullish = ($ev->{type} eq 'CHoCH_UP');
        my $color   = $bullish ? '#26a69a' : '#ef5350';
        my $label   = 'CHoCH';

        my $x2 = $scale->index_to_center_x($ev->{index});
        $x2 = $right_limit if $x2 > $right_limit;

        my $li = defined $ev->{level_index} ? $ev->{level_index} : $ev->{index};
        $li = $start if $li < $start;
        my $x1 = $scale->index_to_center_x($li);
        my $y  = $scale->value_to_y($ev->{level_price} // $ev->{price} // 0);

        next if $x2 <= $x1;

        $canvas->createLine(
            $x1, $y, $x2, $y,
            -fill  => $color,
            -width => 1,
            -dash  => [2, 2],
        );

        $canvas->createText(
            ($x1 + $x2) / 2,
            $y + ($bullish ? -8 : 8),
            -text   => $label,
            -fill   => $color,
            -font   => ['Arial', 7, 'bold'],
            -anchor => 'center',
        );
    }
}

1;
