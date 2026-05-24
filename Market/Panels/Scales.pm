package Market::Panels::Scales;
use strict;
use warnings;

# Cada panel tiene su propio eje vertical Y
# Por otro lado, el horizontal X es común entre todos los paneles, el cual sirve para el zoom, el scroll y crosshair cuyas coordinadas horizontales son las mismas entre todos los paneles
# La clase también gestiona la transformación entre índices de datos y coordenadas en pantalla de los ejes vertical y horizontal
# Importante: NUNCA mezclar coordenadas de datos con coordenadas de pantalla.

# Inicializa sistema de escalas
sub new
{
    my ($class, %args) = @_;
    my $self =
    {
        # Informacion del grafico
        width         => $args{width}         || 800,
        height        => $args{height}        || 400,
        visible_bars  => $args{visible_bars}  || 100,
        offset        => $args{offset}        || 0,
        # Coordenadas
        x_min         => $args{x_min}         || 0,
        y_min         => $args{x_min}         || 1,
        y_min         => $args{y_min}         || 0,
        y_max         => $args{y_max}         || 1,
        # Margenes
        margin_left   => $args{margin_left}   || 0,
        margin_right  => $args{margin_right}  || 65,
        margin_top    => $args{margin_top}    || 10,
        margin_bottom => $args{margin_bottom} || 25,
    };
    bless $self, $class;
    return $self;
}

# Convierte índice → coordenada X
sub index_to_x
{
    my ($self, $index) = @_;
    # TODO
}

# Convierte X → índice entero
sub x_to_index
{
    my ($self, $x) = @_;
    # TODO
}

# Convierte X → índice continuo
# Más precisión para interacción
sub x_to_index_float
{
    my ($self, $x) = @_;
    # TODO
}

# Devuelve centro de una vela en X
sub index_to_center_x
{
    my ($self, $index) = @_;
    # TODO
}

# Convierte valor (precio/indicador) → Y
sub value_to_y
{
    my ($self, $value) = @_;
    # TODO
}

# Convierte Y → valor
sub y_to_value
{
    my ($self, $y) = @_;
    # TODO
}

# Dibuja escala vertical (precios/valores)
sub _draw_y_scale
{
    my ($self, $canvas) = @_;
    # TODO
}
1;