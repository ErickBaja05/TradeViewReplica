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
    $self->{indicators}{$name} = $indicator;
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
    if (not exists $self->{indicators}{$name})
    {
        print "Indicador $name no registrado\n";
        return undef;
    }
    return $self->{indicators}{$name}->get_values();
}

# Devuelve una porción de valores del indicador
# Sincronización con ventana visible
sub slice_array
{
    my ($self, $name, $start, $end) = @_;
    my $values = $self->get($name);
    return [] unless defined $values;

    my $size = scalar(@$values);
    $start = 0 if $start < 0;
    $end = $size if $end > $size;
    return [] if $start >= $end;

    my @slice = @{$values}[$start .. $end - 1];
    return \@slice;
}

# Reinicia todos los indicadores
# Útil al cambiar timeframe
sub reset_all
{
    my ($self) = @_;
    # TODO
}
1;