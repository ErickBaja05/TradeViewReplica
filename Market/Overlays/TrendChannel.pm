package Market::Overlays::TrendChannel;

use strict;
use warnings;

=head1 NOMBRE

Market::Overlays::TrendChannel - Capa visual que dibuja el canal de
regresión lineal calculado por Market::Indicators::TrendChannel (línea
central + bandas superior/inferior a "deviation" desviaciones estándar),
réplica de trendchannel.txt.

Fiel al script original: en cada momento sólo se dibuja UN canal (tres
rectas: superior, central e inferior), correspondiente a la regresión
vigente en la última barra visible, extendido hacia la derecha. No se van
"conectando" los extremos de canales sucesivos (eso produciría una curva,
como una media móvil, en vez de una recta). No se dibuja ningún indicio
de "canal roto": este overlay únicamente representa el canal vigente.

=cut

my $UP_COLOR   = '#26a69a';   # verde (pendiente > 0)
my $DOWN_COLOR = '#ef5350';   # rojo  (pendiente < 0)
my $FLAT_COLOR = '#787b86';   # gris  (pendiente == 0)

sub new {
    my ($class, %args) = @_;

    my $self = {
        result => $args{result},
        show   => $args{show} // 1,
        extend => $args{extend} // 1,   # extender la recta hasta el borde derecho visible
    };

    return bless $self, $class;
}

sub set_result {
    my ($self, $result) = @_;
    $self->{result} = $result;
}

sub _color_for {
    my ($slope) = @_;
    return $slope > 0 ? $UP_COLOR : $slope < 0 ? $DOWN_COLOR : $FLAT_COLOR;
}

=head2 draw($canvas, $scale, $start, $end)

Dibuja el canal (recta central + bandas) vigente en la última barra
visible ($end), recortado/extendido a la ventana [$start, $end].

=cut

sub draw {
    my ($self, $canvas, $scale, $start, $end) = @_;

    return unless $self->{show};
    return unless $self->{result} && $self->{result}->{values};
    return unless $canvas && $scale;

    my $values = $self->{result}->{values};

    # Buscamos el canal vigente en la última barra visible: el valor
    # calculado exactamente en $end, o si no existe (por ejemplo porque
    # $end cae fuera del historial calculado), el más reciente disponible
    # hacia atrás.
    my $ref_index = $end;
    $ref_index = $#$values if $ref_index > $#$values;

    my $v;
    while ($ref_index >= 0 && $ref_index >= $start - 1) {
        $v = $values->[$ref_index];
        last if $v;
        $ref_index--;
    }
    return unless $v;

    my $right_limit = ($canvas->Width() || 0) - 2;
    $right_limit = 0 if $right_limit < 0;

    # Recta completa del canal: (start, y1) -> (end, y2), tal como la
    # calculó el motor sobre su ventana de regresión.
    my $seg_start = $v->{start} < $start ? $start : $v->{start};
    return if $seg_start > $v->{end};

    my $span = $v->{end} - $v->{start};
    $span = 1 if $span == 0;

    # Interpolación lineal para recortar el segmento visible al inicio de
    # la ventana (si el canal arranca antes del área visible).
    my $frac_l = ($seg_start - $v->{start}) / $span;

    my $mid_l   = $v->{mid_y1}   + ($v->{mid_y2}   - $v->{mid_y1})   * $frac_l;
    my $upper_l = $v->{upper_y1} + ($v->{upper_y2} - $v->{upper_y1}) * $frac_l;
    my $lower_l = $v->{lower_y1} + ($v->{lower_y2} - $v->{lower_y1}) * $frac_l;

    my $x1 = $scale->index_to_x($seg_start);
    my $x2 = $self->{extend}
        ? $right_limit
        : $scale->index_to_x($v->{end} + 1);
    $x2 = $right_limit if $x2 > $right_limit;
    return if $x2 <= $x1;

    my $y_mid_l   = $scale->value_to_y($mid_l);
    my $y_mid_r   = $scale->value_to_y($v->{mid_y2});
    my $y_upper_l = $scale->value_to_y($upper_l);
    my $y_upper_r = $scale->value_to_y($v->{upper_y2});
    my $y_lower_l = $scale->value_to_y($lower_l);
    my $y_lower_r = $scale->value_to_y($v->{lower_y2});

    my $color = _color_for($v->{slope});

    $canvas->createLine(
        $x1, $y_upper_l, $x2, $y_upper_r,
        -fill  => $color,
        -width => 2,
    );
    $canvas->createLine(
        $x1, $y_lower_l, $x2, $y_lower_r,
        -fill  => $color,
        -width => 2,
    );
    $canvas->createLine(
        $x1, $y_mid_l, $x2, $y_mid_r,
        -fill  => $color,
        -width => 1,
        -dash  => '4 2',
    );
}

1;
