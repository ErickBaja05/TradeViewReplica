package Market::Overlays::Strategy_Builder;
use strict;
use warnings;
use parent 'Market::Overlays::Base';


sub new {
    my ($class, %args) = @_;
    
    my $self = {
        %args,
        uptrend_color   => 'green',
        downtrend_color => 'red',
        supply_color    => '#FFCCCC', # Rojo pastel
        demand_color    => '#CCFFCC', # Verde pastel
        signal_font     => 'Helvetica 10 bold',
    };
    bless $self, $class;
    return $self;
}

# Responsabilidad: Mostrar gráficamente las decisiones del constructor de estrategias.
sub render {
    my ($self, $strategy_data) = @_;
    
    # TODO: Dibujar las "Supply Zones" y "Demand Zones" persistentes en la memoria.
    # TODO: Colocar flechas o marcadores triangulares (arriba/abajo) en las velas donde se detecta una señal de entrada.
    # TODO: Renderizar las líneas del SuperTrend (verde por debajo en tendencia alcista, rojo por encima en bajista).
}

1;