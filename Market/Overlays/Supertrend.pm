package Market::Overlays::Supertrend;

use strict;
use warnings;

=head1 NOMBRE

Market::Overlays::Supertrend - Capa visual que dibuja la línea SuperTrend
calculada por Market::Indicators::Supertrend sobre el canvas de precios.

Fiel al PineScript original:
  * Tramo alcista (trend == 1)  => línea verde bajo el precio (banda "up")
  * Tramo bajista (trend == -1) => línea roja sobre el precio (banda "dn")
  * Se dibuja como segmentos "linebr" (se corta cuando cambia de tendencia,
    no se conecta un tramo verde con uno rojo).
  * Círculos en los cambios de tendencia (buy/sell signal).

=cut

my $UP_COLOR   = '#26a69a';   # verde
my $DOWN_COLOR = '#ef5350';   # rojo

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

=head2 draw($canvas, $scale, $start, $end)

Dibuja la línea SuperTrend visible en la ventana [$start, $end].

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

    my ($prev_x, $prev_y, $prev_trend);

    for my $i ($draw_start .. $end) {
        my $v = $values->[$i];
        next unless $v;

        my $x = $scale->index_to_center_x($i);
        my $y = $scale->value_to_y($v->{line});
        next unless defined $x && defined $y;

        if (defined $prev_x && defined $prev_trend && $prev_trend == $v->{trend}
            && $prev_x <= $right_limit) {

            my ($x1, $y1, $x2, $y2) = ($prev_x, $prev_y, $x, $y);
            $x2 = $right_limit if $x2 > $right_limit;

            my $color = $v->{trend} == 1 ? $UP_COLOR : $DOWN_COLOR;

            $canvas->createLine(
                $x1, $y1, $x2, $y2,
                -fill  => $color,
                -width => 2,
            );
        }

        if ($v->{buy_signal} && $x <= $right_limit) {
            my $r = 3;
            $canvas->createOval(
                $x - $r, $y - $r, $x + $r, $y + $r,
                -fill => $UP_COLOR, -outline => $UP_COLOR,
            );
        }
        if ($v->{sell_signal} && $x <= $right_limit) {
            my $r = 3;
            $canvas->createOval(
                $x - $r, $y - $r, $x + $r, $y + $r,
                -fill => $DOWN_COLOR, -outline => $DOWN_COLOR,
            );
        }

        ($prev_x, $prev_y, $prev_trend) = ($x, $y, $v->{trend});
    }
}

1;
