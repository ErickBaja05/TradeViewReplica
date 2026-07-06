package Market::MarketData;

use strict;
use warnings;
use Time::Local qw(timegm);

# Duración en minutos de cada temporalidad agregada a partir de la base de 1m.
our %BLOCK_MINUTES = (
   '5m'  => 5,
   '15m' => 15,
   '1h'  => 60,
   '2h'  => 120,
   '4h'  => 240,
   '1d'  => 1440,
);

=head1 NAME

Market::MarketData - Clase para gestionar datos de mercado OHLCV.

=head1 MÉTODOS

=head2 new

Constructor de la clase Market::MarketData.

=cut 

sub new {
   my ($class) = @_;

   my $self = {
      # temporalidad activa por defecto
      timeframe => '1m',
      # temporalidades disponibles
      data => {
         '1m'  => [],
         '5m'  => [],
         '15m' => [],
         '1h'  => [],
         '2h'  => [],
         '4h'  => [],
         '1d'  => [],
      },
      # servirá para almacenar las velas
      candles => []
   };
   bless $self, $class;
   return $self;
}

=head2 get_data

Permite el acceso a los datos de mercado (actúa como un getter).

=cut

sub get_data {
   my ($self) = @_;
    
   return $self->_active_array();
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


=head2 _active_array()

Retorna el arreglo de velas según la temporalidad activa

=cut

sub _active_array {
   my ($self) = @_;
   
   my $tf = $self->{timeframe} // '1m';
   $self->{data}->{$tf} //= [];

   if ($tf eq '1m' && scalar @{$self->{data}->{'1m'}} == 0 && scalar @{$self->{candles}} > 0) {
      $self->{data}->{'1m'} = $self->{candles};
   }

   if (scalar @{$self->{data}->{$tf}} == 0 && scalar @{$self->{candles}} > 0) {
      warn "[MarketData Warning]: La temporalidad '$tf' no ha sido procesada o agrupada.\n";
   }
   return $self->{data}->{$tf};
}

=head2 get_candle()

Recupera una vela del historial basándose en su posición

=cut

sub get_candle {
   my ($self, $index) = @_;
   
   if (defined $index && $index >= 0 && $index <= $self->last_index()) {
      my $array_ref = $self->_active_array();
      return $array_ref->[$index];
   }
   return undef;
}

=head2 last_candle()

Retorna el hash completo de la última vela registrada en el sistema bajo la temporalidad activa.

=cut

sub last_candle {
   my ($self) = @_;
   my $idx = $self->last_index();
   return $self->get_candle($idx);
}


=head2 last_index()

Obtiene el índice de la última vela del arreglo de la temporalidad activa.

=cut

sub last_index {
   my ($self) = @_;
   my $total_elements = $self->size();
   return $total_elements - 1;
}

=head2 size()

Devuelve la cantidad total de velas almacenadas en la temporalidad activa actual.

=cut

sub size {
   my ($self) = @_;
   my $array_ref = $self->_active_array();
   return scalar @{$array_ref};
}

=head2 get_slice()

Extrae una porción de datos entre dos índices delimitadores. 

=cut

sub get_slice {
   my ($self, $start, $end) = @_;
   my $max_idx = $self->last_index();
   
   return [] if $max_idx < 0; 
   $start = 0 if !defined $start || $start < 0;
   $end = $max_idx if !defined $end || $end > $max_idx;
   
   return [] if $start > $end;
   
   my $array_ref = $self->_active_array();
   my @slice = @{$array_ref}[$start .. $end];
   
   return \@slice;
}

=head2 get_timestamp()

Devuelve el valor de tiempo correspondiente a una vela en una posición determinada. 

=cut

sub get_timestamp {
   my ($self, $index) = @_;
   my $candle = $self->get_candle($index);
   if (defined $candle && exists $candle->{time}) {
      return $candle->{time};
   }
   return undef;
}

=head2 build_tf_candles()

Subrutina encargada de comprimir n velas de 1 minuto en una sola vela de mayor temporalidad, 
alineando matemáticamente el reloj (ej. 00, 15, 30, 45) estilo TradingView.

=cut

sub build_tf_candles {
   my ($self, $tf) = @_;

   my $block_minutes = $BLOCK_MINUTES{$tf};
   return unless $block_minutes;

   my $candles_1m = $self->{candles};
   $self->{data}->{$tf} = [];

   return if scalar(@{$candles_1m}) == 0;

   my $block_seconds = $block_minutes * 60;

   my $current_bucket_epoch = undef;
   my $current_candle = undef;

   # Recorremos la línea temporal secuencialmente agrupando por bloques de
   # $block_seconds segundos. Usamos el "reloj de pared" (los componentes
   # Y-M-D H:M:S tal cual aparecen en el CSV, ignorando la zona horaria) para
   # que los cajones queden anclados a las fronteras naturales (00:00, 04:00,
   # 08:00... para 4h; 00:00 para 1D), igual que TradingView. Esto también
   # soporta correctamente temporalidades >= 1 hora, donde una sola hora del
   # reloj ya no alcanza para deducir el cajón (a diferencia de 5m/15m).
   for my $candle (@{$candles_1m}) {
      my $time_str = $candle->{time};

      if ($time_str =~ /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})(.*)$/) {
         my ($year, $mon, $day, $hh, $mm, $ss, $tz) = ($1, $2, $3, $4, $5, $6, $7);

         my $epoch = eval { timegm($ss, $mm, $hh, $day, $mon - 1, $year) };
         next unless defined $epoch;

         my $bucket_epoch = $epoch - ($epoch % $block_seconds);

         # Si no hay bloque activo, o si saltamos a un nuevo bloque de tiempo
         if (!defined $current_bucket_epoch || $bucket_epoch != $current_bucket_epoch) {

            # Guardamos la vela ancla terminada en el historial
            if (defined $current_candle) {
               push @{$self->{data}->{$tf}}, $current_candle;
            }

            my (undef, $b_mm, $b_hh, $b_day, $b_mon, $b_year) = gmtime($bucket_epoch);
            my $bucket_time_str = sprintf(
               "%04d-%02d-%02dT%02d:%02d:00%s",
               $b_year + 1900, $b_mon + 1, $b_day, $b_hh, $b_mm, $tz
            );

            # Inicia una nueva vela ancla
            $current_bucket_epoch = $bucket_epoch;
            $current_candle = {
               time   => $bucket_time_str,
               open   => 0.0 + $candle->{open},
               high   => 0.0 + $candle->{high},
               low    => 0.0 + $candle->{low},
               close  => 0.0 + $candle->{close},
               volume => 0.0 + $candle->{volume}
            };
         } else {
            # Si el tiempo sigue cayendo en el mismo cajón, actualizamos la vela
            $current_candle->{high}  = $candle->{high} if $candle->{high} > $current_candle->{high};
            $current_candle->{low}   = $candle->{low}  if $candle->{low}  < $current_candle->{low};
            $current_candle->{close} = 0.0 + $candle->{close};
            $current_candle->{volume} += 0.0 + $candle->{volume};
         }
      }
   }

   # Guardamos la última vela que quedó formándose en memoria al acabar el bucle
   if (defined $current_candle) {
      push @{$self->{data}->{$tf}}, $current_candle;
   }
}

=head2 build_timeframes()

Construye las temporalidades superiores (5m y 15m) a partir de la base 1m.

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

   for my $tf (sort { $BLOCK_MINUTES{$a} <=> $BLOCK_MINUTES{$b} } keys %BLOCK_MINUTES) {
      $self->build_tf_candles($tf);
   }

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

1;