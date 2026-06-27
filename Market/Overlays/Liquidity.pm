package Market::Overlays::Liquidity;
use strict;
use warnings;
use parent 'Market::Overlays::Base';

# =============================================================================
# Market::Overlays::Liquidity
#
# Renderiza sobre el price_canvas las zonas de liquidez calculadas por
# Market::Indicators::Liquidity. Hereda de Market::Overlays::Base y usa
# sus helpers _x_to_pixel() / _y_to_pixel() a través de Market::Panels::Scales.
#
# CONVENCIÓN DE COLORES (estilo TradingView SMC):
#   BSL activo  -> línea roja   (#ef5350)  etiqueta "BSL"
#   SSL activo  -> línea verde  (#26a69a)  etiqueta "SSL"
#   GRAB        -> resaltado naranja (#ff9800)  etiqueta "GRAB ↑ / GRAB ↓"
#   RUN         -> resaltado azul    (#2196f3)  etiqueta "RUN ↑ / RUN ↓"
#
# USO DESDE ChartEngine::render():
#   $self->{liquidity_overlay}->render($liquidity_zones_arrayref, $start, $end);
# =============================================================================

# Colores constantes para evitar repetición y facilitar mantenimiento
my %COLORS = (
    BSL_line    => '#ef5350',   # rojo
    SSL_line    => '#26a69a',   # verde teal
    GRAB_marker => '#ff9800',   # naranja
    RUN_marker  => '#2196f3',   # azul
    label_fg    => '#ffffff',   # blanco para texto sobre fondo oscuro
);

sub new {
    my ($class, %args) = @_;

    # Llamamos al constructor del padre (Base) que almacena canvas y scales
    my $self = $class->SUPER::new(%args);

    # Configuración visual propia del overlay
    $self->{show_resolved} = exists $args{show_resolved} ? $args{show_resolved} : 1;
    $self->{line_width}    = $args{line_width} || 1;
    $self->{label_font}    = $args{label_font} || ['Helvetica', 8, 'bold'];

    bless $self, $class;
    return $self;
}

# -----------------------------------------------------------------------------
# render(\@zones, $start_index, $end_index)
#
# Punto de entrada principal. Recibe el arrayref de zonas del indicador y la
# ventana visible actual. Borra todos los ítems previos del overlay (tag
# 'liquidity') y redibuja.
#
# Parámetros:
#   $zones       : arrayref de hashrefs de zonas (output de Indicators::Liquidity)
#   $start_index : primer índice visible en la ventana
#   $end_index   : último índice visible en la ventana
# -----------------------------------------------------------------------------
sub render {
    my ($self, $zones, $start_index, $end_index) = @_;

    my $canvas = $self->{canvas};
    return unless $canvas;

    # Limpiar solo los ítems de este overlay
    $canvas->delete('liquidity');

    return unless defined $zones && ref($zones) eq 'ARRAY' && scalar @$zones;
    return unless defined $self->{scales};

    my $canvas_w = $canvas->Width()  || $canvas->reqwidth()  || 1;
    return if $canvas_w <= 1;

    for my $zone (@$zones) {
        next unless defined $zone && ref($zone) eq 'HASH';

        # Solo renderizamos zonas que tienen sentido mostrar en la ventana actual
        next unless $self->_should_draw($zone, $start_index, $end_index);

        if ($zone->{state} eq 'DETECTED') {
            $self->_draw_active_level($zone, $start_index, $end_index, $canvas_w);
        }
        elsif ($zone->{state} eq 'RESOLVED' && $self->{show_resolved}) {
            $self->_draw_resolved_event($zone, $start_index, $end_index, $canvas_w);
        }
    }
}

# =============================================================================
# MÉTODOS PRIVADOS DE RENDERIZADO
# =============================================================================

# Decide si vale la pena dibujar esta zona dado el rango visible
sub _should_draw {
    my ($self, $zone, $start, $end) = @_;

    # Zonas activas (DETECTED): siempre mostramos si el nivel de precio es
    # visible en el rango Y, independientemente del índice del pivote
    return 1 if $zone->{state} eq 'DETECTED';

    # Zonas resueltas: mostramos solo si el evento (pivote o barrida) ocurrió
    # dentro o cerca de la ventana visible
    if ($zone->{state} eq 'RESOLVED') {
        my $pivot_in_window = defined $zone->{index} &&
                              $zone->{index} >= $start && $zone->{index} <= $end;
        my $swept_in_window = defined $zone->{swept_at} &&
                              $zone->{swept_at} >= $start && $zone->{swept_at} <= $end;
        return ($pivot_in_window || $swept_in_window) ? 1 : 0;
    }

    return 0;
}

# Dibuja un nivel activo (BSL rojo / SSL verde) con línea horizontal punteada
# que va desde el pivote hasta el borde derecho del canvas.
sub _draw_active_level {
    my ($self, $zone, $start, $end, $canvas_w) = @_;

    my $canvas = $self->{canvas};
    my $y      = $self->_y_to_pixel($zone->{price});
    return unless defined $y;

    # X de inicio: posición del pivote en pantalla (o borde izquierdo si está
    # fuera de la ventana visible hacia la izquierda)
    my $x_pivot = $self->_x_to_pixel($zone->{index});
    $x_pivot = 0 if !defined $x_pivot || $x_pivot < 0;

    my $color = ($zone->{type} eq 'BSL') ? $COLORS{BSL_line} : $COLORS{SSL_line};
    my $label = $zone->{type};   # 'BSL' o 'SSL'

    # --- Línea horizontal punteada desde el pivote hasta el borde derecho ---
    $canvas->createLine(
        $x_pivot, $y, $canvas_w, $y,
        -fill  => $color,
        -width => $self->{line_width},
        -dash  => [4, 3],
        -tags  => ['liquidity'],
    );

    # --- Pequeño triángulo marcador en el origen del pivote ---
    $self->_draw_pivot_triangle($zone, $x_pivot, $y, $color);

    # --- Etiqueta de texto al final derecho de la línea ---
    $canvas->createText(
        $canvas_w - 4, $y - 8,
        -text   => $label,
        -fill   => $color,
        -anchor => 'e',
        -font   => $self->{label_font},
        -tags   => ['liquidity'],
    );
}

# Dibuja el marcador de evento resuelto (GRAB o RUN) en el punto de barrida
sub _draw_resolved_event {
    my ($self, $zone, $start, $end, $canvas_w) = @_;

    my $canvas = $self->{canvas};

    # Línea tenue del nivel original (desde pivote hasta barrida)
    my $y_level  = $self->_y_to_pixel($zone->{price});
    my $x_pivot  = $self->_x_to_pixel($zone->{index});
    my $x_swept  = defined $zone->{swept_at} ? $self->_x_to_pixel($zone->{swept_at}) : undef;

    return unless defined $y_level;
    $x_pivot //= 0;
    $x_swept //= $canvas_w;

    my $base_color = ($zone->{type} eq 'BSL') ? $COLORS{BSL_line} : $COLORS{SSL_line};

    # Línea del nivel original (más tenue: dash largo)
    $canvas->createLine(
        $x_pivot, $y_level, $x_swept, $y_level,
        -fill  => $base_color,
        -width => 1,
        -dash  => [2, 5],
        -tags  => ['liquidity'],
    );

    # Marcador y etiqueta del tipo de evento en el punto de barrida
    return unless defined $x_swept && $x_swept >= 0 && $x_swept <= $canvas_w + 50;

    my $res   = $zone->{resolution} // '';
    my $arrow = ($zone->{type} eq 'BSL') ? 'up' : 'down';
    my $label = "$res $arrow";

    my $marker_color = ($res eq 'GRAB') ? $COLORS{GRAB_marker} : $COLORS{RUN_marker};

    # Círculo marcador en el punto de barrida
    $canvas->createOval(
        $x_swept - 5, $y_level - 5,
        $x_swept + 5, $y_level + 5,
        -fill    => $marker_color,
        -outline => $marker_color,
        -tags    => ['liquidity'],
    );

    # Etiqueta de clasificación
    $canvas->createText(
        $x_swept, $y_level - 12,
        -text   => $label,
        -fill   => $marker_color,
        -anchor => 'c',
        -font   => $self->{label_font},
        -tags   => ['liquidity'],
    );
}

# Dibuja un pequeño triángulo apuntando hacia el nivel desde la vela pivote
sub _draw_pivot_triangle {
    my ($self, $zone, $x, $y, $color) = @_;
    my $canvas = $self->{canvas};
    my $size   = 4;

    if ($zone->{type} eq 'BSL') {
        # Triángulo hacia arriba (el nivel BSL está encima)
        $canvas->createPolygon(
            $x,         $y - $size * 2,
            $x - $size, $y,
            $x + $size, $y,
            -fill    => $color,
            -outline => $color,
            -tags    => ['liquidity'],
        );
    } else {
        # Triángulo hacia abajo (el nivel SSL está debajo)
        $canvas->createPolygon(
            $x,         $y + $size * 2,
            $x - $size, $y,
            $x + $size, $y,
            -fill    => $color,
            -outline => $color,
            -tags    => ['liquidity'],
        );
    }
}

1;