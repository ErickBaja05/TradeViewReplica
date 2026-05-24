package Market::Panels::PricePanel;

use strict;
use warnings;

=head1 NOMBRE

Market::Panels::PricePanel - Panel principal para el renderizado del gráfico de precios (velas).

=head1 MÉTODOS

=head2 new

Inicializa el panel de precios y configura el comportamiento elástico del canvas.

Atributos de entrada:
  - canvas : Widget Canvas de Tk asignado para el precio.
  - engine : Referencia al objeto integrador Market::ChartEngine.

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        canvas => $args{canvas},
        engine => $args{engine},
    };

    # Validación de seguridad para desarrollo concurrente
    unless ($self->{canvas}) {
        die "[ERROR PricePanel]: Objeto Canvas de Tk no recibido en el constructor.\n";
    }

    # RESOLUCIÓN CUELLO DE BOTELLA - LAYOUT VISUAL ELÁSTICO
    # El panel de precios ocupa la mayor parte de la pantalla (área principal).
    # - fill => 'both' : Permite que el canvas se estire horizontal y verticalmente.
    # - expand => 1    : Le asigna prioridad de crecimiento al redimensionar la ventana.
    $self->{canvas}->pack(
        -side   => 'top',
        -fill   => 'both',
        -expand => 1
    );

    return bless $self, $class;
}

1;