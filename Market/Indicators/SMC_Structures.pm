# package Market::Indicators::SMC_Structures;

# use strict;
# use warnings;
# use List::Util qw(max min);

# sub new {
#     my ($class, %args) = @_;

#     my $self = {
#         min_fvg_atr_mult   => $args{min_fvg_atr_mult}   || 0.5,
#         min_pivot_strength => $args{min_pivot_strength} || 0.8,

#         min_bootstrap_atr_mult => $args{min_bootstrap_atr_mult} // 0.25,

#         min_bars_after_break => $args{min_bars_after_break} // 2,

#         max_fvg_event_gap_bars => $args{max_fvg_event_gap_bars} // 10,

#         max_pivot_history => $args{max_pivot_history} // 500,

#         # Control incremental
#         processed => {
#             # structural    => 0,
#             # minor         => 0,
#             external      => 0,
#             internal      => 0,
#             candles       => 0,
#             candle_breaks => 0,
#         },

#         # Máquinas de estado unificadas
#         external => _init_structure_state(),
#         internal => _init_structure_state(),

#         events => [],
#         fvgs   => [],

#         # Registro temporal para asignar FVG a eventos estructurales recientes
#         last_event_context => undef,
#     };

#     return bless $self, $class;
# }

# sub _init_structure_state {
#     return {
#         trend          => 'UNKNOWN',

#         protected_high => undef,
#         protected_low  => undef,

#         # Swings Candidatos (El mejor nivel alcanzado mientras la estructura no se rompa)
#         candidate_high => undef,
#         candidate_low  => undef,

#         last_break_idx => -1,
#         history        => [],
#         pivots         => [],
#     };
# }

# sub reset {
#     my ($self) = @_;

#     $self->{processed}          = { external => 0, internal => 0, candles => 0, candle_breaks => 0 };
#     $self->{external}           = _init_structure_state();
#     $self->{internal}           = _init_structure_state();
#     $self->{events}             = [];
#     $self->{fvgs}               = [];
#     $self->{last_event_context} = undef;
# }

# sub update {
#     my ($self, $market_data, $liquidity) = @_;

#     # 1. Procesar nuevos pivots (Actualizan candidatos y límites iniciales)
#     $self->_process_tier_pivots('external', $liquidity->get_structural_pivots());
#     $self->_process_tier_pivots('internal', $liquidity->get_minor_pivots());

#     # 2. Evaluar desplazamiento de precio vela a vela (Dispara BOS / CHOCH con el Close)
#     $self->_evaluate_candle_breaks($market_data, $liquidity);

#     # 3. Detectar y actualizar FVG (Requiere desplazamiento dominante)
#     $self->_detect_fvg($market_data);
#     $self->_update_fvg_state($market_data);
# }

# # --- 1. Gestión de Estructura y Pivots ---

# sub _process_tier_pivots {
#     my ($self, $tier_name, $raw_pivots) = @_;

#     my $state     = $self->{$tier_name};
#     my $start_idx = $self->{processed}->{$tier_name};

#     for my $i ($start_idx .. $#$raw_pivots) {
#         my $pivot = { %{$raw_pivots->[$i]}, tier => $tier_name, label => undef };

#         # Descartar pivots de ruido
#         next unless ($pivot->{strength} // 0) >= $self->{min_pivot_strength};

#         $self->_update_candidates($state, $pivot);

#         if ($state->{trend} eq 'UNKNOWN') {
#             $state->{protected_high} = $state->{candidate_high} if $pivot->{type} eq 'HIGH';
#             $state->{protected_low}  = $state->{candidate_low}  if $pivot->{type} eq 'LOW';
#         }
#         else {
#             if (!$state->{protected_high} && $pivot->{type} eq 'HIGH'
#                     && $pivot->{index} >= $state->{last_break_idx} + $self->{min_bars_after_break}) {
#                 $state->{protected_high} = $state->{candidate_high};
#             }
#             if (!$state->{protected_low} && $pivot->{type} eq 'LOW'
#                     && $pivot->{index} >= $state->{last_break_idx} + $self->{min_bars_after_break}) {
#                 $state->{protected_low} = $state->{candidate_low};
#             }
#         }

#         push @{$state->{pivots}}, $pivot;

#         my $max_hist = $self->{max_pivot_history};
#         if (scalar(@{$state->{pivots}}) > $max_hist) {
#             splice(@{$state->{pivots}}, 0, scalar(@{$state->{pivots}}) - $max_hist);
#         }
#     }

#     $self->{processed}->{$tier_name} = scalar(@$raw_pivots);
# }

# sub _update_candidates {
#     my ($self, $state, $pivot) = @_;

#     if ($pivot->{type} eq 'HIGH') {
#         if (!$state->{candidate_high} || $pivot->{price} > $state->{candidate_high}->{price}) {
#             $state->{candidate_high} = $pivot;
#         }
#     } else {
#         if (!$state->{candidate_low} || $pivot->{price} < $state->{candidate_low}->{price}) {
#             $state->{candidate_low} = $pivot;
#         }
#     }
# }

# # --- 2. Detección de Quiebres (Price Displacement) ---

# sub _evaluate_candle_breaks {
#     my ($self, $market_data, $liquidity) = @_;

#     my $size  = $market_data->size();
#     my $start = $self->{processed}->{candle_breaks};

#     for my $i ($start .. $size - 1) {
#         my $candle = $market_data->get_candle($i);
#         $self->_check_structural_break('external', $self->{external}, $candle, $i, $liquidity, $market_data);
#         $self->_check_structural_break('internal', $self->{internal}, $candle, $i, $liquidity, $market_data);
#     }

#     $self->{processed}->{candle_breaks} = $size;
# }

# sub _check_structural_break {
#     my ($self, $tier, $state, $candle, $idx, $liquidity, $market_data) = @_;

#     my $ph = $state->{protected_high};
#     my $pl = $state->{protected_low};

#     # EVALUACIÓN DE QUIEBRE ALCISTA (Requiere cierre de vela por encima)
#     if ($ph && $candle->{close} > $ph->{price} && $idx > $state->{last_break_idx}) {

#         if ($state->{trend} eq 'UNKNOWN') {
#             my $atr    = $self->_quick_atr($market_data, $idx, 14);
#             my $margin = $atr * $self->{min_bootstrap_atr_mult};
#             return if $candle->{close} <= $ph->{price} + $margin;
#         }

#         my $event_type = $self->_classify_event($tier, $state, 'UP');

#         # El origen se busca SOLO entre los pivots posteriores a la ruptura previa,
#         # sobre una secuencia depurada de runs consecutivos del mismo tipo
#         # (ver _find_originating_swing / _collapse_pivot_runs).
#         my $origin = $self->_find_originating_swing($state->{pivots}, 'LOW', $state->{last_break_idx});
#         $state->{protected_low} = $origin if $origin;

#         # El protected_high queda PENDIENTE: nunca se sustituye por el máximo de
#         # la vela de quiebre. Solo un pivot HIGH confirmado tras esta ruptura
#         # (con el margen mínimo de velas) podrá ocuparlo.
#         $state->{protected_high} = undef;

#         $state->{candidate_high} = undef;
#         $state->{candidate_low}  = undef;

#         $state->{trend}          = 'BULLISH';
#         $state->{last_break_idx} = $idx;

#         $self->_emit_event($tier, $state, $event_type, 'UP', $ph, $idx, $liquidity);
#     }

#     # EVALUACIÓN DE QUIEBRE BAJISTA (Requiere cierre de vela por debajo)
#     elsif ($pl && $candle->{close} < $pl->{price} && $idx > $state->{last_break_idx}) {

#         if ($state->{trend} eq 'UNKNOWN') {
#             my $atr    = $self->_quick_atr($market_data, $idx, 14);
#             my $margin = $atr * $self->{min_bootstrap_atr_mult};
#             return if $candle->{close} >= $pl->{price} - $margin;
#         }

#         my $event_type = $self->_classify_event($tier, $state, 'DOWN');

#         my $origin = $self->_find_originating_swing($state->{pivots}, 'HIGH', $state->{last_break_idx});
#         $state->{protected_high} = $origin if $origin;

#         $state->{protected_low}  = undef;

#         $state->{candidate_low}  = undef;
#         $state->{candidate_high} = undef;

#         $state->{trend}          = 'BEARISH';
#         $state->{last_break_idx} = $idx;

#         $self->_emit_event($tier, $state, $event_type, 'DOWN', $pl, $idx, $liquidity);
#     }
# }

# sub _collapse_pivot_runs {
#     my ($self, $pivots, $since_idx) = @_;
#     $since_idx //= -1;

#     my @clean;
#     for my $p (@$pivots) {
#         next if ($p->{index} // -1) <= $since_idx;

#         if (@clean && $clean[-1]->{type} eq $p->{type}) {
#             if ($p->{type} eq 'HIGH') {
#                 $clean[-1] = $p if $p->{price} > $clean[-1]->{price};
#             } else {
#                 $clean[-1] = $p if $p->{price} < $clean[-1]->{price};
#             }
#         } else {
#             push @clean, $p;
#         }
#     }

#     return \@clean;
# }

# sub _find_originating_swing {
#     my ($self, $pivots, $target_type, $since_idx) = @_;

#     my $clean = $self->_collapse_pivot_runs($pivots, $since_idx);
#     return undef unless @$clean;

#     for (my $i = scalar(@$clean) - 1; $i >= 0; $i--) {
#         return $clean->[$i] if $clean->[$i]->{type} eq $target_type;
#     }
#     return undef;
# }

# sub _classify_event {
#     my ($self, $tier, $state, $direction) = @_;

#     my $target_trend = $direction eq 'UP' ? 'BULLISH' : 'BEARISH';

#     # Continuación de la tendencia ya vigente en este mismo tier -> BOS.
#     return 'BOS' if $state->{trend} eq $target_trend;

#     # Tier externo: cualquier cambio de tendencia es un CHOCH clásico.
#     return 'CHOCH' if $tier eq 'external';

#     # Tier interno: MSS solo tiene sentido como señal temprana de un giro que
#     # la estructura externa aún no refleja.
#     my $ext_trend = $self->{external}->{trend};
#     return 'MSS' if $ext_trend ne $target_trend;

#     return 'CHOCH';
# }

# # --- 3. Sistema de Eventos y Contexto ---

# sub _emit_event {
#     my ($self, $tier, $state, $event_type, $direction, $broken_swing, $idx, $liquidity) = @_;

#     my $liq_ctx = $self->_build_liquidity_context($idx, $liquidity, $direction, $broken_swing);

#     # El prefijo INTERNAL_ aplica a BOS/CHOCH internos; MSS ya es, por
#     # definición, un concepto exclusivamente interno y se deja sin prefijo.
#     my $prefix = ($tier eq 'internal' && $event_type ne 'MSS') ? 'INTERNAL_' : '';
#     my $full_event_type = $prefix . $event_type;

#     my $event_record = {
#         type                => $full_event_type,
#         direction           => $direction,
#         index               => $idx,
#         price               => $broken_swing->{price},
#         tier                => $tier,
#         broken_pivot_index  => $broken_swing->{index} // $idx,
#         trend_after         => $state->{trend},
#         liquidity_context   => $liq_ctx,
#         is_confirmed        => 1,
#     };

#     push @{$self->{events}}, $event_record;

#     # Almacenar referencia temporal para enriquecer el FVG que confirme ser
#     # continuación de este desplazamiento (ver _detect_fvg / Problema 7).
#     $self->{last_event_context} = {
#         type      => $full_event_type,
#         tier      => $tier,
#         index     => $idx,
#         direction => $direction,
#     };
# }

# sub _build_liquidity_context {
#     my ($self, $current_idx, $liquidity, $direction, $broken_swing) = @_;

#     my %ctx = (
#         recent_sweep          => 0,
#         recent_grab           => 0,
#         is_liquidity_induced   => 0,
#         after_sweep            => 0,
#         failed_break_attempts  => 0, # Intrabar sweeps (Failed BOS/CHOCH)
#         active_eq_highs        => 0,
#         active_eq_lows         => 0,
#     );

#     my $resolved = $liquidity->get_resolved_events();

#     for (my $i = scalar(@$resolved) - 1; $i >= 0; $i--) {
#         my $ev = $resolved->[$i];
#         my $dist = $current_idx - $ev->{resolved_index};
#         next if $dist < 0;
#         last if $dist > 15; # Ventana de contexto limitada

#         my $class = $ev->{classification} // '';

#         $ctx{recent_sweep} = 1 if $class eq 'Sweep';
#         $ctx{recent_grab}  = 1 if $class eq 'Grab';

#         if ($class eq 'Sweep' || $class eq 'Grab') {
#             $ctx{after_sweep} = 1;
#             $ctx{is_liquidity_induced} = 1;
#         }

#         if (($direction eq 'UP' && $ev->{type} eq 'BSL' && $class eq 'Sweep') ||
#             ($direction eq 'DOWN' && $ev->{type} eq 'SSL' && $class eq 'Sweep')) {
#             $ctx{failed_break_attempts}++;
#         }
#     }

#     my $eq_levels = $liquidity->get_equal_levels();
#     foreach my $eq (@$eq_levels) {
#         next unless uc($eq->{state}) eq 'ACTIVE';
#         $ctx{active_eq_highs}++ if $eq->{type} eq 'EQH';
#         $ctx{active_eq_lows}++  if $eq->{type} eq 'EQL';
#     }

#     return \%ctx;
# }

# # --- 4. Fair Value Gaps (Con Desplazamiento SMC Real) ---

# sub _detect_fvg {
#     my ($self, $market_data) = @_;

#     my $size  = $market_data->size();
#     my $start = $self->{processed}->{candles};
#     $start = 2 if $start < 2;

#     for my $i ($start .. $size - 1) {
#         my $c1 = $market_data->get_candle($i - 2);
#         my $c2 = $market_data->get_candle($i - 1); # Vela del desplazamiento
#         my $c3 = $market_data->get_candle($i);

#         my $atr = $self->_quick_atr($market_data, $i, 14);

#         my $c2_body = abs($c2->{open} - $c2->{close});
#         next unless $c2_body >= ($atr * 1.2);

#         my $min_gap = $atr * $self->{min_fvg_atr_mult};

#         next if ($c2->{high} <= $c1->{high} && $c2->{low} >= $c1->{low});

#         my $fvg_node = undef;

#         if ($c3->{low} > $c1->{high} && ($c3->{low} - $c1->{high}) >= $min_gap) {
#             $fvg_node = $self->_create_fvg_node('FVG_UP', $i - 1, $c3->{low}, $c1->{high});
#         }
#         elsif ($c3->{high} < $c1->{low} && ($c1->{low} - $c3->{high}) >= $min_gap) {
#             $fvg_node = $self->_create_fvg_node('FVG_DOWN', $i - 1, $c1->{low}, $c3->{high});
#         }

#         if ($fvg_node) {
#             if ($self->{last_event_context}) {
#                 my $ctx = $self->{last_event_context};
#                 my $gap = $i - $ctx->{index};

#                 my $direction_matches =
#                     ($ctx->{direction} eq 'UP'   && $fvg_node->{type} eq 'FVG_UP') ||
#                     ($ctx->{direction} eq 'DOWN' && $fvg_node->{type} eq 'FVG_DOWN');

#                 if ($gap > $self->{max_fvg_event_gap_bars}) {
#                     # El desplazamiento tardó demasiado: se descarta el contexto,
#                     # ya no se considera continuación del evento original.
#                     $self->{last_event_context} = undef;
#                 }
#                 elsif ($direction_matches) {
#                     $fvg_node->{origin_event} = $ctx->{type};
#                     $fvg_node->{tier}         = $ctx->{tier};
#                     $self->{last_event_context} = undef;
#                 }
#                 # Si la dirección no coincide pero seguimos dentro del margen,
#                 # se conserva el contexto por si el FVG correcto aparece después.
#             }
#             push @{$self->{fvgs}}, $fvg_node;
#         }
#     }
#     $self->{processed}->{candles} = $size;
# }

# sub _create_fvg_node {
#     my ($self, $type, $idx, $top, $bottom) = @_;
#     return {
#         type                  => $type,
#         index                 => $idx,
#         top                   => $top,
#         bottom                => $bottom,
#         state                 => 'ACTIVE',
#         mitigation_percentage => 0,
#         first_touch_index     => undef,
#         last_touch_index      => undef,
#         origin_event          => 'NONE', # BOS | CHOCH | MSS | NONE
#         tier                  => 'unknown',
#     };
# }

# sub _update_fvg_state {
#     my ($self, $market_data) = @_;

#     my $size = $market_data->size();
#     my $candle = $market_data->last_candle();
#     return unless $candle;
#     my $curr_idx = $size - 1;

#     foreach my $fvg (@{$self->{fvgs}}) {
#         next if $fvg->{state} eq 'FULLY_MITIGATED' || $fvg->{state} eq 'INVALIDATED';

#         my $gap_size = abs($fvg->{top} - $fvg->{bottom});
#         next if $gap_size == 0;

#         my $penetration = 0;

#         if ($fvg->{type} eq 'FVG_UP') {
#             $fvg->{state} = 'INVALIDATED' if $candle->{close} < $fvg->{bottom};
#             $penetration = $fvg->{top} - $candle->{low} if $candle->{low} < $fvg->{top};
#         }
#         elsif ($fvg->{type} eq 'FVG_DOWN') {
#             $fvg->{state} = 'INVALIDATED' if $candle->{close} > $fvg->{top};
#             $penetration = $candle->{high} - $fvg->{bottom} if $candle->{high} > $fvg->{bottom};
#         }

#         if ($penetration > 0 && $fvg->{state} ne 'INVALIDATED') {
#             $fvg->{first_touch_index} //= $curr_idx;
#             $fvg->{last_touch_index}    = $curr_idx;
#             $fvg->{state}               = 'TOUCHED' if $fvg->{state} eq 'ACTIVE';

#             my $pct = ($penetration / $gap_size) * 100;
#             $fvg->{mitigation_percentage} = max($fvg->{mitigation_percentage}, $pct);

#             if ($fvg->{mitigation_percentage} >= 95) {
#                 $fvg->{state} = 'FULLY_MITIGATED';
#             } elsif ($fvg->{mitigation_percentage} >= 25) {
#                 $fvg->{state} = 'PARTIALLY_MITIGATED';
#             }
#         }
#     }
# }

# sub _quick_atr {
#     my ($self, $md, $current_idx, $period) = @_;
#     my $start = max(1, $current_idx - $period);
#     my $sum = 0; my $count = 0;

#     for my $i ($start .. $current_idx) {
#         my $curr = $md->get_candle($i);
#         my $prev = $md->get_candle($i - 1);
#         my $tr = max(
#             $curr->{high} - $curr->{low},
#             abs($curr->{high} - $prev->{close}),
#             abs($curr->{low} - $prev->{close})
#         );
#         $sum += $tr; $count++;
#     }
#     return $count ? $sum / $count : 0;
# }

# # --- API Pública Estricta (No Modificada) ---

# sub get_external_structure { return $_[0]->{external}->{pivots}; }
# sub get_internal_structure { return $_[0]->{internal}->{pivots}; }
# sub get_events             { return $_[0]->{events}; }
# sub get_fvg                { return $_[0]->{fvgs}; }
# sub get_equal_levels       { return []; } # Evitamos estado duplicado, la API la conserva por compatibilidad pero vacía.

# sub get_latest_events {
#     my ($self, $limit) = @_;
#     $limit //= 5;
#     my @events = @{$self->{events}};
#     return [] unless @events;

#     my $start = max(0, scalar(@events) - $limit);
#     my @latest = @events[$start .. $#events];
#     return \@latest;
# }

# 1;

package Market::Indicators::SMC_Structures;

use strict;
use warnings;
use List::Util qw(max min);

sub new {
    my ($class, %args) = @_;

    my $self = {
        config => {
            min_fvg_atr_mult       => $args{min_fvg_atr_mult}       || 0.5,
            min_pivot_strength     => $args{min_pivot_strength}     || 0.8,
            min_bootstrap_atr_mult => $args{min_bootstrap_atr_mult} // 0.25,
            min_bars_after_break   => $args{min_bars_after_break}   // 2,
            max_fvg_event_gap_bars => $args{max_fvg_event_gap_bars} // 10,
            max_pivot_history      => $args{max_pivot_history}      // 500,
            max_event_history      => $args{max_event_history}      // 500, # Límite añadido para eventos
            max_fvg_history        => $args{max_fvg_history}        // 500, # Límite añadido para FVG
        },
        
        timeframes       => {},
        active_timeframe => '1m',
    };

    bless $self, $class;
    $self->_init_timeframe($self->{active_timeframe});
    
    return $self;
}

sub _init_timeframe {
    my ($self, $tf) = @_;
    return if exists $self->{timeframes}->{$tf};

    $self->{timeframes}->{$tf} = {
        # Control incremental aislado por timeframe
        processed => {
            external      => -1, # Guardará el último índice de vela del pivot procesado
            internal      => -1,
            candles       => 0,  # Guardará el último índice de vela evaluado
            candle_breaks => 0,
        },

        # Máquinas de estado unificadas
        external => _init_structure_state(),
        internal => _init_structure_state(),

        events => [],
        fvgs   => [],

        # Registro temporal para asignar FVG a eventos estructurales recientes
        last_event_context => undef,
    };
}

sub _init_structure_state {
    return {
        trend          => 'UNKNOWN',
        protected_high => undef,
        protected_low  => undef,
        candidate_high => undef,
        candidate_low  => undef,
        last_break_idx => -1,
        pivots         => [], # Se eliminó el campo 'history' sin uso
    };
}

# --- Control de Contexto (Timeframe) ---

sub set_active_timeframe {
    my ($self, $tf) = @_;
    $self->_init_timeframe($tf);
    $self->{active_timeframe} = $tf;
}

sub _get_active_state {
    return $_[0]->{timeframes}->{$_[0]->{active_timeframe}};
}

sub reset {
    my ($self, $tf) = @_;
    
    if ($tf) {
        delete $self->{timeframes}->{$tf};
        $self->_init_timeframe($tf);
    } else {
        $self->{timeframes} = {};
        $self->_init_timeframe($self->{active_timeframe});
    }
}

# --- Procesamiento Principal ---

sub update {
    my ($self, $market_data, $liquidity) = @_;

    my $tf_state = $self->_get_active_state();

    # 1. Procesar nuevos pivots (Actualizan candidatos, límites iniciales y etiquetas HH/HL)
    $self->_process_tier_pivots($tf_state, 'external', $liquidity->get_structural_pivots());
    $self->_process_tier_pivots($tf_state, 'internal', $liquidity->get_minor_pivots());

    # 2. Evaluar desplazamiento de precio vela a vela (Dispara BOS / CHOCH con el Close)
    $self->_evaluate_candle_breaks($tf_state, $market_data, $liquidity);

    # 3. Detectar y actualizar FVG (Requiere desplazamiento dominante)
    $self->_detect_fvg($tf_state, $market_data);
    $self->_update_fvg_state($tf_state, $market_data);
}

# --- 1. Gestión de Estructura y Pivots ---

sub _process_tier_pivots {
    my ($self, $tf_state, $tier_name, $raw_pivots) = @_;

    my $state    = $tf_state->{$tier_name};
    my $last_idx = $tf_state->{processed}->{$tier_name};

    for my $raw_pivot (@$raw_pivots) {
        # Evitar reprocesar pivots si Liquidity recortó su histórico (Tracking basado en index de vela)
        next if $raw_pivot->{index} <= $last_idx;

        # 1° Descartar pivots de ruido según fuerza ANTES de procesar etiquetas
        next unless ($raw_pivot->{strength} // 0) >= $self->{config}->{min_pivot_strength};

        # 2° Asignar la etiqueta de estructura al vuelo solo considerando pivots válidos
        my $label = $self->_determine_structure_label($state->{pivots}, $raw_pivot);
        my $pivot = { %$raw_pivot, tier => $tier_name, label => $label };

        # 3° Almacenar y actualizar contexto
        $self->_update_candidates($state, $pivot);

        if ($state->{trend} eq 'UNKNOWN') {
            $state->{protected_high} = $state->{candidate_high} if $pivot->{type} eq 'HIGH';
            $state->{protected_low}  = $state->{candidate_low}  if $pivot->{type} eq 'LOW';
        }
        else {
            if (!$state->{protected_high} && $pivot->{type} eq 'HIGH'
                    && $pivot->{index} >= $state->{last_break_idx} + $self->{config}->{min_bars_after_break}) {
                $state->{protected_high} = $state->{candidate_high};
            }
            if (!$state->{protected_low} && $pivot->{type} eq 'LOW'
                    && $pivot->{index} >= $state->{last_break_idx} + $self->{config}->{min_bars_after_break}) {
                $state->{protected_low} = $state->{candidate_low};
            }
        }

        push @{$state->{pivots}}, $pivot;

        # Prevención de desborde de memoria independiente de Liquidity
        my $max_hist = $self->{config}->{max_pivot_history};
        if (scalar(@{$state->{pivots}}) > $max_hist) {
            shift @{$state->{pivots}};
        }

        # Actualizamos el puntero de procesados al último index consumido
        $tf_state->{processed}->{$tier_name} = $pivot->{index};
    }
}

sub _determine_structure_label {
    my ($self, $pivots, $new_pivot) = @_;
    
    my $type  = $new_pivot->{type};
    my $price = $new_pivot->{price};

    for (my $i = scalar(@$pivots) - 1; $i >= 0; $i--) {
        if ($pivots->[$i]->{type} eq $type) {
            if ($type eq 'HIGH') {
                return $price > $pivots->[$i]->{price} ? 'HH' : 'LH';
            } else {
                return $price > $pivots->[$i]->{price} ? 'HL' : 'LL';
            }
        }
    }
    
    # Comportamiento por defecto si es el primer pivot detectado del histórico
    return $type eq 'HIGH' ? 'HH' : 'LL';
}

sub _update_candidates {
    my ($self, $state, $pivot) = @_;

    if ($pivot->{type} eq 'HIGH') {
        if (!$state->{candidate_high} || $pivot->{price} > $state->{candidate_high}->{price}) {
            $state->{candidate_high} = $pivot;
        }
    } else {
        if (!$state->{candidate_low} || $pivot->{price} < $state->{candidate_low}->{price}) {
            $state->{candidate_low} = $pivot;
        }
    }
}

# --- 2. Detección de Quiebres (Price Displacement) ---

sub _evaluate_candle_breaks {
    my ($self, $tf_state, $market_data, $liquidity) = @_;

    my $size  = $market_data->size();
    my $start = $tf_state->{processed}->{candle_breaks};

    for my $i ($start .. $size - 1) {
        my $candle = $market_data->get_candle($i);
        $self->_check_structural_break($tf_state, 'external', $tf_state->{external}, $candle, $i, $liquidity, $market_data);
        $self->_check_structural_break($tf_state, 'internal', $tf_state->{internal}, $candle, $i, $liquidity, $market_data);
    }

    $tf_state->{processed}->{candle_breaks} = $size;
}

sub _check_structural_break {
    my ($self, $tf_state, $tier, $state, $candle, $idx, $liquidity, $market_data) = @_;

    my $ph = $state->{protected_high};
    my $pl = $state->{protected_low};

    # EVALUACIÓN DE QUIEBRE ALCISTA (Requiere cierre de vela por encima)
    if ($ph && $candle->{close} > $ph->{price} && $idx > $state->{last_break_idx}) {

        if ($state->{trend} eq 'UNKNOWN') {
            my $atr    = $self->_quick_atr($market_data, $idx, 14);
            my $margin = $atr * $self->{config}->{min_bootstrap_atr_mult};
            return if $candle->{close} <= $ph->{price} + $margin;
        }

        my $event_type = $self->_classify_event($tf_state, $tier, $state, 'UP');

        my $origin = $self->_find_originating_swing($state->{pivots}, 'LOW', $state->{last_break_idx});
        $state->{protected_low} = $origin if $origin;

        $state->{protected_high} = undef;
        $state->{candidate_high} = undef;
        $state->{candidate_low}  = undef;

        $state->{trend}          = 'BULLISH';
        $state->{last_break_idx} = $idx;

        $self->_emit_event($tf_state, $tier, $state, $event_type, 'UP', $ph, $idx, $liquidity);
    }

    # EVALUACIÓN DE QUIEBRE BAJISTA (Requiere cierre de vela por debajo)
    elsif ($pl && $candle->{close} < $pl->{price} && $idx > $state->{last_break_idx}) {

        if ($state->{trend} eq 'UNKNOWN') {
            my $atr    = $self->_quick_atr($market_data, $idx, 14);
            my $margin = $atr * $self->{config}->{min_bootstrap_atr_mult};
            return if $candle->{close} >= $pl->{price} - $margin;
        }

        my $event_type = $self->_classify_event($tf_state, $tier, $state, 'DOWN');

        my $origin = $self->_find_originating_swing($state->{pivots}, 'HIGH', $state->{last_break_idx});
        $state->{protected_high} = $origin if $origin;

        $state->{protected_low}  = undef;
        $state->{candidate_low}  = undef;
        $state->{candidate_high} = undef;

        $state->{trend}          = 'BEARISH';
        $state->{last_break_idx} = $idx;

        $self->_emit_event($tf_state, $tier, $state, $event_type, 'DOWN', $pl, $idx, $liquidity);
    }
}

sub _collapse_pivot_runs {
    my ($self, $pivots, $since_idx) = @_;
    $since_idx //= -1;

    my @clean;
    for my $p (@$pivots) {
        next if ($p->{index} // -1) <= $since_idx;

        if (@clean && $clean[-1]->{type} eq $p->{type}) {
            if ($p->{type} eq 'HIGH') {
                $clean[-1] = $p if $p->{price} > $clean[-1]->{price};
            } else {
                $clean[-1] = $p if $p->{price} < $clean[-1]->{price};
            }
        } else {
            push @clean, $p;
        }
    }

    return \@clean;
}

sub _find_originating_swing {
    my ($self, $pivots, $target_type, $since_idx) = @_;

    my $clean = $self->_collapse_pivot_runs($pivots, $since_idx);
    return undef unless @$clean;

    for (my $i = scalar(@$clean) - 1; $i >= 0; $i--) {
        return $clean->[$i] if $clean->[$i]->{type} eq $target_type;
    }
    return undef;
}

sub _classify_event {
    my ($self, $tf_state, $tier, $state, $direction) = @_;

    my $target_trend = $direction eq 'UP' ? 'BULLISH' : 'BEARISH';

    return 'BOS' if $state->{trend} eq $target_trend;
    return 'CHOCH' if $tier eq 'external';

    my $ext_trend = $tf_state->{external}->{trend};
    return 'MSS' if $ext_trend ne $target_trend;

    return 'CHOCH';
}

# --- 3. Sistema de Eventos y Contexto ---

sub _emit_event {
    my ($self, $tf_state, $tier, $state, $event_type, $direction, $broken_swing, $idx, $liquidity) = @_;

    my $liq_ctx = $self->_build_liquidity_context($idx, $liquidity, $direction, $broken_swing);

    my $prefix = ($tier eq 'internal' && $event_type ne 'MSS') ? 'INTERNAL_' : '';
    my $full_event_type = $prefix . $event_type;

    my $event_record = {
        type                => $full_event_type,
        direction           => $direction,
        index               => $idx,
        price               => $broken_swing->{price},
        tier                => $tier,
        broken_pivot_index  => $broken_swing->{index} // $idx,
        trend_after         => $state->{trend},
        liquidity_context   => $liq_ctx,
        is_confirmed        => 1,
    };

    push @{$tf_state->{events}}, $event_record;
    
    # Prevenir crecimiento infinito del arreglo de eventos
    my $max_ev = $self->{config}->{max_event_history};
    if (scalar(@{$tf_state->{events}}) > $max_ev) {
        shift @{$tf_state->{events}};
    }

    $tf_state->{last_event_context} = {
        type      => $full_event_type,
        tier      => $tier,
        index     => $idx,
        direction => $direction,
    };
}

sub _build_liquidity_context {
    my ($self, $current_idx, $liquidity, $direction, $broken_swing) = @_;

    my %ctx = (
        recent_sweep           => 0,
        recent_grab            => 0,
        is_liquidity_induced   => 0,
        after_sweep            => 0,
        failed_break_attempts  => 0,
        active_eq_highs        => 0,
        active_eq_lows         => 0,
    );

    # Al consultar a Liquidity, los métodos públicos por diseño ya devuelven 
    # la data del active_timeframe y en el caché de velocidad máxima
    my $resolved = $liquidity->get_resolved_events();

    for (my $i = scalar(@$resolved) - 1; $i >= 0; $i--) {
        my $ev = $resolved->[$i];
        my $dist = $current_idx - $ev->{resolved_index};
        next if $dist < 0;
        last if $dist > 15; 

        my $class = $ev->{classification} // '';

        $ctx{recent_sweep} = 1 if $class eq 'Sweep';
        $ctx{recent_grab}  = 1 if $class eq 'Grab';

        if ($class eq 'Sweep' || $class eq 'Grab') {
            $ctx{after_sweep} = 1;
            $ctx{is_liquidity_induced} = 1;
        }

        if (($direction eq 'UP' && $ev->{type} eq 'BSL' && $class eq 'Sweep') ||
            ($direction eq 'DOWN' && $ev->{type} eq 'SSL' && $class eq 'Sweep')) {
            $ctx{failed_break_attempts}++;
        }
    }

    my $eq_levels = $liquidity->get_equal_levels();
    foreach my $eq (@$eq_levels) {
        next unless uc($eq->{state}) eq 'ACTIVE';
        $ctx{active_eq_highs}++ if $eq->{type} eq 'EQH';
        $ctx{active_eq_lows}++  if $eq->{type} eq 'EQL';
    }

    return \%ctx;
}

# --- 4. Fair Value Gaps (Con Desplazamiento SMC Real) ---

sub _detect_fvg {
    my ($self, $tf_state, $market_data) = @_;

    my $size  = $market_data->size();
    my $start = $tf_state->{processed}->{candles};
    $start = 2 if $start < 2;

    for my $i ($start .. $size - 1) {
        my $c1 = $market_data->get_candle($i - 2);
        my $c2 = $market_data->get_candle($i - 1); 
        my $c3 = $market_data->get_candle($i);

        my $atr = $self->_quick_atr($market_data, $i, 14);

        my $c2_body = abs($c2->{open} - $c2->{close});
        next unless $c2_body >= ($atr * 1.2);

        my $min_gap = $atr * $self->{config}->{min_fvg_atr_mult};

        next if ($c2->{high} <= $c1->{high} && $c2->{low} >= $c1->{low});

        my $fvg_node = undef;

        if ($c3->{low} > $c1->{high} && ($c3->{low} - $c1->{high}) >= $min_gap) {
            $fvg_node = $self->_create_fvg_node('FVG_UP', $i - 1, $c3->{low}, $c1->{high});
        }
        elsif ($c3->{high} < $c1->{low} && ($c1->{low} - $c3->{high}) >= $min_gap) {
            $fvg_node = $self->_create_fvg_node('FVG_DOWN', $i - 1, $c1->{low}, $c3->{high});
        }

        if ($fvg_node) {
            if ($tf_state->{last_event_context}) {
                my $ctx = $tf_state->{last_event_context};
                my $gap = $i - $ctx->{index};

                my $direction_matches =
                    ($ctx->{direction} eq 'UP'   && $fvg_node->{type} eq 'FVG_UP') ||
                    ($ctx->{direction} eq 'DOWN' && $fvg_node->{type} eq 'FVG_DOWN');

                if ($gap > $self->{config}->{max_fvg_event_gap_bars}) {
                    $tf_state->{last_event_context} = undef;
                }
                elsif ($direction_matches) {
                    $fvg_node->{origin_event} = $ctx->{type};
                    $fvg_node->{tier}         = $ctx->{tier};
                    $tf_state->{last_event_context} = undef;
                }
            }
            
            push @{$tf_state->{fvgs}}, $fvg_node;
            
            # Prevenir crecimiento infinito del arreglo de FVGs
            my $max_fvg = $self->{config}->{max_fvg_history};
            if (scalar(@{$tf_state->{fvgs}}) > $max_fvg) {
                shift @{$tf_state->{fvgs}};
            }
        }
    }
    $tf_state->{processed}->{candles} = $size;
}

sub _create_fvg_node {
    my ($self, $type, $idx, $top, $bottom) = @_;
    return {
        type                  => $type,
        index                 => $idx,
        top                   => $top,
        bottom                => $bottom,
        state                 => 'ACTIVE',
        mitigation_percentage => 0,
        first_touch_index     => undef,
        last_touch_index      => undef,
        origin_event          => 'NONE', 
        tier                  => 'unknown',
    };
}

sub _update_fvg_state {
    my ($self, $tf_state, $market_data) = @_;

    my $size = $market_data->size();
    my $candle = $market_data->last_candle();
    return unless $candle;
    my $curr_idx = $size - 1;

    foreach my $fvg (@{$tf_state->{fvgs}}) {
        next if $fvg->{state} eq 'FULLY_MITIGATED' || $fvg->{state} eq 'INVALIDATED';

        my $gap_size = abs($fvg->{top} - $fvg->{bottom});
        next if $gap_size == 0;

        my $penetration = 0;

        if ($fvg->{type} eq 'FVG_UP') {
            $fvg->{state} = 'INVALIDATED' if $candle->{close} < $fvg->{bottom};
            $penetration = $fvg->{top} - $candle->{low} if $candle->{low} < $fvg->{top};
        }
        elsif ($fvg->{type} eq 'FVG_DOWN') {
            $fvg->{state} = 'INVALIDATED' if $candle->{close} > $fvg->{top};
            $penetration = $candle->{high} - $fvg->{bottom} if $candle->{high} > $fvg->{bottom};
        }

        if ($penetration > 0 && $fvg->{state} ne 'INVALIDATED') {
            $fvg->{first_touch_index} //= $curr_idx;
            $fvg->{last_touch_index}    = $curr_idx;
            $fvg->{state}               = 'TOUCHED' if $fvg->{state} eq 'ACTIVE';

            my $pct = ($penetration / $gap_size) * 100;
            $fvg->{mitigation_percentage} = max($fvg->{mitigation_percentage}, $pct);

            if ($fvg->{mitigation_percentage} >= 95) {
                $fvg->{state} = 'FULLY_MITIGATED';
            } elsif ($fvg->{mitigation_percentage} >= 25) {
                $fvg->{state} = 'PARTIALLY_MITIGATED';
            }
        }
    }
}

sub _quick_atr {
    my ($self, $md, $current_idx, $period) = @_;
    my $start = max(1, $current_idx - $period);
    my $sum = 0; my $count = 0;

    for my $i ($start .. $current_idx) {
        my $curr = $md->get_candle($i);
        my $prev = $md->get_candle($i - 1);
        my $tr = max(
            $curr->{high} - $curr->{low},
            abs($curr->{high} - $prev->{close}),
            abs($curr->{low} - $prev->{close})
        );
        $sum += $tr; $count++;
    }
    return $count ? $sum / $count : 0;
}

# --- API Pública Estricta (Actúa sobre Active Timeframe) ---

sub get_external_structure { return $_[0]->_get_active_state()->{external}->{pivots}; }
sub get_internal_structure { return $_[0]->_get_active_state()->{internal}->{pivots}; }
sub get_events             { return $_[0]->_get_active_state()->{events}; }
sub get_fvg                { return $_[0]->_get_active_state()->{fvgs}; }
sub get_equal_levels       { return []; } # Evitamos estado duplicado, la API la conserva por compatibilidad pero vacía.

sub get_latest_events {
    my ($self, $limit) = @_;
    $limit //= 5;
    
    my $events_ref = $self->_get_active_state()->{events};
    return [] unless @$events_ref;

    my $start = max(0, scalar(@$events_ref) - $limit);
    my @latest = @$events_ref[$start .. $#$events_ref];
    return \@latest;
}

1;