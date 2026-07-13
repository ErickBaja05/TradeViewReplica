package Market::Overlays::ChoCH_External;

use strict;
use warnings;

=head1 NOMBRE

Market::Overlays::ChoCH_External - Dibuja los eventos de Change of Character
EXTERNOS generados por Market::Indicators::Structure.

Características visuales (réplica del PineScript LuxAlgo — swing tier):
  * Línea PUNTEADA horizontal desde el nivel roto hasta la barra de ruptura.
  * CHoCH alcista (CHoCH_UP)   => color verde (#089981).
  * CHoCH bajista (CHoCH_DOWN) => color rojo  (#F23645).
  * Grosor: 2 px, guion largo [5,3] para diferenciarlo del BOS externo.
  * Etiqueta "CHoCH" centrada.

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

        next unless $ev->{tier} eq 'external';
        next unless $ev->{type} eq 'CHoCH_UP' || $ev->{type} eq 'CHoCH_DOWN';
        next if $ev->{index} < $start;
        next if defined $ev->{level_index} && $ev->{level_index} > $end;

        my $bullish = ($ev->{type} eq 'CHoCH_UP');
        my $color   = $bullish ? '#089981' : '#F23645';
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
            -width => 2,
        );

        $canvas->createText(
            ($x1 + $x2) / 2,
            $y + ($bullish ? -10 : 10),
            -text   => $label,
            -fill   => $color,
            -font   => ['Arial', 8, 'bold'],
            -anchor => 'center',
        );
    }
}

1;
