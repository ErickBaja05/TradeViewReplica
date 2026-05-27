package Market::Panels::PricePanel;

use strict;
use warnings;
use Market::Panels::Scales;

=head1 NOMBRE

Market::Panels::PricePanel - Panel principal para el renderizado del gráfico de precios (velas).

=head1 MÉTODOSS

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

Calcula el precio mínimo (low) y máximo (high) de las velas visibles en la ventana actual.
Añade un margen de holgura vertical para optimizar la visualización de datos en el Canvas.

Retorna:
  - Lista con dos flotantes: ($min_y, $max_y)

=cut

sub get_y_range {
    my ($self) = @_;

    # 1. Obtener los límites del índice de datos visibles calculado por Erick en el motor central
    my ($start, $end) = $self->{engine}->compute_window();
    
    # 2. Acceder de forma segura a las velas a través del módulo MarketData de Josué
    my $candles = $self->{engine}->{market_data}->get_data();

    # Si no hay datos cargados aún en el sistema, devolvemos un rango por defecto estándar
    if (!defined $candles || scalar @$candles == 0) {
        return (0, 100);
    }

    # Inicializar los extremos con el primer elemento del rango visible actual
    my $min_y = $candles->[$start]->{low};
    my $max_y = $candles->[$start]->{high};

    # 3. Encontrar el valor máximo de los 'high' y el valor mínimo de los 'low' en la ventana actual
    for my $i ($start .. $end) {
        my $candle = $candles->[$i];
        if (defined $candle) {
            $min_y = $candle->{low}  if $candle->{low}  < $min_y;
            $max_y = $candle->{high} if $candle->{high} > $max_y;
        }
    }

    # Evitar una división por cero inesperada si el precio se mantiene completamente idéntico
    if ($max_y == $min_y) {
        $max_y += 1.0;
        $min_y -= 1.0;
    }

    # 4. RESOLUCIÓN DE CUELLO DE BOTELLA: Añadir holgura (padding) del 5%
    # para que las velas no choquen agresivamente con los límites físicos del Canvas
    my $padding = ($max_y - $min_y) * 0.05;
    $max_y += $padding;
    $min_y -= $padding;

    return ($min_y, $max_y);
}

=head2 set_scale

Instancia y actualiza el objeto Scales de Ricardo adaptándose al tamaño geométrico
actual del widget Canvas de Tk. Permite una respuesta elástica al redimensionar.

Retorna:
  - Instancia del objeto Market::Panels::Scales actualizado.

=cut

sub set_scale {
    my ($self) = @_;

    my ($min_y, $max_y) = $self->get_y_range();
    my $width  = $self->{canvas}->Width();
    my $height = $self->{canvas}->Height();

    my ($start_index, $end_index) = $self->{engine}->compute_window();

    # EL SECRETO DEL ANCLAJE TRADINGVIEW:
    # Calculamos el inicio teórico (incluso si es negativo) para que Ricardo 
    # siempre ancle la última vela ($end_index) al margen derecho.
    my $visible_bars = $self->{engine}->{visible_bars} || 100;
    my $scale_offset = $end_index - $visible_bars + 1;

    $self->{scale} = Market::Panels::Scales->new(
        width        => $width,
        height       => $height,
        visible_bars => $visible_bars,
        offset       => $scale_offset, # Le pasamos el offset teórico, no el start_index
        y_min        => $min_y,
        y_max        => $max_y,
    );

    return $self->{scale};
}

=head2 render

Dibuja las velas japonesas (mechas y cuerpos) en el canvas superior utilizando
el data_slice recibido de la capa lógica. Aplica el parche matemático para el eje Y.

Atributos de entrada:
  - $data_slice : Referencia a un arreglo de hashes con los datos OHLCV visibles.

=cut

sub render {
    my ($self, $data_slice) = @_;

    return unless $data_slice && scalar(@$data_slice) > 0;

    # 1. Forzar la actualización matemática de las escalas según la geometría actual de Tk
    my $scale = $self->set_scale();
    my $canvas_height = $self->{canvas}->Height();

    # 2. Obtener el rango dinámico vertical de este conjunto para aplicar la fórmula temporal
    my ($precio_min, $precio_max) = $self->get_y_range();
    my $rango_y = $precio_max - $precio_min;
    $rango_y = 1.0 if $rango_y == 0; # Prevenir división por cero

    # 3. Calcular un ancho dinámico proporcional para las velas financieras
    my $canvas_width = $self->{canvas}->Width();
    my $visible_bars = $self->{engine}->{visible_bars} || 100;
    my $candle_width = ($canvas_width / $visible_bars) * 0.7; # 70% ocupado por la vela, 30% espacio
    $candle_width = 1 if $candle_width < 1;

    # Sincronizamos el ancho de dibujado con el espacio real que usa Ricardo (restando su margen derecho de 65px)
    my $plot_width = $canvas_width - 65; 
    my $candle_width = ($plot_width / $visible_bars) * 0.8; # 80% ocupado por la vela, 20% espacio vacío
    $candle_width = 1 if $candle_width < 1;

    # 4. Recuperar los índices de datos reales mapeados por Erick
    my ($start_index, $end_index) = $self->{engine}->compute_window();

    # 5. Iterar sobre las velas usando SOLO el índice incremental ($i)
    my $i = $start_index;
    for my $candle (@$data_slice) {
        last if $i > $end_index; 

        # A. X con Ricardo (Precisión perfecta para el Zoom)
        my $x_center = $scale->index_to_center_x($i);

        # B. Y con Ricardo (Adiós parche matemático, usamos su función oficial)
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
    # 1. Llamar al dibujo del eje temporal
    $self->draw_time_axis();

    # 2. Inicializar los objetos de la cruz
    $self->_init_crosshair_objects();

    # 3. Dibujar el último precio visible
    $self->render_last_visible_price($data_slice, $scale);
}

=head2 _init_crosshair_objects

Inicializa los objetos gráficos del crosshair (líneas, cajas de fondo y textos) 
dentro del canvas y almacena sus IDs para optimizar el rendimiento.
=cut

sub _init_crosshair_objects {
    my ($self) = @_;

    # Aquí controlas los colores:
    my $crosshair_color = '#555555'; # Color de la línea de la cruz
    
    # --- COLORES DE LAS CAJITAS ---
    my $label_bg_color  = '#659c39'; # <-- CAMBIA ESTE para el fondo (TradingView usa azul/gris muy oscuro)
    my $label_txt_color = '#1e15a8'; # <-- CAMBIA ESTE para el texto (Blanco)

    # 1. Las líneas (Ya las tenía Dome)
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

Actualiza las coordenadas de la cruz y de las etiquetas flotantes (precio y tiempo).
=cut

=head2 draw_crosshair

Actualiza las coordenadas de la cruz y de las etiquetas flotantes (precio y tiempo).
=cut

sub draw_crosshair {
    my ($self, $x, $y, $is_active) = @_;

    my $canvas_height = $self->{canvas}->Height();
    my $canvas_width  = $self->{canvas}->Width();
    my $scale         = $self->{scale};

    return if $canvas_width <= 1 || $canvas_height <= 1 || !defined $scale;

    # --- 1. MOVER LÍNEA VERTICAL Y ETIQUETA DE TIEMPO (Eje X) ---
    if (defined $self->{crosshair_v_id}) {
        # A. Mover la línea vertical
        $self->{canvas}->coords($self->{crosshair_v_id}, $x, 0, $x, $canvas_height);
        
        # B. Lógica del Tiempo (CORRECCIÓN: Ricardo ya devuelve el índice absoluto)
        my $indice_global = $scale->x_to_index($x);
        my $velas = $self->{engine}->{market_data}->get_data();

        # Verificamos que el índice exista dentro del arreglo de datos
        if (defined $indice_global && $indice_global >= 0 && $indice_global < scalar(@$velas)) {
            my $ts = $velas->[$indice_global]->{time} || "";
            
            # Formato de tiempo (TradingView Style)
            my $etiqueta_tiempo = $ts; 
            if (my ($anio, $mes, $dia, $hora) = $ts =~ /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}:\d{2})/) {
                my @nombres_meses = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
                my $nombre_mes = $nombres_meses[$mes - 1]; 
                $etiqueta_tiempo = "$dia $nombre_mes $anio $hora";
            }

            # Posicionamos el texto en el margen inferior (franja gris de Ricardo)
            my $y_franja = $canvas_height - 12;
            $self->{canvas}->coords($self->{crosshair_x_txt}, $x, $y_franja);
            $self->{canvas}->itemconfigure($self->{crosshair_x_txt}, -text => $etiqueta_tiempo, -state => 'normal');

            # Creamos el fondo dinámico envolviendo el texto
            my @bbox = $self->{canvas}->bbox($self->{crosshair_x_txt});
            if (@bbox) {
                $self->{canvas}->coords($self->{crosshair_x_bg}, $bbox[0]-6, $bbox[1]-2, $bbox[2]+6, $bbox[3]+2);
                $self->{canvas}->itemconfigure($self->{crosshair_x_bg}, -state => 'normal');
                
                # 'raise' pone los elementos por encima de las velas
                $self->{canvas}->raise($self->{crosshair_x_bg});
                $self->{canvas}->raise($self->{crosshair_x_txt});
            }
        } else {
            # Si el mouse sale de la zona con velas, escondemos la etiqueta de tiempo
            $self->{canvas}->itemconfigure($self->{crosshair_x_bg}, -state => 'hidden');
            $self->{canvas}->itemconfigure($self->{crosshair_x_txt}, -state => 'hidden');
        }
    }

    # --- 2. MOVER LÍNEA HORIZONTAL Y ETIQUETA DE PRECIO (Eje Y) ---
    if (defined $self->{crosshair_h_id}) {
        if ($is_active) {
            # A. Mover la línea horizontal
            $self->{canvas}->coords($self->{crosshair_h_id}, 0, $y, $canvas_width, $y);
            
            # B. Lógica del Precio/Valor usando las escalas de Ricardo
            my $valor_y = $scale->y_to_value($y);
            my $valor_fmt = sprintf("%.2f", $valor_y);

            # Posicionamos el texto a la derecha (Margen derecho de Ricardo = 65px)
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
            # Si el ratón sale del panel, escondemos la línea y sus etiquetas
            $self->{canvas}->coords($self->{crosshair_h_id}, 0, 0, 0, 0);
            $self->{canvas}->itemconfigure($self->{crosshair_y_bg}, -state => 'hidden');
            $self->{canvas}->itemconfigure($self->{crosshair_y_txt}, -state => 'hidden');
        }
    }
    return;
}

=head2 draw_time_axis

Dibuja las etiquetas de tiempo (horas/minutos) en el margen inferior del lienzo.
=cut

sub draw_time_axis {
    my ($self) = @_;

    my $etiquetas = $self->{engine}->compute_intraday_labels();
    return unless $etiquetas && scalar(@$etiquetas) > 0;

    $self->{canvas}->delete('time_axis_labels');

    my $scale = $self->{scale};
    my $canvas_height = $self->{canvas}->Height();
    my $y_pos = $canvas_height - 12; 
    
    # Recuperamos el inicio real de la pantalla
    my ($start_index, $end_index) = $self->{engine}->compute_window();

    for my $etiqueta (@$etiquetas) {
        # Erick envía la posición relativa (0, 1, 2...)
        my $pos_relativa = $etiqueta->{indice_relativo} // 0;
        
        # LA SOLUCIÓN: Calculamos el índice global absoluto para Ricardo
        my $absolute_index = $start_index + $pos_relativa;
        my $x = $scale->index_to_center_x($absolute_index);
        
        my $texto = $etiqueta->{timestamp};
        my ($hora) = $texto =~ /T(\d{2}:\d{2})/;
        $hora //= $texto; # Fallback

        my $color_texto = '#787b86';
        my $font_weight = 'normal';
        
        if ($etiqueta->{es_cambio_dia}) {
            $color_texto = '#d1d4dc';
            $font_weight = 'bold';
            # Si es cambio de día, mostramos la fecha en lugar de solo la hora
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

Dibuja una línea horizontal punteada y una caja resaltada a la derecha
con el precio de cierre de la última vela visible en pantalla.
=cut

sub render_last_visible_price {
    my ($self, $data_slice, $scale) = @_;

    # Obtenemos la última vela del arreglo que acabamos de iterar
    my $last_candle = $data_slice->[-1];
    return unless defined $last_candle;

    my $last_close = $last_candle->{close};
    my $last_open  = $last_candle->{open};

    # Calculamos la altura exacta usando la nueva función de Ricardo
    my $y = $scale->value_to_y($last_close);
    my $canvas_width = $self->{canvas}->Width();

    # Determinamos el color: Verde si cerró arriba o igual, Rojo si bajó
    my $color = ($last_close >= $last_open) ? '#26a69a' : '#ef5350';

    # 1. Línea horizontal punteada cruzando todo el gráfico
    $self->{canvas}->createLine(
        0, $y,
        $canvas_width, $y,
        -fill => $color,
        -dash => '.',
        -tags => ['last_price_indicator']
    );

    # 2. Etiqueta de precio a la derecha ($canvas_width - 32)
    my $x_pos = $canvas_width - 32;
    my $valor_fmt = sprintf("%.2f", $last_close);

    # Creamos primero el texto para conocer su tamaño
    my $txt_id = $self->{canvas}->createText(
        $x_pos, $y,
        -text => $valor_fmt,
        -fill => '#ffffff',
        -font => ['Helvetica', 10, 'bold'],
        -tags => ['last_price_indicator']
    );

    # Creamos la caja de fondo dinámicamente según el tamaño del texto
    my @bbox = $self->{canvas}->bbox($txt_id);
    if (@bbox) {
        my $bg_id = $self->{canvas}->createRectangle(
            $bbox[0]-6, $bbox[1]-2, $bbox[2]+6, $bbox[3]+2,
            -fill    => $color,
            -outline => $color,
            -tags    => ['last_price_indicator']
        );
        # Bajamos el fondo para que no tape los números
        $self->{canvas}->lower($bg_id, $txt_id);
    }
}

1;