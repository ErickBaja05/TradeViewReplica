package Market::Overlays::AnchoredVWAP;
use strict;
use warnings;
use parent 'Market::Overlays::Base';

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        %args,
        line_color => $args{line_color} || 'purple',
        line_width => $args{line_width} || 2,
    };
    bless $self, $class;
    return $self;
}

# Responsabilidad: Dibujar la línea continua del VWAP anclado.
sub render {
    my ($self, $vwap_data) = @_;
    
    # TODO: Iterar sobre el array de vwap_values visibles.
    # TODO: Convertir valores a coordenadas usando $self->_x_to_pixel() y $self->_y_to_pixel().
    # TODO: Dibujar una línea continua suavizada conectando los puntos en el Canvas.
}

# CONTRATO DE ENTRADA (Para recibir órdenes del sistema)
# Responsabilidad: Recibir un evento y limpiar los acumuladores si el evento es válido.
# Inputs: 
#   $anchor_type (String): 'SESSION', 'BOS', 'CHOCH', o 'POC'
#   $anchor_index (Int): El índice de la vela donde ocurre el anclaje
sub reset_anchors {
    my ($self, $anchor_type, $anchor_index) = @_;
    
    # Validación de seguridad: Solo aceptar tipos conocidos
    my %valid_anchors = map { $_ => 1 } ('SESSION', 'BOS', 'CHOCH', 'POC');
    return unless $valid_anchors{$anchor_type};

    # Limpiar las sumatorias para reiniciar el cálculo
    $self->{cumulative_volume} = 0;
    $self->{cumulative_pv}     = 0;
    $self->{anchor_index}      = $anchor_index; # Guardar dónde nos anclamos
    $self->{active_anchor}     = $anchor_type;  # Guardar el motivo del anclaje
    
    # Opcional: Podría limpiar el array de vwap_values previos si el anclaje lo exige
    # $self->{vwap_values} = []; 
}

# La función principal que se llamará por cada vela
sub calculate {
    my ($self, $market_data, $current_index) = @_;
    # ... Lógica de cálculo acumulativo de Domenica ...
}

1;