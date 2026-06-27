package Market::Overlays::SMC_Structures;
use strict;
use warnings;
use parent 'Market::Overlays::Base'; 

sub new {
    my ($class, %args) = @_;
    my $self = {
        %args,
        fvg_alpha_decay => 0.05, # Ritmo de desvanecimiento
    };
    bless $self, $class;
    return $self;
}

# Responsabilidad: Dibujar en el Canvas Tk de forma sincronizada con el Zoom/Scroll
# Inputs: $canvas, $smc_data , $scales (transformaciones index_to_x, value_to_y)
sub render {
    my ($self, $smc_data, $current_replay_index) = @_;
    my $canvas = $self->{canvas};
    my $scales = $self->{scales};

    $canvas->delete('smc_layer');

    # --- 1. RENDERIZAR FAIR VALUE GAPS (Con Fading temporal) ---
    foreach my $fvg (@{$smc_data->{fvg_zones}}) {
        next if $fvg->{index} > $current_replay_index;

        my $age_in_candles = $current_replay_index - $fvg->{index};
        my $max_lifetime   = 50; # Límite de velas hasta que el FVG caduque/desaparezca

        if ($age_in_candles < $max_lifetime) {
            my $x1 = $scales->index_to_center_x($fvg->{index});
            my $x2 = $scales->index_to_center_x($current_replay_index);
            my $y1 = $scales->value_to_y($fvg->{high_price});
            my $y2 = $scales->value_to_y($fvg->{low_price});
            
            # Colores sutiles institucionales
            my $color = $fvg->{type} eq 'BULLISH' ? '#26a69a' : '#ef5350';

            $canvas->createRectangle($x1, $y1, $x2, $y2, 
                -fill    => $color, 
                -outline => '', 
                -stipple => 'gray50', # Truco Tk: Crea un patrón de tablero de ajedrez para simular opacidad
                -tags    => ['smc_layer', 'fvg']
            );
        }
    }
    
    # --- 2. RENDERIZAR QUIEBRES (BOS / CHOCH) ---
    # Unificamos ambos arrays de eventos estructurales
    my @structural_events = (@{$smc_data->{bos_events}}, @{$smc_data->{choch_events}});
    
    foreach my $struct (@structural_events) {
        next if $struct->{index} > $current_replay_index;
        
        my $x_start = $scales->index_to_center_x($struct->{start_index});
        my $x_end   = $scales->index_to_center_x($struct->{index});
        my $y       = $scales->value_to_y($struct->{price});
        
        # Línea sólida negra/oscura marcando la ruptura
        $canvas->createLine($x_start, $y, $x_end, $y, 
            -fill  => '#131722', 
            -width => 2, 
            -tags  => ['smc_layer']
        );
        
        # Etiqueta centrada justo encima de la línea de ruptura
        my $x_center_label = $x_start + (($x_end - $x_start) / 2);
        $canvas->createText($x_center_label, $y - 10, 
            -text => $struct->{type}, # "BOS" o "CHOCH"
            -fill => '#131722', 
            -font => ['Helvetica', 9, 'bold'], 
            -tags => ['smc_layer']
        );
    }
}
1;