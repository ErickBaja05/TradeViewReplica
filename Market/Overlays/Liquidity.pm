package Market::Overlays::Liquidity;
use strict;
use warnings;
use parent 'Market::Overlays::Base'; # Heredamos de Base.pm

sub new {
    my ($class, %args) = @_;
    
    # Creamos el objeto incluyendo los argumentos del padre (canvas, scales)
    # y agregamos nuestras propiedades visuales específicas.
    my $self = {
        %args,
        bsl_color   => 'red',
        ssl_color   => 'green',
        grab_color  => 'orange',
        run_color   => 'blue',
        dash_style  => '-', # Estilo de línea punteada para Tk
    };
    bless $self, $class;
    return $self;
}

# Responsabilidad: Renderizar líneas y etiquetas de Liquidez (BSL, SSL, Sweeps)
# Inputs: $liquidity_data
sub render {
    my ($self, $liquidity_data) = @_;
    my $canvas = $self->{canvas};
    
    # TODO: Iterar sobre los eventos en estado 'DETECTED'
    # TODO: Si es BSL, usar $canvas->createLine(...) con estilo punteado rojo y etiqueta "BSL".
    # TODO: Si es SSL, dibujar línea punteada verde y etiqueta "SSL".
    # TODO: Si el estado es 'RESOLVED' y la clasificación es 'SWEEP', dibujar marcador de quiebre (SWEEP ↑ o SWEEP ↓).
    # TODO: Si es 'GRAB', destacar con color naranja ("LQ GRAB").
}

1;