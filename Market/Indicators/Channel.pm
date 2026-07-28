package Market::Indicators::Channel;

use strict;
use warnings;

=head1 NAME

Market::Indicators::Channel - Canal de Regresión Lineal (Linear Regression Channel)

Implementación del indicador "Linear Regression Channel" basado en el script
de PineScript de LonesomeTheBlue, simplificado para mostrar únicamente el
canal actual (sin canales rotos).

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        length      => $args{length}      // 100,
        deviation   => $args{deviation}   // 2.0,
        src         => $args{src}         // 'close',

        channel     => undef,
        last_index  => -1,
        cache_key   => undef,
    };

    bless $self, $class;
    return $self;
}

sub set_parameters {
    my ($self, $length, $deviation) = @_;
    
    $self->{length}    = $length    if defined $length    && $length >= 2;
    $self->{deviation} = $deviation if defined $deviation && $deviation > 0;
    
    $self->{cache_key} = undef;
    $self->{channel}   = undef;
}

sub update_last {
    my ($self, $candles, $atr_values, $i) = @_;
    
    return $self->{channel} if !defined $i || $i < 0 || !$candles;
    
    my $len = $self->{length} // 100;
    return $self->{channel} if $i < $len - 1;
    
    my $src = $self->{src} // 'close';
    
    # Obtener los últimos 'len' valores
    my @values;
    for my $j (0 .. $len - 1) {
        my $idx = $i - $len + 1 + $j;
        last if $idx > $i;
        my $c = $candles->[$idx];
        next unless $c;
        push @values, $c->{$src};
    }
    
    return $self->{channel} if scalar(@values) < $len;
    
    # Calcular regresión lineal
    my ($intercept, $slope) = $self->_linear_regression(\@values);
    
    # Calcular desviación estándar de los residuos
    my $dev = $self->_calculate_deviation(\@values, $intercept, $slope);
    
    # --- CALCULAR EXTREMOS DEL CANAL PARA TODO EL RANGO ---
    # El canal se extiende desde x=0 hasta x=len-1
    # y = intercept + slope * x
    
    my $start_idx = $i - $len + 1;
    
    # Valores en el punto inicial (x=0)
    my $y_start_mid   = $intercept;
    my $y_start_upper = $intercept + $dev * $self->{deviation};
    my $y_start_lower = $intercept - $dev * $self->{deviation};
    
    # Valores en el punto final (x=len-1)
    my $y_end_mid     = $intercept + $slope * ($len - 1);
    my $y_end_upper   = $intercept + $slope * ($len - 1) + $dev * $self->{deviation};
    my $y_end_lower   = $intercept + $slope * ($len - 1) - $dev * $self->{deviation};
    
    $self->{channel} = {
        # Línea superior
        upper_start => $y_start_upper,
        upper_end   => $y_end_upper,
        
        # Línea media (regresión)
        mid_start   => $y_start_mid,
        mid_end     => $y_end_mid,
        
        # Línea inferior
        lower_start => $y_start_lower,
        lower_end   => $y_end_lower,
        
        slope       => $slope,
        intercept   => $intercept,
        deviation   => $dev,
        start_index => $start_idx,
        end_index   => $i,
        length      => $len,
    };
    
    $self->{last_index} = $i;
    
    return $self->{channel};
}

sub calculate {
    my ($self, $candles) = @_;
    
    return [] unless $candles && @$candles;
    
    my $len = $self->{length} // 100;
    my $src = $self->{src} // 'close';
    my @results;
    
    for my $i (0 .. $#$candles) {
        if ($i < $len - 1) {
            push @results, undef;
            next;
        }
        
        my @values;
        for my $j (0 .. $len - 1) {
            my $idx = $i - $len + 1 + $j;
            my $c = $candles->[$idx];
            last unless $c;
            push @values, $c->{$src};
        }
        
        next if scalar(@values) < $len;
        
        my ($intercept, $slope) = $self->_linear_regression(\@values);
        my $dev = $self->_calculate_deviation(\@values, $intercept, $slope);
        
        my $start_idx = $i - $len + 1;
        
        push @results, {
            upper_start => $intercept + $dev * $self->{deviation},
            upper_end   => $intercept + $slope * ($len - 1) + $dev * $self->{deviation},
            mid_start   => $intercept,
            mid_end     => $intercept + $slope * ($len - 1),
            lower_start => $intercept - $dev * $self->{deviation},
            lower_end   => $intercept + $slope * ($len - 1) - $dev * $self->{deviation},
            slope       => $slope,
            intercept   => $intercept,
            deviation   => $dev,
            start_index => $start_idx,
            end_index   => $i,
            length      => $len,
        };
    }
    
    return \@results;
}

sub _linear_regression {
    my ($self, $values) = @_;
    
    my $n = scalar(@$values);
    return (0, 0) if $n < 2;
    
    my ($sum_x, $sum_y, $sum_xy, $sum_x2) = (0, 0, 0, 0);
    
    for my $i (0 .. $n - 1) {
        my $x = $i;
        my $y = $values->[$i];
        $sum_x  += $x;
        $sum_y  += $y;
        $sum_xy += $x * $y;
        $sum_x2 += $x * $x;
    }
    
    my $denom = $n * $sum_x2 - $sum_x * $sum_x;
    return (0, 0) if $denom == 0;
    
    my $slope     = ($n * $sum_xy - $sum_x * $sum_y) / $denom;
    my $intercept = ($sum_y - $slope * $sum_x) / $n;
    
    return ($intercept, $slope);
}

sub _calculate_deviation {
    my ($self, $values, $intercept, $slope) = @_;
    
    my $n = scalar(@$values);
    return 0 if $n < 2;
    
    my $sum_sq = 0;
    for my $i (0 .. $n - 1) {
        my $expected = $intercept + $slope * $i;
        my $resid    = $values->[$i] - $expected;
        $sum_sq += $resid * $resid;
    }
    
    return sqrt($sum_sq / $n);
}

sub get_channel {
    my ($self) = @_;
    return $self->{channel};
}

sub get_last_value {
    my ($self) = @_;
    return $self->{channel};
}

1;