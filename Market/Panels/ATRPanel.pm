package Market::Panels::ATRPanel;

use strict;
use warnings;

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

1;