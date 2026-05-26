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

    # 1. Calcular el rango dinámico de precios actual en base a las velas visibles
    my ($min_y, $max_y) = $self->get_y_range();

    # 2. Obtener dimensiones dinámicas reales en píxeles mediante lectura directa de Tk
    my $width  = $self->{canvas}->Width();
    my $height = $self->{canvas}->Height();

    # 3. Construir el objeto matemático de escalas vinculando las propiedades de Ricardo
    $self->{scale} = Market::Panels::Scales->new(
        width        => $width,
        height       => $height,
        visible_bars => $self->{engine}->{visible_bars},
        offset       => $self->{engine}->{offset},
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

    # 4. Recuperar los índices de datos reales mapeados por Erick para este bloque visible
    my ($start_index, $end_index) = $self->{engine}->compute_window();

    # 5. Iterar sobre las velas usando un índice incremental
    my $i = $start_index;
    my $posicion_relativa = 0; # Para depuración y trazabilidad de datos
    for my $candle (@$data_slice) {
        last if $i > $end_index; # Control de seguridad para desbordamientos

        my $offset_actual = $self->{engine}->{offset} || 0;
        my $x_center = $scale->index_to_center_x($posicion_relativa + $offset_actual);

        # B. Aplicar el parche matemático temporal para mapear los precios OHLC al eje Y de píxeles
        my $y_open  = $canvas_height - (($candle->{open}  - $precio_min) / $rango_y) * $canvas_height;
        my $y_high  = $canvas_height - (($candle->{high}  - $precio_min) / $rango_y) * $canvas_height;
        my $y_low   = $canvas_height - (($candle->{low}   - $precio_min) / $rango_y) * $canvas_height;
        my $y_close = $canvas_height - (($candle->{close}  - $precio_min) / $rango_y) * $canvas_height;

        # C. Determinar el color financiero de la vela según su comportamiento de cierre
        my $color = '#ef5350'; # Rojo bajista por defecto (TradingView Style)
        if ($candle->{close} >= $candle->{open}) {
            $color = '#26a69a'; # Verde alcista (TradingView Style)
        }

        # D. DIBUJAR LA MECHA (Línea vertical continua desde el High hasta el Low)
        $self->{canvas}->createLine(
            $x_center, $y_high,
            $x_center, $y_low,
            -fill  => $color,
            -width => 1
        );

        # E. DIBUJAR EL CUERPO (Rectángulo delimitado entre Open y Close)
        my $x1 = $x_center - ($candle_width / 2);
        my $x2 = $x_center + ($candle_width / 2);
        
        # Asegurar orden correcto de coordenadas en Tk para evitar glitches visuales
        my $y_top = $y_open < $y_close ? $y_open : $y_close;
        my $y_bot = $y_open > $y_close ? $y_open : $y_close;

        $self->{canvas}->createRectangle(
            $x1, $y_top,
            $x2, $y_bot,
            -fill    => $color,
            -outline => $color
        );

        $i++;
        $posicion_relativa++;
    }
    # 1. Llamar al dibujo del eje temporal
    $self->draw_time_axis();

    # 2. Inicializar los objetos de la cruz
    $self->_init_crosshair_objects();
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
        
       # B. Lógica del Tiempo (Erick's logic)
        my ($start_index, $end_index) = $self->{engine}->compute_window();
        my $indice_local = $scale->x_to_index($x);
        
        # Sumamos el inicio global al índice local de la pantalla
        my $indice_global = $start_index + $indice_local;
        my $velas = $self->{engine}->{market_data}->get_data();

        if ($indice_global >= 0 && $indice_global < scalar(@$velas)) {
            my $ts = $velas->[$indice_global]->{time} || "";
            
            # --- NUEVO FORMATO DE TIEMPO (TRADINGVIEW STYLE) ---
            my $etiqueta_tiempo = $ts; # Fallback por si la fecha viene rara
            
            # Extraemos las partes de la fecha (Ej: 2026-05-26T12:00)
            if (my ($anio, $mes, $dia, $hora) = $ts =~ /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}:\d{2})/) {
                # Mapeamos el número de mes a su abreviatura en inglés
                my @nombres_meses = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
                my $nombre_mes = $nombres_meses[$mes - 1]; # Restamos 1 porque los arreglos empiezan en 0
                
                # Armamos la cadena final (Ej: "26 May 2026 12:00")
                # Si quieres quitar el año, solo borra el "$anio " de la línea de abajo
                $etiqueta_tiempo = "$dia $nombre_mes $anio $hora";
            }
            # ---------------------------------------------------

            # Posicionamos el texto en el margen inferior (franja gris)
            my $y_franja = $canvas_height - 12;
            $self->{canvas}->coords($self->{crosshair_x_txt}, $x, $y_franja);
            
            # Inyectamos nuestra nueva etiqueta de tiempo formateada
            $self->{canvas}->itemconfigure($self->{crosshair_x_txt}, -text => $etiqueta_tiempo, -state => 'normal');

            # Creamos el fondo negro envolviendo el texto (bbox = Bounding Box)
            my @bbox = $self->{canvas}->bbox($self->{crosshair_x_txt});
            if (@bbox) {
                # [x1-padding, y1-padding, x2+padding, y2+padding]
                $self->{canvas}->coords($self->{crosshair_x_bg}, $bbox[0]-6, $bbox[1]-2, $bbox[2]+6, $bbox[3]+2);
                $self->{canvas}->itemconfigure($self->{crosshair_x_bg}, -state => 'normal');
                
                # 'raise' pone los elementos por encima de las velas para que no se tapen
                $self->{canvas}->raise($self->{crosshair_x_bg});
                $self->{canvas}->raise($self->{crosshair_x_txt});
            }
        }
    }

    # --- 2. MOVER LÍNEA HORIZONTAL Y ETIQUETA DE PRECIO (Eje Y) ---
    if (defined $self->{crosshair_h_id}) {
        if ($is_active) {
            # A. Mover la línea horizontal
            $self->{canvas}->coords($self->{crosshair_h_id}, 0, $y, $canvas_width, $y);
            
            # B. Lógica del Precio/Valor usando las escalas de Ricardo
            my $valor_y = $scale->y_to_value($y);
            my $valor_fmt = sprintf("%.2f", $valor_y); # Forzamos 2 decimales

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

    # Obtenemos los timestamps gracias a la función de Erick en el motor
    my $timestamps = $self->{engine}->get_all_timestamps();
    return unless $timestamps && scalar(@$timestamps) > 0;

    my $scale = $self->{scale};
    my $canvas_height = $self->{canvas}->Height();
    
    # Dibujamos el texto en el margen inferior (los 25 píxeles que dejó Ricardo)
    my $y_pos = $canvas_height - 10; 

    my $posicion_relativa = 0;
    my $offset_actual = $self->{engine}->{offset} || 0;

    for my $ts (@$timestamps) {
        # Mostrar solo 1 de cada 10 etiquetas para que los textos no se amontonen
        if ($posicion_relativa % 10 == 0) {
            my $x = $scale->index_to_center_x($posicion_relativa + $offset_actual);
            
            # Extraer solo la hora (HH:MM) del formato ISO usando una expresión regular
            my ($hora) = $ts =~ /T(\d{2}:\d{2})/;
            $hora //= $ts; # Fallback por si el formato es distinto
            
            $self->{canvas}->createText(
                $x, $y_pos,
                -text => $hora,
                -fill => '#c43f3f', # Color gris claro para textos secundarios
                -font => ['Helvetica', 21]
            );
        }
        $posicion_relativa++;
    }
}

1;