package Market::Indicators::ATR;
use strict;
use warnings;

# Implementa el indicador Average True Range (ATR)
# Debe calcular volatilidad basada en precios históricos

# Inicializa ATR con su período
sub new
{
    my ($class, $period) = @_;
    my $self = {
        period => $period,
        values => [],
    };
    bless $self, $class;
    return $self;
}

# Actualiza el ATR con la última vela
# Implementa cálculo incremental
sub update_last
{
    my ($self, $market_data) = @_;
    # TODO
}

# Devuelve serie completa del ATR
sub get_values
{
    my ($self) = @_;
    # TODO
}

# Reinicia el indicador
sub reset
{
    my ($self) = @_;
    # TODO
}
1;