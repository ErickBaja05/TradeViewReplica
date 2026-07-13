package Market::Overlays::Fibonacci;

use strict;
use warnings;

=head1 NOMBRE

Market::Overlays::Fibonacci - Capa visual que dibuja los niveles de
retroceso de Fibonacci calculados por Market::Indicators::Fibonacci
(altura del último tramo del ZigZag Externo) sobre el canvas de precios.

Cada nivel se traza como una línea horizontal desde el pivote de origen
(100%) hasta el borde derecho visible del gráfico, con una etiqueta de
porcentaje + precio, al estilo de la herramienta "Fib Retracement" de
TradingView.

=cut

# Paleta por nivel (orden: 0%, 23.6%, 38.2%, 50%, 61.8%, 78.6%, 100%),
# similar a la que usa TradingView por defecto para el retroceso de Fibonacci.
my @LEVEL_COLORS = (
    '#787b86', # 0%
    '#f23645', # 23.6%
    '#ff9800', # 38.2%
    '#4caf50', # 50%
    '#089981', # 61.8%
    '#2962ff', # 78.6%
    '#9c27b0', # 100%
);

sub new {
    my ($class, %args) = @_;

    my $self = {
        result      => $args{result},
        show        => $args{show}        // 1,
        show_labels => $args{show_labels}  // 1,
    };

    return bless $self, $class;
}

=head2 set_result($fib_result)

Actualiza el resultado calculado por Market::Indicators::Fibonacci.

=cut

sub set_result {
    my ($self, $fib_result) = @_;
    $self->{result} = $fib_result;
}

=head2 draw($canvas, $scale, $start, $end)

Dibuja los niveles de Fibonacci visibles entre los índices [$start, $end].

=cut

sub draw {
    my ($self, $canvas, $scale, $start, $end) = @_;

    return if !$self->{show};
    return unless $self->{result} && $self->{result}->{levels} && @{ $self->{result}->{levels} };
    return unless $canvas && $scale;

    my $result = $self->{result};
    my $levels = $result->{levels};

    my $origin_index = $result->{origin_index};
    return unless defined $origin_index;

    # Si todo el tramo queda a la derecha de la ventana visible, no hay nada
    # que trazar todavía dentro del área visible.
    return if $origin_index > $end;

    my $x_start = $scale->index_to_center_x($origin_index);
    return unless defined $x_start;

    my $right_limit = ($canvas->Width() || 0) - 2;
    $right_limit = 0 if $right_limit < 0;

    # No dibujamos nada si el punto de origen ya está más allá del borde
    # derecho visible (no debería ocurrir dado el chequeo anterior, pero
    # protege ante anchos de canvas todavía no realizados).
    return if $x_start > $right_limit;

    for my $i (0 .. $#$levels) {
        my $lvl_data = $levels->[$i];
        my $y = $scale->value_to_y($lvl_data->{price});
        next unless defined $y;

        my $color = $LEVEL_COLORS[$i % scalar(@LEVEL_COLORS)];
        my $is_edge = ($lvl_data->{level} == 0 || $lvl_data->{level} == 1);

        $canvas->createLine(
            $x_start, $y, $right_limit, $y,
            -fill  => $color,
            -width => $is_edge ? 2 : 1,
            ($is_edge ? () : (-dash => '.')),
        );

        next unless $self->{show_labels};

        my $pct = sprintf('%.1f%%', $lvl_data->{level} * 100);

        $canvas->createText(
            $right_limit - 4,
            $y - 8,
            -text   => sprintf('%s  %s', $pct, _fmt_price($lvl_data->{price})),
            -fill   => $color,
            -font   => ['Arial', 8, 'bold'],
            -anchor => 'e',
        );
    }

    # Marcadores en los puntos de anclaje (origen y punto reciente)
    my $ay = $scale->value_to_y($result->{origin_price});
    if (defined $ay) {
        my $r = 3;
        $canvas->createOval(
            $x_start - $r, $ay - $r, $x_start + $r, $ay + $r,
            -fill => '#9c27b0', -outline => '#9c27b0'
        );
    }

    my $anchor_index = $result->{anchor_index};
    if (defined $anchor_index && $anchor_index >= $start && $anchor_index <= $end) {
        my $bx = $scale->index_to_center_x($anchor_index);
        my $by = $scale->value_to_y($result->{anchor_price});
        if (defined $bx && defined $by) {
            my $r = 3;
            $canvas->createOval(
                $bx - $r, $by - $r, $bx + $r, $by + $r,
                -fill => '#787b86', -outline => '#787b86'
            );
        }
    }
}

sub _fmt_price {
    my ($p) = @_;
    return '' unless defined $p;
    return sprintf('%.5f', $p);
}

1;
