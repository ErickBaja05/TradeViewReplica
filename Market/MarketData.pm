package Market::MarketData;

use strict;
use warnings;
use Time::Local qw(timelocal);

sub new {
   my ($class) = @_;

   my $self = {
      timeframe => '1m',
      data => {
         '1m'  => [], '5m'  => [], '15m' => [], '1h' => [],
         '2h'  => [], '4h'  => [], 'D'   => [], 'W'  => []
      },
      candles => [],

      replay_mode  => 0,
      replay_index => 0,
   };
   bless $self, $class;
   return $self;
}

# ==========================================================
# Utilidades de tiempo: todas las temporalidades se agrupan
# por epoch, como en el proyecto guía. Esto evita que al
# cambiar de temporalidad queden velas mal agrupadas.
# ==========================================================
sub _parse_time_to_epoch {
   my ($time_str) = @_;
   return undef unless defined $time_str;

   # Acepta: 2026-04-30T22:38:00, 2026-04-30 22:38:00,
   # con o sin milisegundos y con o sin zona horaria final.
   my $clean = $time_str;
   $clean =~ s/\.\d+//;
   $clean =~ s/Z$//;
   $clean =~ s/[-+]\d{2}:?\d{2}$//;

   if ($clean =~ /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?/) {
      my ($y, $mo, $d, $h, $m, $s) = ($1, $2, $3, $4, $5, $6 // 0);
      return timelocal($s, $m, $h, $d, $mo - 1, $y);
   }
   return undef;
}

sub _epoch_to_time_str {
   my ($epoch) = @_;
   my @lt = localtime($epoch);
   return sprintf('%04d-%02d-%02dT%02d:%02d:%02d',
      $lt[5] + 1900, $lt[4] + 1, $lt[3], $lt[2], $lt[1], $lt[0]
   );
}

sub _tf_seconds {
   my ($tf) = @_;
   return 60       if $tf eq '1m';
   return 5 * 60   if $tf eq '5m';
   return 15 * 60  if $tf eq '15m';
   return 60 * 60  if $tf eq '1h';
   return 2 * 3600 if $tf eq '2h';
   return 4 * 3600 if $tf eq '4h';
   return undef;
}

sub _bucket_epoch {
   my ($epoch, $tf) = @_;
   return undef unless defined $epoch;

   if (my $seconds = _tf_seconds($tf)) {
      return int($epoch / $seconds) * $seconds;
   }

   my @lt = localtime($epoch);

   if ($tf eq 'D') {
      return timelocal(0, 0, 0, $lt[3], $lt[4], $lt[5] + 1900);
   }

   if ($tf eq 'W') {
      my $midnight = timelocal(0, 0, 0, $lt[3], $lt[4], $lt[5] + 1900);
      my $wday = $lt[6];                 # 0 domingo, 1 lunes, ..., 6 sábado
      my $days_back = $wday == 0 ? 6 : $wday - 1;
      return $midnight - ($days_back * 24 * 60 * 60);
   }

   return undef;
}

sub _supported_timeframe {
   my ($self, $tf) = @_;
   return defined $tf && exists $self->{data}{$tf};
}

# ==========================================================
# Controles de replay
# ==========================================================
sub set_replay_mode {
    my ($self, $state, $start_index) = @_;
    $self->{replay_mode} = $state ? 1 : 0;

    my $array_ref = $self->{data}{ $self->{timeframe} } // [];
    my $max_idx = scalar(@$array_ref) - 1;
    $max_idx = 0 if $max_idx < 0;

    if ($self->{replay_mode}) {
        $start_index = 0 unless defined $start_index;
        $start_index = 0 if $start_index < 0;
        $start_index = $max_idx if $start_index > $max_idx;
        $self->{replay_index} = $start_index;
    } else {
        $self->{replay_index} = $max_idx;
    }
}

sub is_replay_active { return $_[0]->{replay_mode}; }
sub get_replay_index { return $_[0]->{replay_index}; }

sub step_forward {
    my ($self) = @_;
    return unless $self->{replay_mode};
    my $array_ref = $self->{data}{ $self->{timeframe} } // [];
    my $max_idx = scalar(@$array_ref) - 1;
    if ($self->{replay_index} < $max_idx) {
        $self->{replay_index}++;
        return 1;
    }
    return 0;
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

# ==========================================================
# Acceso a datos
# ==========================================================
sub _active_array {
   my ($self) = @_;
   my $tf = $self->{timeframe} // '1m';
   $self->{data}{$tf} //= [];

   if ($tf eq '1m' && scalar(@{$self->{data}{'1m'}}) == 0 && scalar(@{$self->{candles}}) > 0) {
      $self->{data}{'1m'} = $self->{candles};
   }
   return $self->{data}{$tf};
}

sub get_data {
   my ($self) = @_;
   my $array_ref = $self->_active_array();

   if ($self->{replay_mode}) {
       my $last = $self->{replay_index};
       $last = scalar(@$array_ref) - 1 if $last > scalar(@$array_ref) - 1;
       return [] if $last < 0;
       my @sliced = @{$array_ref}[0 .. $last];
       return \@sliced;
   }
   return $array_ref;
}

sub size {
   my ($self) = @_;
   my $array_ref = $self->_active_array();
   my $total = scalar(@$array_ref);
   return 0 if $total <= 0;

   if ($self->{replay_mode}) {
       my $visible = $self->{replay_index} + 1;
       $visible = $total if $visible > $total;
       return $visible;
   }
   return $total;
}

sub last_index { return $_[0]->size() - 1; }

sub get_candle {
   my ($self, $index) = @_;
   return undef unless defined $index && $index >= 0 && $index <= $self->last_index();
   return $self->_active_array()->[$index];
}

sub last_candle {
   my ($self) = @_;
   my $idx = $self->last_index();
   return $self->get_candle($idx);
}

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

sub get_timestamp {
   my ($self, $index) = @_;
   my $candle = $self->get_candle($index);
   return defined $candle ? $candle->{time} : undef;
}

sub compute_time_anchors {
   my ($self) = @_;
   my $active_array = $self->_active_array();
   my @raw_anchors;
   my $prev_day = '';

   for my $i (0 .. $#$active_array) {
      my $time_str = $active_array->[$i]->{time};
      next unless defined $time_str;

      if ($time_str =~ /^(\d{4}-\d{2}-\d{2})[ T](\d{2}):(\d{2})/) {
         my ($date, $hh, $mm) = ($1, $2, $3);
         if ($date ne $prev_day || $mm =~ /^(00|15|30|45)$/) {
            push @raw_anchors, {
               index   => $i,
               label   => "$hh:$mm",
               date    => $date,
               hour    => "$hh:$mm",
               minute  => int($mm),
               new_day => ($date ne $prev_day) ? 1 : 0,
            };
            $prev_day = $date;
         }
      }
   }
   return \@raw_anchors;
}

# ==========================================================
# Carga y construcción de temporalidades
# ==========================================================
sub add_candle {
   my ($self, $candle) = @_;

   if (defined $candle && ref($candle) eq 'HASH') {
      if (exists $candle->{time} && exists $candle->{open} && exists $candle->{high}
          && exists $candle->{low} && exists $candle->{close} && exists $candle->{volume}) {

         my $epoch = exists $candle->{epoch} ? $candle->{epoch} : _parse_time_to_epoch($candle->{time});
         my $normalized = {
            time   => $candle->{time},
            epoch  => $epoch,
            open   => 0.0 + $candle->{open},
            high   => 0.0 + $candle->{high},
            low    => 0.0 + $candle->{low},
            close  => 0.0 + $candle->{close},
            volume => 0.0 + $candle->{volume},
         };
         push @{$self->{candles}}, $normalized;
         $self->{data}{'1m'} = $self->{candles};
      } else {
         warn "[MarketData Error] Intento de agregar una vela con campos incompletos.\n";
      }
   } else {
      warn "[MarketData Error] El argumento provisto a add_candle no es un Hash válido.\n";
   }
   return $self;
}

sub build_tf_candles {
   my ($self, $tf) = @_;
   return $self->{data}{'1m'} if $tf eq '1m';
   return [] unless $self->_supported_timeframe($tf);

   my $candles_1m = $self->{candles} || [];
   my @out;
   return \@out if scalar(@$candles_1m) == 0;

   my $current;
   my $current_bucket;

   for my $c (@$candles_1m) {
      next unless $c && ref($c) eq 'HASH';
      my $epoch = exists $c->{epoch} && defined $c->{epoch} ? $c->{epoch} : _parse_time_to_epoch($c->{time});
      next unless defined $epoch;

      my $bucket = _bucket_epoch($epoch, $tf);
      next unless defined $bucket;

      if (!defined $current || $bucket != $current_bucket) {
         push @out, $current if defined $current;
         $current_bucket = $bucket;
         $current = {
            time   => _epoch_to_time_str($bucket),
            epoch  => $bucket,
            open   => 0.0 + $c->{open},
            high   => 0.0 + $c->{high},
            low    => 0.0 + $c->{low},
            close  => 0.0 + $c->{close},
            volume => 0.0 + $c->{volume},
         };
      } else {
         $current->{high}   = $c->{high} if $c->{high} > $current->{high};
         $current->{low}    = $c->{low}  if $c->{low}  < $current->{low};
         $current->{close}  = 0.0 + $c->{close};
         $current->{volume} += 0.0 + $c->{volume};
      }
   }
   push @out, $current if defined $current;

   $self->{data}{$tf} = \@out;
   return \@out;
}

sub build_timeframes {
   my ($self) = @_;

   if (defined $self->{candles} && scalar @{$self->{candles}} > 0) {
      $self->{data}{'1m'} = $self->{candles};
   } elsif (defined $self->{data}{'1m'} && scalar @{$self->{data}{'1m'}} > 0) {
      $self->{candles} = $self->{data}{'1m'};
   }

   if (!defined $self->{candles} || scalar @{$self->{candles}} == 0) {
      warn "[MarketData Error] | build_timeframes: No se encontraron datos base en 'candles'.\n";
      return $self;
   }

   for my $tf (qw(5m 15m 1h 2h 4h D W)) {
      $self->build_tf_candles($tf);
   }

   return $self;
}

sub set_timeframe {
   my ($self, $tf) = @_;

   if ($self->_supported_timeframe($tf)) {
      # Reconstruir siempre evita que una temporalidad conserve velas antiguas
      # si el CSV se recarga o se añaden datos nuevos.
      $self->{data}{'1m'} = $self->{candles} if $tf eq '1m';
      $self->build_tf_candles($tf) if $tf ne '1m';
      $self->{timeframe} = $tf;

      # Al cambiar temporalidad se desactiva replay para no mezclar índices
      # de una compresión anterior con otra diferente.
      $self->set_replay_mode(0);
   } else {
      warn "[MarketData Error] | set_timeframe: La temporalidad '" . ($tf // 'undef') . "' no está soportada.\n";
   }

   return $self;
}

sub merge_delta_row {
   my ($self, $row) = @_;
   return $self unless defined $row && ref($row) eq 'HASH' && exists $row->{time};

   my $epoch = exists $row->{epoch} ? $row->{epoch} : _parse_time_to_epoch($row->{time});
   $row->{epoch} = $epoch if defined $epoch;

   my $last = $self->{candles}->[-1];
   if (defined $last && $last->{time} eq $row->{time}) {
      %$last = (%$last, %$row);
   } else {
      $self->add_candle($row);
   }

   $self->build_timeframes();
   return $self;
}

1;
