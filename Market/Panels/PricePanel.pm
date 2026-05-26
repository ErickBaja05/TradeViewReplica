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
        x_min        => 0,
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
    for my $candle (@$data_slice) {
        last if $i > $end_index; # Control de seguridad para desbordamientos

        # A. Obtener la coordenada X central llamando a la función de Ricardo
        my $x_center = $scale->index_to_center_x($i);

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
    }
}

1;