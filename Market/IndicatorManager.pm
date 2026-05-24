package Market::IndicatorManager;
use strict;
use warnings;

# Gestiona múltiples indicadores técnicos de forma desacoplada
# Permite registrar, actualizar y consultar indicadores sin acoplarlos al sistema de render

# Inicializa el contenedor de indicadores
sub new
{
    my ($class) = @_;
    my $self =
    {
        indicators => {},
    };
    bless $self, $class;
    return $self;
}

# Registra un indicador
# Permite extensibilidad
sub register
{
    my ($self, $name, $indicator) = @_;
    # TODO
}

# Actualiza indicadores con la última vela
# Cálculo incremental eficiente
sub update_last
{
    my ($self, $market_data) = @_;
    # TODO
}

# Obtiene valores de un indicador
sub get
{
    my ($self, $name) = @_;
    # TODO
}

# Devuelve una porción de valores del indicador
# Sincronización con ventana visible
sub slice_array
{
    my ($self, $name, $start, $end) = @_;
    # TODO
}

# Reinicia todos los indicadores
# Útil al cambiar timeframe
sub reset_all
{
    my ($self) = @_;
    # TODO
}
1;