package Market::Panels::PricePanel;

use strict;
use warnings;
use Market::Panels::Scales;

=head1 NOMBRE

Market::Panels::PricePanel - Panel principal para el renderizado del gráfico de precios (velas).

=head1 MÉTODOS

=head2 new

Inicializa el panel de precios y configura el comportamiento elástico del canvas.

Atributos de entrada:
  - canvas : Widget Canvas de Tk asignado para el precio.
  - engine : Referencia al objeto integrador Market::ChartEngine.

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        canvas => $args{canvas},
        engine => $args{engine},
        scale  => undef, # Contenedor interno para la escala vertical del panel
    };

    # Validación de seguridad para desarrollo concurrente
    unless ($self->{canvas}) {
        die "[ERROR PricePanel]: Objeto Canvas de Tk no recibido en el constructor.\n";
    }

    # El panel se adueña de su color de fondo (TradingView Style)
    $self->{canvas}->configure(-bg => '#131722');

    # Resolución layout visual elástico
    $self->{canvas}->pack(
        -side   => 'top',
        -fill   => 'both',
        -expand => 1
    );
    
    return bless $self, $class;
}

=head2 get_y_range

Calcula el precio mínimo (low) y máximo (high) de las velas visibles con blindaje contra datos corruptos.
Controla el Modo Manual (Drag Y) y el Modo Automático.

Retorna:
  - Lista con dos flotantes: ($min_y, $max_y)
=cut

sub get_y_range {
    my ($self) = @_;

    # 1. Modo Manual (ESENCIAL PARA EL DRAG EN EL EJE Y)
    if (defined $self->{engine}->{auto_scale} && $self->{engine}->{auto_scale} == 0) {
        return ($self->{engine}->{manual_y_min}, $self->{engine}->{manual_y_max});
    }

    # 2. Modo Automático
    my ($start, $end) = $self->{engine}->compute_window();
    my $candles = $self->{engine}->{market_data}->get_data();

    if (!defined $candles || scalar @$candles == 0) {
        return (0, 100);
    }

    my $min_y = undef;
    my $max_y = undef;

    for my $i ($start .. $end) {
        my $candle = $candles->[$i];
        
        # BLINDAJE: Ignorar velas vacías, nulas o saltos de línea del CSV
        next unless defined $candle && defined $candle->{low} && $candle->{low} =~ /^[\d\.]+$/;
        
        $min_y = $candle->{low}  if !defined $min_y || $candle->{low}  < $min_y;
        $max_y = $candle->{high} if !defined $max_y || $candle->{high} > $max_y;
    }

    # Fallback por si toda la ventana estaba vacía
    return (0, 100) if !defined $min_y;

    if ($max_y == $min_y) {
        $max_y += 1.0;
        $min_y -= 1.0;
    }

    # RESOLUCIÓN DE CUELLO DE BOTELLA: Añadir holgura (padding) del 5%
    my $padding = ($max_y - $min_y) * 0.05;
    $max_y += $padding;
    $min_y -= $padding;

    # 3. Sincronización (Prepara los valores por si el usuario decide hacer Drag manual)
    $self->{engine}->{manual_y_min} = $min_y;
    $self->{engine}->{manual_y_max} = $max_y;

    return ($min_y, $max_y);
}

=head2 set_scale

Instancia y actualiza el objeto Scales adaptándose al tamaño geométrico
actual del widget Canvas de Tk. Permite una respuesta elástica al redimensionar.
=cut

sub set_scale {
    my ($self) = @_;

    my ($min_y, $max_y) = $self->get_y_range();
    my $width  = $self->{canvas}->Width();
    my $height = $self->{canvas}->Height();

    my ($start_index, $end_index) = $self->{engine}->compute_window();

    # EL SECRETO DEL ANCLAJE TRADINGVIEW:
    # Calculamos el inicio teórico (incluso si es negativo) para siempre anclar la última vela al margen derecho.
    my $visible_bars = $self->{engine}->{visible_bars} || 100;
    my $scale_offset = $end_index - $visible_bars + 1;

    $self->{scale} = Market::Panels::Scales->new(
        width        => $width,
        height       => $height,
        visible_bars => $visible_bars,
        offset       => $scale_offset, 
        y_min        => $min_y,
        y_max        => $max_y,
    );

    return $self->{scale};
}

=head2 render

Dibuja las velas japonesas (mechas y cuerpos) en el canvas superior utilizando
el data_slice recibido de la capa lógica. 
=cut

sub render {
    my ($self, $data_slice) = @_;

    return unless $data_slice && scalar(@$data_slice) > 0;

    # 1. Forzar la actualización matemática de las escalas según la geometría actual de Tk
    my $scale = $self->set_scale();
    my $canvas_height = $self->{canvas}->Height();

    # INTEGRACIÓN V2: Ordenarle a las escalas que dibujen su propia cuadrícula y eje Y de precios
    $scale->_draw_y_scale($self->{canvas});

    # 2. Obtener el rango dinámico vertical de este conjunto
    my ($precio_min, $precio_max) = $self->get_y_range();
    my $rango_y = $precio_max - $precio_min;
    $rango_y = 1.0 if $rango_y == 0; # Prevenir división por cero

    # 3. Calcular un ancho dinámico proporcional para las velas financieras
    my $canvas_width = $self->{canvas}->Width();
    my $visible_bars = $self->{engine}->{visible_bars} || 100;
    
    # Sincronizamos el ancho de dibujado con el espacio real que se usa (restando el margen derecho de 65px)
    my $plot_width = $canvas_width - 65; 
    my $candle_width = ($plot_width / $visible_bars) * 0.8; # 80% ocupado por la vela, 20% espacio vacío
    $candle_width = 1 if $candle_width < 1;

    # 4. Recuperar los índices de datos reales
    my ($start_index, $end_index) = $self->{engine}->compute_window();

    # 5. Iterar sobre las velas usando SOLO el índice incremental ($i)
    my $i = $start_index;
    for my $candle (@$data_slice) {
        last if $i > $end_index; 

        # A. X (Precisión perfecta para el Zoom)
        my $x_center = $scale->index_to_center_x($i);

        # B. Y (Usando la función oficial de Escalas)
        my $y_open  = $scale->value_to_y($candle->{open});
        my $y_high  = $scale->value_to_y($candle->{high});
        my $y_low   = $scale->value_to_y($candle->{low});
        my $y_close = $scale->value_to_y($candle->{close});

        # C. Determinar el color financiero
        my $color = ($candle->{close} >= $candle->{open}) ? '#26a69a' : '#ef5350';

        # D. DIBUJAR LA MECHA
        $self->{canvas}->createLine(
            $x_center, $y_high,
            $x_center, $y_low,
            -fill  => $color,
            -width => 1
        );

        # E. DIBUJAR EL CUERPO
        my $x1 = $x_center - ($candle_width / 2);
        my $x2 = $x_center + ($candle_width / 2);
        
        my $y_top = $y_open < $y_close ? $y_open : $y_close;
        my $y_bot = $y_open > $y_close ? $y_open : $y_close;

        $self->{canvas}->createRectangle(
            $x1, $y_top,
            $x2, $y_bot,
            -fill    => $color,
            -outline => $color
        );

        $i++;
    }
    
    # 6. Llamar al dibujo del eje temporal
    $self->draw_time_axis();

    # 7. Inicializar los objetos de la cruz
    $self->_init_crosshair_objects();

    # 8. Dibujar el último precio visible
    $self->render_last_visible_price($data_slice, $scale);
}

=head2 _init_crosshair_objects
=cut

sub _init_crosshair_objects {
    my ($self) = @_;

    my $crosshair_color = '#555555'; 
    my $label_bg_color  = '#659c39'; 
    my $label_txt_color = '#1e15a8'; 

    # 1. Las líneas
    $self->{crosshair_v_id} = $self->{canvas}->createLine(
        0, 0, 0, 0, -fill => $crosshair_color, -dash => '.', -tags => ['crosshair_internal']
    );
    $self->{crosshair_h_id} = $self->{canvas}->createLine(
        0, 0, 0, 0, -fill => $crosshair_color, -dash => '.', -tags => ['crosshair_internal']
    );

    # 2. Etiqueta X (Tiempo) - Abajo
    $self->{crosshair_x_bg} = $self->{canvas}->createRectangle(
        0, 0, 0, 0, -fill => $label_bg_color, -outline => $label_txt_color, -state => 'hidden', -tags => ['crosshair_internal']
    );
    $self->{crosshair_x_txt} = $self->{canvas}->createText(
        0, 0, -fill => $label_txt_color, -font => ['Helvetica', 16, 'bold'], -state => 'hidden', -tags => ['crosshair_internal']
    );

    # 3. Etiqueta Y (Precio/Volatilidad) - Derecha
    $self->{crosshair_y_bg} = $self->{canvas}->createRectangle(
        0, 0, 0, 0, -fill => $label_bg_color, -outline => $label_txt_color, -state => 'hidden', -tags => ['crosshair_internal']
    );
    $self->{crosshair_y_txt} = $self->{canvas}->createText(
        0, 0, -fill => $label_txt_color, -font => ['Helvetica', 16, 'bold'], -state => 'hidden', -tags => ['crosshair_internal']
    );

    return;
}

=head2 draw_crosshair
=cut

sub draw_crosshair {
    my ($self, $x, $y, $is_active) = @_;

    my $canvas_height = $self->{canvas}->Height();
    my $canvas_width  = $self->{canvas}->Width();
    my $scale         = $self->{scale};

    return if $canvas_width <= 1 || $canvas_height <= 1 || !defined $scale;

    # --- 1. MOVER LÍNEA VERTICAL Y ETIQUETA DE TIEMPO (Eje X) ---
    if (defined $self->{crosshair_v_id}) {
        $self->{canvas}->coords($self->{crosshair_v_id}, $x, 0, $x, $canvas_height);
        
        my $indice_global = $scale->x_to_index($x);
        my $velas = $self->{engine}->{market_data}->get_data();

        if (defined $indice_global && $indice_global >= 0 && $indice_global < scalar(@$velas)) {
            my $ts = $velas->[$indice_global]->{time} || "";
            
            my $etiqueta_tiempo = $ts; 
            if (my ($anio, $mes, $dia, $hora) = $ts =~ /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}:\d{2})/) {
                my @nombres_meses = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
                my $nombre_mes = $nombres_meses[$mes - 1]; 
                $etiqueta_tiempo = "$dia $nombre_mes $anio $hora";
            }

            my $y_franja = $canvas_height - 12;
            $self->{canvas}->coords($self->{crosshair_x_txt}, $x, $y_franja);
            $self->{canvas}->itemconfigure($self->{crosshair_x_txt}, -text => $etiqueta_tiempo, -state => 'normal');

            my @bbox = $self->{canvas}->bbox($self->{crosshair_x_txt});
            if (@bbox) {
                $self->{canvas}->coords($self->{crosshair_x_bg}, $bbox[0]-6, $bbox[1]-2, $bbox[2]+6, $bbox[3]+2);
                $self->{canvas}->itemconfigure($self->{crosshair_x_bg}, -state => 'normal');
                
                $self->{canvas}->raise($self->{crosshair_x_bg});
                $self->{canvas}->raise($self->{crosshair_x_txt});
            }
        } else {
            $self->{canvas}->itemconfigure($self->{crosshair_x_bg}, -state => 'hidden');
            $self->{canvas}->itemconfigure($self->{crosshair_x_txt}, -state => 'hidden');
        }
    }

    # --- 2. MOVER LÍNEA HORIZONTAL Y ETIQUETA DE PRECIO (Eje Y) ---
    if (defined $self->{crosshair_h_id}) {
        if ($is_active) {
            $self->{canvas}->coords($self->{crosshair_h_id}, 0, $y, $canvas_width, $y);
            
            my $valor_y = $scale->y_to_value($y);
            my $valor_fmt = sprintf("%.2f", $valor_y);

            my $x_precio = $canvas_width - 32; 
            
            $self->{canvas}->coords($self->{crosshair_y_txt}, $x_precio, $y);
            $self->{canvas}->itemconfigure($self->{crosshair_y_txt}, -text => $valor_fmt, -state => 'normal');

            my @bbox_y = $self->{canvas}->bbox($self->{crosshair_y_txt});
            if (@bbox_y) {
                $self->{canvas}->coords($self->{crosshair_y_bg}, $bbox_y[0]-6, $bbox_y[1]-2, $bbox_y[2]+6, $bbox_y[3]+2);
                $self->{canvas}->itemconfigure($self->{crosshair_y_bg}, -state => 'normal');
                
                $self->{canvas}->raise($self->{crosshair_y_bg});
                $self->{canvas}->raise($self->{crosshair_y_txt});
            }
        } else {
            $self->{canvas}->coords($self->{crosshair_h_id}, 0, 0, 0, 0);
            $self->{canvas}->itemconfigure($self->{crosshair_y_bg}, -state => 'hidden');
            $self->{canvas}->itemconfigure($self->{crosshair_y_txt}, -state => 'hidden');
        }
    }
    return;
}

=head2 draw_time_axis
=cut

sub draw_time_axis {
    my ($self) = @_;

    my $etiquetas = $self->{engine}->compute_intraday_labels();
    return unless $etiquetas && scalar(@$etiquetas) > 0;

    $self->{canvas}->delete('time_axis_labels');

    my $scale = $self->{scale};
    my $canvas_height = $self->{canvas}->Height();
    my $y_pos = $canvas_height - 12; 
    
    my ($start_index, $end_index) = $self->{engine}->compute_window();

    for my $etiqueta (@$etiquetas) {
        my $pos_relativa = $etiqueta->{indice_relativo} // 0;
        
        my $absolute_index = $start_index + $pos_relativa;
        my $x = $scale->index_to_center_x($absolute_index);
        
        my $texto = $etiqueta->{timestamp};
        my ($hora) = $texto =~ /T(\d{2}:\d{2})/;
        $hora //= $texto; 

        my $color_texto = '#787b86';
        my $font_weight = 'normal';
        
        if ($etiqueta->{es_cambio_dia}) {
            $color_texto = '#d1d4dc';
            $font_weight = 'bold';
            ($hora) = $texto =~ /^(\d{4}-\d{2}-\d{2})/; 
        }
        
        $self->{canvas}->createText(
            $x, $y_pos,
            -text => $hora,
            -fill => $color_texto,
            -font => ['Helvetica', 9, $font_weight],
            -tags => ['time_axis_labels']
        );
    }
}

=head2 render_last_visible_price
=cut

sub render_last_visible_price {
    my ($self, $data_slice, $scale) = @_;

    my $last_candle = $data_slice->[-1];
    return unless defined $last_candle;

    my $last_close = $last_candle->{close};
    my $last_open  = $last_candle->{open};

    my $y = $scale->value_to_y($last_close);
    my $canvas_width = $self->{canvas}->Width();

    my $color = ($last_close >= $last_open) ? '#26a69a' : '#ef5350';

    # 1. Línea horizontal punteada
    $self->{canvas}->createLine(
        0, $y,
        $canvas_width, $y,
        -fill => $color,
        -dash => '.',
        -tags => ['last_price_indicator']
    );

    # 2. Etiqueta de precio a la derecha
    my $x_pos = $canvas_width - 32;
    my $valor_fmt = sprintf("%.2f", $last_close);

    my $txt_id = $self->{canvas}->createText(
        $x_pos, $y,
        -text => $valor_fmt,
        -fill => '#ffffff',
        -font => ['Helvetica', 10, 'bold'],
        -tags => ['last_price_indicator']
    );

    my @bbox = $self->{canvas}->bbox($txt_id);
    if (@bbox) {
        my $bg_id = $self->{canvas}->createRectangle(
            $bbox[0]-6, $bbox[1]-2, $bbox[2]+6, $bbox[3]+2,
            -fill    => $color,
            -outline => $color,
            -tags    => ['last_price_indicator']
        );
        $self->{canvas}->lower($bg_id, $txt_id);
    }
}

1;