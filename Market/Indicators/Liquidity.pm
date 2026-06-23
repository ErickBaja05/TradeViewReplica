package Market::Indicators::Liquidity;
use strict;
use warnings;

# Constructor
sub new {
    my ($class, %args) = @_;
    my $self = {
        atr_period => $args{atr_period} || 14,
        k_depth    => $args{k_depth} || 3, # Vecindad para Swing Points
        swing_highs => [],
        swing_lows  => [],
        liquidity_events => [], # Almacenará la máquina de estados
    };
    bless $self, $class;
    return $self;
}

# Responsabilidad: Detectar Swing Highs y Lows base
# Inputs: array_slice (velas previas y actuales)
# Outputs: Hash con indices de swings confirmados
sub detect_swing_points {
    my ($self, $market_data, $current_index) = @_;
    
    # TODO: Extraer ventana de velas de tamaño (2 * k_depth + 1)
    # TODO: Validar si High[current_index - k] es mayor que sus vecinos.
    # TODO: Si es Swing High, agregarlo a $self->{swing_highs} con estado 'DETECTED'
}

# Responsabilidad: Máquina de estados principal por vela
# Inputs: market_data (vela actual en el Replay)
# Outputs: Eventos resueltos para el Chart y SMC
sub update_state_machine {
    my ($self, $market_data) = @_;
    my $current_candle = $market_data->last_candle();
    
    # TODO: Iterar sobre $self->{liquidity_events} que estén en 'DETECTED'
    # TODO: Si $current_candle->high cruza un BSL -> Cambiar estado a 'SWEPT'
    # TODO: Evaluar N velas de cierre. Si cierra por encima -> 'ACCEPTANCE'
    # TODO: Si regresa -> 'RECLAIMED'. 
    # TODO: Evaluar tiempo de rechazo para clasificar como 'GRAB', 'SWEEP' o 'RUN' -> Cambiar a 'RESOLVED'
}

# Responsabilidad: Calcular Tolerancia para EQH/EQL
sub calculate_eq_tolerance {
    my ($self, $atr_value) = @_;
    # TODO: Retornar atr_value * 0.10
    return $atr_value * 0.10;
}

1;