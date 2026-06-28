package Market::Indicators::SMC_Structures;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        # 1. Dependencias Inyectadas (Inversion of Control)
        market_data      => $args{market_data},
        liquidity_engine => $args{liquidity_engine},
        atr_indicator    => $args{atr_indicator},
        settings         => $args{settings} || {},
        
        # 2. Historial Permanente de Swing Points (consumidos desde Liquidity.pm)
        swings => {
            highs => [],
            lows  => [],
            processed_indexes => {},
        },
        
        # 3. Estado Estructural del Mercado
        market_structure => {
            trend                 => 0,     # 1 (Bullish), -1 (Bearish), 0 (Neutral)
            last_bos              => undef, 
            last_choch            => undef, 
            last_structural_swing => undef, 
        },
        
        # 4. Contexto de Liquidez (Espejo analítico de Liquidity.pm)
        liquidity_context => {
            processed_events => {},
            recent_events    => [], 
            last_sweep       => undef,
            last_grab        => undef,
            last_run         => undef,
        },
        
        # 5. Listas de Datos Específicos 
        bos_list   => [],
        choch_list => [],
        fvg_list   => [],
        active_fvg => [],
        
        # 6. Historial Cronológico Unificado: Todo evento detectado (BOS, CHOCH, FVG, etc.) ordenado por tiempo
        events => [],
        
        # 7. Buffer de Eventos de la Última Actualización (Para Anchored VWAP / Strategy Builder)
        latest_anchor_events => [], 

        # Estado temporal (Runtime)
        runtime => {
            pending_events => [],
            current_cycle  => 0,
            dirty          => 0,
        },
    };
    
    bless $self, $class;
    return $self;
}

sub update {
    my ($self, $candle_index) = @_;
    
    # validación de dependencias para evitar fallos de ejecución
    return unless $self->{market_data} && $self->{liquidity_engine};

    # Limpiar los eventos "ancla" del tick anterior
    $self->{latest_anchor_events} = [];
    
    # Flujo secuencial determinista
    $self->_sync_liquidity_events($candle_index);
    $self->_update_swings($candle_index);
    $self->_detect_fvg($candle_index);
    $self->_mitigate_fvg($candle_index);
    $self->_evaluate_market_structure($candle_index);
    
    # Emitir eventos (Poblar 'events' y 'latest_anchor_events')
    $self->_emit_events();
}

# Getters 

sub get_bos                  { return $_[0]->{bos_list}; }
sub get_choch                { return $_[0]->{choch_list}; }
sub get_fvg                  { return $_[0]->{fvg_list}; }
sub get_events               { return $_[0]->{events}; }
sub get_latest_anchor_events { return $_[0]->{latest_anchor_events}; }
sub get_swings               { return $_[0]->{swings}; }
sub get_liquidity_context    { return $_[0]->{liquidity_context}; }
sub get_market_structure     { return $_[0]->{market_structure}; }



# Control de estado
sub reset {
    my ($self) = @_;
    
    # Reiniciar estructuras sin perder las referencias a dependencias (market_data, etc.)
    $self->{swings} = {
        highs => [], 
        lows => [] ,
        processed_indexes => {}
    };
    
    $self->{market_structure} = {
        trend                 => 0,
        last_bos              => undef,
        last_choch            => undef,
        last_structural_swing => undef,
    };
    
    $self->{liquidity_context} = {
        processed_events => {},
        recent_events    => [],
        last_sweep       => undef,
        last_grab        => undef,
        last_run         => undef,
    };
    
    $self->{bos_list}             = [];
    $self->{choch_list}           = [];
    $self->{fvg_list}             = [];
    $self->{active_fvg}           = [];
    $self->{events}               = [];
    $self->{latest_anchor_events} = [];
    $self->{runtime}{pending_events} = [];
    $self->{runtime}{dirty}          = 0;
}

# MÉTODOS PRIVADOS

sub _sync_liquidity_events {
    my ($self, $candle_index) = @_;
    
    # Extraer todos los eventos resueltos por la máquina de estados de liquidez
    my $resolved_events = $self->{liquidity_engine}->get_resolved_events();
    my $limit = $self->{settings}{recent_events_limit} || 50;

    foreach my $event (@$resolved_events) {
        my $event_id = "$event->{index}_$event->{type}_$event->{state}";
        next if $self->{liquidity_context}{processed_events}{$event_id};
        
        push @{$self->{liquidity_context}{recent_events}}, $event;

        while (scalar @{$self->{liquidity_context}{recent_events}} > $limit) {
            shift @{$self->{liquidity_context}{recent_events}};
        }

        my $state = $event->{state} || '';
        if ($state eq 'GRAB') {
            $self->{liquidity_context}{last_grab} = $event;
        } elsif ($state eq 'RUN') {
            $self->{liquidity_context}{last_run} = $event;
        } elsif ($state eq 'RECLAIMED') {
            $self->{liquidity_context}{last_sweep} = $event;
        }

        # Marcar como procesado definitivamente
        $self->{liquidity_context}{processed_events}{$event_id} = 1;
    }
}

sub _update_swings {
    my ($self, $candle_index) = @_;
    
    my $available_events = $self->{liquidity_engine}->get_resolved_events();
    
    foreach my $event (@$available_events) {
        my $type  = $event->{type} || '';
        my $index = $event->{index};

        # Solo nos interesan los eventos que representan estructuralmente un Swing
        next unless ($type eq 'BSL' || $type eq 'SSL');
        next if $self->{swings}{processed_indexes}{$index};
        my $timestamp = $event->{detected_at} || $self->{market_data}->get_timestamp($index);
        
        # Construir estructura del Swing
        my $swing_data = {
            index        => $index,
            price        => $event->{price},
            timestamp    => $timestamp,
            source_event => $event, # Referencia inmutable del evento de Liquidity
        };
        
        # Almacenamiento permanente basado en su tipo de liquidez generada
        if ($type eq 'BSL') {
            push @{$self->{swings}{highs}}, $swing_data;
        } elsif ($type eq 'SSL') {
            push @{$self->{swings}{lows}}, $swing_data;
        }
        
        $self->{swings}{processed_indexes}{$index} = 1;
    }
}


sub _detect_fvg {
    my ($self, $candle_index) = @_;
    
    # El FVG requiere obligatoriamente evaluar el índice actual y los 2 anteriores
    return if $candle_index < 2;
    
    my $market = $self->{market_data};
    
    # Obtener subconjunto de velas
    my $c0 = $market->get_candle($candle_index);       # Vela actual
    my $c2 = $market->get_candle($candle_index - 2);   # Vela generadora
    
    # Salvaguarda en caso de faltar datos
    return unless ($c0 && $c2);
    
    # Variables de contorno
    my $low_0  = $c0->{low};
    my $high_0 = $c0->{high};
    my $low_2  = $c2->{low};
    my $high_2 = $c2->{high};
    
    # Timestamp base para registro
    my $timestamp = $c0->{timestamp} || $market->get_timestamp($candle_index);
    
    # Detección FVG Alcista (Bullish Imbalance)
    if ($low_0 > $high_2) {
        $self->_register_fvg(
            type          => 'BULLISH',
            top           => $low_0,
            bottom        => $high_2,
            created_index => $candle_index,
            timestamp     => $timestamp
        );
    }
    
    # Detección FVG Bajista (Bearish Imbalance)
    if ($high_0 < $low_2) {
        $self->_register_fvg(
            type          => 'BEARISH',
            top           => $low_2,
            bottom        => $high_0,
            created_index => $candle_index,
            timestamp     => $timestamp
        );
    }
}

sub _mitigate_fvg {
    my ($self, $candle_index) = @_;
    return unless @{$self->{active_fvg}};
    
    my $candle = $self->{market_data}->get_candle($candle_index);
    return unless $candle;
    
    my $timestamp = $candle->{timestamp} || $self->{market_data}->get_timestamp($candle_index);
    my @remaining_fvgs;
    
    foreach my $fvg (@{$self->{active_fvg}}) {
        my $is_mitigated = 0;
        
        # Invasión de la zona de desequilibrio por la vela actual
        if ($fvg->{type} eq 'BULLISH' && $candle->{low} <= $fvg->{top}) {
            $is_mitigated = 1;
        } elsif ($fvg->{type} eq 'BEARISH' && $candle->{high} >= $fvg->{bottom}) {
            $is_mitigated = 1;
        }
        
        if ($is_mitigated) {
            # Se actualiza el objeto por referencia (permanece en fvg_list con nuevo estado)
            $fvg->{state}               = 'MITIGATED';
            $fvg->{mitigated_index}     = $candle_index;
            $fvg->{mitigated_timestamp} = $timestamp;
        } else {
            push @remaining_fvgs, $fvg;
        }
    }
    # Se sobrescribe el buffer únicamente con los que siguen activos
    $self->{active_fvg} = \@remaining_fvgs;
}


sub _evaluate_market_structure {
    my ($self, $candle_index) = @_;
    my $highs = $self->{swings}{highs};
    my $lows  = $self->{swings}{lows};
    
    return unless @$highs && @$lows;
    
    my $candle = $self->{market_data}->get_candle($candle_index);
    my $close  = $candle->{close};
    
    my $last_high = $highs->[-1];
    my $last_low  = $lows->[-1];
    
    my $struct = $self->{market_structure};
    my $trend  = $struct->{trend};
    my $last_bos   = $struct->{last_bos};
    my $last_choch = $struct->{last_choch};
    
    # Extraer evento de liquidez reciente de contexto (Sweeps/Grabs son respaldos fuertes)
    my $ctx = $self->{liquidity_context};
    my $recent_liquidity_event = $ctx->{last_sweep} || $ctx->{last_grab} || $ctx->{last_run};
    
    if ($trend == 0) {
        if ($close > $last_high->{price}) {
            if (!$last_bos || $last_bos->{swing_index} != $last_high->{index}) {
                $self->_register_bos(
                    type        => 'BOS',
                    direction   => 'BULLISH',
                    break_index => $candle_index,
                    break_price => $close,
                    swing_index => $last_high->{index},
                    timestamp   => $candle->{timestamp},
                    swing       => $last_high
                );
            }
        } elsif ($close < $last_low->{price}) {
            if (!$last_bos || $last_bos->{swing_index} != $last_low->{index}) {
                $self->_register_bos(
                    type        => 'BOS',
                    direction   => 'BEARISH',
                    break_index => $candle_index,
                    break_price => $close,
                    swing_index => $last_low->{index},
                    timestamp   => $candle->{timestamp},
                    swing       => $last_low
                );
            }
        }
        return;
    }
    # Tendencia Alcista 
    if ($trend == 1) { 
        # Detección de BOS Alcista
        if ($close > $last_high->{price}) {
            if (!$last_bos || $last_bos->{swing_index} != $last_high->{index}) {
                $self->_register_bos(
                    type        => 'BOS',
                    direction   => 'BULLISH',
                    break_index => $candle_index,
                    break_price => $close,
                    swing_index => $last_high->{index},
                    timestamp   => $candle->{timestamp},
                    swing       => $last_high
                );
            }
        }
        # Detección de CHOCH Bajista (Requiere ruptura opuesta + contexto de liquidez)
        elsif ($close < $last_low->{price}) {
            if (!$last_choch || $last_choch->{swing_index} != $last_low->{index}) {
                if ($recent_liquidity_event) {
                    $self->_register_choch(
                        type            => 'CHOCH',
                        direction       => 'BEARISH',
                        break_index     => $candle_index,
                        break_price     => $close,
                        swing_index     => $last_low->{index},
                        liquidity_event => $recent_liquidity_event,
                        timestamp       => $candle->{timestamp},
                        swing           => $last_low
                    );
                }
            }
        }
    }
    # Tendencia Bajista
    elsif ($trend == -1) { 
        # Detección de BOS Bajista
        if ($close < $last_low->{price}) {
            if (!$last_bos || $last_bos->{swing_index} != $last_low->{index}) {
                $self->_register_bos(
                    type        => 'BOS',
                    direction   => 'BEARISH',
                    break_index => $candle_index,
                    break_price => $close,
                    swing_index => $last_low->{index},
                    timestamp   => $candle->{timestamp},
                    swing       => $last_low
                );
            }
        }
        # Detección de CHOCH Alcista
        elsif ($close > $last_high->{price}) {
            if (!$last_choch || $last_choch->{swing_index} != $last_high->{index}) {
                if ($recent_liquidity_event) {
                    $self->_register_choch(
                        type            => 'CHOCH',
                        direction       => 'BULLISH',
                        break_index     => $candle_index,
                        break_price     => $close,
                        swing_index     => $last_high->{index},
                        liquidity_event => $recent_liquidity_event,
                        timestamp       => $candle->{timestamp},
                        swing           => $last_high
                    );
                }
            }
        }
    }
}



sub _build_event_weight {
    my ($self, $event) = @_;
    
    # Extraer el índice independientemente del tipo de evento (FVG, BOS o CHOCH)
    my $index = $event->{break_index} || $event->{created_index} || $event->{index} || 0;
    
    # 1. Volumen (Arquitectura preparada para multi-temporalidad)
    my $candle = $self->{market_data}->get_candle($index);
    my $volume_score = $candle ? ($candle->{volume} || 0) : 0;
    
    # 2. Liquidez
    my $liquidity_score = 1.0;
    my $ctx = $self->{liquidity_context};
    # Un respaldo de liquidez reciente incrementa ligeramente el peso estructural
    if ($ctx->{last_sweep} || $ctx->{last_grab} || $ctx->{last_run}) {
        $liquidity_score += 0.5;
    }
    
    # 3. ATR (Volatilidad)
    my $atr_score = 1.0;
    if ($self->{atr_indicator}) {
        my $atr_values = $self->{atr_indicator}->get_values();
        if ($atr_values && $atr_values->[$index]) {
            $atr_score = $atr_values->[$index];
        }
    }
    
    # 4. Timeframe
    my $timeframe_score = 1.0; 
    
    # Cálculo final
    # Previene división por cero en caso de falta de datos de ATR
    my $safe_atr = $atr_score > 0 ? $atr_score : 1; 
    my $final_weight = ($volume_score * $liquidity_score * $timeframe_score) / $safe_atr;
    
    return {
        volume_score    => $volume_score,
        liquidity_score => $liquidity_score,
        timeframe_score => $timeframe_score,
        atr_score       => $atr_score,
        final_weight    => $final_weight,
    };
}

sub _register_fvg {
    my ($self, %args) = @_;

    my $ctx = $self->{liquidity_context};
    my $recent_liq = $ctx->{last_sweep} || $ctx->{last_grab} || $ctx->{last_run};
    
    my $high_reaction = 0;
    my $proximity_threshold = $self->{settings}{fvg_reaction_threshold} || 5; 
    
    if ($recent_liq && abs($args{created_index} - $recent_liq->{index}) <= $proximity_threshold) {
        $high_reaction = 1;
    }

    my $fvg = {
        type          => $args{type},
        direction     => $args{direction} || $args{type},
        top           => $args{top},
        bottom        => $args{bottom},
        created_index => $args{created_index},
        timestamp     => $args{timestamp},
        state         => 'ACTIVE',
        high_reaction => $high_reaction,
    };
    

    $fvg->{weight} = $self->_build_event_weight($fvg);
    
    push @{$self->{fvg_list}}, $fvg;
    push @{$self->{active_fvg}}, $fvg;
    
    push @{$self->{runtime}{pending_events}}, $fvg;
    $self->{runtime}{dirty} = 1;
}

sub _register_bos {
    my ($self, %args) = @_;
    my $bos_object = {
        type        => $args{type},
        direction   => $args{direction},
        break_index => $args{break_index},
        break_price => $args{break_price},
        swing_index => $args{swing_index},
        timestamp   => $args{timestamp} || $self->{market_data}->get_timestamp($args{break_index}),
    };

    $bos_object->{weight} = $self->_build_event_weight($bos_object);

    # Actualización del estado interno
    $self->{market_structure}{last_bos}              = $bos_object;
    $self->{market_structure}{last_structural_swing} = $args{swing};
    $self->{market_structure}{trend}                 = $args{direction} eq 'BULLISH' ? 1 : -1;
    
    push @{$self->{bos_list}}, $bos_object;
    push @{$self->{runtime}{pending_events}}, $bos_object;
    $self->{runtime}{dirty} = 1;
}

sub _register_choch {
    my ($self, %args) = @_;
    my $choch_object = {
        type            => $args{type},
        direction       => $args{direction},
        break_index     => $args{break_index},
        break_price     => $args{break_price},
        swing_index     => $args{swing_index},
        liquidity_event => $args{liquidity_event},
        timestamp       => $args{timestamp} || $self->{market_data}->get_timestamp($args{break_index}),
    };

    $choch_object->{weight} = $self->_build_event_weight($choch_object);

    # Inversión de tendencia y actualización de contexto estructural
    $self->{market_structure}{last_choch}            = $choch_object;
    $self->{market_structure}{last_structural_swing} = $args{swing};
    $self->{market_structure}{trend}                 = $args{direction} eq 'BULLISH' ? 1 : -1;
    
    push @{$self->{choch_list}}, $choch_object;
    push @{$self->{runtime}{pending_events}}, $choch_object;
    $self->{runtime}{dirty} = 1;
}

sub _emit_events {
    my ($self) = @_;
    my $pending = $self->{runtime}{pending_events};
    return unless @$pending;
    
    # Evitar compartir referencias mutables (Shallow Copy) para proteger inmutabilidad en el historial
    my @immutable_pending = map { { %$_ } } @$pending;
    
    # Persistencia cronológica en el historial maestro
    push @{$self->{events}}, @immutable_pending;
    
    # Exposición transitoria para módulos externos
    $self->{latest_anchor_events} = \@immutable_pending;
    
    # Limpieza del ciclo de ejecución
    $self->{runtime}{pending_events} = [];
    $self->{runtime}{dirty}          = 0;
    
    if (exists $self->{runtime}{current_cycle}) {
        $self->{runtime}{current_cycle}++;
    }
}

1;