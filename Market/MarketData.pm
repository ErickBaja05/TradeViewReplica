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
   '1w'  => 10080,
);

# Epoch de referencia (segundos) de un lunes 00:00:00 UTC cualquiera
# (05-ene-1970). Se usa únicamente para anclar los cajones de la
# temporalidad semanal ('1w') al inicio de semana (lunes), ya que el
# epoch 0 (01-ene-1970) fue un jueves y el alineamiento por defecto
# (epoch % block_seconds) dejaría los cajones arrancando en jueves.
use constant MONDAY_EPOCH_REF => 345600;

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
         '1w'  => [],
      },
      # servirá para almacenar las velas
      candles => [],

      # --- Modo Replay ---
      # Cuando replay_active está activo, todas las lecturas (size,
      # last_index, get_candle, get_slice, index_for_time, etc.) quedan
      # restringidas a las velas cuyo tiempo sea <= replay_time, sin
      # importar la temporalidad activa. Esto permite "viajar en el
      # tiempo" simplemente moviendo un límite, sin borrar ni duplicar
      # datos reales.
      replay_active => 0,
      replay_time   => undef,
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

   return $self->_apply_replay_boundary($self->{data}->{$tf});
}

=head2 _apply_replay_boundary($full_array)

Dado el arreglo COMPLETO de velas de una temporalidad, devuelve una copia
recortada hasta (e incluyendo) la vela cuyo tiempo coincide con el límite
actual del Modo Replay (C<replay_time>), mediante búsqueda binaria (las
velas están ordenadas cronológicamente). Si el Modo Replay no está activo,
devuelve el arreglo original sin modificar.

=cut

sub _apply_replay_boundary {
   my ($self, $full) = @_;

   return $full unless $self->{replay_active} && defined $self->{replay_time};
   return [] unless $full && @$full;

   my ($lo, $hi) = (0, $#$full);
   my $result = -1;

   while ($lo <= $hi) {
      my $mid = int(($lo + $hi) / 2);
      if ($full->[$mid]->{time} le $self->{replay_time}) {
         $result = $mid;
         $lo = $mid + 1;
      } else {
         $hi = $mid - 1;
      }
   }

   return [] if $result < 0;
   return [ @{$full}[0 .. $result] ];
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

         # Para la mayoría de temporalidades el cajón se calcula alineando
         # directamente al epoch (0 = jueves 00:00 UTC), lo cual funciona
         # bien para bloques que dividen exactamente al día (5m..1d). Para
         # la temporalidad semanal ('1w') eso dejaría los cajones arrancando
         # en jueves en vez de lunes (convención de TradingView), así que
         # alineamos contra un epoch de referencia que sí cae en lunes.
         my $bucket_epoch =
              $tf eq '1w'
            ? $epoch - (($epoch - MONDAY_EPOCH_REF) % $block_seconds)
            : $epoch - ($epoch % $block_seconds);

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

=head2 get_timeframe_candles($tf)

Devuelve el arreglo de velas ya agregadas para la temporalidad indicada
($tf), sin importar cuál sea la temporalidad activa del gráfico. Se usa
para indicadores "Multi Time Frame" (por ejemplo el ZigZag Interno) que
necesitan calcular sobre una temporalidad distinta a la que se está
graficando en pantalla.

=cut

sub get_timeframe_candles {
   my ($self, $tf) = @_;
   return [] unless defined $tf && exists $self->{data}->{$tf};
   return $self->_apply_replay_boundary($self->{data}->{$tf});
}

=head2 index_for_time($time_str)

Dado un timestamp (formato "YYYY-MM-DDTHH:MM:SS..."), devuelve el índice,
dentro del arreglo de la temporalidad ACTIVA, de la última vela cuyo
tiempo sea menor o igual a $time_str (búsqueda binaria, ya que las velas
están ordenadas cronológicamente). Se usa para "traducir" un pivote
calculado en una temporalidad superior (MTF) al sistema de coordenadas
(índices) de la temporalidad que se está dibujando en el gráfico.

=cut

sub index_for_time {
   my ($self, $time_str) = @_;
   return undef unless defined $time_str;

   my $arr = $self->_active_array();
   return undef unless @$arr;

   my ($lo, $hi) = (0, $#$arr);
   my $result = 0;

   while ($lo <= $hi) {
      my $mid = int(($lo + $hi) / 2);
      if ($arr->[$mid]->{time} le $time_str) {
         $result = $mid;
         $lo = $mid + 1;
      } else {
         $hi = $mid - 1;
      }
   }

   return $result;
}

=head2 find_pivot_index($time_from, $time_to, $type)

Dado un rango de tiempo [$time_from, $time_to) (bucket de una vela de
temporalidad superior, MTF), busca DENTRO de la temporalidad ACTIVA la
vela cuyo C<high> (si C<$type> es 'high') o C<low> (si es 'low') es el
extremo del rango — es decir, la vela exacta que originó ese máximo o
mínimo al agregar hacia la temporalidad superior. Devuelve
C<($index, $value)> o C<(undef, undef)> si el rango está vacío.

Se usa para "traducir" un pivote del ZigZag Interno (calculado en una
temporalidad MTF) a una vela real y visible de la temporalidad activa,
en lugar de anclarlo únicamente al inicio del bloque horario (lo cual
podía dejar el pivote "flotando" sin tocar ninguna mecha).

=cut

sub find_pivot_index {
   my ($self, $time_from, $time_to, $type) = @_;
   return (undef, undef) unless defined $time_from && defined $type;

   my $arr = $self->_active_array();
   return (undef, undef) unless @$arr;

   my $start_idx = $self->index_for_time($time_from);
   return (undef, undef) unless defined $start_idx;

   # Aseguramos que start_idx no quede antes del inicio real del bucket
   # (index_for_time devuelve la última vela <= time_from, lo cual es
   # correcto salvo que esa vela sea, en realidad, anterior al bucket).
   $start_idx++ while $start_idx < $#$arr && $arr->[$start_idx]->{time} lt $time_from;

   my $end_idx;
   if (defined $time_to) {
      $end_idx = $self->index_for_time($time_to);
      $end_idx = $#$arr unless defined $end_idx;
      $end_idx-- while $end_idx >= $start_idx && $arr->[$end_idx]->{time} ge $time_to;
   } else {
      $end_idx = $#$arr;
   }

   return (undef, undef) if !defined $end_idx || $end_idx < $start_idx;

   my $best_idx = $start_idx;
   my $best_val = $arr->[$start_idx]->{$type};

   for my $i ($start_idx .. $end_idx) {
      my $v = $arr->[$i]->{$type};
      next unless defined $v;

      if ($type eq 'high') {
         if ($v > $best_val) { $best_val = $v; $best_idx = $i; }
      } else {
         if ($v < $best_val) { $best_val = $v; $best_idx = $i; }
      }
   }

   return ($best_idx, $best_val);
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

=head2 find_last_session_open_index($until_index)

Busca, retrocediendo desde C<$until_index>, el hueco de tiempo más grande
entre dos velas consecutivas (por ejemplo el cierre diario de un futuro, o
el corte de fin de semana) y devuelve el índice de la primera vela
INMEDIATAMENTE POSTERIOR a ese hueco: es decir, la vela de "apertura" de la
última sesión de mercado que contiene a C<$until_index>.

Un hueco se considera significativo cuando es mayor a 3 veces el intervalo
"normal" entre velas de la temporalidad activa (deducido de las dos
primeras velas del arreglo). Si no se detecta ningún hueco relevante antes
de C<$until_index>, se devuelve 0 (la primera vela de todo el historial).

=cut

sub find_last_session_open_index {
   my ($self, $until_index) = @_;

   my $arr = $self->_active_array();
   return undef unless $arr && @$arr;

   $until_index = $#$arr if $until_index > $#$arr;
   return 0 if !defined $until_index || $until_index <= 0;

   my $typical = $self->_seconds_between($arr->[0]{time}, $arr->[1]{time});
   $typical = 60 unless defined $typical && $typical > 0;

   my $threshold = $typical * 3;

   for (my $i = $until_index; $i > 0; $i--) {
      my $gap = $self->_seconds_between($arr->[$i - 1]{time}, $arr->[$i]{time});
      next unless defined $gap;

      return $i if $gap > $threshold;
   }

   return 0;
}

=head2 _seconds_between($t1, $t2)

Diferencia en segundos entre dos timestamps del CSV (formato
"YYYY-MM-DDTHH:MM:SS..."), usando la misma convención de "reloj de pared"
(ignorando el offset de zona horaria) que C<build_tf_candles>, para que las
diferencias sean consistentes con el resto del motor.

=cut

sub _seconds_between {
   my ($self, $t1, $t2) = @_;
   return undef unless defined $t1 && defined $t2;

   my $e1 = $self->_parse_epoch($t1);
   my $e2 = $self->_parse_epoch($t2);
   return undef unless defined $e1 && defined $e2;

   return $e2 - $e1;
}

sub _parse_epoch {
   my ($self, $t) = @_;
   return undef unless defined $t;

   if ($t =~ /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})/) {
      my ($year, $mon, $day, $hh, $mm, $ss) = ($1, $2, $3, $4, $5, $6);
      return eval { timegm($ss, $mm, $hh, $day, $mon - 1, $year) };
   }

   return undef;
}

=head2 is_replay_active()

Indica si el Modo Replay está actualmente activo.

=cut

sub is_replay_active {
   my ($self) = @_;
   return $self->{replay_active} ? 1 : 0;
}

=head2 replay_start($index)

Activa el Modo Replay, fijando el límite de velas visibles en la vela de
posición C<$index> (índice global, inclusive) de la temporalidad ACTIVA en
ese momento (ignorando cualquier límite de Replay previo, para poder
re-anclar el punto de partida). Devuelve 1 si el Replay quedó activado, o
0 si el índice/temporalidad no tienen datos.

=cut

sub replay_start {
   my ($self, $index) = @_;
   return 0 unless defined $index;

   my $tf   = $self->{timeframe} // '1m';
   my $full = $self->{data}->{$tf} || [];
   return 0 unless @$full;

   $index = 0      if $index < 0;
   $index = $#$full if $index > $#$full;

   $self->{replay_active} = 1;
   $self->{replay_time}   = $full->[$index]->{time};

   return 1;
}

=head2 replay_stop()

Desactiva el Modo Replay y restaura la visibilidad de todo el historial
cargado, en todas las temporalidades.

=cut

sub replay_stop {
   my ($self) = @_;
   $self->{replay_active} = 0;
   $self->{replay_time}   = undef;
   return $self;
}

=head2 replay_forward($steps)

Avanza C<$steps> velas (por defecto 1) el límite del Modo Replay
(revela las siguientes velas de la temporalidad activa). Si el avance
solicitado supera la última vela disponible, se detiene ahí (sin fallar).
Devuelve la cantidad de velas efectivamente avanzadas (0 si el Replay no
está activo o ya se había alcanzado el final).

=cut

sub replay_forward {
   my ($self, $steps) = @_;
   $steps = 1 unless defined $steps && $steps > 0;
   return 0 unless $self->{replay_active};

   my $tf   = $self->{timeframe} // '1m';
   my $full = $self->{data}->{$tf} || [];
   return 0 unless @$full;

   my $current_idx = $self->_replay_index($full);
   return 0 unless defined $current_idx;
   return 0 if $current_idx >= $#$full;

   my $target_idx = $current_idx + $steps;
   $target_idx = $#$full if $target_idx > $#$full;

   $self->{replay_time} = $full->[$target_idx]->{time};
   return $target_idx - $current_idx;
}

=head2 replay_backward($steps)

Retrocede C<$steps> velas (por defecto 1) el límite del Modo Replay
(retira las últimas velas visibles). Nunca deja menos de una vela
visible. Devuelve la cantidad de velas efectivamente retrocedidas (0 si
el Replay no está activo o ya se había alcanzado la primera vela).

=cut

sub replay_backward {
   my ($self, $steps) = @_;
   $steps = 1 unless defined $steps && $steps > 0;
   return 0 unless $self->{replay_active};

   my $tf   = $self->{timeframe} // '1m';
   my $full = $self->{data}->{$tf} || [];
   return 0 unless @$full;

   my $current_idx = $self->_replay_index($full);
   return 0 unless defined $current_idx;
   return 0 if $current_idx <= 0;

   my $target_idx = $current_idx - $steps;
   $target_idx = 0 if $target_idx < 0;

   $self->{replay_time} = $full->[$target_idx]->{time};
   return $current_idx - $target_idx;
}

=head2 _replay_index($full_array)

Devuelve el índice, dentro del arreglo COMPLETO recibido, correspondiente
al límite actual del Modo Replay (C<replay_time>).

=cut

sub _replay_index {
   my ($self, $full) = @_;
   return undef unless defined $self->{replay_time} && $full && @$full;

   my ($lo, $hi) = (0, $#$full);
   my $result;

   while ($lo <= $hi) {
      my $mid = int(($lo + $hi) / 2);
      if ($full->[$mid]->{time} le $self->{replay_time}) {
         $result = $mid;
         $lo = $mid + 1;
      } else {
         $hi = $mid - 1;
      }
   }

   return $result;
}

# En Market/MarketData.pm - Añadir este método

=head2 get_replay_index()

Devuelve el índice actual del Modo Replay (la última vela visible/aceptada).
Si el Replay no está activo, devuelve el último índice del histórico.

=cut

sub get_replay_index {
    my ($self) = @_;
    
    if ($self->{replay_active}) {
        return $self->{replay_end_index};
    }
    
    return $self->last_index();
}

1;