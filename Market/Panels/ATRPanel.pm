package Market::Panels::ATRPanel;

use strict;
use warnings;
use Market::Panels::Scales;

=head1 NOMBRE

Market::Panels::ATRPanel - Panel inferior para el renderizado del indicador de volatilidad ATR.

=head1 MÉTODOS

=head2 new

Inicializa el panel del ATR y define su proporción visual en el layout.

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        canvas => $args{canvas},
        engine => $args{engine},
        scale  => undef, # Contenedor interno para la escala del indicador
    };

    unless ($self->{canvas}) {
        die "[ERROR ATRPanel]: Objeto Canvas de Tk no recibido en el constructor.\n";
    }
    
    # El panel se adueña de su color de fondo (TradingView Style)
    $self->{canvas}->configure(-bg => '#131722');

    # Resolución layout visual elástico
    $self->{canvas}->pack(
        -side   => 'bottom',
        -fill   => 'both',
        -expand => 0
    );
    
    return bless $self, $class;
}

=head2 round

Redondeo numérico auxiliar para el mapeo discreto de píxeles en el panel del indicador.

Atributos de entrada:
  - $value : Valor decimal flotante.

Retorna:
  - Entero más cercano.

=cut

sub round {
    my ($self, $value) = @_;
    return int($value + 0.5 * ($value <=> 0));
}

=head2 get_y_range

Calcula el rango de valores mínimos y máximos visibles exclusivamente del indicador ATR.

Retorna:
  - Lista con dos flotantes: ($min_y, $max_y)

=cut

sub get_y_range {
    my ($self) = @_;

    # 1. Sincronizar la ventana de datos con el motor central de Erick
    my ($start, $end) = $self->{engine}->compute_window();
    
    #2. Recuperar el arreglo de valores del ATR de forma ultra-segura
    my $atr_values = [];
    if (defined $self->{engine}->{indicator_manager}) {
        
        # Usamos el método oficial 'get'
        my $atr_indicator = $self->{engine}->{indicator_manager}->get('ATR');
        
        # Validación estricta de tipos para evitar que un número falso rompa el programa
        if (defined $atr_indicator) {
            if (ref($atr_indicator) eq 'ARRAY') {
                $atr_values = $atr_indicator;
            } elsif (ref($atr_indicator) eq 'HASH') {
                $atr_values = $atr_indicator->{values} || [];
            }
            # Si ref() devuelve vacío, significa que es un string o número simple (como el '2').
            # En ese caso, lo ignoramos y dejamos $atr_values vacío.
        }
    }
    
    # Si sigue vacío, lo inicializamos para evitar errores
    $atr_values //= [];

    # Si no existen cálculos aún en el sistema, devolvemos un rango por defecto plano para el indicador
    if (scalar @$atr_values == 0) {
        return (0.0, 10.0);
    }

    # Inicializar los extremos con valores reales del indicador en el primer índice visible
    my $min_y = defined $atr_values->[$start] ? $atr_values->[$start] : 0.0;
    my $max_y = defined $atr_values->[$start] ? $atr_values->[$start] : 1.0;

    # 3. Buscar los puntos máximos y mínimos del ATR en la porción de pantalla activa
    for my $i ($start .. $end) {
        my $val = $atr_values->[$i];
        if (defined $val) {
            $min_y = $val if $val < $min_y;
            $max_y = $val if $val > $max_y;
        }
    }

    # Forzar el límite inferior a cero si el ATR cae en valores negativos por ruido matemático
    $min_y = 0.0 if $min_y < 0.0;

    # Evitar indeterminaciones matemáticas si el indicador se mantiene plano
    if ($max_y == $min_y) {
        $max_y += 1.0;
    }

    # 4. Margen técnico (padding del 5%) para que la línea del indicador respire en los bordes del canvas inferior
    my $padding = ($max_y - $min_y) * 0.05;
    $max_y += $padding;
    $min_y = ($min_y - $padding < 0) ? 0.0 : ($min_y - $padding);

    return ($min_y, $max_y);
}

=head2 set_scale

Establece y refresca de forma independiente la escala del panel del indicador ATR.

Retorna:
  - Instancia del objeto Market::Panels::Scales actualizado para este panel.

=cut

sub set_scale {
    my ($self) = @_;

    my ($min_y, $max_y) = $self->get_y_range();
    my $width  = $self->{canvas}->Width();
    my $height = $self->{canvas}->Height();

    my ($start_index, $end_index) = $self->{engine}->compute_window();

    # EL SECRETO DEL ANCLAJE TRADINGVIEW:
    # Calculamos el inicio teórico (incluso si es negativo) para que Ricardo 
    # siempre ancle la última vela ($end_index) al margen derecho.
    my $visible_bars = $self->{engine}->{visible_bars} || 100;
    my $scale_offset = $end_index - $visible_bars + 1;

    $self->{scale} = Market::Panels::Scales->new(
        width        => $width,
        height       => $height,
        visible_bars => $visible_bars,
        offset       => $scale_offset, # Le pasamos el offset teórico, no el start_index
        y_min        => $min_y,
        y_max        => $max_y,
    );

    return $self->{scale};
}

=head2 render

Dibuja la curva continua del indicador ATR uniendo los puntos calculados mediante
líneas vectoriales. Usa las escalas de Ricardo para X y el parche matemático para Y.

Atributos de entrada:
  - $data_slice : Referencia a la lista de hashes (necesaria para sincronizar los índices).

=cut

sub render {
    my ($self, $data_slice) = @_;

    return unless $data_slice && scalar(@$data_slice) > 0;

    # 1. Actualizar las escalas locales del panel
    my $scale = $self->set_scale();
    my $canvas_height = $self->{canvas}->Height();

    #2. Recuperar el arreglo de valores del ATR de forma ultra-segura
    my $atr_values = [];
    if (defined $self->{engine}->{indicator_manager}) {
        
        # Usamos el método oficial 'get'
        my $atr_indicator = $self->{engine}->{indicator_manager}->get('ATR');
        
        # Validación estricta de tipos para evitar que un número falso rompa el programa
        if (defined $atr_indicator) {
            if (ref($atr_indicator) eq 'ARRAY') {
                $atr_values = $atr_indicator;
            } elsif (ref($atr_indicator) eq 'HASH') {
                $atr_values = $atr_indicator->{values} || [];
            }
            # Si ref() devuelve vacío, significa que es un string o número simple (como el '2').
            # En ese caso, lo ignoramos y dejamos $atr_values vacío.
        }
    }
    
    # Si sigue vacío, lo inicializamos para evitar errores
    $atr_values //= [];

    # 3. Obtener el rango vertical de volatilidad visible para aplicar la fórmula temporal
    my ($atr_min, $atr_max) = $self->get_y_range();
    my $rango_y = $atr_max - $atr_min;
    $rango_y = 1.0 if $rango_y == 0;

   # 4. Sincronizar índices de iteración
    my ($start_index, $end_index) = $self->{engine}->compute_window();
    my $i = $start_index;
    my ($last_x, $last_y);

    for my $candle (@$data_slice) {
        last if $i > $end_index;

        my $atr_val = $atr_values->[$i];
        
        if (defined $atr_val) {
            # X e Y usando únicamente los métodos matemáticos oficiales de Ricardo
            my $x_current = $scale->index_to_center_x($i);
            my $y_current = $scale->value_to_y($atr_val);

            # Trazamos el segmento de línea
            if (defined $last_x && defined $last_y) {
                $self->{canvas}->createLine(
                    $last_x, $last_y,
                    $x_current, $y_current,
                    -fill  => '#2196f3', 
                    -width => 2
                );
            }
            $last_x = $x_current;
            $last_y = $y_current;
        }
        $i++;
    }

    $self->init_crosshair();
    
    # 2. Dibujar el último valor visible del indicador
    $self->render_last_visible_value($data_slice, $scale, $atr_values);
}

=head2 init_crosshair

Inicializa los objetos de tipo línea para el crosshair en el panel del indicador ATR.

=cut

sub init_crosshair {
    my ($self) = @_;

    my $crosshair_color = '#555555';

    # Línea vertical inicial en cero
    $self->{crosshair_v_id} = $self->{canvas}->createLine(
        0, 0, 0, 0,
        -fill => $crosshair_color,
        -dash => '.',
        -tags => ['crosshair_internal']
    );

    # Línea horizontal inicial en cero
    $self->{crosshair_h_id} = $self->{canvas}->createLine(
        0, 0, 0, 0,
        -fill => $crosshair_color,
        -dash => '.',
        -tags => ['crosshair_internal']
    );

    return;
}

=head2 draw_crosshair

Actualiza la posición del cursor en cruz dentro del panel del indicador ATR.

=cut

sub draw_crosshair {
    my ($self, $x, $y, $is_active) = @_;

    my $canvas_height = $self->{canvas}->Height();
    my $canvas_width  = $self->{canvas}->Width();

    return if $canvas_width <= 1 || $canvas_height <= 1;

    # 1. Mover la línea vertical de forma sincronizada con el precio
    if (defined $self->{crosshair_v_id}) {
        $self->{canvas}->coords($self->{crosshair_v_id}, $x, 0, $x, $canvas_height);
    }

    # 2. Mover u ocultar la línea horizontal local del ATR
    if (defined $self->{crosshair_h_id}) {
        if ($is_active) {
            $self->{canvas}->coords($self->{crosshair_h_id}, 0, $y, $canvas_width, $y);
        } else {
            $self->{canvas}->coords($self->{crosshair_h_id}, 0, 0, 0, 0);
        }
    }

    return;
}

=head2 render_last_visible_value

Dibuja una línea horizontal punteada y una caja resaltada a la derecha
con el valor del indicador ATR de la última vela visible en pantalla.
=cut

sub render_last_visible_value {
    my ($self, $data_slice, $scale, $atr_values) = @_;

    # Obtenemos los límites actuales para saber cuál es el índice final
    my ($start_index, $end_index) = $self->{engine}->compute_window();
    
    # Extraemos el último valor de volatilidad de ese índice
    my $last_atr_val = $atr_values->[$end_index];
    return unless defined $last_atr_val;

    # Calculamos la altura en píxeles usando la escala de Ricardo
    my $y = $scale->value_to_y($last_atr_val);
    my $canvas_width = $self->{canvas}->Width();
    
    my $color = '#2196f3'; # Azul oficial del indicador ATR

    # 1. Línea horizontal punteada
    $self->{canvas}->createLine(
        0, $y,
        $canvas_width, $y,
        -fill => $color,
        -dash => '.',
        -tags => ['last_atr_indicator']
    );

    # 2. Etiqueta de valor a la derecha ($canvas_width - 32)
    my $x_pos = $canvas_width - 32;
    my $valor_fmt = sprintf("%.4f", $last_atr_val); # 4 decimales para indicadores

    my $txt_id = $self->{canvas}->createText(
        $x_pos, $y,
        -text => $valor_fmt,
        -fill => '#ffffff',
        -font => ['Helvetica', 10, 'bold'],
        -tags => ['last_atr_indicator']
    );

    my @bbox = $self->{canvas}->bbox($txt_id);
    if (@bbox) {
        my $bg_id = $self->{canvas}->createRectangle(
            $bbox[0]-6, $bbox[1]-2, $bbox[2]+6, $bbox[3]+2,
            -fill    => $color,
            -outline => $color,
            -tags    => ['last_atr_indicator']
        );
        $self->{canvas}->lower($bg_id, $txt_id);
    }
}

1;