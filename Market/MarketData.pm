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


sub build_tf_candles {
   my ($self, $tf) = @_;
   # TODO
}
sub build_timeframes {
   my ($self) = @_;
   # TODO
}
sub set_timeframe {
   my ($self, $tf) = @_;
   # TODO
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