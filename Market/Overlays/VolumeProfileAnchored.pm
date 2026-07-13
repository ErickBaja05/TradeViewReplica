package Market::Overlays::VolumeProfileAnchored;

use strict;
use warnings;

=head1 NOMBRE

Market::Overlays::VolumeProfileAnchored - Capa visual que dibuja el Volume
Profile Anclado calculado por Market::Indicators::VolumeProfileAnchored
sobre el canvas de precios.

  * Histograma horizontal          => barras pegadas al borde derecho del
                                       panel de precios, ancho proporcional
                                       al volumen de cada franja de precio
                                       (no se dibuja sobre las velas)
  * Franja POC (Point of Control)  => barra naranja resaltada
  * Zona de valor de 1 sigma       => barras dentro de [val, vah] en azul,
                                       el resto en gris semitransparente
  * Líneas de referencia VAH/VAL/POC punteadas a lo ancho de la ventana
  * Marcador triangular en la vela de ancla (igual que el VWAP Anclado)

El indicador sólo se dibuja desde la vela de ancla en adelante (nunca hacia
atrás), tal como en TradingView.

=cut

my $POC_COLOR      = '#ff9800';   # naranja (franja de mayor volumen)
my $VALUE_COLOR     = '#2962ff';  # azul (franjas dentro de la zona de valor)
my $OUTSIDE_COLOR   = '#787b86';  # gris (franjas fuera de la zona de valor)
my $VAH_VAL_COLOR    = '#2962ff'; # azul (líneas VAH/VAL)
my $POC_LINE_COLOR   = '#ff9800'; # naranja (línea POC)
my $ANCHOR_COLOR    = '#ff9800';  # naranja (marcador de ancla)

# Ancho máximo (en píxeles) que puede alcanzar la barra más larga del
# histograma (la de mayor volumen / el POC).
my $MAX_BAR_WIDTH = 90;

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

Dibuja el Volume Profile Anclado (histograma + zona de valor de 1 sigma)
anclado en la vela de ancla. El histograma se dibuja siempre que la vela de
ancla esté a la izquierda del borde derecho de la ventana visible; las
barras se pegan al borde derecho del panel de precios y crecen hacia la
izquierda (como un panel lateral), de modo que nunca se dibujan encima de
las velas. Las líneas de referencia (VAH/VAL/POC) sí se extienden desde la
vela de ancla hasta el borde derecho, igual que en TradingView.

=cut

sub draw {
    my ($self, $canvas, $scale, $start, $end) = @_;

    return unless $self->{show};
    return unless $self->{result} && $self->{result}->{bins};
    return unless $canvas && $scale;

    my $result       = $self->{result};
    my $bins         = $result->{bins};
    my $anchor_index = $result->{anchor_index};
    return unless @$bins;
    return unless defined $anchor_index;
    return if $anchor_index > $end;

    my $max_volume = $result->{max_volume} || 0;
    return if $max_volume <= 0;

    my $right_limit = ($canvas->Width() || 0) - 2;
    $right_limit = 0 if $right_limit < 0;

    # Origen horizontal de las LÍNEAS de referencia (VAH/VAL/POC): el borde
    # izquierdo de la vela de ancla (o el borde izquierdo visible, si el
    # ancla quedó fuera por la izquierda del scroll). El histograma en sí,
    # en cambio, se dibuja pegado al borde derecho del panel para no tapar
    # las velas (ver más abajo).
    my $anchor_x = $scale->index_to_x($anchor_index);
    $anchor_x = 0 if !defined $anchor_x || $anchor_x < 0;

    # --- Zona de valor de 1 sigma: banda horizontal semitransparente a lo
    #     ancho de toda la ventana visible ---
    my ($vah, $val) = ($result->{vah}, $result->{val});
    if (defined $vah && defined $val) {
        my $y_vah = $scale->value_to_y($vah);
        my $y_val = $scale->value_to_y($val);
        $canvas->createRectangle(
            $anchor_x, $y_vah, $right_limit, $y_val,
            -fill    => $VAH_VAL_COLOR,
            -outline => '',
            -stipple => 'gray12',
        );

        for my $y ($y_vah, $y_val) {
            $canvas->createLine(
                $anchor_x, $y, $right_limit, $y,
                -fill  => $VAH_VAL_COLOR,
                -width => 1,
                -dash  => '.',
            );
        }
    }

    # --- Línea de referencia POC, a lo ancho de la ventana visible ---
    if (defined $result->{poc_price}) {
        my $y_poc = $scale->value_to_y($result->{poc_price});
        $canvas->createLine(
            $anchor_x, $y_poc, $right_limit, $y_poc,
            -fill  => $POC_LINE_COLOR,
            -width => 1,
            -dash  => '-',
        );
    }

    # --- Histograma: una barra horizontal por franja de precio, pegada al
    #     borde derecho del panel y creciendo hacia la izquierda (como un
    #     panel lateral), para no dibujarse encima de las velas ---
    for my $bin (@$bins) {
        next unless $bin->{volume} > 0;

        my $y_top    = $scale->value_to_y($bin->{price_high});
        my $y_bottom = $scale->value_to_y($bin->{price_low});
        next if $y_bottom <= $y_top - 0.0001 && $y_top == $y_bottom; # sin altura

        my $bar_width = $MAX_BAR_WIDTH * ($bin->{volume} / $max_volume);
        my $x_start   = $right_limit - $bar_width;
        $x_start = 0 if $x_start < 0;
        next if $x_start >= $right_limit;

        my $mid = ($bin->{price_low} + $bin->{price_high}) / 2;
        my $is_poc = defined $result->{poc_price}
            && $bin->{price_low} <= $result->{poc_price}
            && $result->{poc_price} <= $bin->{price_high};
        my $in_value_area = defined $vah && defined $val
            && $mid >= $val && $mid <= $vah;

        my $color = $is_poc ? $POC_COLOR
                  : $in_value_area ? $VALUE_COLOR
                  : $OUTSIDE_COLOR;

        $canvas->createRectangle(
            $x_start, $y_top, $right_limit, $y_bottom,
            -fill    => $color,
            -outline => '',
            -stipple => 'gray50',
        );
    }

    # --- Marcador de la vela de ancla (triángulo naranja), igual que en el
    #     VWAP Anclado ---
    if ($anchor_index >= $start && $anchor_index <= $end) {
        my $ax = $scale->index_to_center_x($anchor_index);
        if (defined $ax) {
            my $ref_price = defined $result->{poc_price} ? $result->{poc_price}
                          : ($bins->[0]{price_low} + $bins->[-1]{price_high}) / 2;
            my $ay = $scale->value_to_y($ref_price);
            my $r  = 5;
            $canvas->createPolygon(
                $ax,      $ay - $r,
                $ax - $r, $ay + $r,
                $ax + $r, $ay + $r,
                -fill    => $ANCHOR_COLOR,
                -outline => '#ffffff',
            );
        }
    }
}

1;
