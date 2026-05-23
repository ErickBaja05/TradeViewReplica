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

Permite el acceso a los datos de mercado.

=cut

sub get_data {
   my ($self) = @_;
   
   # Datos de prueba: solo se cargarán si el arreglo de velas está vacío
   if (scalar @{$self->{candles}} == 0) {
      $self->{candles} = [
         { time => '2026-04-01T00:00:00-05:00', open => 24013.75, high => 24013.75, low => 24007.5,  close => 24009.25, volume => 67  },
         { time => '2026-04-01T00:01:00-05:00', open => 24009.75, high => 24013.00, low => 24007.75, close => 24012.75, volume => 33  },
         { time => '2026-04-01T00:02:00-05:00', open => 24012.00, high => 24017.00, low => 24012.00, close => 24016.50, volume => 61  },
         { time => '2026-04-01T00:03:00-05:00', open => 24015.25, high => 24018.50, low => 24014.00, close => 24018.50, volume => 47  },
         { time => '2026-04-01T00:04:00-05:00', open => 24017.25, high => 24019.50, low => 24012.50, close => 24019.50, volume => 60  },
         { time => '2026-04-01T00:05:00-05:00', open => 24019.25, high => 24029.50, low => 24017.00, close => 24025.50, volume => 102 },
         { time => '2026-04-01T00:06:00-05:00', open => 24025.75, high => 24028.25, low => 24022.50, close => 24026.25, volume => 47  },
         { time => '2026-04-01T00:07:00-05:00', open => 24025.25, high => 24031.00, low => 24024.00, close => 24029.50, volume => 82  },
         { time => '2026-04-01T00:08:00-05:00', open => 24030.25, high => 24031.00, low => 24027.75, close => 24028.25, volume => 78  },
         { time => '2026-04-01T00:09:00-05:00', open => 24027.00, high => 24034.75, low => 24027.00, close => 24032.50, volume => 80  },
         { time => '2026-04-01T00:10:00-05:00', open => 24033.50, high => 24036.50, low => 24030.25, close => 24031.00, volume => 92  },
         { time => '2026-04-01T00:11:00-05:00', open => 24031.50, high => 24038.50, low => 24031.50, close => 24035.00, volume => 92  },
         { time => '2026-04-01T00:12:00-05:00', open => 24034.25, high => 24034.50, low => 24030.75, close => 24032.00, volume => 73  },
         { time => '2026-04-01T00:13:00-05:00', open => 24032.75, high => 24039.00, low => 24031.25, close => 24038.25, volume => 117 },
         { time => '2026-04-01T00:14:00-05:00', open => 24037.75, high => 24045.00, low => 24036.75, close => 24043.00, volume => 172 },
         { time => '2026-04-01T00:15:00-05:00', open => 24042.75, high => 24042.75, low => 24036.00, close => 24039.50, volume => 97  },
         { time => '2026-04-01T00:16:00-05:00', open => 24040.25, high => 24042.75, low => 24038.75, close => 24040.75, volume => 71  },
         { time => '2026-04-01T00:17:00-05:00', open => 24040.25, high => 24044.00, low => 24040.00, close => 24044.00, volume => 48  },
         { time => '2026-04-01T00:18:00-05:00', open => 24044.25, high => 24046.25, low => 24041.50, close => 24045.25, volume => 83  }
      ];
   }
   return $self->{candles};
}

=head3 add_candle()

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

1;