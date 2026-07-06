# package Market::IndicatorManager;

# use strict;
# use warnings;

# # Importación de los módulos analíticos
# use Market::Indicators::Liquidity;
# use Market::Indicators::SMC_Structures;

# sub new {
#     my ($class, %args) = @_;

#     my $self = {
#         # Inicialización del motor de Liquidez (ZigZag, Sweeps, Equal Levels)
#         liquidity => Market::Indicators::Liquidity->new(
#             atr_period       => $args{atr_period}       || 14,
#             atr_multiplier   => $args{atr_multiplier}   || 4.0,
#             minor_atr_mult   => $args{minor_atr_mult}   || 1.5,
#             eq_tolerance     => $args{eq_tolerance}     || 0.10,
#             confirm_bars     => $args{confirm_bars}     || 3,
#             min_bars_pivot   => $args{min_bars_pivot}   || 2,
#         ),
        
#         # Inicialización del motor Estructural (BOS, CHOCH, MSS, FVG)
#         smc => Market::Indicators::SMC_Structures->new(
#             min_fvg_atr_mult   => $args{min_fvg_atr_mult}   || 0.5,
#             min_pivot_strength => $args{min_pivot_strength} || 0.8,
#         ),
#     };

#     return bless $self, $class;
# }

# sub reset {
#     my ($self) = @_;
    
#     # Fundamental para la compatibilidad con el sistema Replay
#     $self->{liquidity}->reset();
#     $self->{smc}->reset();
# }

# sub update {
#     my ($self, $market_data) = @_;

#     return unless $market_data && $market_data->size() > 0;

#     # ------------------------------------------------------------------
#     # ORDEN ESTRATÉGICO DE EJECUCIÓN (CAUSALIDAD SMC)
#     # ------------------------------------------------------------------
    
#     # 1. Motor de Liquidez: Actualiza candidatos, confirma pivotes, 
#     # evalúa EQH/EQL y procesa barridos (Sweeps/Grabs) intrabar.
#     $self->{liquidity}->update_last($market_data);

#     # 2. Motor Estructural: Evalúa si la acción del precio (desplazamiento)
#     # ha roto un swing protegido utilizando el contexto actualizado de liquidez.
#     $self->{smc}->update($market_data, $self->{liquidity});
# }

# --- API Pública de Acceso para Overlays y Strategy Builder ---

# sub get_liquidity {
#     my ($self) = @_;
#     return $self->{liquidity};
# }

# sub get_smc_structures {
#     my ($self) = @_;
#     return $self->{smc};
# }

# 1;
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
    for my $name (keys %{$self->{indicators}})
    {
        $self->{indicators}{$name}->update_last($market_data);
    }
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
    for my $name (keys %{$self->{indicators}})
    {
        $self->{indicators}{$name}->reset();
    }
}

sub get_liquidity {
    my ($self) = @_;
    return $self->{indicators}{Liquidity} // $self->{liquidity};
}

sub get_smc_structures {
    my ($self) = @_;
    return $self->{indicators}{SMC} // $self->{smc};
}
1;