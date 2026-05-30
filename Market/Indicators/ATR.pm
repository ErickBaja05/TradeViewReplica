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