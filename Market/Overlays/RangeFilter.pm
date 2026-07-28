package Market::Overlays::RangeFilter;

use strict;
use warnings;

=head1 NOMBRE

Market::Overlays::RangeFilter - Capa visual que dibuja la línea Range
Filter calculada por Market::Indicators::RangeFilter sobre el canvas de
precios.

Fiel al PineScript original:
  * filtcolor = upward > 0 ? lime (verde) : downward > 0 ? red (rojo) : orange (naranja)
  * Se dibuja como una única línea (plot 'filt'), coloreada por tramos
    según el signo del contador upward/downward de esa barra.
  * Triángulos en los cambios de tendencia (buy/sell signal), replicando
    los marcadores "uprf"/"downrf" del indicador original.

=cut

my $UP_COLOR      = '#00ff00';   # lime
my $DOWN_COLOR    = '#ef5350';   # red
my $NEUTRAL_COLOR = '#ff9800';   # orange

sub new {
    my ($class, %args) = @_;

    my $self = {
        result => $args{result},
        show   => $args{show} // 1,
    };

    return bless $self, $class;
}

sub set_result {
    my ($self, $result) = @_;
    $self->{result} = $result;
}

sub _color_for {
    my ($v) = @_;
    return $UP_COLOR   if $v->{trend} == 1;
    return $DOWN_COLOR if $v->{trend} == -1;
    return $NEUTRAL_COLOR;
}

=head2 draw($canvas, $scale, $start, $end)

Dibuja la línea Range Filter visible en la ventana [$start, $end].

=cut

sub draw {
    my ($self, $canvas, $scale, $start, $end) = @_;

    return unless $self->{show};
    return unless $self->{result} && $self->{result}->{values};
    return unless $canvas && $scale;

    my $values = $self->{result}->{values};
    my $right_limit = ($canvas->Width() || 0) - 2;
    $right_limit = 0 if $right_limit < 0;

    # Extendemos un índice a la izquierda para que el segmento que entra en
    # la ventana visible se dibuje conectado correctamente.
    my $draw_start = $start > 0 ? $start - 1 : 0;

    my ($prev_x, $prev_y);

    for my $i ($draw_start .. $end) {
        my $v = $values->[$i];
        next unless $v;

        my $x = $scale->index_to_center_x($i);
        my $y = $scale->value_to_y($v->{filt});
        next unless defined $x && defined $y;

        if (defined $prev_x && $prev_x <= $right_limit) {
            my ($x1, $y1, $x2, $y2) = ($prev_x, $prev_y, $x, $y);
            $x2 = $right_limit if $x2 > $right_limit;

            $canvas->createLine(
                $x1, $y1, $x2, $y2,
                -fill  => _color_for($v),
                -width => 2,
            );
        }

        if (($v->{buy_signal} || $v->{sell_signal}) && $x <= $right_limit) {
            my $r     = 4;
            my $color = $v->{buy_signal} ? $UP_COLOR : $DOWN_COLOR;

            if ($v->{buy_signal}) {
                # Triángulo apuntando hacia arriba, debajo de la línea.
                $canvas->createPolygon(
                    $x, $y + $r,
                    $x - $r, $y + $r * 2,
                    $x + $r, $y + $r * 2,
                    -fill => $color, -outline => $color,
                );
            }
            else {
                # Triángulo apuntando hacia abajo, encima de la línea.
                $canvas->createPolygon(
                    $x, $y - $r,
                    $x - $r, $y - $r * 2,
                    $x + $r, $y - $r * 2,
                    -fill => $color, -outline => $color,
                );
            }
        }

        ($prev_x, $prev_y) = ($x, $y);
    }
}

1;
