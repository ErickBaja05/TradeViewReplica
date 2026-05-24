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

    # RESOLUCIÓN CUELLO DE BOTELLA - LAYOUT VISUAL ELÁSTICO
    # El panel de precios ocupa la mayor parte de la pantalla (área principal).
    # - fill => 'both' : Permite que el canvas se estire horizontal y verticalmente.
    # - expand => 1    : Le asigna prioridad de crecimiento al redimensionar la ventana.
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

1;