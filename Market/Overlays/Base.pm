package Market::Overlays::Base;
use strict;
use warnings;

# Constructor base. Todos los overlays heredarán esto.
sub new {
    my ($class, %args) = @_;

    my $self = {
        canvas => $args{canvas},   # Referencia al widget Tk::Canvas
        scale  => $args{scale},    # Escala actual, si se desea guardar
        engine => $args{engine},   # Referencia al ChartEngine
        colors => $args{colors} || { default => 'black' },
    };

    bless $self, $class;
    return $self;
}

# Método virtual. Si un overlay hijo no lo implementa, el programa falla.
sub render {
    my ($self, @args) = @_;
    die "El método render() debe ser implementado por la clase hija " . ref($self);
}

# Utilidad compartida: convertir índice temporal a píxel X
sub _x_to_pixel {
    my ($self, $index, $scale) = @_;

    $scale ||= $self->{scale};
    return undef unless $scale;

    return $scale->index_to_center_x($index);
}

# Utilidad compartida: convertir precio a píxel Y
sub _y_to_pixel {
    my ($self, $value, $scale) = @_;

    $scale ||= $self->{scale};
    return undef unless $scale;

    return $scale->value_to_y($value);
}

1;