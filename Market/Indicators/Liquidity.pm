# package Market::Indicators::Liquidity;

# use strict;
# use warnings;

# sub new {
#     my ($class, %args) = @_;

#     my $self = {
#         atr_period     => $args{atr_period}     || 14,
#         eq_tolerance   => $args{eq_tolerance}   || 0.10,
#         confirm_bars   => $args{confirm_bars}   || 3,
#         min_bars_pivot => $args{min_bars_pivot} || 2,
        
#         tiers => {
#             structural => _init_tier('structural', $args{atr_multiplier} || 4.0),
#             minor      => _init_tier('minor', $args{minor_atr_mult} || 1.5),
#         },

#         liquidity_events => [],
#         equal_levels     => [],
#     };

#     return bless $self, $class;
# }

# sub _init_tier {
#     my ($name, $mult) = @_;
#     return {
#         name       => $name,
#         mult       => $mult,
#         trend      => 'UNKNOWN',
#         cand_h     => undef,
#         cand_l     => undef,
#         last_pivot => undef,
#         pivots     => [],
#     };
# }

# sub reset {
#     my ($self) = @_;
    
#     foreach my $tier (values %{$self->{tiers}}) {
#         $tier->{trend}      = 'UNKNOWN';
#         $tier->{cand_h}     = undef;
#         $tier->{cand_l}     = undef;
#         $tier->{last_pivot} = undef;
#         $tier->{pivots}     = [];
#     }
    
#     $self->{liquidity_events} = [];
#     $self->{equal_levels}     = [];
# }

# sub update_last {
#     my ($self, $market_data) = @_;
    
#     my $size = $market_data->size();
#     return if $size == 0;

#     my $current_index = $size - 1;
#     my $candle = $market_data->get_candle($current_index);
#     return unless $candle;

#     my $atr = $self->_compute_atr($market_data);
#     return if $atr <= 0;

#     $self->_process_tier($self->{tiers}->{minor}, $candle, $atr, $current_index);
#     $self->_process_tier($self->{tiers}->{structural}, $candle, $atr, $current_index);
    
#     $self->_update_equal_levels($candle, $current_index);
#     $self->_update_liquidity_events($candle, $current_index);
# }

# # --- Motor Central ZigZag ---

# sub _process_tier {
#     my ($self, $tier, $bar, $atr, $index) = @_;
    
#     my $threshold = $atr * $tier->{mult};

#     if ($tier->{trend} eq 'UNKNOWN') {
#         $self->_bootstrap_trend($tier, $bar, $atr, $index, $threshold);
#     } 
#     elsif ($tier->{trend} eq 'UP') {
#         $self->_handle_uptrend($tier, $bar, $atr, $index, $threshold);
#     } 
#     elsif ($tier->{trend} eq 'DOWN') {
#         $self->_handle_downtrend($tier, $bar, $atr, $index, $threshold);
#     }
# }

# sub _bootstrap_trend {
#     my ($self, $tier, $bar, $atr, $index, $threshold) = @_;

#     $tier->{cand_h} //= _create_candidate('HIGH', $bar->{high}, $index, $atr, $tier->{name});
#     $tier->{cand_l} //= _create_candidate('LOW', $bar->{low}, $index, $atr, $tier->{name});

#     $self->_extend_candidate($tier->{cand_h}, $bar->{high}, $index, $atr) if $bar->{high} > $tier->{cand_h}->{price};
#     $self->_extend_candidate($tier->{cand_l}, $bar->{low}, $index, $atr)  if $bar->{low}  < $tier->{cand_l}->{price};

#     my $dist_down = $tier->{cand_h}->{price} - $bar->{low};
#     my $dist_up   = $bar->{high} - $tier->{cand_l}->{price};

#     if ($dist_down >= $threshold) {
#         $self->_confirm_pivot($tier, $tier->{cand_h}, $index);
#         $tier->{trend}  = 'DOWN';
#         $tier->{cand_l} = _create_candidate('LOW', $bar->{low}, $index, $atr, $tier->{name});
#         $tier->{cand_h} = undef;
#     } 
#     elsif ($dist_up >= $threshold) {
#         $self->_confirm_pivot($tier, $tier->{cand_l}, $index);
#         $tier->{trend}  = 'UP';
#         $tier->{cand_h} = _create_candidate('HIGH', $bar->{high}, $index, $atr, $tier->{name});
#         $tier->{cand_l} = undef;
#     }
# }

# sub _handle_uptrend {
#     my ($self, $tier, $bar, $atr, $index, $threshold) = @_;
    
#     # 1. Extensión del candidato
#     if ($bar->{high} > $tier->{cand_h}->{price}) {
#         $self->_extend_candidate($tier->{cand_h}, $bar->{high}, $index, $atr);
#     }
    
#     # 2. Evaluación de reversión (usando Low para máxima amplitud adversa)
#     my $reversal = $tier->{cand_h}->{price} - $bar->{low};
#     my $bars_lapsed = $index - $tier->{cand_h}->{index};
    
#     if ($reversal >= $threshold && $self->_meets_min_bars($tier, $tier->{cand_h})) {
#         $self->_confirm_pivot($tier, $tier->{cand_h}, $index);
#         $tier->{trend}  = 'DOWN';
#         $tier->{cand_l} = _create_candidate('LOW', $bar->{low}, $index, $atr, $tier->{name});
#         $tier->{cand_h} = undef;
#     }
# }

# sub _handle_downtrend {
#     my ($self, $tier, $bar, $atr, $index, $threshold) = @_;
    
#     # 1. Extensión del candidato
#     if ($bar->{low} < $tier->{cand_l}->{price}) {
#         $self->_extend_candidate($tier->{cand_l}, $bar->{low}, $index, $atr);
#     }
    
#     # 2. Evaluación de reversión (usando High para máxima amplitud adversa)
#     my $reversal = $bar->{high} - $tier->{cand_l}->{price};
    
#     if ($reversal >= $threshold && $self->_meets_min_bars($tier, $tier->{cand_l})) {
#         $self->_confirm_pivot($tier, $tier->{cand_l}, $index);
#         $tier->{trend}  = 'UP';
#         $tier->{cand_h} = _create_candidate('HIGH', $bar->{high}, $index, $atr, $tier->{name});
#         $tier->{cand_l} = undef;
#     }
# }

# sub _meets_min_bars {
#     my ($self, $tier, $candidate) = @_;
#     return 1 unless defined $tier->{last_pivot};
#     return ($candidate->{index} - $tier->{last_pivot}->{index}) >= $self->{min_bars_pivot};
# }

# sub _create_candidate {
#     my ($type, $price, $index, $atr, $tier_name) = @_;
#     return {
#         type  => $type,
#         price => $price,
#         index => $index,
#         atr   => $atr,
#         tier  => $tier_name,
#     };
# }

# sub _extend_candidate {
#     my ($self, $candidate, $new_price, $new_index, $new_atr) = @_;
#     $candidate->{price} = $new_price;
#     $candidate->{index} = $new_index;
#     $candidate->{atr}   = $new_atr;
# }

# sub _confirm_pivot {
#     my ($self, $tier, $candidate, $confirmed_at_index) = @_;
    
#     # Metadatos analíticos para SMC_Structures
#     my $bars_since = defined $tier->{last_pivot} ? ($candidate->{index} - $tier->{last_pivot}->{index}) : 0;
#     my $rev_dist   = defined $tier->{last_pivot} ? abs($candidate->{price} - $tier->{last_pivot}->{price}) : 0;
#     my $atr_dist   = $candidate->{atr} > 0 ? ($rev_dist / $candidate->{atr}) : 0;
    
#     my $pivot = {
#         %$candidate,
#         confirmed_at      => $confirmed_at_index,
#         bars_since_last   => $bars_since,
#         reversal_distance => $rev_dist,
#         atr_distance      => $atr_dist,
#         strength          => $atr_dist * ($bars_since > 0 ? log($bars_since + 1) : 1),
#     };
    
#     push @{$tier->{pivots}}, $pivot;
#     $tier->{last_pivot} = $pivot;
    
#     if ($tier->{name} eq 'structural') {
#         $self->_register_structural_liquidity($pivot);
#     } else {
#         $self->_detect_equal_levels($pivot);
#     }
# }

# # --- Eventos de Liquidez Estructural ---

# sub _register_structural_liquidity {
#     my ($self, $pivot) = @_;
    
#     my $liq_type = $pivot->{type} eq 'HIGH' ? 'BSL' : 'SSL';
    
#     push @{$self->{liquidity_events}}, {
#         type           => $liq_type,
#         state          => 'DETECTED',
#         index          => $pivot->{index},
#         price          => $pivot->{price},
#         tier           => 'structural',
#         created_index  => $pivot->{index},
#         swept_index    => undef,
#         resolved_index => undef,
#         classification => undef,
#         outside_count  => 0,
#     };
# }

# sub _update_liquidity_events {
#     my ($self, $candle, $current_index) = @_;

#     foreach my $event (@{$self->{liquidity_events}}) {
#         next if $event->{state} eq 'RESOLVED';

#         if ($event->{state} eq 'DETECTED') {
#             $self->_check_event_sweep($event, $candle, $current_index);
#         } else {
#             $self->_resolve_event_status($event, $candle, $current_index);
#         }
#     }
# }

# sub _check_event_sweep {
#     my ($self, $event, $candle, $current_index) = @_;
#     my $price = $event->{price};

#     if ($event->{type} eq 'BSL' && $candle->{high} > $price) {
#         $event->{state}       = 'SWEPT';
#         $event->{swept_index} = $current_index;
#     }
#     elsif ($event->{type} eq 'SSL' && $candle->{low} < $price) {
#         $event->{state}       = 'SWEPT';
#         $event->{swept_index} = $current_index;
#     }
# }

# sub _resolve_event_status {
#     my ($self, $event, $candle, $current_index) = @_;
    
#     my $price = $event->{price};
#     my $bars_after_sweep = $current_index - $event->{swept_index};
#     my $reclaimed = 0;

#     if ($event->{type} eq 'BSL') {
#         $reclaimed = 1 if $candle->{close} < $price;
#     } else {
#         $reclaimed = 1 if $candle->{close} > $price;
#     }

#     if ($reclaimed) {
#         $event->{state}          = 'RECLAIMED';
#         $event->{resolved_index} = $current_index;
        
#         # Diferenciación algorítmica entre Sweep y Grab
#         $event->{classification} = $bars_after_sweep == 0 ? 'Sweep' : 'Grab';
#         $event->{classification} = 'Grab' if $bars_after_sweep > 3; # Si tardó mucho, fue una absorción profunda
        
#         $event->{state} = 'RESOLVED';
#     } else {
#         $event->{state} = 'ACCEPTANCE';
#         $event->{outside_count}++;
        
#         if ($event->{outside_count} >= $self->{confirm_bars}) {
#             $event->{resolved_index} = $current_index;
#             $event->{classification} = 'Run';
#             $event->{state}          = 'RESOLVED';
#         }
#     }
# }

# # --- Agrupación Dinámica de Equal Levels (Zonas) ---

# sub _detect_equal_levels {
#     my ($self, $pivot) = @_;
    
#     my $tolerance = $pivot->{atr} * $self->{eq_tolerance};
#     my $eq_type   = $pivot->{type} eq 'HIGH' ? 'EQH' : 'EQL';

#     # 1. Absorber en zona activa existente
#     foreach my $eql (@{$self->{equal_levels}}) {
#         next if $eql->{type} ne $eq_type || $eql->{state} eq 'RESOLVED'; 
        
#         if ($pivot->{price} <= $eql->{upper_bound} && $pivot->{price} >= $eql->{lower_bound}) {
#             push @{$eql->{touches}}, $pivot;
#             $eql->{last_touch} = $pivot->{index};
#             return;
#         }
#     }

#     # 2. Formar nueva zona
#     my $pivots = $self->{tiers}->{minor}->{pivots};
#     my $lookback_limit = 15;
#     my $checked = 0;

#     for (my $i = scalar(@$pivots) - 2; $i >= 0; $i--) {
#         my $prev = $pivots->[$i];
#         next if $prev->{type} ne $pivot->{type};

#         if (abs($pivot->{price} - $prev->{price}) <= $tolerance) {
#             my $avg_price = ($pivot->{price} + $prev->{price}) / 2;
            
#             push @{$self->{equal_levels}}, {
#                 type        => $eq_type,
#                 price       => $avg_price,
#                 upper_bound => $avg_price + ($tolerance / 2),
#                 lower_bound => $avg_price - ($tolerance / 2),
#                 touches     => [$prev, $pivot],
#                 last_touch  => $pivot->{index},
#                 state       => 'ACTIVE',
#             };
#             last;
#         }
#         last if ++$checked >= $lookback_limit;
#     }
# }

# sub _update_equal_levels {
#     my ($self, $candle, $current_index) = @_;

#     foreach my $eql (@{$self->{equal_levels}}) {
#         next if $eql->{state} eq 'RESOLVED';

#         if ($eql->{state} eq 'ACTIVE') {
#             if ($eql->{type} eq 'EQH' && $candle->{high} > $eql->{upper_bound}) {
#                 $eql->{state} = 'SWEPT';
#             } elsif ($eql->{type} eq 'EQL' && $candle->{low} < $eql->{lower_bound}) {
#                 $eql->{state} = 'SWEPT';
#             }
#         } 
#         elsif ($eql->{state} eq 'SWEPT') {
#             # Se resuelve si el precio cierra claramente al otro lado de la zona
#             if ($eql->{type} eq 'EQH' && $candle->{close} > $eql->{upper_bound}) {
#                 $eql->{state} = 'RESOLVED';
#             } elsif ($eql->{type} eq 'EQL' && $candle->{close} < $eql->{lower_bound}) {
#                 $eql->{state} = 'RESOLVED';
#             }
#         }
#     }
# }

# sub _compute_atr {
#     my ($self, $market_data) = @_;
    
#     my $period = $self->{atr_period};
#     my $size   = $market_data->size();
#     return 0 if $size < 2;

#     my $start = $size - $period - 1;
#     $start = 0 if $start < 0;

#     my $sum = 0;
#     my $count = 0;

#     for my $idx ($start + 1 .. $size - 1) {
#         my $current  = $market_data->get_candle($idx);
#         my $previous = $market_data->get_candle($idx - 1);
        
#         my $tr = $current->{high} - $current->{low};
#         my $hc = abs($current->{high} - $previous->{close});
#         my $lc = abs($current->{low}  - $previous->{close});

#         $tr = $hc if $hc > $tr;
#         $tr = $lc if $lc > $tr;

#         $sum += $tr;
#         $count++;
#     }

#     return $count ? $sum / $count : 0;
# }

# # --- API Pública Original

# sub get_structural_pivots { return $_[0]->{tiers}->{structural}->{pivots}; }
# sub get_minor_pivots      { return $_[0]->{tiers}->{minor}->{pivots}; }
# sub get_liquidity_events  { return $_[0]->{liquidity_events}; }
# sub get_equal_levels      { return $_[0]->{equal_levels}; }
# sub get_resolved_events   { 
#     my @resolved = grep { $_->{state} eq 'RESOLVED' } @{$_[0]->{liquidity_events}}; 
#     return \@resolved; 
# }

# # --- Nueva API Extendida ---

# sub get_candidate_high {
#     my ($self, $tier_name) = @_;
#     return $self->{tiers}->{$tier_name}->{cand_h};
# }

# sub get_candidate_low {
#     my ($self, $tier_name) = @_;
#     return $self->{tiers}->{$tier_name}->{cand_l};
# }

# 1;

package Market::Indicators::Liquidity;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;

    my $self = {
        config => {
            atr_period        => $args{atr_period}        || 14,
            eq_tolerance      => $args{eq_tolerance}      || 0.10,
            confirm_bars      => $args{confirm_bars}      || 3,
            min_bars_pivot    => $args{min_bars_pivot}    || 2,
            atr_multiplier    => $args{atr_multiplier}    || 4.0,
            minor_atr_mult    => $args{minor_atr_mult}    || 1.5,
            max_history_items => $args{max_history_items} || 1000, # Límite para evitar crecimiento ilimitado
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

    my $cfg = $self->{config};
    
    $self->{timeframes}->{$tf} = {
        tiers => {
            structural => _init_tier('structural', $cfg->{atr_multiplier}),
            minor      => _init_tier('minor', $cfg->{minor_atr_mult}),
        },
        liquidity_events     => [],
        resolved_events      => [], # Caché dedicado para lecturas instantáneas (O(1))
        equal_levels         => [],
        zigzag_segments      => [], # Caché de líneas ya formadas
        
        last_processed_index => -1, # Puntero de memoria incremental
        cached_atr           => 0,
    };
}

sub _init_tier {
    my ($name, $mult) = @_;
    return {
        name       => $name,
        mult       => $mult,
        trend      => 'UNKNOWN',
        cand_h     => undef,
        cand_l     => undef,
        last_pivot => undef,
        pivots     => [],
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

# --- Procesamiento Histórico vs Incremental ---

# Construye o reanuda el cálculo histórico masivo del timeframe activo
sub build_history {
    my ($self, $market_data) = @_;
    
    my $tf_state = $self->_get_active_state();
    my $size = $market_data->size();
    return if $size == 0;

    my $start = $tf_state->{last_processed_index} + 1;
    $start = 0 if $start < 0;

    for my $i ($start .. $size - 1) {
        $self->_process_candle($tf_state, $market_data, $i);
    }
    
    $tf_state->{last_processed_index} = $size - 1;
    $self->_prune_state($tf_state);
}

# Actualiza secuencialmente asumiendo que el histórico ya está construido
sub update_last {
    my ($self, $market_data) = @_;
    
    my $tf_state = $self->_get_active_state();
    my $size = $market_data->size();
    return if $size == 0;

    my $current_index = $size - 1;

    # Auto-sanación: Si estamos demasiado atrasados, delegar a histórico
    if ($tf_state->{last_processed_index} < $current_index - 1) {
        $self->build_history($market_data);
        return;
    }

    # Procesar solo la última vela
    $self->_process_candle($tf_state, $market_data, $current_index);
    $tf_state->{last_processed_index} = $current_index;
    
    $self->_prune_state($tf_state);
}

sub _process_candle {
    my ($self, $tf_state, $market_data, $index) = @_;
    
    my $candle = $market_data->get_candle($index);
    return unless $candle;

    my $atr = $self->_compute_atr_at($market_data, $index);
    return if $atr <= 0;
    
    $tf_state->{cached_atr} = $atr;

    $self->_process_tier($tf_state, $tf_state->{tiers}->{minor}, $candle, $atr, $index);
    $self->_process_tier($tf_state, $tf_state->{tiers}->{structural}, $candle, $atr, $index);
    
    $self->_update_equal_levels($tf_state, $candle, $index);
    $self->_update_liquidity_events($tf_state, $candle, $index);
}

# --- Motor Central ZigZag ---

sub _process_tier {
    my ($self, $tf_state, $tier, $bar, $atr, $index) = @_;
    
    my $threshold = $atr * $tier->{mult};

    if ($tier->{trend} eq 'UNKNOWN') {
        $self->_bootstrap_trend($tf_state, $tier, $bar, $atr, $index, $threshold);
    } 
    elsif ($tier->{trend} eq 'UP') {
        $self->_handle_uptrend($tf_state, $tier, $bar, $atr, $index, $threshold);
    } 
    elsif ($tier->{trend} eq 'DOWN') {
        $self->_handle_downtrend($tf_state, $tier, $bar, $atr, $index, $threshold);
    }
}

sub _bootstrap_trend {
    my ($self, $tf_state, $tier, $bar, $atr, $index, $threshold) = @_;
    
    my $tf_name = $self->{active_timeframe};

    $tier->{cand_h} //= _create_candidate('HIGH', $bar->{high}, $index, $atr, $tier->{name}, $tf_name);
    $tier->{cand_l} //= _create_candidate('LOW', $bar->{low}, $index, $atr, $tier->{name}, $tf_name);

    $self->_extend_candidate($tier->{cand_h}, $bar->{high}, $index, $atr) if $bar->{high} > $tier->{cand_h}->{price};
    $self->_extend_candidate($tier->{cand_l}, $bar->{low}, $index, $atr)  if $bar->{low}  < $tier->{cand_l}->{price};

    my $dist_down = $tier->{cand_h}->{price} - $bar->{low};
    my $dist_up   = $bar->{high} - $tier->{cand_l}->{price};

    if ($dist_down >= $threshold) {
        $self->_confirm_pivot($tf_state, $tier, $tier->{cand_h}, $index);
        $tier->{trend}  = 'DOWN';
        $tier->{cand_l} = _create_candidate('LOW', $bar->{low}, $index, $atr, $tier->{name}, $tf_name);
        $tier->{cand_h} = undef;
    } 
    elsif ($dist_up >= $threshold) {
        $self->_confirm_pivot($tf_state, $tier, $tier->{cand_l}, $index);
        $tier->{trend}  = 'UP';
        $tier->{cand_h} = _create_candidate('HIGH', $bar->{high}, $index, $atr, $tier->{name}, $tf_name);
        $tier->{cand_l} = undef;
    }
}

sub _handle_uptrend {
    my ($self, $tf_state, $tier, $bar, $atr, $index, $threshold) = @_;
    
    if ($bar->{high} > $tier->{cand_h}->{price}) {
        $self->_extend_candidate($tier->{cand_h}, $bar->{high}, $index, $atr);
    }
    
    my $reversal = $tier->{cand_h}->{price} - $bar->{low};
    
    if ($reversal >= $threshold && $self->_meets_min_bars($tier, $tier->{cand_h})) {
        $self->_confirm_pivot($tf_state, $tier, $tier->{cand_h}, $index);
        $tier->{trend}  = 'DOWN';
        $tier->{cand_l} = _create_candidate('LOW', $bar->{low}, $index, $atr, $tier->{name}, $self->{active_timeframe});
        $tier->{cand_h} = undef;
    }
}

sub _handle_downtrend {
    my ($self, $tf_state, $tier, $bar, $atr, $index, $threshold) = @_;
    
    if ($bar->{low} < $tier->{cand_l}->{price}) {
        $self->_extend_candidate($tier->{cand_l}, $bar->{low}, $index, $atr);
    }
    
    my $reversal = $bar->{high} - $tier->{cand_l}->{price};
    
    if ($reversal >= $threshold && $self->_meets_min_bars($tier, $tier->{cand_l})) {
        $self->_confirm_pivot($tf_state, $tier, $tier->{cand_l}, $index);
        $tier->{trend}  = 'UP';
        $tier->{cand_h} = _create_candidate('HIGH', $bar->{high}, $index, $atr, $tier->{name}, $self->{active_timeframe});
        $tier->{cand_l} = undef;
    }
}

sub _meets_min_bars {
    my ($self, $tier, $candidate) = @_;
    return 1 unless defined $tier->{last_pivot};
    return ($candidate->{index} - $tier->{last_pivot}->{index}) >= $self->{config}->{min_bars_pivot};
}

sub _create_candidate {
    my ($type, $price, $index, $atr, $tier_name, $tf_name) = @_;
    return {
        type      => $type,
        price     => $price,
        index     => $index,
        atr       => $atr,
        tier      => $tier_name,
        timeframe => $tf_name,
    };
}

sub _extend_candidate {
    my ($self, $candidate, $new_price, $new_index, $new_atr) = @_;
    $candidate->{price} = $new_price;
    $candidate->{index} = $new_index;
    $candidate->{atr}   = $new_atr;
}

sub _confirm_pivot {
    my ($self, $tf_state, $tier, $candidate, $confirmed_at_index) = @_;
    
    my $bars_since = defined $tier->{last_pivot} ? ($candidate->{index} - $tier->{last_pivot}->{index}) : 0;
    my $rev_dist   = defined $tier->{last_pivot} ? abs($candidate->{price} - $tier->{last_pivot}->{price}) : 0;
    my $atr_dist   = $candidate->{atr} > 0 ? ($rev_dist / $candidate->{atr}) : 0;
    
    # Se consolida toda la información para SMC (Sin inferir etiquetas HH/HL aquí)
    my $pivot = {
        %$candidate,
        confirmed_at      => $confirmed_at_index,
        bars_since_last   => $bars_since,
        reversal_distance => $rev_dist,
        atr_distance      => $atr_dist,
        strength          => $atr_dist * ($bars_since > 0 ? log($bars_since + 1) : 1),
    };
    
    my $prev_pivot = $tier->{last_pivot};
    
    push @{$tier->{pivots}}, $pivot;
    $tier->{last_pivot} = $pivot;
    
    if ($tier->{name} eq 'structural') {
        # Formación de segmentos pre-calculados (Caché ZigZag)
        if ($prev_pivot) {
            push @{$tf_state->{zigzag_segments}}, {
                start_pivot => $prev_pivot,
                end_pivot   => $pivot,
                start_index => $prev_pivot->{index},
                end_index   => $pivot->{index},
            };
        }
        $self->_register_structural_liquidity($tf_state, $pivot);
    } else {
        $self->_detect_equal_levels($tf_state, $pivot);
    }
}

# --- Eventos de Liquidez ---

sub _register_structural_liquidity {
    my ($self, $tf_state, $pivot) = @_;
    
    my $liq_type = $pivot->{type} eq 'HIGH' ? 'BSL' : 'SSL';
    
    push @{$tf_state->{liquidity_events}}, {
        type           => $liq_type,
        state          => 'DETECTED',
        index          => $pivot->{index},
        price          => $pivot->{price},
        tier           => 'structural',
        timeframe      => $pivot->{timeframe},
        created_index  => $pivot->{index},
        swept_index    => undef,
        resolved_index => undef,
        classification => undef,
        outside_count  => 0,
    };
}

sub _update_liquidity_events {
    my ($self, $tf_state, $candle, $current_index) = @_;

    foreach my $event (@{$tf_state->{liquidity_events}}) {
        next if $event->{state} eq 'RESOLVED';

        if ($event->{state} eq 'DETECTED') {
            $self->_check_event_sweep($event, $candle, $current_index);
        } else {
            $self->_resolve_event_status($tf_state, $event, $candle, $current_index);
        }
    }
}

sub _check_event_sweep {
    my ($self, $event, $candle, $current_index) = @_;
    my $price = $event->{price};

    if ($event->{type} eq 'BSL' && $candle->{high} > $price) {
        $event->{state}       = 'SWEPT';
        $event->{swept_index} = $current_index;
    }
    elsif ($event->{type} eq 'SSL' && $candle->{low} < $price) {
        $event->{state}       = 'SWEPT';
        $event->{swept_index} = $current_index;
    }
}

sub _resolve_event_status {
    my ($self, $tf_state, $event, $candle, $current_index) = @_;
    
    my $price = $event->{price};
    my $bars_after_sweep = $current_index - $event->{swept_index};
    my $reclaimed = 0;

    if ($event->{type} eq 'BSL') {
        $reclaimed = 1 if $candle->{close} < $price;
    } else {
        $reclaimed = 1 if $candle->{close} > $price;
    }

    if ($reclaimed) {
        $event->{state}          = 'RECLAIMED';
        $event->{resolved_index} = $current_index;
        
        $event->{classification} = $bars_after_sweep == 0 ? 'Sweep' : 'Grab';
        $event->{classification} = 'Grab' if $bars_after_sweep > 3; 
        
        $event->{state} = 'RESOLVED';
        push @{$tf_state->{resolved_events}}, $event; # Inyectar directo al caché resuelto
    } else {
        $event->{state} = 'ACCEPTANCE';
        $event->{outside_count}++;
        
        if ($event->{outside_count} >= $self->{config}->{confirm_bars}) {
            $event->{resolved_index} = $current_index;
            $event->{classification} = 'Run';
            $event->{state}          = 'RESOLVED';
            push @{$tf_state->{resolved_events}}, $event; # Inyectar directo al caché resuelto
        }
    }
}

# --- Agrupación Dinámica (Equal Levels) ---

sub _detect_equal_levels {
    my ($self, $tf_state, $pivot) = @_;
    
    my $tolerance = $pivot->{atr} * $self->{config}->{eq_tolerance};
    my $eq_type   = $pivot->{type} eq 'HIGH' ? 'EQH' : 'EQL';

    foreach my $eql (@{$tf_state->{equal_levels}}) {
        next if $eql->{type} ne $eq_type || $eql->{state} eq 'RESOLVED'; 
        
        if ($pivot->{price} <= $eql->{upper_bound} && $pivot->{price} >= $eql->{lower_bound}) {
            push @{$eql->{touches}}, $pivot;
            $eql->{last_touch} = $pivot->{index};
            return;
        }
    }

    my $pivots = $tf_state->{tiers}->{minor}->{pivots};
    my $lookback_limit = 15;
    my $checked = 0;

    for (my $i = scalar(@$pivots) - 2; $i >= 0; $i--) {
        my $prev = $pivots->[$i];
        next if $prev->{type} ne $pivot->{type};

        if (abs($pivot->{price} - $prev->{price}) <= $tolerance) {
            my $avg_price = ($pivot->{price} + $prev->{price}) / 2;
            
            push @{$tf_state->{equal_levels}}, {
                type        => $eq_type,
                price       => $avg_price,
                upper_bound => $avg_price + ($tolerance / 2),
                lower_bound => $avg_price - ($tolerance / 2),
                touches     => [$prev, $pivot],
                last_touch  => $pivot->{index},
                state       => 'ACTIVE',
                timeframe   => $pivot->{timeframe},
            };
            last;
        }
        last if ++$checked >= $lookback_limit;
    }
}

sub _update_equal_levels {
    my ($self, $tf_state, $candle, $current_index) = @_;

    foreach my $eql (@{$tf_state->{equal_levels}}) {
        next if $eql->{state} eq 'RESOLVED';

        if ($eql->{state} eq 'ACTIVE') {
            if ($eql->{type} eq 'EQH' && $candle->{high} > $eql->{upper_bound}) {
                $eql->{state} = 'SWEPT';
            } elsif ($eql->{type} eq 'EQL' && $candle->{low} < $eql->{lower_bound}) {
                $eql->{state} = 'SWEPT';
            }
        } 
        elsif ($eql->{state} eq 'SWEPT') {
            if ($eql->{type} eq 'EQH' && $candle->{close} > $eql->{upper_bound}) {
                $eql->{state} = 'RESOLVED';
            } elsif ($eql->{type} eq 'EQL' && $candle->{close} < $eql->{lower_bound}) {
                $eql->{state} = 'RESOLVED';
            }
        }
    }
}

# --- Helpers e Infraestructura ---

# Calcula el ATR en un punto arbitrario del pasado
sub _compute_atr_at {
    my ($self, $market_data, $index) = @_;
    
    my $period = $self->{config}->{atr_period};
    return 0 if $index < 1;

    my $start = $index - $period;
    $start = 0 if $start < 0;

    my $sum = 0;
    my $count = 0;

    for my $i ($start + 1 .. $index) {
        my $curr = $market_data->get_candle($i);
        my $prev = $market_data->get_candle($i - 1);
        
        my $tr = $curr->{high} - $curr->{low};
        my $hc = abs($curr->{high} - $prev->{close});
        my $lc = abs($curr->{low}  - $prev->{close});

        $tr = $hc if $hc > $tr;
        $tr = $lc if $lc > $tr;

        $sum += $tr;
        $count++;
    }

    return $count ? $sum / $count : 0;
}

# Implementación de límite de memoria por ventanas (O(1) incremental)
sub _prune_state {
    my ($self, $tf_state) = @_;
    my $max = $self->{config}->{max_history_items};
    
    my $trim_array = sub {
        my ($arr) = @_;
        while (scalar(@$arr) > $max) {
            shift @$arr;
        }
    };

    $trim_array->($tf_state->{tiers}->{structural}->{pivots});
    $trim_array->($tf_state->{tiers}->{minor}->{pivots});
    $trim_array->($tf_state->{zigzag_segments});
    $trim_array->($tf_state->{liquidity_events});
    $trim_array->($tf_state->{resolved_events});
    $trim_array->($tf_state->{equal_levels});
}

# --- API Pública para Consumo (Siempre en TF Activo) ---

sub get_structural_pivots { return $_[0]->_get_active_state()->{tiers}->{structural}->{pivots}; }
sub get_minor_pivots      { return $_[0]->_get_active_state()->{tiers}->{minor}->{pivots}; }
sub get_liquidity_events  { return $_[0]->_get_active_state()->{liquidity_events}; }
sub get_equal_levels      { return $_[0]->_get_active_state()->{equal_levels}; }

# Cache dedicado para máxima velocidad en render
sub get_resolved_events   { return $_[0]->_get_active_state()->{resolved_events}; }

# Retorna los segmentos ya conectados listos para iterar
sub get_zigzag_segments   { return $_[0]->_get_active_state()->{zigzag_segments}; }

sub get_candidate_high {
    my ($self, $tier_name) = @_;
    return $self->_get_active_state()->{tiers}->{$tier_name}->{cand_h};
}

sub get_candidate_low {
    my ($self, $tier_name) = @_;
    return $self->_get_active_state()->{tiers}->{$tier_name}->{cand_l};
}

1;