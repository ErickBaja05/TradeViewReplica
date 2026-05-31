package Market::MarketData;

use strict;
use warnings;

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
   
   # se valida que se reciba un argumento definido y que sea una referencia a un HASH
   if (defined $candle && ref($candle) eq 'HASH') {
      
      # ahora se valida que todos los campos existan en el HASH
      if ( exists $candle->{time}   &&
            exists $candle->{open}   &&
            exists $candle->{high}   &&
            exists $candle->{low}    &&
            exists $candle->{close}  &&
            exists $candle->{volume} ) {
            
            # si pasa el filtro, se agrega de forma segura al array
            push @{$self->{candles}}, $candle;
      } else {
         # si no pasa el filtro, se muestra una advertencia 
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
   
   # Recuperamos el identificador de la temporalidad activa
   my $tf = $self->{timeframe} // '1m';
   
   # Si por alguna razón la estructura interna de esa TF no existe, la inicializamos
   $self->{data}->{$tf} //= [];

   # La temporalidad base es 1 minuto, en caso de no usar build_timeframes
   if ($tf eq '1m' && scalar @{$self->{data}->{'1m'}} == 0 && scalar @{$self->{candles}} > 0) {
      $self->{data}->{'1m'} = $self->{candles};
   }

   # Si se selcciona '5m' o '15m' y siguen vacíos tras la carga, emitimos una advertencia en consola
   if (scalar @{$self->{data}->{$tf}} == 0 && scalar @{$self->{candles}} > 0) {
      warn "[MarketData Warning]: La temporalidad '$tf' no ha sido procesada o agrupada.\n";
   }
   return $self->{data}->{$tf};
}

=head2 get_candle()

Recupera una vela del historial basándose en su posición

=cut

sub get_candle {
   # Se recibe la posición de la vela
   my ($self, $index) = @_;
   
   # Validamos que el índice sea un número definido y que esté dentro del rango existente
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
El motor de renderizado obtiene solo las velas de la ventana visible
y para calcular indicadores sobre ventanas móviles.

=cut

sub get_slice {
   # se recibe los índices de inicio y fin
   my ($self, $start, $end) = @_;
   my $max_idx = $self->last_index();
   
   # Validaciones de seguridad de fronteras e índices
   return [] if $max_idx < 0; # Si no hay datos, retorna arreglo vacío
   $start = 0 if !defined $start || $start < 0;
   $end = $max_idx if !defined $end || $end > $max_idx;
   
   # Si los índices están cruzados de forma incorrecta, se retorna vacío
   return [] if $start > $end;
   
   my $array_ref = $self->_active_array();
   my @slice = @{$array_ref}[$start .. $end];
   
   return \@slice;
}

=head2 get_timestamp()

Devuelve el valor de tiempo correspondiente a una vela en una posición determinada. 
Es utilizado por el motor gráfico para renderizar las etiquetas dinámicas del eje horizontal X.

=cut

sub get_timestamp {
   # se recibe la posición de la vela de la cual se requiere la marca temporal
   my ($self, $index) = @_;
   my $candle = $self->get_candle($index);
   if (defined $candle && exists $candle->{time}) {
      return $candle->{time};
   }
   return undef;
}

=head2 build_tf_candles()

Subrutina encargada de comprimir n velas 
de 1 minuto en una sola vela de mayor temporalidad, respetando las reglas de agregación OHLCV

=cut

sub build_tf_candles {
   my ($self, $tf) = @_;
# Determinamos el tamaño del bloque según el string de la temporalidad
   my $block_size = 0;
   if    ($tf eq '5m')  { $block_size = 5; }
   elsif ($tf eq '15m') { $block_size = 15; }
   else                 { return; } # Si es '1m' o un parámetro inválido, salimos

   my $candles_1m = $self->{candles};
   my $total_candles = scalar @{$candles_1m};

   # Limpiamos el contenedor destino antes de realizar la carga masiva
   $self->{data}->{$tf} = [];

   # Recorremos el arreglo base de 1m en saltos según el tamaño del bloque
   for (my $i = 0; $i < $total_candles; $i += $block_size) {
      
      # Calculamos el índice final del bloque controlando el desborde del arreglo
      my $end = $i + $block_size - 1;
      if ($end >= $total_candles) {
         $end = $total_candles - 1;
      }

      # Aplicamos las reglas algebraicas financieras para la vela compresa
      my $time_val  = $candles_1m->[$i]->{time};     # El tiempo inicial del bloque
      my $open_val  = $candles_1m->[$i]->{open};     # El open de la primera vela
      my $close_val = $candles_1m->[$end]->{close};   # El close de la última vela
      
      # Inicializamos los extremos con los valores de la primera vela del grupo
      my $high_val  = $candles_1m->[$i]->{high};
      my $low_val   = $candles_1m->[$i]->{low};
      my $vol_val   = 0;

      # Bucle interno para extraer el máximo High, mínimo Low y la sumatoria de Volumen
      for my $j ($i .. $end) {
         my $current = $candles_1m->[$j];
         $high_val = $current->{high} if $current->{high} > $high_val;
         $low_val  = $current->{low}  if $current->{low} < $low_val;
         $vol_val += $current->{volume};
      }

      # Inserción limpia de la estructura estructurada en el cajón correspondiente
      push @{$self->{data}->{$tf}}, {
         time   => $time_val,
         open   => 0.0 + $open_val,   # Forzamos contexto numérico flotante
         high   => 0.0 + $high_val,
         low    => 0.0 + $low_val,
         close  => 0.0 + $close_val,
         volume => 0.0 + $vol_val
      };
   }
}

=head2 build_timeframes()

Construye las temporalidades superiores (5m y 15m) a partir de la base 1m.

=cut

sub build_timeframes {
   my ($self) = @_;
   # 1. Sincronización de seguridad de la temporalidad base (1m)
   if (defined $self->{candles} && scalar @{$self->{candles}} > 0) {
      $self->{data}->{'1m'} = $self->{candles};
   } elsif (defined $self->{data}->{'1m'} && scalar @{$self->{data}->{'1m'}} > 0) {
      $self->{candles} = $self->{data}->{'1m'};
   }

   # Control de fallos: Si no hay datos cargados, no hay nada que preprocesar
   if (!defined $self->{candles} || scalar @{$self->{candles}} == 0) {
      warn "[MarketData Error] | Build_timeframes: No se encontraron datos base en 'candles' para procesar.\n";
      return $self;
   }

   # 2. Construcción previa y secuencial de las temporalidades superiores
   $self->build_tf_candles('5m');
   $self->build_tf_candles('15m');

   return $self;
}
sub set_timeframe {
   my ($self, $tf) = @_;
   # Validación de seguridad: Comprobamos que el parámetro no sea nulo 
   # y que exista como una clave válida dentro de nuestro hash estructurado 'data'
   if (defined $tf && exists $self->{data}->{$tf}) {
      $self->{timeframe} = $tf;
   } else {
      # Si la interfaz manda algo inválido (ej: '1h' o undef), emitimos una advertencia
      warn "[MarketData Error] | SET_TIMEFRAME : La temporalidad '" . ($tf // 'undef') . "' no está soportada.\n";
   }

   # Retornar $self permite hacer cosas como: $market->set_timeframe('5m')->get_data();
   return $self;
}

=head2 merge_delta_row()

Gestiona la entrada de datos en tiempo real. 
Si el registro entrante pertenece al mismo bloque de tiempo 
que la última vela registrada, actualiza sus valores (High, Low, Close, Volume)
dinámicamente. Si corresponde a un nuevo bloque de tiempo,
inserta una nueva vela.

=cut

sub merge_delta_row {
   my ($self, $row) = @_;
   # Validación estricta de seguridad
   return $self unless defined $row && ref($row) eq 'HASH' && exists $row->{time};

   my $active_array = $self->_active_array();
   my $last_idx = $self->last_index();

   # Comprobamos si el arreglo tiene datos y si el tiempo del stream coincide con la última vela
   if ($last_idx >= 0 && $active_array->[$last_idx]->{time} eq $row->{time}) {
      
      my $last_candle = $active_array->[$last_idx];
      
      # Actualizamos los extremos de la vela (si el precio subió o bajó más de lo registrado)
      $last_candle->{high} = $row->{high} if $row->{high} > $last_candle->{high};
      $last_candle->{low}  = $row->{low}  if $row->{low}  < $last_candle->{low};
      
      # El precio de cierre y el volumen se sobrescriben con el último dato del stream
      $last_candle->{close}  = $row->{close};
      $last_candle->{volume} = $row->{volume};
   } else {
      # Si el timestamp es distinto (o el arreglo está vacío), nace una nueva vela
      push @{$active_array}, $row;
   }
   return $self;
}

=head2 compute_time_anchors()

Analiza el arreglo de velas activas y calcula puntos estratégicos (anclajes) en la línea de tiempo. 
Retorna una lista de índices y etiquetas formateadas para que el panel inferior dibuje el eje X
sin sobreponer los textos.

=cut

sub compute_time_anchors {
   my ($self) = @_;
   my $active_array = $self->_active_array();
   my @raw_anchors;
   
   # Recorremos todas las velas para procesar la marca de tiempo
   for my $i (0 .. $#$active_array) {
      my $time_str = $active_array->[$i]->{time};
      
      # Extraemos Hora (HH) y Minuto (MM) en dos grupos de captura nativos
      if (defined $time_str && $time_str =~ /T(\d{2}):(\d{2})/) {
         my $hh = $1;
         my $mm = $2;
         
         # Guardamos el índice, la etiqueta visual y el minuto numérico.
         push @raw_anchors, {
            index  => $i,
            label  => "$hh:$mm",
            minute => int($mm) # Extraemos el entero para facilitar cálculos matemáticos
         };
      }
   }
   return \@raw_anchors;
}


1;