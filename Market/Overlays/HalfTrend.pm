package Market::Overlays::HalfTrend;

use strict;
use warnings;

=head1 NOMBRE

Market::Overlays::HalfTrend - Capa visual que dibuja la línea HalfTrend
calculada por Market::Indicators::HalfTrend sobre el canvas de precios.

Fiel al PineScript original:
  * trend == 0 (alcista) => línea azul
  * trend == 1 (bajista) => línea roja
  * Flechas (triángulos) en los puntos de cambio de tendencia
    (arrow_up / arrow_down).
  * Canal opcional (atr_high / atr_low) dibujado como líneas punteadas
    tenues.

=cut

my $BUY_COLOR  = '#2962ff';   # azul (buyColor del original)
my $SELL_COLOR = '#ef5350';   # rojo (sellColor del original)

sub new {
    my ($class, %args) = @_;

    my $self = {
        result        => $args{result},
        show          => $args{show} // 1,
        show_channels => $args{show_channels} // 0,
        show_arrows   => $args{show_arrows} // 1,
    };

    return bless $self, $class;
}

sub set_result {
    my ($self, $result) = @_;
    $self->{result} = $result;
}

sub draw {
    my ($self, $canvas, $scale, $start, $end) = @_;

    return unless $self->{show};
    return unless $self->{result} && $self->{result}->{values};
    return unless $canvas && $scale;

    my $values = $self->{result}->{values};
    my $right_limit = ($canvas->Width() || 0) - 2;
    $right_limit = 0 if $right_limit < 0;

    my $draw_start = $start > 0 ? $start - 1 : 0;

    my ($prev_x, $prev_y);

    for my $i ($draw_start .. $end) {
        my $v = $values->[$i];
        next unless $v && defined $v->{line};

        my $x = $scale->index_to_center_x($i);
        my $y = $scale->value_to_y($v->{line});
        next unless defined $x && defined $y;

        my $color = $v->{trend} == 0 ? $BUY_COLOR : $SELL_COLOR;

        if ($self->{show_channels} && defined $v->{atr_high} && defined $v->{atr_low}) {
            my $y_high = $scale->value_to_y($v->{atr_high});
            my $y_low  = $scale->value_to_y($v->{atr_low});
            $canvas->createLine(
                $x, $y_high, $x, $y_low,
                -fill => $color, -width => 1, -dash => '.',
            ) if $x <= $right_limit;
        }

        if (defined $prev_x && $prev_x <= $right_limit) {
            my ($x1, $y1, $x2, $y2) = ($prev_x, $prev_y, $x, $y);
            $x2 = $right_limit if $x2 > $right_limit;

            $canvas->createLine(
                $x1, $y1, $x2, $y2,
                -fill  => $color,
                -width => 2,
            );
        }

        if ($self->{show_arrows} && $x <= $right_limit) {
            if (defined $v->{arrow_up}) {
                my $ay = $scale->value_to_y($v->{arrow_up});
                _draw_triangle_up($canvas, $x, $ay, $BUY_COLOR);
            }
            if (defined $v->{arrow_down}) {
                my $ay = $scale->value_to_y($v->{arrow_down});
                _draw_triangle_down($canvas, $x, $ay, $SELL_COLOR);
            }
        }

        ($prev_x, $prev_y) = ($x, $y);
    }
}

sub _draw_triangle_up {
    my ($canvas, $x, $y, $color) = @_;
    my $s = 5;
    $canvas->createPolygon(
        $x, $y - $s,
        $x - $s, $y + $s,
        $x + $s, $y + $s,
        -fill => $color, -outline => $color,
    );
}

sub _draw_triangle_down {
    my ($canvas, $x, $y, $color) = @_;
    my $s = 5;
    $canvas->createPolygon(
        $x, $y + $s,
        $x - $s, $y - $s,
        $x + $s, $y - $s,
        -fill => $color, -outline => $color,
    );
}

1;
