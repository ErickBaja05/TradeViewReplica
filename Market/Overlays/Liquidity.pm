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
    my ($self, $liquidity_events, $current_replay_index) = @_;
    my $canvas = $self->{canvas};
    my $scales = $self->{scales};

    # Limpiar la capa antes de re-dibujar el frame actual
    $canvas->delete('liquidity_layer');

    foreach my $event (@$liquidity_events) {
        # Filtro estricto: El overlay es ciego al futuro del Replay
        next if $event->{index} > $current_replay_index;

        my $x_start = $scales->index_to_center_x($event->{index});
        my $y       = $scales->value_to_y($event->{price});
        
        # Las líneas de liquidez se extienden hasta la vela actual del replay
        my $x_current = $scales->index_to_center_x($current_replay_index);

        if ($event->{type} eq 'BSL') {
            $canvas->createLine($x_start, $y, $x_current, $y, 
                -dash => '.', 
                -fill => 'red', 
                -width => 1,
                -tags => ['liquidity_layer']
            );
            $canvas->createText($x_current + 15, $y, -text => 'BSL', -fill => 'red', -font => ['Helvetica', 8, 'bold'], -tags => ['liquidity_layer']);
        }
        elsif ($event->{type} eq 'SSL') {
            $canvas->createLine($x_start, $y, $x_current, $y, 
                -dash => '.', 
                -fill => 'green', 
                -width => 1,
                -tags => ['liquidity_layer']
            );
            $canvas->createText($x_current + 15, $y, -text => 'SSL', -fill => 'green', -font => ['Helvetica', 8, 'bold'], -tags => ['liquidity_layer']);
        }
        
        # --- ETIQUETAS DE MÁQUINA DE ESTADOS (SWEEP, GRAB, RUN) ---
        if ($event->{state} eq 'SWEEP_UP') {
            $canvas->createText($x_start, $y - 15, -text => "SWEEP \x{2191}", -fill => 'red', -tags => ['liquidity_layer']);
        }
        elsif ($event->{state} eq 'SWEEP_DOWN') {
            $canvas->createText($x_start, $y + 15, -text => "SWEEP \x{2193}", -fill => 'green', -tags => ['liquidity_layer']);
        }
        elsif ($event->{state} eq 'GRAB') {
            $canvas->createText($x_start, $y - 20, -text => 'LQ GRAB', -fill => 'orange', -font => ['Helvetica', 9, 'bold'], -tags => ['liquidity_layer']);
        }
        elsif ($event->{state} eq 'RUN') {
            $canvas->createText($x_start, $y - 20, -text => 'LQ RUN', -fill => 'blue', -font => ['Helvetica', 9, 'bold'], -tags => ['liquidity_layer']);
        }
    }
}

1;