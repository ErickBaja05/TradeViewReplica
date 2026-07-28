package Market::Overlays::Base;
use strict;
use warnings;

# Constructor base. Todos los overlays heredarán esto.
sub new {
    my ($class, %args) = @_;
    my $self = {
        canvas => $args{canvas}, # Referencia al widget Tk::Canvas
        scales => $args{scales}, # Referencia a Market::Panels::Scales
        colors => $args{colors} || { default => 'black' },
    };
    bless $self, $class;
    return $self;
}

# Método virtual puro. Si un overlay hijo no lo implementa, el programa falla.
sub render {
    my ($self, $data) = @_;
    die "El método render() debe ser implementado por la clase hija " . ref($self);
}

# Utilidad compartida: Convertir índice temporal a píxel X
sub _x_to_pixel {
    my ($self, $index) = @_;
    return $self->{scales}->index_to_x($index);
}

# Utilidad compartida: Convertir precio a píxel Y
sub _y_to_pixel {
    my ($self, $value) = @_;
    return $self->{scales}->value_to_y($value);
}

1;