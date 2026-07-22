package Market::Overlays::Channel;

use strict;
use warnings;

=head1 NAME

Market::Overlays::Channel - Capa visual para el Canal de Regresión Lineal

Dibuja el canal actual (líneas superior, media e inferior) inclinadas
siguiendo la pendiente de regresión.

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        result   => undef,
        up_color => $args{up_color}   // '#26a69a',
        dn_color => $args{dn_color}   // '#ef5350',
        width    => $args{width}      // 2,
    };
    
    return bless $self, $class;
}

sub set_result {
    my ($self, $result) = @_;
    $self->{result} = $result;
}

sub draw {
    my ($self, $canvas, $scale, $start, $end) = @_;
    
    my $ch = $self->{result};
    return unless $ch && ref($ch) eq 'HASH';
    
    # Verificar que tenemos todos los campos necesarios
    return unless exists $ch->{upper_start} && exists $ch->{upper_end};
    
    my $slope = $ch->{slope} // 0;
    
    # Color según pendiente
    my $color = ($slope >= 0) ? $self->{up_color} : $self->{dn_color};
    
    # Obtener coordenadas X
    my $x1 = $scale->index_to_x($ch->{start_index});
    my $x2 = $scale->index_to_x($ch->{end_index});
    
    # --- Convertir valores Y a coordenadas de pantalla ---
    # Línea superior
    my $upper_y1 = $scale->value_to_y($ch->{upper_start});
    my $upper_y2 = $scale->value_to_y($ch->{upper_end});
    
    # Línea media (regresión)
    my $mid_y1 = $scale->value_to_y($ch->{mid_start});
    my $mid_y2 = $scale->value_to_y($ch->{mid_end});
    
    # Línea inferior
    my $lower_y1 = $scale->value_to_y($ch->{lower_start});
    my $lower_y2 = $scale->value_to_y($ch->{lower_end});
    
    my $width = $self->{width} // 2;
    
    # Dibujar las tres líneas INCLINADAS
    $canvas->createLine(
        $x1, $upper_y1, $x2, $upper_y2,
        -fill => $color,
        -width => $width,
        -tags => ['channel'],
    );
    
    $canvas->createLine(
        $x1, $mid_y1, $x2, $mid_y2,
        -fill => $color,
        -width => $width,
        -dash => [6, 4],  # Línea discontinua para la media
        -tags => ['channel'],
    );
    
    $canvas->createLine(
        $x1, $lower_y1, $x2, $lower_y2,
        -fill => $color,
        -width => $width,
        -tags => ['channel'],
    );
}

1;