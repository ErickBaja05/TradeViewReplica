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
        period      => $period || 14,
        values      => [],
        tr_sum      => 0,
        tr_count    => 0,
        prev_close  => 0,
        last_atr    => 0,
        wilder_phase=> 0
    };
    bless $self, $class;
    return $self;
}

# Actualiza el ATR con la última vela
# Implementa cálculo incremental
sub update_last
{
    my ($self, $market_data) = @_;
    my $size = $market_data->size();
    return if $size == 0;

    # informacion de la ultima vela
    my $candle = $market_data->last_candle();
    my $high = $candle->{high};
    my $low = $candle->{low};
    my $close = $candle->{close};

    # Calcular true range
    my $tr;
    if (not defined $self->{prev_close})
    {
        # Primera vela
        $tr = $high - $close;
    }
    else
    {
        # Demas velas
        my $highlow = $high - $low;
        my $highclose = abs($high - $self->{prev_close});
        my $lowclose = abs($low - $self->{prev_close});

        $tr = $highlow;
        $tr = $highclose if $highclose > $tr;
        $tr = $lowclose if $lowclose > $tr;
    }

    $self->{prev_close} = $close;
    my $period = $self->{period};

    # Calcular ATR antes de completar el periodo
    if (not $self->{wilder_phase})
    {
        $self->{tr_sum} += $tr;
        $self->{tr_count} += 1;
        push @{$self->{values}}, undef;

        # Cuando se complete el periodo obtener el ATR inicial
        if ($self->{tr_count} >= $period)
        {
            my $first_atr = $self->{tr_sum} / $period;
            my $start = scalar(@{$self->{values}}) - $period;
            for my $i ($start .. $#{$self->{values}})
            {
                $self->{values}[$i] = $first_atr;
            }
            $self->{last_atr} = $first_atr;
            $self->{wilder_phase} = 1;
        }
        
    }else
        {
            # Calcular ATR despues del periodo (fase wilder)
            my $atr = ($self->{last_atr} * ($period - 1) + $tr) / $period;
            push @{$self->{values}}, $atr;
            $self->{last_atr} = $atr
        }
}

# Devuelve serie completa del ATR
sub get_values
{
    my ($self) = @_;

    return $self->{values};
}

# Recalcula la serie completa de ATR desde cero para la temporalidad
# actualmente activa en $market_data. Es necesario porque el cálculo
# incremental de update_last() sólo conoce la última vela agregada, y al
# cambiar de temporalidad (1m/5m/15m) el historial completo debe rehacerse
# para que los indicadores derivados (Liquidez, SMC) trabajen con una serie
# de ATR coherente con la nueva cantidad de velas.
sub recompute_all
{
    my ($self, $market_data) = @_;
    return unless $market_data;

    $self->reset();

    my $last_index = $market_data->last_index();
    return if $last_index < 0;

    my $data = $market_data->get_slice(0, $last_index);
    my $period = $self->{period};

    my @tr;

    for my $i (0 .. $#$data) {
        my $candle = $data->[$i];
        my $tr;

        if ($i == 0) {
            $tr = $candle->{high} - $candle->{low};
        } else {
            my $prev_close = $data->[$i - 1]->{close};
            my $highlow    = $candle->{high} - $candle->{low};
            my $highclose  = abs($candle->{high} - $prev_close);
            my $lowclose   = abs($candle->{low}  - $prev_close);

            $tr = $highlow;
            $tr = $highclose if $highclose > $tr;
            $tr = $lowclose  if $lowclose  > $tr;
        }

        push @tr, $tr;

        if ($i < $period - 1) {
            push @{$self->{values}}, undef;
        } elsif ($i == $period - 1) {
            my $sum = 0;
            $sum += $_ for @tr[0 .. $period - 1];
            my $first_atr = $sum / $period;
            push @{$self->{values}}, $first_atr;
            $self->{last_atr} = $first_atr;
        } else {
            my $atr = ($self->{last_atr} * ($period - 1) + $tr) / $period;
            push @{$self->{values}}, $atr;
            $self->{last_atr} = $atr;
        }
    }

    $self->{prev_close}   = $data->[-1]->{close};
    $self->{wilder_phase} = 1;
}

# Reinicia el indicador
sub reset
{
    my ($self) = @_;
    $self->{values} = [];
    $self->{tr_sum} = 0;
    $self->{tr_count} = 0;
    $self->{prev_close} = undef;
    $self->{last_atr} = undef;
    $self->{wilder_phase} = 0;
}
1;