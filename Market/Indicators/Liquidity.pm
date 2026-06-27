package Market::Indicators::Liquidity;
use strict;
use warnings;

# =============================================================================
# Market::Indicators::Liquidity
#
# Detecta zonas de liquidez institucional (Buy-Side Liquidity / Sell-Side
# Liquidity) identificando Swing Highs y Swing Lows en el historial de velas.
#
# ARQUITECTURA:
#   Sigue el mismo patrón que Market::Indicators::ATR:
#   - new()         : constructor con parámetros de configuración
#   - update_last() : actualización incremental llamada por IndicatorManager
#   - get_values()  : devuelve la serie completa (requerido por IndicatorManager)
#   - reset()       : reinicio al cambiar de timeframe
#
# ESTADOS DE UNA ZONA (máquina de estados interna):
#   'DETECTED'  -> Swing confirmado, nivel activo, aún no barrido
#   'RESOLVED'  -> Clasificación final: 'GRAB' (rechazo rápido) o 'RUN'
#                  (precio acepta y continúa)
#
# ESTRUCTURA DE CADA ZONA (hashref):
#   type       => 'BSL' (Buy-Side / Swing High) | 'SSL' (Sell-Side / Swing Low)
#   price      => valor del pivote
#   index      => índice global de la vela pivote en market_data
#   state      => 'DETECTED' | 'RESOLVED'
#   resolution => undef | 'GRAB' | 'RUN'
#   swept_at   => índice de vela donde fue barrido (undef si no barrido)
# =============================================================================

sub new {
    my ($class, %args) = @_;
    my $self = {
        atr_period    => $args{atr_period} || 14,
        k_depth       => $args{k_depth}    || 3,
        _zones        => [],    # arrayref de hashrefs de zonas
        _seen_indices => {},    # hash de pivot_idx ya procesados — O(1) lookup
        _candle_count => 0,
        _active_bsl => [],
        _active_ssl => []
    };
    bless $self, $class;
    return $self;
}

# -----------------------------------------------------------------------------
# update_last($market_data)
#
# Llamado por IndicatorManager tras cada vela. Todo el trabajo es O(1) o O(z)
# donde z = número de zonas activas (DETECTED), que en la práctica es pequeño.
# -----------------------------------------------------------------------------
sub update_last {
    my ($self, $market_data) = @_;

    my $size = $market_data->size();
    return if $size == 0;

    $self->{_candle_count} = $size;
    my $k    = $self->{k_depth};
    my $data = $market_data->get_data();

    # --- PASO 1: Detección de pivote en [size - k - 1] ---
    # Necesitamos k velas de confirmación a la derecha, por tanto la candidata
    # es la que está k posiciones antes de la última.
    my $pivot_idx = $size - $k - 1;

    if ($pivot_idx >= $k && !$self->{_seen_indices}{$pivot_idx}) {
        # Marcar inmediatamente para evitar reprocesar este índice
        $self->{_seen_indices}{$pivot_idx} = 1;

        my $is_swing_high = 1;
        my $is_swing_low  = 1;

        for my $j (1 .. $k) {
            if ($data->[$pivot_idx]{high} <= $data->[$pivot_idx - $j]{high} ||
                $data->[$pivot_idx]{high} <= $data->[$pivot_idx + $j]{high}) {
                $is_swing_high = 0;
            }
            if ($data->[$pivot_idx]{low} >= $data->[$pivot_idx - $j]{low} ||
                $data->[$pivot_idx]{low} >= $data->[$pivot_idx + $j]{low}) {
                $is_swing_low = 0;
            }
        }

        if ($is_swing_high) {
        
            my $zone = {
                type       => 'BSL',
                price      => $data->[$pivot_idx]{high},
                index      => $pivot_idx,
                state      => 'DETECTED',
                resolution => undef,
                swept_at   => undef,
            };

            push @{$self->{_zones}}, $zone;
            push @{$self->{_active_bsl}}, $zone;
        }

        if ($is_swing_low) {
        
            my $zone = {
                type       => 'SSL',
                price      => $data->[$pivot_idx]{low},
                index      => $pivot_idx,
                state      => 'DETECTED',
                resolution => undef,
                swept_at   => undef,
            };

            push @{$self->{_zones}}, $zone;
            push @{$self->{_active_ssl}}, $zone;
        }
    }

    # --- PASO 2: Máquina de estados — solo iterar zonas DETECTED ---
    # Al mantener una lista separada de índices activos esto es O(activas),
    # no O(total de zonas).
# --- PASO 2: Resolver únicamente zonas activas ---

my $current     = $data->[$size - 1];
my $current_idx = $size - 1;

return unless $current;

#
# BUY SIDE LIQUIDITY
#

my @remaining_bsl;

for my $zone (@{$self->{_active_bsl}}) {

    if ($current->{high} > $zone->{price}) {

        $zone->{state}      = 'RESOLVED';
        $zone->{swept_at}   = $current_idx;
        $zone->{resolution} =
            ($current->{close} < $zone->{price})
                ? 'GRAB'
                : 'RUN';
    }
    else {
        push @remaining_bsl, $zone;
    }
}

$self->{_active_bsl} = \@remaining_bsl;

#
# SELL SIDE LIQUIDITY
#

my @remaining_ssl;

for my $zone (@{$self->{_active_ssl}}) {

    if ($current->{low} < $zone->{price}) {

        $zone->{state}      = 'RESOLVED';
        $zone->{swept_at}   = $current_idx;
        $zone->{resolution} =
            ($current->{close} > $zone->{price})
                ? 'GRAB'
                : 'RUN';
    }
    else {
        push @remaining_ssl, $zone;
    }
}

$self->{_active_ssl} = \@remaining_ssl;
}

# -----------------------------------------------------------------------------
# get_values() — requerido por IndicatorManager
# -----------------------------------------------------------------------------
sub get_values {
    my ($self) = @_;
    return $self->{_zones};
}

# -----------------------------------------------------------------------------
# calculate_eq_tolerance($atr_value)
# Tolerancia de precio para detectar Equal Highs / Equal Lows.
# -----------------------------------------------------------------------------
sub calculate_eq_tolerance {
    my ($self, $atr_value) = @_;
    return ($atr_value // 0) * 0.10;
}

# -----------------------------------------------------------------------------
# zones_in_window($start, $end)
# Zonas relevantes para la ventana visible actual.
# Zonas DETECTED: siempre incluidas (son niveles activos aunque el pivote
# esté fuera de la ventana).
# Zonas RESOLVED: solo si el pivote o la barrida cayó en ventana.
# -----------------------------------------------------------------------------
sub zones_in_window {
    my ($self, $start, $end) = @_;
    my @visible;
    for my $zone (@{$self->{_zones}}) {
        if ($zone->{state} eq 'DETECTED') {
            push @visible, $zone;
        }
        elsif ($zone->{state} eq 'RESOLVED') {
            my $pivot_in = defined $zone->{index}    && $zone->{index}    >= $start && $zone->{index}    <= $end;
            my $swept_in = defined $zone->{swept_at} && $zone->{swept_at} >= $start && $zone->{swept_at} <= $end;
            push @visible, $zone if $pivot_in || $swept_in;
        }
    }
    return \@visible;
}

# -----------------------------------------------------------------------------
# reset() — llamado por IndicatorManager::reset_all al cambiar TF
# -----------------------------------------------------------------------------
sub reset {
    my ($self) = @_;

    $self->{_zones}        = [];
    $self->{_active_bsl}   = [];
    $self->{_active_ssl}   = [];
    $self->{_seen_indices} = {};
    $self->{_candle_count} = 0;
}

1;