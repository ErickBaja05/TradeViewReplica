package Market::MarketData;

use strict;
use warnings;

sub new {
   my ($class) = @_;

   my $self = {
      timeframe => '1m',
      data => {
         '1m'  => [], '5m'  => [], '15m' => [], '1h' => [], 
         '2h'  => [], '4h'  => [], 'D'   => [], 'W'  => []
      },
      candles => [],
      
      # VARIABLES DEL SISTEMA REPLAY
      replay_mode  => 0,
      replay_index => 0,
   };
   bless $self, $class;
   return $self;
}

# --- CONTROLES DE REPLAY ---

sub set_replay_mode {
    my ($self, $state, $start_index) = @_;
    $self->{replay_mode} = $state;
    if ($state) {
        $self->{replay_index} = defined $start_index ? $start_index : 0;
    } else {
        # Si apagamos el replay, el índice salta al final de los datos reales
        my $array_ref = $self->{data}->{$self->{timeframe}} // [];
        $self->{replay_index} = scalar(@$array_ref) - 1;
    }
}

sub is_replay_active {
    my ($self) = @_;
    return $self->{replay_mode};
}

sub get_replay_index {
    my ($self) = @_;
    return $self->{replay_index};
}

sub step_forward {
    my ($self) = @_;
    return unless $self->{replay_mode};
    my $array_ref = $self->{data}->{$self->{timeframe}} // [];
    my $max_idx = scalar(@$array_ref) - 1;
    if ($self->{replay_index} < $max_idx) {
        $self->{replay_index}++;
        return 1; # Retorna 1 si avanzó
    }
    return 0; # Final de los datos
}

sub step_backward {
    my ($self) = @_;
    return unless $self->{replay_mode};
    if ($self->{replay_index} > 0) {
        $self->{replay_index}--;
        return 1;
    }
    return 0;
}

# --- ACCESO A DATOS (BLINDADOS POR EL REPLAY) ---

sub _active_array {
   my ($self) = @_;
   my $tf = $self->{timeframe} // '1m';
   $self->{data}->{$tf} //= [];

   if ($tf eq '1m' && scalar @{$self->{data}->{'1m'}} == 0 && scalar @{$self->{candles}} > 0) {
      $self->{data}->{'1m'} = $self->{candles};
   }
   return $self->{data}->{$tf};
}

sub get_data {
   my ($self) = @_;
   my $array_ref = $self->_active_array();
   
   # Si estamos en replay, devolvemos solo hasta el índice actual
   if ($self->{replay_mode}) {
       my @sliced = @{$array_ref}[0 .. $self->{replay_index}];
       return \@sliced;
   }
   return $array_ref;
}

sub size {
   my ($self) = @_;
   my $array_ref = $self->_active_array();
   my $total = scalar @{$array_ref};
   
   if ($self->{replay_mode}) {
       return ($self->{replay_index} + 1 > $total) ? $total : $self->{replay_index} + 1;
   }
   return $total;
}

sub last_index {
   my ($self) = @_;
   return $self->size() - 1;
}

sub get_candle {
   my ($self, $index) = @_;
   if (defined $index && $index >= 0 && $index <= $self->last_index()) {
      my $array_ref = $self->_active_array();
      return $array_ref->[$index];
   }
   return undef;
}

sub last_candle {
   my ($self) = @_;
   my $idx = $self->last_index();
   return $self->get_candle($idx);
}

sub get_slice {
   my ($self, $start, $end) = @_;
   my $max_idx = $self->last_index(); # Blindado por Replay
   
   return [] if $max_idx < 0; 
   $start = 0 if !defined $start || $start < 0;
   $end = $max_idx if !defined $end || $end > $max_idx;
   
   return [] if $start > $end;
   
   my $array_ref = $self->_active_array();
   my @slice = @{$array_ref}[$start .. $end];
   
   return \@slice;
}

sub get_timestamp {
   my ($self, $index) = @_;
   my $candle = $self->get_candle($index);
   if (defined $candle && exists $candle->{time}) {
      return $candle->{time};
   }
   return undef;
}




=head2 compute_time_anchors()

Analiza el arreglo de velas activas y calcula puntos estratégicos (anclajes) en la línea de tiempo. 

=cut

sub compute_time_anchors {
   my ($self) = @_;
   my $active_array = $self->_active_array();
   my @raw_anchors;
   
   for my $i (0 .. $#$active_array) {
      my $time_str = $active_array->[$i]->{time};
      
      if (defined $time_str && $time_str =~ /T(\d{2}):(\d{2})/) {
         my $hh = $1;
         my $mm = $2;
         
         push @raw_anchors, {
            index  => $i,
            label  => "$hh:$mm",
            minute => int($mm)
         };
      }
   }
   return \@raw_anchors;
}



=head2 add_candle()

Este método recibe un hash de una vela y lo agrega al arreglo dinámico.

=cut

sub add_candle {
   my ($self, $candle) = @_;
   
   if (defined $candle && ref($candle) eq 'HASH') {
      if ( exists $candle->{time}   &&
            exists $candle->{open}   &&
            exists $candle->{high}   &&
            exists $candle->{low}    &&
            exists $candle->{close}  &&
            exists $candle->{volume} ) {
            
            push @{$self->{candles}}, $candle;
      } else {
         warn "[MarketData Error] Intento de agregar una vela con campos incompletos.\n";
      }
   } else {
      warn "[MarketData Error] El argumento provisto a add_candle no es un Hash válido.\n";
   }
   return $self;
}



=head2 build_tf_candles()

Subrutina encargada de comprimir n velas de 1 minuto en una sola vela de mayor temporalidad, 
alineando matemáticamente el reloj (ej. 00, 15, 30, 45, o inicios de hora/día/semana).

=cut

sub build_tf_candles {
   my ($self, $tf) = @_;

   my $candles_1m = $self->{candles};
   $self->{data}->{$tf} = [];

   return if scalar(@{$candles_1m}) == 0;

   my $current_bucket_time = undef;
   my $current_candle = undef;

   # Recorremos la línea temporal secuencialmente analizando el reloj de cada vela
   for my $candle (@{$candles_1m}) {
      my $time_str = $candle->{time};
      my $bucket_time_str = "";
      
      # Nueva Expresión Regular para desglosar todo: Año, Mes, Día, Hora, Minutos
      if ($time_str =~ /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(.*)$/) {
         my $yyyy = $1;
         my $mo   = $2;
         my $dd   = $3;
         my $hh   = int($4);
         my $min  = int($5);
         my $suffix = $6 || ":00";
         
         # 1. Temporalidades Intradía (Minutos)
         if ($tf eq '5m' || $tf eq '15m') {
             my $block = ($tf eq '5m') ? 5 : 15;
             my $bucket_min = $min - ($min % $block);
             $bucket_time_str = sprintf("%s-%s-%s %02d:%02d%s", $yyyy, $mo, $dd, $hh, $bucket_min, $suffix);
         }
         # 2. Temporalidades Intradía (Horas)
         elsif ($tf eq '1h' || $tf eq '2h' || $tf eq '4h') {
             my $block = ($tf eq '1h') ? 1 : (($tf eq '2h') ? 2 : 4);
             my $bucket_hh = $hh - ($hh % $block);
             $bucket_time_str = sprintf("%s-%s-%s %02d:00:00", $yyyy, $mo, $dd, $bucket_hh);
         }
         # 3. Temporalidades Diarias
         elsif ($tf eq 'D') {
             $bucket_time_str = sprintf("%s-%s-%s 00:00:00", $yyyy, $mo, $dd);
         }
         # 4. Temporalidades Semanales
         elsif ($tf eq 'W') {
             require Time::Moment;
             # Creamos el momento asumiendo UTC para cálculos limpios y rápidos
             my $tm = Time::Moment->from_string("${yyyy}-${mo}-${dd}T00:00:00Z");
             my $dow = $tm->day_of_week; # 1 = Lunes, 7 = Domingo
             
             # Retrocedemos los días necesarios para anclar al Lunes de esa semana
             my $monday = $tm->minus_days($dow - 1);
             $bucket_time_str = sprintf("%04d-%02d-%02d 00:00:00", $monday->year, $monday->month, $monday->day_of_month);
         }
         else {
             warn "[MarketData Error] Temporalidad '$tf' no configurada en build_tf_candles.\n";
             return;
         }
         
         # Lógica de agrupación de la vela ancla
         if (!defined $current_bucket_time || $bucket_time_str ne $current_bucket_time) {
            
            if (defined $current_candle) {
               push @{$self->{data}->{$tf}}, $current_candle;
            }
            
            $current_bucket_time = $bucket_time_str;
            $current_candle = {
               time   => $bucket_time_str,
               open   => 0.0 + $candle->{open},
               high   => 0.0 + $candle->{high},
               low    => 0.0 + $candle->{low},
               close  => 0.0 + $candle->{close},
               volume => 0.0 + $candle->{volume}
            };
         } else {
            # Actualización de extremos si caemos dentro del mismo bloque de tiempo
            $current_candle->{high}  = $candle->{high} if $candle->{high} > $current_candle->{high};
            $current_candle->{low}   = $candle->{low}  if $candle->{low}  < $current_candle->{low};
            $current_candle->{close} = 0.0 + $candle->{close};
            $current_candle->{volume} += 0.0 + $candle->{volume};
         }
      }
   }
   
   # Guardamos la última vela que quedó formándose en memoria
   if (defined $current_candle) {
      push @{$self->{data}->{$tf}}, $current_candle;
   }
}

=head2 build_timeframes()

Construye progresivamente todas las temporalidades superiores a partir de la base 1m.

=cut

sub build_timeframes {
   my ($self) = @_;
   
   if (defined $self->{candles} && scalar @{$self->{candles}} > 0) {
      $self->{data}->{'1m'} = $self->{candles};
   } elsif (defined $self->{data}->{'1m'} && scalar @{$self->{data}->{'1m'}} > 0) {
      $self->{candles} = $self->{data}->{'1m'};
   }

   if (!defined $self->{candles} || scalar @{$self->{candles}} == 0) {
      warn "[MarketData Error] | Build_timeframes: No se encontraron datos base en 'candles' para procesar.\n";
      return $self;
   }

   # Generación en cascada de todas las temporalidades soportadas en el OptionMenu
   $self->build_tf_candles('5m');
   $self->build_tf_candles('15m');
   $self->build_tf_candles('1h');
   $self->build_tf_candles('2h');
   $self->build_tf_candles('4h');
   $self->build_tf_candles('D');
   $self->build_tf_candles('W');

   return $self;
}

sub set_timeframe {
   my ($self, $tf) = @_;
   
   if (defined $tf && exists $self->{data}->{$tf}) {
      $self->{timeframe} = $tf;
   } else {
      warn "[MarketData Error] | SET_TIMEFRAME : La temporalidad '" . ($tf // 'undef') . "' no está soportada.\n";
   }

   return $self;
}

=head2 merge_delta_row()

Gestiona la entrada de datos en tiempo real. 

=cut

sub merge_delta_row {
   my ($self, $row) = @_;
   return $self unless defined $row && ref($row) eq 'HASH' && exists $row->{time};

   my $active_array = $self->_active_array();
   my $last_idx = $self->last_index();

   if ($last_idx >= 0 && $active_array->[$last_idx]->{time} eq $row->{time}) {
      
      my $last_candle = $active_array->[$last_idx];
      
      $last_candle->{high} = $row->{high} if $row->{high} > $last_candle->{high};
      $last_candle->{low}  = $row->{low}  if $row->{low}  < $last_candle->{low};
      
      $last_candle->{close}  = $row->{close};
      $last_candle->{volume} = $row->{volume};
   } else {
      push @{$active_array}, $row;
   }
   return $self;
}


1;