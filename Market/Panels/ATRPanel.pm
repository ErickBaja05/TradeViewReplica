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

    # RESOLUCIÓN CUELLO DE BOTELLA - LAYOUT VISUAL ESTÁTICO/ACOTADO
    # El panel del indicador va abajo y no debe competir agresivamente en altura con el precio.
    # - fill => 'x'    : Se estira completamente a lo ancho.
    # - expand => 0    : No crece desproporcionadamente de alto al estirar la ventana principal.
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
    
    # 2. Acceder al manejador de indicadores técnicos para extraer el arreglo del ATR de Josué
    my $atr_values = [];
    if (defined $self->{engine}->{indicator_manager}) {
        $atr_values = $self->{engine}->{indicator_manager}->get_atr_values() || [];
    }

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

    # 1. Calcular el rango dinámico de fluctuación del indicador en la ventana actual
    my ($min_y, $max_y) = $self->get_y_range();
    
    # 2. Obtener dimensiones físicas del Canvas
    my $width  = $self->{canvas}->Width();
    my $height = $self->{canvas}->Height();

    # 3. Re-instanciar las escalas mapeando los límites específicos del ATR
    $self->{scale} = Market::Panels::Scales->new(
        width        => $width,
        height       => $height,
        visible_bars => $self->{engine}->{visible_bars},
        offset       => $self->{engine}->{offset},
        x_min        => 0,
        y_min        => $min_y,
        y_max        => $max_y,
    );

    return $self->{scale};
}

1; # Retorno verdadero obligatorio para módulos en Perl