#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin";
use Text::CSV;
use Time::Piece;
use List::Util qw(max min);
use Market::MarketData;
use Market::Indicators::ATR;
use Market::Indicators::SMC_Structures;
use Market::Indicators::Structure;
use Market::Indicators::FVG;
use Market::Indicators::OrderBlocks;
use Market::Indicators::Liquidity;
use Market::Indicators::ZigzagInternal;
use Market::Indicators::Fibonacci;
use Market::Indicators::HalfTrend;
use Market::Indicators::Supertrend;
use Market::Indicators::RangeFilter;
use Market::Indicators::VWAPAnchored;
use Market::Indicators::VolumeProfileAnchored;

# Configuración inicial
my $input_file = 'input.csv';
my $output_file = 'output.csv';
my $length = 50; # Longitud de pivote basada en el script original[cite: 1]
my $pip_multiplier = 10000;
my $atr_period = 14;

# ─── Helpers para trend_int_* (zigzag interno multi-temporalidad) ─────────
# Convierte el campo `time` de una vela (ISO "YYYY-MM-DD[ HH:MM:SS]" o
# timestamp epoch numérico) a epoch en segundos. Devuelve undef si el
# formato no es reconocido.
sub _parse_epoch {
    my ($time_str) = @_;
    return undef unless defined $time_str && length $time_str;

    if ($time_str =~ /^\d+$/) {
        return $time_str;
    }
    if ($time_str =~ /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})/) {
        my $tp = eval { Time::Piece->strptime("$1-$2-$3 $4:$5:$6", "%Y-%m-%d %H:%M:%S") };
        return $tp ? $tp->epoch : undef;
    }
    if ($time_str =~ /^(\d{4})-(\d{2})-(\d{2})$/) {
        my $tp = eval { Time::Piece->strptime("$1-$2-$3", "%Y-%m-%d") };
        return $tp ? $tp->epoch : undef;
    }
    return undef;
}

# Extrae (minuto, hora, día, mes, año) del campo `time` de una vela, sin
# pasar por epoch/Time::Piece (para no perder el "reloj de pared" del CSV,
# igual criterio que build_tf_candles/las columnas distance_daily_*, que
# ignoran la zona horaria y usan los componentes Y-M-D H:M:S tal cual
# aparecen). Soporta el mismo formato ISO ("YYYY-MM-DD[T ]HH:MM:SS...") y
# timestamp epoch numérico que _parse_epoch. Devuelve una lista de 5
# elementos (undef en los que no se puedan determinar).
sub _extract_time_parts {
    my ($time_str) = @_;
    return (undef, undef, undef, undef, undef) unless defined $time_str && length $time_str;

    if ($time_str =~ /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})/) {
        my ($year, $mon, $day, $hh, $mm) = ($1, $2, $3, $4, $5);
        return (int($mm), int($hh), int($day), int($mon), int($year));
    }
    if ($time_str =~ /^(\d{4})-(\d{2})-(\d{2})$/) {
        my ($year, $mon, $day) = ($1, $2, $3);
        return (0, 0, int($day), int($mon), int($year));
    }
    if ($time_str =~ /^\d+$/) {
        my @g = gmtime($time_str);
        return ($g[1], $g[2], $g[3], $g[4] + 1, $g[5] + 1900);
    }
    return (undef, undef, undef, undef, undef);
}

# Barra de progreso simple en STDERR (sin dependencias externas de CPAN).
# Se redibuja en la misma línea con retorno de carro ("\r"); no ensucia
# STDOUT (por si el CSV o cualquier otra salida se redirige por pipe).
# Para no penalizar el rendimiento en series muy largas, sólo redibuja
# cuando cambia el porcentaje entero (o en la última vela).
sub _print_progress {
    my ($current, $total, $label, $width) = @_;
    return if !$total || $total <= 0;
    $label //= 'Procesando';
    $width //= 40;

    my $pct = $current / $total;
    $pct = 1 if $pct > 1;

    my $prev_pct = $current > 0 ? ($current - 1) / $total : -1;
    return if int($pct * 100) == int($prev_pct * 100) && $current < $total;

    my $filled = int($pct * $width);
    my $bar    = ('#' x $filled) . ('-' x ($width - $filled));

    printf STDERR "\r%-38s [%s] %d/%d (%3d%%)", $label, $bar, $current, $total, int($pct * 100);
    print STDERR "\n" if $current >= $total;
}

# Re-muestrea @$data_ref (velas base) en barras OHLC de $minutes minutos, en
# orden cronológico. Devuelve ($resampled_aref, $group_of_row_aref), donde
# $group_of_row_aref->[$i] es el índice (dentro de $resampled_aref) de la
# barra a la que pertenece la vela base $i (undef si su `time` no se pudo
# interpretar y todavía no hay ninguna barra abierta).
sub _resample_bars {
    my ($data_ref, $minutes) = @_;
    my $bucket_seconds = $minutes * 60;

    my @resampled;
    my @group_of_row = (undef) x scalar(@$data_ref);
    my $current_key;

    my $total_in = scalar @$data_ref;
    for my $i (0 .. $#$data_ref) {
        _print_progress($i + 1, $total_in, "Re-muestreando a ${minutes}min");
        my $c     = $data_ref->[$i];
        my $epoch = _parse_epoch($c->{time});
        my $key   = defined $epoch ? int($epoch / $bucket_seconds) : undef;

        if (defined $key && (!defined $current_key || $key != $current_key)) {
            push @resampled, {
                time  => $c->{time},
                open  => $c->{open},
                high  => $c->{high},
                low   => $c->{low},
                close => $c->{close},
            };
            $current_key = $key;
        } elsif (@resampled) {
            my $bar = $resampled[-1];
            $bar->{high}  = $c->{high}  if $c->{high} > $bar->{high};
            $bar->{low}   = $c->{low}   if $c->{low}  < $bar->{low};
            $bar->{close} = $c->{close};
        } else {
            next; # sin timestamp reconocible y todavía sin ninguna barra abierta
        }

        $group_of_row[$i] = $#resampled;
    }

    return (\@resampled, \@group_of_row);
}

# Constante usada para alinear los cajones semanales al lunes (igual
# criterio que Market::MarketData::MONDAY_EPOCH_REF): epoch de referencia
# (segundos) de un lunes 00:00:00 UTC cualquiera (05-ene-1970). El epoch 0
# (01-ene-1970) fue jueves, así que sin este ajuste los cajones semanales
# arrancarían en jueves en vez de lunes.
use constant _MONDAY_EPOCH_REF => 345600;

# Re-muestrea @$data_ref (velas base leídas de input.csv) a barras OHLCV de
# $minutes minutos, sumando el volumen de las velas agrupadas (a diferencia
# de _resample_bars(), que sólo se usa internamente para trend_int_* y no
# necesita volumen). Replica la misma lógica de alineación de cajones que
# Market::MarketData::build_tf_candles() (incluida la alineación al lunes
# para la temporalidad semanal), para que el timeframe elegido por el
# usuario en el menú de consola quede alineado igual que el resto del
# ecosistema (TradingView-like). Se usa para transformar @data ANTES de
# correr todos los indicadores, así que todo el resto del script no
# necesita saber qué timeframe se eligió.
sub _resample_ohlcv {
    my ($data_ref, $minutes) = @_;
    my $bucket_seconds = $minutes * 60;
    my $is_weekly = ($minutes == 10080);

    my @resampled;
    my $current_bucket_epoch;
    my $total_in = scalar @$data_ref;

    for my $i (0 .. $#$data_ref) {
        _print_progress($i + 1, $total_in, "Re-muestreando a timeframe elegido");
        my $c     = $data_ref->[$i];
        my $epoch = _parse_epoch($c->{time});
        next unless defined $epoch;

        my $bucket_epoch = $is_weekly
            ? $epoch - (($epoch - _MONDAY_EPOCH_REF) % $bucket_seconds)
            : $epoch - ($epoch % $bucket_seconds);

        my $vol = $c->{volume};
        $vol = 0 unless defined $vol && $vol ne '';

        if (!defined $current_bucket_epoch || $bucket_epoch != $current_bucket_epoch) {
            my (undef, $mm, $hh, $day, $mon, $year) = gmtime($bucket_epoch);
            my $bucket_time_str = sprintf(
                "%04d-%02d-%02dT%02d:%02d:00",
                $year + 1900, $mon + 1, $day, $hh, $mm
            );

            push @resampled, {
                time   => $bucket_time_str,
                open   => 0.0 + $c->{open},
                high   => 0.0 + $c->{high},
                low    => 0.0 + $c->{low},
                close  => 0.0 + $c->{close},
                volume => 0.0 + $vol,
            };
            $current_bucket_epoch = $bucket_epoch;
        } else {
            my $bar = $resampled[-1];
            $bar->{high}   = $c->{high} if $c->{high} > $bar->{high};
            $bar->{low}    = $c->{low}  if $c->{low}  < $bar->{low};
            $bar->{close}  = 0.0 + $c->{close};
            $bar->{volume} += 0.0 + $vol;
        }
    }

    return \@resampled;
}

# Menú de consola: el usuario elige el timeframe de trabajo. Devuelve
# ($label, $minutes). Si la entrada no es interactiva (EOF) o el usuario
# ingresa algo inválido repetidamente, hace fallback a "1 minuto" para que
# el script nunca quede colgado esperando input en un entorno no
# interactivo (ej. cron, pipe).
sub _prompt_timeframe {
    my @options = (
        ['1 minuto',   1],
        ['5 minutos',  5],
        ['15 minutos', 15],
        ['30 minutos', 30],
        ['1 hora',     60],
        ['2 horas',    120],
        ['4 horas',    240],
        ['1 dia',      1440],
        ['1 semana',   10080],
    );

    print STDERR "\n=== Selecciona el timeframe de trabajo ===\n";
    for my $i (0 .. $#options) {
        printf STDERR "  %d) %s\n", $i + 1, $options[$i][0];
    }

    while (1) {
        print STDERR "\nIngresa el numero de opcion [1-" . scalar(@options) . "]: ";
        my $choice = <STDIN>;

        if (!defined $choice) {
            # EOF / sin entrada interactiva disponible
            print STDERR "\nNo se recibio entrada; usando '1 minuto' por defecto.\n";
            return @{ $options[0] };
        }

        chomp $choice;
        $choice =~ s/^\s+|\s+$//g;

        if ($choice =~ /^\d+$/ && $choice >= 1 && $choice <= scalar(@options)) {
            return @{ $options[$choice - 1] };
        }

        print STDERR "Opcion invalida, intenta de nuevo.\n";
    }
}

# Calcula, para cada vela base de @$data_ref, la tendencia interna vigente
# según el ZigZag (Market::Indicators::ZigzagInternal) de la temporalidad
# $minutes: re-muestrea las velas base a esa temporalidad, corre el zigzag
# barra a barra sobre la serie re-muestreada (tal como indica el contrato
# de ZigzagInternal.pm) y propaga (forward-fill) la dirección vigente
# (`dir`: 1=UP, -1=DOWN, 0=UNKNOWN antes del primer pivote) a cada vela
# base perteneciente a esa barra.
sub compute_trend_int {
    my ($data_ref, $minutes, $period) = @_;

    my ($resampled, $group_of_row) = _resample_bars($data_ref, $minutes);
    my $total_resampled = scalar @$resampled;

    my @trend_int = (0) x scalar(@$data_ref);
    return \@trend_int if $total_resampled == 0;

    my $zz = Market::Indicators::ZigzagInternal->new(period => $period // 2);
    my @trend_resampled = (0) x $total_resampled;

    for my $b (0 .. $total_resampled - 1) {
        _print_progress($b + 1, $total_resampled, "ZigZag interno ${minutes}min");
        $zz->update_last($resampled, undef, $b);
        $trend_resampled[$b] = $zz->{dir} // 0;
    }

    for my $i (0 .. $#$data_ref) {
        my $g = $group_of_row->[$i];
        $trend_int[$i] = defined $g ? $trend_resampled[$g] : 0;
    }

    return \@trend_int;
}

# Dado un array de "anclas" (uno por vela: el índice al que debe anclarse el
# VWAP en esa vela, o undef si todavía no hay ancla disponible), calcula la
# distancia normalizada por ATR entre el VWAP anclado y el close de cada
# vela, usando Market::Indicators::VWAPAnchored. En vez de llamar a
# calculate_until() vela a vela (lo cual recalcularía desde el ancla en cada
# llamada, con costo O(n) por vela y O(n^2) en total), agrupamos las velas
# consecutivas que comparten la misma ancla en un solo "segmento" y llamamos
# a calculate_until() una única vez por segmento (desde el ancla hasta el
# final del segmento), reutilizando toda la serie devuelta. Esto mantiene el
# costo total en O(n).
sub compute_anchored_vwap_distances {
    my ($vwap_module, $anchor_idx, $data_ref, $atr_values_ref, $total_rows) = @_;

    my @distances = (0) x $total_rows;
    my $i = 0;

    while ($i < $total_rows) {
        my $anchor = $anchor_idx->[$i];

        if (!defined $anchor) {
            $i++;
            next;
        }

        my $j = $i;
        $j++ while ($j + 1 < $total_rows)
                 && defined($anchor_idx->[$j + 1])
                 && $anchor_idx->[$j + 1] == $anchor;

        my $result = $vwap_module->calculate_until($data_ref, $anchor, $j);
        my $values = $result->{values};

        for my $k ($i .. $j) {
            my $v = $values->[$k - $anchor];
            next unless $v;

            my $close   = $data_ref->[$k]->{close};
            my $atr_raw = $atr_values_ref->[$k] // 0;
            next unless $atr_raw > 0;

            $distances[$k] = ($v->{vwap} - $close) / $atr_raw;
        }

        _print_progress($j + 1, $total_rows, "VWAP anclado");
        $i = $j + 1;
    }
    _print_progress($total_rows, $total_rows, "VWAP anclado");

    return \@distances;
}

my $csv = Text::CSV->new({ binary => 1, auto_diag => 1, eol => "\n" });

my ($timeframe_label, $timeframe_minutes) = _prompt_timeframe();
print STDERR "Timeframe seleccionado: $timeframe_label\n";

open my $fh_in, "<", $input_file or die "No se pudo abrir $input_file: $!";
my $headers = $csv->getline($fh_in);

my @raw_data;

while (my $row = $csv->getline($fh_in)) {
    my %row_data = (
        time   => $row->[0],
        open   => $row->[1],
        high   => $row->[2],
        low    => $row->[3],
        close  => $row->[4],
        volume => $row->[5]
    );

    push @raw_data, \%row_data;
}
close $fh_in;

my @data;
if ($timeframe_minutes > 1) {
    print STDERR "Re-muestreando input.csv a $timeframe_label...\n";
    @data = @{ _resample_ohlcv(\@raw_data, $timeframe_minutes) };
} else {
    @data = @raw_data;
}

my $market_data = Market::MarketData->new();
for my $c (@data) {
    $market_data->add_candle({ %$c });
}

my $total_rows = scalar @data;

# Calcular ATR sobre toda la serie usando MarketData.pm y ATR.pm
my $atr = Market::Indicators::ATR->new($atr_period);
$atr->recompute_all($market_data);
my $atr_values = $atr->get_values();

# Variables de estado
my $sys_max = 0;
my $sys_min = 999999;
my $max_x1 = 0;
my $min_x1 = 0;

my @is_pivot      = (0) x $total_rows;
my @is_high_pivot = (0) x $total_rows; # subconjunto de is_pivot: pivotes de tipo HIGH
my @is_low_pivot  = (0) x $total_rows; # subconjunto de is_pivot: pivotes de tipo LOW

# 1. Procesamiento Incremental (Detección y Rastro de Pivotes)
print STDERR "Detectando pivotes...\n";
for my $b (0 .. $total_rows - 1) {
    _print_progress($b + 1, $total_rows, "Detectando pivotes");
    my $lookback_idx = $b >= $length ? $b - $length : 0;
    
    my $curr_high = $data[$lookback_idx]->{high};
    my $curr_low  = $data[$lookback_idx]->{low};

    # Lógica de reubicación: Si el máximo o mínimo es superado, marcamos TANTO 
    # el índice anterior (rastro histórico) como el nuevo[cite: 1].
    if ($b > 0) {
        if ($curr_high > $sys_max) {
            # Se reubica el máximo. Guardamos el anterior como 1.
            if ($max_x1 > 0) {
                $is_pivot[$max_x1] = 1;
                $is_high_pivot[$max_x1] = 1;
            }
            
            # Actualizamos al nuevo índice y lo marcamos también.
            $max_x1 = $lookback_idx;
            $is_pivot[$max_x1] = 1;
            $is_high_pivot[$max_x1] = 1;
            $sys_max = $curr_high;
        }
        
        if ($curr_low < $sys_min) {
            # Se reubica el mínimo. Guardamos el anterior como 1.
            if ($min_x1 > 0) {
                $is_pivot[$min_x1] = 1;
                $is_low_pivot[$min_x1] = 1;
            }
            
            # Actualizamos al nuevo índice y lo marcamos también.
            $min_x1 = $lookback_idx;
            $is_pivot[$min_x1] = 1;
            $is_low_pivot[$min_x1] = 1;
            $sys_min = $curr_low;
        }
    } else {
        # Inicialización en la primera iteración
        $sys_max = $curr_high;
        $sys_min = $curr_low;
        $max_x1 = 0;
        $min_x1 = 0;
    }

    # Lógica estándar de pivotes confirmados en retrospectiva
    my $is_ph = 1;
    my $is_pl = 1;
    
    if ($b >= $length * 2) {
        my $pivot_candidate_high = $data[$b - $length]->{high};
        my $pivot_candidate_low  = $data[$b - $length]->{low};
        
        for my $i ($b - 2*$length .. $b) {
            $is_ph = 0 if $data[$i]->{high} > $pivot_candidate_high && $i != ($b - $length);
            $is_pl = 0 if $data[$i]->{low}  < $pivot_candidate_low  && $i != ($b - $length);
        }
        
        # Guardar el pivote confirmado independientemente de los rastros
        if ($is_ph || $is_pl) {
            $is_pivot[$b - $length] = 1;
            $is_high_pivot[$b - $length] = 1 if $is_ph;
            $is_low_pivot[$b - $length]  = 1 if $is_pl;
            # Al confirmarse, reiniciamos el seguimiento local para permitir nuevos rastros
            $sys_max = $is_ph ? $data[$b - $length]->{high} : 0;
            $sys_min = $is_pl ? $data[$b - $length]->{low} : 999999;
        }
    }
}

# Estructura de mercado (SMC): recorremos los pivotes en orden cronológico y
# alimentamos Market::Indicators::SMC_Structures para derivar la tendencia
# vigente en cada barra. Ver lookup.md para la equivalencia de valores.
my %TREND_VALUE = ( UP => 1, DOWN => -1, UNKNOWN => 0 );
my $smc = Market::Indicators::SMC_Structures->new();
my @trend_series = (0) x $total_rows;
my $current_trend = 0;

my @hh_price = (undef) x $total_rows;
my @ll_price = (undef) x $total_rows;
my $last_hh_price;
my $last_ll_price;

# Fibonacci: usa el mismo "zigzag externo" que ya construye $smc->{structure}
# (pivotes estructurales de SMC_Structures) para calcular, en cada vela, los
# niveles de retroceso entre el último y el penúltimo tramo (ver
# Fibonacci.pm: usa $structure->[-2] como anchor y $structure->[-3] como
# origin). $fib->calculate() es O(1) por llamada (solo mira los últimos dos
# elementos), así que se puede invocar vela a vela sin costo adicional.
my $fib = Market::Indicators::Fibonacci->new();
my @fib_labels = (0, 0.236, 0.382, 0.5, 0.618, 0.786, 1.0);
my @nearest_fib_level = (0) x $total_rows;

print STDERR "Calculando estructura SMC y niveles Fibonacci...\n";
for my $i (0 .. $total_rows - 1) {
    _print_progress($i + 1, $total_rows, "Estructura SMC / Fibonacci");
    my $atr_for_pivot = $atr_values->[$i] // 0;

    if ($is_high_pivot[$i]) {
        my $result = $smc->update_last({
            type  => 'HIGH',
            price => $data[$i]->{high},
            index => $i,
            atr   => $atr_for_pivot,
        });
        my $label = $result->{structure}[-1]{label} // '';
        $last_hh_price = $data[$i]->{high} if $label eq 'HH';
    }
    if ($is_low_pivot[$i]) {
        my $result = $smc->update_last({
            type  => 'LOW',
            price => $data[$i]->{low},
            index => $i,
            atr   => $atr_for_pivot,
        });
        my $label = $result->{structure}[-1]{label} // '';
        $last_ll_price = $data[$i]->{low} if $label eq 'LL';
    }

    $current_trend = $TREND_VALUE{ $smc->{trend} } // 0;
    $trend_series[$i] = $current_trend;

    $hh_price[$i] = $last_hh_price;
    $ll_price[$i] = $last_ll_price;

    if ($atr_for_pivot > 0) {
        my $fib_result = $fib->calculate($smc->{structure});
        my $fib_levels = $fib_result->{levels};
        if ($fib_levels && @$fib_levels) {
            my $close = $data[$i]->{close};
            my ($best_label, $best_diff);
            for my $idx (0 .. $#$fib_levels) {
                my $label = $fib_labels[$idx];
                next unless defined $label;
                my $diff = abs($fib_levels->[$idx]{price} - $close);
                if (!defined $best_diff || $diff < $best_diff) {
                    $best_diff  = $diff;
                    $best_label = $label;
                }
            }
            $nearest_fib_level[$i] = $best_label if defined $best_label;
        }
    }
}

# Estructura de mercado (BOS/CHoCH/EQH/EQL): Market::Indicators::Structure
# procesa internamente sus propios swings (externos e internos) y detecta
# equal highs/lows, así que basta con llamarlo vela a vela con el historial
# completo. Los eventos se acumulan en $structure->{events} con el índice de
# la vela donde ocurrieron (para EQH/EQL ese índice es el de la vela pivote
# central, no necesariamente la vela actual).
my $structure = Market::Indicators::Structure->new();
print STDERR "Calculando estructura de mercado (BOS/CHoCH/EQH/EQL)...\n";
for my $i (0 .. $total_rows - 1) {
    _print_progress($i + 1, $total_rows, "Estructura BOS/CHoCH/EQH/EQL");
    $structure->update_last(\@data, $atr_values, $i);
}

my @bos_ext   = (0) x $total_rows;
my @bos_int   = (0) x $total_rows;
my @choch_ext = (0) x $total_rows;
my @choch_int = (0) x $total_rows;
my @eqh       = (0) x $total_rows;
my @eql       = (0) x $total_rows;

for my $ev (@{ $structure->{events} }) {
    my $idx = $ev->{index};
    next unless defined $idx && $idx >= 0 && $idx < $total_rows;

    if ($ev->{type} eq 'BOS_UP' || $ev->{type} eq 'BOS_DOWN') {
        if ($ev->{tier} eq 'external') { $bos_ext[$idx] = 1; }
        else                           { $bos_int[$idx] = 1; }
    } elsif ($ev->{type} eq 'CHoCH_UP' || $ev->{type} eq 'CHoCH_DOWN') {
        if ($ev->{tier} eq 'external') { $choch_ext[$idx] = 1; }
        else                           { $choch_int[$idx] = 1; }
    } elsif ($ev->{type} eq 'EQH') {
        $eqh[$idx] = 1;
    } elsif ($ev->{type} eq 'EQL') {
        $eql[$idx] = 1;
    }
}

# Fair Value Gaps (FVG): recorremos las velas en orden cronológico llamando a
# Market::Indicators::FVG->update_last() vela a vela. En cada índice tomamos
# el FVG más reciente creado hasta el momento (último elemento de {zones}) y
# calculamos, respecto al cierre de esa vela: si el cierre está dentro de la
# zona (inside_fvg), la distancia normalizada por ATR entre el centro de la
# zona y el cierre (distance_FVG), y el tamaño de la zona normalizado por
# ATR (fvg_size = (top - bottom) / ATR, mismo criterio que el resto de
# columnas `distance_*`, en vez del tamaño en pips absolutos).
my $fvg = Market::Indicators::FVG->new();
my @inside_fvg   = (0) x $total_rows;
my @distance_fvg = (0) x $total_rows;
my @fvg_size     = (0) x $total_rows;
my @fvg_created_index = (undef) x $total_rows;

print STDERR "Calculando Fair Value Gaps...\n";
for my $i (0 .. $total_rows - 1) {
    _print_progress($i + 1, $total_rows, "Fair Value Gaps");
    my $result = $fvg->update_last(\@data, $atr_values, $i);
    my $zones  = $result->{zones};
    my $recent = ($zones && @$zones) ? $zones->[-1] : undef;

    if ($recent) {
        my $close   = $data[$i]->{close};
        my $atr_raw = $atr_values->[$i] // 0;
        my $center  = ($recent->{top} + $recent->{bottom}) / 2;

        $inside_fvg[$i] = ($close >= $recent->{bottom} && $close <= $recent->{top}) ? 1 : 0;
        $distance_fvg[$i] = $atr_raw > 0 ? ($center - $close) / $atr_raw : 0;
        $fvg_size[$i] = $atr_raw > 0 ? ($recent->{top} - $recent->{bottom}) / $atr_raw : 0;
        $fvg_created_index[$i] = $recent->{created_index};
    }
}

# Order Blocks: recorremos las velas en orden cronológico llamando a
# Market::Indicators::OrderBlocks->update_last() vela a vela. En cada índice
# tomamos el Order Block más reciente creado hasta el momento (último
# elemento de {zones}) y calculamos, respecto al cierre de esa vela: si el
# cierre está dentro de la zona (inside_order_block), la distancia
# normalizada por ATR entre el poi de la zona y el cierre (distance_ob), y
# el tipo de zona (ob_type: 1 = SUPPLY/offer, -1 = DEMAND).
my $order_blocks = Market::Indicators::OrderBlocks->new();
my @inside_ob = (0) x $total_rows;
my @distance_ob = (0) x $total_rows;
my @ob_type = (0) x $total_rows;
my @ob_created_index = (undef) x $total_rows;

print STDERR "Calculando Order Blocks...\n";
for my $i (0 .. $total_rows - 1) {
    _print_progress($i + 1, $total_rows, "Order Blocks");
    my $result = $order_blocks->update_last(\@data, $atr_values, $i);
    my $zones  = $result->{zones};
    my $recent = ($zones && @$zones) ? $zones->[-1] : undef;

    if ($recent) {
        my $close   = $data[$i]->{close};
        my $atr_raw = $atr_values->[$i] // 0;

        $inside_ob[$i] = ($close >= $recent->{bottom} && $close <= $recent->{top}) ? 1 : 0;
        $distance_ob[$i] = $atr_raw > 0 ? ($recent->{poi} - $close) / $atr_raw : 0;
        $ob_type[$i] = $recent->{type} eq 'SUPPLY' ? 1 : -1;
        $ob_created_index[$i] = $recent->{created_index};
    }
}

# Niveles MTF (Multi Time Frame): en vez de llamar a
# Market::Indicators::Levels->calculate_until() vela a vela (lo cual
# recalcula toda la historia desde cero en cada llamada, con costo O(n) por
# vela y O(n^2) en total), replicamos aquí la misma lógica de detección de
# cambio de período (día/semana/mes) y de Alto/Bajo del período anterior,
# pero de forma incremental: cada vela se procesa una sola vez, en O(1)
# amortizado, manteniendo el mismo criterio de claves (Y-M-D, semana ISO
# Y-W vía Time::Piece, Y-M) y el mismo resultado que Levels.pm.
my @distance_daily_high   = (0) x $total_rows;
my @distance_daily_low    = (0) x $total_rows;
my @distance_weekly_high  = (0) x $total_rows;
my @distance_weekly_low   = (0) x $total_rows;
my @distance_monthly_high = (0) x $total_rows;
my @distance_monthly_low  = (0) x $total_rows;

{
    my %st = (
        D => { key => '', h => -1, l => 9999999, ph => undef, pl => undef },
        W => { key => '', h => -1, l => 9999999, ph => undef, pl => undef },
        M => { key => '', h => -1, l => 9999999, ph => undef, pl => undef },
    );

    print STDERR "Calculando niveles MTF (diario/semanal/mensual)...\n";
    for my $i (0 .. $total_rows - 1) {
        _print_progress($i + 1, $total_rows, "Niveles MTF diario/semanal/mensual");
        my $c = $data[$i];

        if ($c->{time}) {
            my ($year, $mon, $mday);
            if ($c->{time} =~ /^(\d{4})-(\d{2})-(\d{2})/) {
                ($year, $mon, $mday) = ($1, $2, $3);
            } elsif ($c->{time} =~ /^\d+$/) {
                my @g = gmtime($c->{time});
                ($year, $mon, $mday) = ($g[5] + 1900, sprintf("%02d", $g[4] + 1), sprintf("%02d", $g[3]));
            }

            if (defined $year) {
                my $d_key = "$year-$mon-$mday";
                my $tp    = Time::Piece->strptime("$year-$mon-$mday", "%Y-%m-%d");
                my $w_key = $tp->strftime("%G-%V");
                my $m_key = "$year-$mon";

                for my $pair ([D => $d_key], [W => $w_key], [M => $m_key]) {
                    my ($tf, $key) = @$pair;
                    my $s = $st{$tf};
                    if ($s->{key} ne $key) {
                        $s->{ph} = $s->{h} if $s->{key};
                        $s->{pl} = $s->{l} if $s->{key};
                        $s->{key} = $key;
                        $s->{h}   = $c->{high};
                        $s->{l}   = $c->{low};
                    } else {
                        $s->{h} = $c->{high} if $c->{high} > $s->{h};
                        $s->{l} = $c->{low}  if $c->{low}  < $s->{l};
                    }
                }
            }
        }

        my $close   = $data[$i]->{close};
        my $atr_raw = $atr_values->[$i] // 0;
        next unless $atr_raw > 0;

        $distance_daily_high[$i]   = ($st{D}{ph} - $close) / $atr_raw if defined $st{D}{ph};
        $distance_daily_low[$i]    = ($st{D}{pl} - $close) / $atr_raw if defined $st{D}{pl};
        $distance_weekly_high[$i]  = ($st{W}{ph} - $close) / $atr_raw if defined $st{W}{ph};
        $distance_weekly_low[$i]   = ($st{W}{pl} - $close) / $atr_raw if defined $st{W}{pl};
        $distance_monthly_high[$i] = ($st{M}{ph} - $close) / $atr_raw if defined $st{M}{ph};
        $distance_monthly_low[$i]  = ($st{M}{pl} - $close) / $atr_raw if defined $st{M}{pl};
    }
}

# Liquidez (BSL/SSL) + swings menores (SH/SL): recorremos las velas en
# orden cronológico llamando a Market::Indicators::Liquidity->update_last()
# vela a vela. En vez de volver a escanear toda la lista de niveles/pivotes
# en cada vela (lo cual sería O(n) por vela), aprovechamos que tanto los
# niveles de liquidez ($result->{liquidity}) como los pivotes menores
# ($result->{minor_pivots}) siempre se agregan al final de sus respectivas
# listas: comparamos el tamaño de cada lista antes/después de cada llamada
# y solo inspeccionamos las entradas nuevas (O(1) amortizado por vela).
#
# Nota sobre "is_sh"/"is_sl": un pivote menor se confirma varias velas
# después de ocurrir (cuando el precio se aleja lo suficiente, según
# minor_atr_mult), y su índice (`->{index}`) es el de la vela donde ocurrió
# el extremo, no el de la vela de confirmación. Por eso "is_sh"/"is_sl" se
# marcan retroactivamente en `->{index}` en cuanto el pivote aparece en
# `minor_pivots`, no en la vela `$i` que dispara la confirmación.
my $liquidity = Market::Indicators::Liquidity->new();
my @distance_bsl = (0) x $total_rows;
my @distance_ssl = (0) x $total_rows;
my @lq_sweep_bsl = (0) x $total_rows;
my @lq_sweep_ssl = (0) x $total_rows;
my @lq_grab      = (0) x $total_rows;
my @lq_run       = (0) x $total_rows;
my @is_sh        = (0) x $total_rows;
my @is_sl        = (0) x $total_rows;
my @distance_sh  = (0) x $total_rows;
my @distance_sl  = (0) x $total_rows;

my $last_bsl_price;
my $last_ssl_price;
my $last_sh_price;
my $last_sl_price;
my $prev_liq_count   = 0;
my $prev_minor_count = 0;

print STDERR "Calculando liquidez (BSL/SSL) y swings menores...\n";
for my $i (0 .. $total_rows - 1) {
    _print_progress($i + 1, $total_rows, "Liquidez y swings menores");
    my $result = $liquidity->update_last(\@data, $atr_values, $i);

    if ($result) {
        my $liq_list  = $result->{liquidity};
        my $new_count = scalar @$liq_list;
        if ($new_count > $prev_liq_count) {
            for my $k ($prev_liq_count .. $new_count - 1) {
                my $lvl = $liq_list->[$k];
                if ($lvl->{type} eq 'BSL') {
                    $last_bsl_price = $lvl->{price};
                } elsif ($lvl->{type} eq 'SSL') {
                    $last_ssl_price = $lvl->{price};
                }
            }
            $prev_liq_count = $new_count;
        }

        my $minor_list  = $result->{minor_pivots};
        my $new_minor_count = scalar @$minor_list;
        if ($new_minor_count > $prev_minor_count) {
            for my $k ($prev_minor_count .. $new_minor_count - 1) {
                my $p   = $minor_list->[$k];
                my $idx = $p->{index};
                next unless defined $idx && $idx >= 0 && $idx < $total_rows;
                if ($p->{type} eq 'HIGH') {
                    $is_sh[$idx]  = 1;
                    $last_sh_price = $p->{price};
                } elsif ($p->{type} eq 'LOW') {
                    $is_sl[$idx]  = 1;
                    $last_sl_price = $p->{price};
                }
            }
            $prev_minor_count = $new_minor_count;
        }
    }

    my $close   = $data[$i]->{close};
    my $atr_raw = $atr_values->[$i] // 0;
    next unless $atr_raw > 0;

    $distance_bsl[$i] = ($last_bsl_price - $close) / $atr_raw if defined $last_bsl_price;
    $distance_ssl[$i] = ($last_ssl_price - $close) / $atr_raw if defined $last_ssl_price;
    $distance_sh[$i]  = ($last_sh_price  - $close) / $atr_raw if defined $last_sh_price;
    $distance_sl[$i]  = ($last_sl_price  - $close) / $atr_raw if defined $last_sl_price;
}

# Los eventos de resolución (Sweep/Grab/Run) se guardan en el propio nivel
# (`resolved_index`, `classification`) en vez de en una lista de eventos
# aparte, así que hacemos un único recorrido final -O(m), con m = cantidad
# total de niveles de liquidez creados- sobre $liquidity->{liquidity} para
# volcar cada resolución en la vela (`index`) donde ocurrió. Se guardan como
# 4 flags binarios independientes en vez de un único código categórico, así
# que si dos niveles distintos se resuelven en la misma vela ya no se pisan
# entre sí (antes, con un solo código, solo quedaba el último procesado).
my $total_liq_levels = scalar @{ $liquidity->{liquidity} };
print STDERR "Volcando resoluciones de liquidez (Sweep/Grab/Run)...\n";
my $liq_lvl_n = 0;
for my $lvl (@{ $liquidity->{liquidity} }) {
    $liq_lvl_n++;
    _print_progress($liq_lvl_n, $total_liq_levels, "Resoluciones de liquidez");
    next unless defined $lvl->{resolved_index} && defined $lvl->{classification};
    my $idx = $lvl->{resolved_index};
    next unless $idx >= 0 && $idx < $total_rows;

    if ($lvl->{classification} eq 'Sweep') {
        if ($lvl->{type} eq 'BSL') { $lq_sweep_bsl[$idx] = 1; }
        else                       { $lq_sweep_ssl[$idx] = 1; }
    } elsif ($lvl->{classification} eq 'Grab') {
        $lq_grab[$idx] = 1;
    } elsif ($lvl->{classification} eq 'Run') {
        $lq_run[$idx] = 1;
    }
}

# bars_since_*: cantidad de velas transcurridas desde el último evento de
# cada tipo, incluyendo la propia vela del evento (que vale 0). El valor
# se acota a BARS_SINCE_CAP velas y se normaliza dividiendo por ese mismo
# tope, quedando siempre en el rango [0, 1] (0 = el evento ocurrió en esta
# misma vela; 1 = el evento ocurrió hace BARS_SINCE_CAP velas o más).
# Mientras el evento correspondiente todavía no ha ocurrido ninguna vez en
# la serie, se guarda `1` (el valor más alto posible, igual que si hubiera
# ocurrido hace muchísimo tiempo: no hay forma de distinguir "muy lejano"
# de "nunca" una vez acotado, así que ambos casos comparten el mismo
# extremo de la escala).
#   - bars_since_bos:      último BOS *externo* (`bos_ext`).
#   - bars_since_choch:    último CHoCH *externo* (`choch_ext`).
#   - bars_since_eqh:      último Equal High (`eqh`).
#   - bars_since_eql:      último Equal Low (`eql`).
#   - bars_since_fvg:      creación del último Fair Value Gap (`created_index`
#                          de la zona más reciente que reporta FVG.pm).
#   - bars_since_ob:       creación del último Order Block (`created_index`
#                          de la zona más reciente que reporta OrderBlocks.pm).
#   - bars_since_lq_event: última resolución de liquidez (Sweep/Grab/Run:
#                          `lq_sweep_bsl`, `lq_sweep_ssl`, `lq_grab` o
#                          `lq_run`).
#
# distance_bos / distance_choch: distancia normalizada por ATR (mismo
# criterio que distance_fvg/distance_hh) entre el `close` de la vela donde
# ocurrió el último BOS/CHoCH externo y el `close` de la vela actual. Igual
# que distance_hh/distance_ll, mientras no haya ocurrido ningún BOS/CHoCH
# todavía en la serie, el valor es `0`.
# distance_eqh / distance_eql: distancia normalizada por ATR entre el
# precio (`high`/`low`) de la vela pivote del último Equal High/Equal Low
# confirmado y el `close` de la vela actual. Mismo criterio que
# distance_hh/distance_ll (que usan `high`/`low` de la vela pivote, no el
# `close`).
use constant BARS_SINCE_CAP => 100;

sub _normalize_bars_since {
    my ($raw, $cap) = @_;
    return 1 if !defined $raw || $raw < 0;
    my $capped = $raw > $cap ? $cap : $raw;
    return $capped / $cap;
}

my @bars_since_bos      = (-1) x $total_rows;
my @bars_since_choch    = (-1) x $total_rows;
my @bars_since_eqh      = (-1) x $total_rows;
my @bars_since_eql      = (-1) x $total_rows;
my @bars_since_fvg      = (-1) x $total_rows;
my @bars_since_ob       = (-1) x $total_rows;
my @bars_since_lq_event = (-1) x $total_rows;
my @distance_bos        = (0) x $total_rows;
my @distance_choch      = (0) x $total_rows;
my @distance_eqh        = (0) x $total_rows;
my @distance_eql        = (0) x $total_rows;

{
    my ($last_bos, $last_choch, $last_eqh, $last_eql, $last_fvg, $last_ob, $last_lq);

    print STDERR "Calculando bars_since (BOS/CHoCH/EQH/EQL/FVG/OB/liquidez)...\n";
    for my $i (0 .. $total_rows - 1) {
        _print_progress($i + 1, $total_rows, "bars_since_*");
        $last_bos   = $i if $bos_ext[$i];
        $last_choch = $i if $choch_ext[$i];
        $last_eqh   = $i if $eqh[$i];
        $last_eql   = $i if $eql[$i];
        $last_lq    = $i if $lq_sweep_bsl[$i] || $lq_sweep_ssl[$i] || $lq_grab[$i] || $lq_run[$i];

        my $fvg_created = $fvg_created_index[$i];
        $last_fvg = $fvg_created if defined $fvg_created;

        my $ob_created = $ob_created_index[$i];
        $last_ob = $ob_created if defined $ob_created;

        $bars_since_bos[$i]      = $i - $last_bos   if defined $last_bos;
        $bars_since_choch[$i]    = $i - $last_choch if defined $last_choch;
        $bars_since_eqh[$i]      = $i - $last_eqh   if defined $last_eqh;
        $bars_since_eql[$i]      = $i - $last_eql   if defined $last_eql;
        $bars_since_fvg[$i]      = $i - $last_fvg   if defined $last_fvg;
        $bars_since_ob[$i]       = $i - $last_ob    if defined $last_ob;
        $bars_since_lq_event[$i] = $i - $last_lq    if defined $last_lq;

        my $atr_raw = $atr_values->[$i] // 0;
        my $close   = $data[$i]->{close};

        $distance_bos[$i]   = (defined $last_bos   && $atr_raw > 0)
            ? ($data[$last_bos]->{close}   - $close) / $atr_raw : 0;
        $distance_choch[$i] = (defined $last_choch && $atr_raw > 0)
            ? ($data[$last_choch]->{close} - $close) / $atr_raw : 0;
        $distance_eqh[$i]   = (defined $last_eqh   && $atr_raw > 0)
            ? ($data[$last_eqh]->{high}    - $close) / $atr_raw : 0;
        $distance_eql[$i]   = (defined $last_eql   && $atr_raw > 0)
            ? ($data[$last_eql]->{low}     - $close) / $atr_raw : 0;
    }
}

# Acotamos y normalizamos los 7 `bars_since_*` en el rango [0, 1] (ver
# comentario más arriba): dividimos por BARS_SINCE_CAP y capamos el
# resultado en 1. El sentinel `-1` ("todavía no ha ocurrido") también
# queda en `1`, el valor más alto posible.
$_ = _normalize_bars_since($_, BARS_SINCE_CAP) for @bars_since_bos;
$_ = _normalize_bars_since($_, BARS_SINCE_CAP) for @bars_since_choch;
$_ = _normalize_bars_since($_, BARS_SINCE_CAP) for @bars_since_eqh;
$_ = _normalize_bars_since($_, BARS_SINCE_CAP) for @bars_since_eql;
$_ = _normalize_bars_since($_, BARS_SINCE_CAP) for @bars_since_fvg;
$_ = _normalize_bars_since($_, BARS_SINCE_CAP) for @bars_since_ob;
$_ = _normalize_bars_since($_, BARS_SINCE_CAP) for @bars_since_lq_event;

# trend_int_*: tendencia interna (zigzag) en 15min/30min/1hr/2hr/4hr,
# re-muestreando las velas base a cada temporalidad y corriendo
# Market::Indicators::ZigzagInternal sobre la serie re-muestreada.
print STDERR "Calculando tendencia interna multi-temporalidad (trend_int_*)...\n";
my $trend_int_15min = compute_trend_int(\@data, 15);
my $trend_int_30min = compute_trend_int(\@data, 30);
my $trend_int_1hr    = compute_trend_int(\@data, 60);
my $trend_int_2hr    = compute_trend_int(\@data, 120);
my $trend_int_4hr    = compute_trend_int(\@data, 240);

# HalfTrend: Market::Indicators::HalfTrend calcula su propio ATR Wilder
# interno (atr_period=100, fijo) para su lógica de trend/canal, así que no
# depende de $atr_values. Lo recorremos vela a vela con el historial
# completo (según su contrato incremental) y, para las distancias, usamos
# el ATR "del gráfico" ($atr_values, el mismo que el resto de columnas
# distance_*) en vez del ATR Wilder interno del indicador, para mantener
# la misma escala/criterio que las demás columnas de distancia.
# "UNKNOWN" (0) se usa mientras el ATR Wilder interno todavía no tiene
# suficientes velas (calentamiento de atr_period barras); recién entonces
# el indicador empieza a clasificar trend como alcista/bajista.
my $halftrend = Market::Indicators::HalfTrend->new();
my @half_trend               = (0) x $total_rows;
my @distance_high_half_trend = (0) x $total_rows;
my @distance_low_half_trend  = (0) x $total_rows;

print STDERR "Calculando HalfTrend...\n";
for my $i (0 .. $total_rows - 1) {
    _print_progress($i + 1, $total_rows, "HalfTrend");
    my $result = $halftrend->update_last(\@data, $atr_values, $i);
    my $value  = $result->{values}[$i];

    next unless $value && defined $halftrend->{atr_wilder};

    $half_trend[$i] = $value->{trend} == 0 ? 1 : -1;

    my $close   = $data[$i]->{close};
    my $atr_raw = $atr_values->[$i] // 0;
    next unless $atr_raw > 0;

    $distance_high_half_trend[$i] = ($value->{atr_high} - $close) / $atr_raw;
    $distance_low_half_trend[$i]  = ($value->{atr_low}  - $close) / $atr_raw;
}

# SuperTrend: al igual que HalfTrend, Market::Indicators::Supertrend
# calcula su propio ATR interno (Wilder por defecto, `change_atr => 1`) y
# no depende de $atr_values para su lógica de `up`/`dn`/`trend`. Para las
# distancias usamos, igual que en HalfTrend, el ATR "del gráfico"
# ($atr_values) en vez del ATR interno del indicador, para mantener la
# misma escala que el resto de columnas distance_*. `up` es la banda
# inferior (soporte en tendencia alcista) y `dn` la banda superior
# (resistencia en tendencia bajista); "high"/"low" en el nombre de las
# columnas se refiere a esa posición relativa de la banda, no a la vela.
my $supertrend = Market::Indicators::Supertrend->new();
my @super_trend               = (0) x $total_rows;
my @distance_high_super_trend = (0) x $total_rows;
my @distance_low_super_trend  = (0) x $total_rows;

print STDERR "Calculando SuperTrend...\n";
for my $i (0 .. $total_rows - 1) {
    _print_progress($i + 1, $total_rows, "SuperTrend");
    my $result = $supertrend->update_last(\@data, $atr_values, $i);
    my $value  = $result->{values}[$i];

    next unless $value && defined $supertrend->{atr_wilder};

    $super_trend[$i] = $value->{trend};

    my $close   = $data[$i]->{close};
    my $atr_raw = $atr_values->[$i] // 0;
    next unless $atr_raw > 0;

    $distance_high_super_trend[$i] = ($value->{dn} - $close) / $atr_raw;
    $distance_low_super_trend[$i]  = ($value->{up} - $close) / $atr_raw;
}

# Range Filter: Market::Indicators::RangeFilter replica la lógica
# PineScript de "Range Filter" (smoothrng/rngfilt), basada únicamente en
# dos EMA anidadas sobre |close - close[1]| (no usa $atr_values). Para las
# distancias (`distance_high_range_filter`/`distance_low_range_filter`) se
# usa el ATR "del gráfico" ($atr_values), igual criterio que en
# HalfTrend/SuperTrend, para mantener la misma escala que el resto de
# columnas distance_*.
my $range_filter = Market::Indicators::RangeFilter->new();
my @range_filter               = (0) x $total_rows;
my @distance_high_range_filter = (0) x $total_rows;
my @distance_low_range_filter  = (0) x $total_rows;

print STDERR "Calculando Range Filter...\n";
for my $i (0 .. $total_rows - 1) {
    _print_progress($i + 1, $total_rows, "Range Filter");
    my $result = $range_filter->update_last(\@data, $atr_values, $i);
    my $value  = $result->{values}[$i];

    next unless $value;

    $range_filter[$i] = $value->{trend};

    my $close   = $data[$i]->{close};
    my $atr_raw = $atr_values->[$i] // 0;
    next unless $atr_raw > 0;

    $distance_high_range_filter[$i] = ($value->{hband} - $close) / $atr_raw;
    $distance_low_range_filter[$i]  = ($value->{lband} - $close) / $atr_raw;
}

# VWAP Anclado (Anchored VWAP): Market::Indicators::VWAPAnchored calcula un
# VWAP con bandas de desviación estándar, reiniciado ("anclado") en un
# índice de vela concreto. Aquí se calculan 5 variantes, cada una con un
# criterio de ancla distinto, y se vuelca la distancia normalizada por ATR
# entre el `vwap` de esa ancla y el `close` de cada vela (mismo criterio
# `distance = (level - close) / ATR` que el resto de columnas `distance_*`,
# usando siempre el ATR "del gráfico", $atr_values).
#
# - session_vwap_distance: ancla fija en la primera vela de toda la serie
#   (índice 0), acumulando desde el inicio del histórico.
# - open_vwap_distance: ancla en la apertura de la última sesión de mercado
#   vigente en cada vela, según Market::MarketData->find_last_session_open_index(),
#   que detecta el hueco de tiempo más grande antes de esa vela (cierre
#   diario, corte de fin de semana, etc.).
# - bos_vwap_distance: ancla en la vela del último BOS *externo*
#   (`bos_ext`, ver Structure más arriba) confirmado hasta esa vela.
# - choch_vwap_distance: ancla en la vela del último CHoCH *externo*
#   (`choch_ext`) confirmado hasta esa vela.
# - pivot_vwap_distance: ancla en la última vela marcada como pivote
#   (`is_pivot`, alta o baja, ver detección de pivotes más arriba).
#
# Mientras la ancla correspondiente todavía no existe (por ejemplo, antes
# del primer BOS/CHoCH/pivote de la serie), la distancia queda en `0`.
my $vwap_anchored = Market::Indicators::VWAPAnchored->new();

my @session_anchor_idx = (0) x $total_rows;   # siempre ancla en la vela 0

my @open_anchor_idx;
print STDERR "Calculando anclas de sesión (open_vwap)...\n";
{
    # Réplica O(n) de Market::MarketData->find_last_session_open_index():
    # detecta, en una sola pasada hacia adelante, el hueco de tiempo más
    # grande entre dos velas consecutivas (cierre diario, corte de fin de
    # semana, etc.) y propaga (forward-fill) el índice de la vela de
    # "apertura" de la sesión vigente. El método original de MarketData.pm
    # escanea hacia atrás desde cada vela (O(n) por llamada, O(n^2) en
    # total sobre toda la serie); aquí basta con recordar el último hueco
    # significativo visto hasta el momento (O(1) amortizado por vela).
    # Mismo criterio de "hueco significativo" que el original: > 3 veces el
    # intervalo típico entre las dos primeras velas de la serie.
    my $e0 = _parse_epoch($data[0]->{time});
    my $e1 = $total_rows > 1 ? _parse_epoch($data[1]->{time}) : undef;
    my $typical = (defined $e0 && defined $e1 && $e1 - $e0 > 0) ? $e1 - $e0 : 60;
    my $threshold = $typical * 3;

    my $last_session_open = 0;
    my $prev_epoch = $e0;
    $open_anchor_idx[0] = 0 if $total_rows > 0;

    for my $i (1 .. $total_rows - 1) {
        _print_progress($i + 1, $total_rows, "Anclas de sesión");
        my $epoch = _parse_epoch($data[$i]->{time});

        if (defined $prev_epoch && defined $epoch) {
            my $gap = $epoch - $prev_epoch;
            $last_session_open = $i if $gap > $threshold;
        }

        $open_anchor_idx[$i] = $last_session_open;
        $prev_epoch = $epoch if defined $epoch;
    }
}

my (@bos_anchor_idx, @choch_anchor_idx, @pivot_anchor_idx);
my ($last_bos_ext_idx, $last_choch_ext_idx, $last_pivot_idx);
print STDERR "Calculando anclas de BOS/CHoCH/pivote...\n";
for my $i (0 .. $total_rows - 1) {
    _print_progress($i + 1, $total_rows, "Anclas BOS/CHoCH/pivote");
    $last_bos_ext_idx   = $i if $bos_ext[$i];
    $last_choch_ext_idx = $i if $choch_ext[$i];
    $last_pivot_idx     = $i if $is_pivot[$i];

    $bos_anchor_idx[$i]   = $last_bos_ext_idx;
    $choch_anchor_idx[$i] = $last_choch_ext_idx;
    $pivot_anchor_idx[$i] = $last_pivot_idx;
}

print STDERR "Calculando VWAP anclado: session_vwap...\n";
my $session_vwap_distance = compute_anchored_vwap_distances(
    $vwap_anchored, \@session_anchor_idx, \@data, $atr_values, $total_rows);
print STDERR "Calculando VWAP anclado: open_vwap...\n";
my $open_vwap_distance = compute_anchored_vwap_distances(
    $vwap_anchored, \@open_anchor_idx, \@data, $atr_values, $total_rows);
print STDERR "Calculando VWAP anclado: bos_vwap...\n";
my $bos_vwap_distance = compute_anchored_vwap_distances(
    $vwap_anchored, \@bos_anchor_idx, \@data, $atr_values, $total_rows);
print STDERR "Calculando VWAP anclado: choch_vwap...\n";
my $choch_vwap_distance = compute_anchored_vwap_distances(
    $vwap_anchored, \@choch_anchor_idx, \@data, $atr_values, $total_rows);
print STDERR "Calculando VWAP anclado: pivot_vwap...\n";
my $pivot_vwap_distance = compute_anchored_vwap_distances(
    $vwap_anchored, \@pivot_anchor_idx, \@data, $atr_values, $total_rows);

# --- Ancla del Volume Profile: última vela de cambio de tendencia ---
# Se ancla cada vez que `trend_series` cambia de valor respecto a la vela
# anterior (incluida la vela 0, que siempre marca el inicio de un tramo).
my @trend_anchor_idx = (undef) x $total_rows;
{
    my $last_trend_change_idx;
    print STDERR "Calculando anclas de cambio de tendencia (Volume Profile)...\n";
    for my $i (0 .. $total_rows - 1) {
        _print_progress($i + 1, $total_rows, "Anclas de cambio de tendencia");
        $last_trend_change_idx = $i if $i == 0 || $trend_series[$i] != $trend_series[$i - 1];
        $trend_anchor_idx[$i] = $last_trend_change_idx;
    }
}

# Volume Profile Anclado (Market::Indicators::VolumeProfileAnchored): se
# ancla en la última vela de cambio de tendencia (`trend_ext`, ver arriba)
# y se recalcula, en cada vela, con todas las velas desde esa ancla hasta
# la vela actual (ventana expansiva), respetando el mismo criterio de "no
# mirar al futuro" que el resto de columnas del script. A diferencia del
# VWAP Anclado (que devuelve, en una sola llamada, la serie completa de
# valores acumulados del tramo), VolumeProfileAnchored no soporta cálculo
# incremental: cada vela requiere su propia llamada a calculate_until()
# con el rango completo desde el ancla, por lo que el costo es
# O(largo_del_tramo) por vela (en el peor caso, si la tendencia se
# mantiene sin cambios durante un tramo muy largo, el costo total de ese
# tramo es O(largo^2)).
# poc/vah/val se guardan normalizados por ATR, igual criterio que el resto
# de columnas `distance_*` del script: `(nivel - close) / ATR`. Mientras
# no exista ancla todavía (no debería ocurrir, ya que la vela 0 siempre
# ancla) o el ATR de la vela sea `0`, el valor es `0`.
my $volume_profile = Market::Indicators::VolumeProfileAnchored->new();
my @poc = (0) x $total_rows;
my @vah = (0) x $total_rows;
my @val = (0) x $total_rows;

print STDERR "Calculando Volume Profile anclado (cambio de tendencia)...\n";
for my $i (0 .. $total_rows - 1) {
    _print_progress($i + 1, $total_rows, "Volume Profile anclado");
    my $anchor = $trend_anchor_idx[$i];
    next unless defined $anchor;

    my $result  = $volume_profile->calculate_until(\@data, $anchor, $i);
    my $close   = $data[$i]->{close};
    my $atr_raw = $atr_values->[$i] // 0;
    next unless $atr_raw > 0;

    $poc[$i] = ($result->{poc_price} - $close) / $atr_raw if defined $result->{poc_price};
    $vah[$i] = ($result->{vah}       - $close) / $atr_raw if defined $result->{vah};
    $val[$i] = ($result->{val}       - $close) / $atr_raw if defined $result->{val};
}

# 2. Generación Retroactiva y Escritura en CSV
open my $fh_out, ">", $output_file or die "No se pudo crear $output_file: $!";
$csv->print($fh_out, [
    # --- Tiempo ---
    "minute", "hour", "day", "month", "year",
    # --- Vela (OHLCV, ATR y geometría de la vela) ---
    "open (pip)", "high (pip)", "low (pip)", "close (pip)",
    "volume", "atr (pct)",
    "body", "upper_wick", "lower_wick", "candle_type", "momentum", "lenght",
    # --- Pivotes (detección propia del script) ---
    "pivote", "pivote3", "pivote5", "pivote10", "pivote15",
    # --- Estructura de mercado (Market::Indicators::SMC_Structures / Structure) ---
    "trend_ext", "bos_ext", "bos_int", "choch_ext", "choch_int", "eqh", "eql",
    "bars_since_eqh", "bars_since_eql", "distance_eqh", "distance_eql",
    "bars_since_bos", "distance_bos", "bars_since_choch", "distance_choch",
    # --- Fair Value Gaps (Market::Indicators::FVG) ---
    "inside_fvg", "distance_FVG", "fvg_size", "bars_since_fvg",
    # --- Order Blocks (Market::Indicators::OrderBlocks) ---
    "inside_order_block", "distance_ob", "ob_type", "bars_since_ob",
    # --- Último HH/LL confirmado (SMC_Structures) ---
    "distance_hh", "distance_ll",
    # --- Fibonacci (Market::Indicators::Fibonacci) ---
    "nearest_fib_level",
    # --- Niveles MTF: alto/bajo del período anterior (día/semana/mes) ---
    "distance_daily_high", "distance_daily_low",
    "distance_weekly_high", "distance_weekly_low",
    "distance_monthly_high", "distance_monthly_low",
    # --- Liquidez y swings menores (Market::Indicators::Liquidity) ---
    "distance_bsl", "distance_ssl",
    "lq_sweep_bsl", "lq_sweep_ssl", "lq_grab", "lq_run",
    "bars_since_lq_event",
    "is_sh", "is_sl", "distance_sh", "distance_sl",
    # --- Tendencia interna multi-temporalidad (ZigzagInternal re-muestreado) ---
    "trend_int_15min", "trend_int_30min", "trend_int_1hr", "trend_int_2hr", "trend_int_4hr",
    # --- HalfTrend (Market::Indicators::HalfTrend) ---
    "half_trend", "distance_high_half_trend", "distance_low_half_trend",
    # --- SuperTrend (Market::Indicators::Supertrend) ---
    "super_trend", "distance_high_super_trend", "distance_low_super_trend",
    # --- Range Filter (Market::Indicators::RangeFilter) ---
    "range_filter", "distance_high_range_filter", "distance_low_range_filter",
    # --- VWAP Anclado (Market::Indicators::VWAPAnchored) ---
    "session_vwap_distance", "open_vwap_distance", "bos_vwap_distance",
    "choch_vwap_distance", "pivot_vwap_distance",
    # --- Volume Profile Anclado (Market::Indicators::VolumeProfileAnchored) ---
    "poc", "vah", "val"
]);

# Volumen relativo: en vez de volcar el volumen crudo (cuya escala varía
# muchísimo entre activos/sesiones/temporalidades y no es comparable entre
# sí), se guarda la razón entre el volumen de la vela y la media móvil de
# volumen de las últimas VOLUME_SMA_PERIOD velas (incluyendo la vela
# actual, sin mirar al futuro). Un valor de `1` indica volumen igual al
# promedio reciente; `> 1`, por encima del promedio; `< 1`, por debajo.
# Se usa una suma prefijo para que el costo total sea O(n) en vez de O(n *
# VOLUME_SMA_PERIOD).
use constant VOLUME_SMA_PERIOD => 20;
my @volume_ratio = (0) x $total_rows;
{
    my $prefix_sum = 0;
    my @prefix = (0) x ($total_rows + 1);
    for my $i (0 .. $total_rows - 1) {
        my $vol = $data[$i]->{volume};
        $vol = 0 unless defined $vol && $vol ne '';
        $prefix_sum += $vol;
        $prefix[$i + 1] = $prefix_sum;
    }

    for my $i (0 .. $total_rows - 1) {
        my $start = $i - VOLUME_SMA_PERIOD + 1;
        $start = 0 if $start < 0;
        my $count = $i - $start + 1;
        my $avg   = $count > 0 ? ($prefix[$i + 1] - $prefix[$start]) / $count : 0;

        my $vol = $data[$i]->{volume};
        $vol = 0 unless defined $vol && $vol ne '';

        $volume_ratio[$i] = $avg > 0 ? $vol / $avg : 0;
    }
}

print STDERR "Generando output.csv ($total_rows velas)...\n";

for my $i (0 .. $total_rows - 1) {
    _print_progress($i + 1, $total_rows, "Generando output.csv");

    # Pip "de verdad": variacion en puntos porcentuales (pips) respecto al cierre
    # de la vela anterior, en vez de precio absoluto * multiplicador.
    my $prev_close = $i > 0 ? $data[$i - 1]->{close} : $data[$i]->{open};

    my $open_pip  = ($data[$i]->{open}  - $prev_close) / $prev_close * $pip_multiplier;
    my $high_pip  = ($data[$i]->{high}  - $prev_close) / $prev_close * $pip_multiplier;
    my $low_pip   = ($data[$i]->{low}   - $prev_close) / $prev_close * $pip_multiplier;
    my $close_pip = ($data[$i]->{close} - $prev_close) / $prev_close * $pip_multiplier;

    my $volume = $volume_ratio[$i];

    # ATR calculado por Market::Indicators::ATR sobre precios absolutos;
    # se guarda como % del precio (ATR / close) para que sea comparable
    # entre activos con precios distintos, en vez de en pips absolutos.
    # Durante el periodo de calentamiento se guarda 0 en vez de dejarlo
    # vacío.
    my $atr_raw = $atr_values->[$i];
    my $close_for_atr = $data[$i]->{close};
    my $atr_pct = (defined $atr_raw && $close_for_atr && $close_for_atr > 0)
        ? $atr_raw / $close_for_atr : 0;

    # Geometría de la vela (cuerpo, mechas, largo total) y momentum,
    # normalizados por ATR (mismo criterio que el resto de columnas
    # `distance_*`/`fvg_size`), en vez de en pips absolutos: así son
    # comparables entre distintos regímenes de volatilidad, a diferencia
    # de open/high/low/close_pip, que siguen siendo relativos al cierre
    # anterior.
    my $c_open  = $data[$i]->{open};
    my $c_high  = $data[$i]->{high};
    my $c_low   = $data[$i]->{low};
    my $c_close = $data[$i]->{close};
    my $body_max = $c_open > $c_close ? $c_open : $c_close;
    my $body_min = $c_open < $c_close ? $c_open : $c_close;

    my $atr_raw_for_geom = $atr_raw // 0;
    my $body        = $atr_raw_for_geom > 0 ? abs($c_close - $c_open) / $atr_raw_for_geom : 0;
    my $upper_wick  = $atr_raw_for_geom > 0 ? ($c_high - $body_max) / $atr_raw_for_geom : 0;
    my $lower_wick  = $atr_raw_for_geom > 0 ? ($body_min - $c_low) / $atr_raw_for_geom : 0;
    my $candle_type = $c_close >= $c_open ? 1 : -1;
    my $momentum    = $atr_raw_for_geom > 0 ? ($c_close - $prev_close) / $atr_raw_for_geom : 0;
    my $length      = $atr_raw_for_geom > 0 ? ($c_high - $c_low) / $atr_raw_for_geom : 0;

    my ($minute, $hour, $day, $month, $year) = _extract_time_parts($data[$i]->{time});
    $minute //= 0;
    $hour   //= 0;
    $day    //= 0;
    $month  //= 0;
    $year   //= 0;

    my $trend = $trend_series[$i];

    my $atr_raw_for_dist = $atr_values->[$i] // 0;
    my $distance_hh = (defined $hh_price[$i] && $atr_raw_for_dist > 0)
        ? ($hh_price[$i] - $data[$i]->{close}) / $atr_raw_for_dist : 0;
    my $distance_ll = (defined $ll_price[$i] && $atr_raw_for_dist > 0)
        ? ($ll_price[$i] - $data[$i]->{close}) / $atr_raw_for_dist : 0;

    my $pivote = $is_pivot[$i];

    my $pivote3_count  = 0;
    my $pivote5_count  = 0;
    my $pivote10_count = 0;
    my $pivote15_count = 0;

    for my $j (1 .. 15) {
        last if ($i + $j) >= $total_rows;
        if ($is_pivot[$i + $j]) {
            $pivote3_count++  if $j <= 3;
            $pivote5_count++  if $j <= 5;
            $pivote10_count++ if $j <= 10;
            $pivote15_count++;
        }
    }

    # Cada conteo se normaliza dividiendo por el tamaño de su propia
    # ventana, para que las 4 columnas queden en el mismo rango [0, 1] y
    # sean comparables entre sí (antes, pivote3 iba de 0-3, pivote15 de
    # 0-15, etc.).
    my $pivote3  = $pivote3_count  / 3;
    my $pivote5  = $pivote5_count  / 5;
    my $pivote10 = $pivote10_count / 10;
    my $pivote15 = $pivote15_count / 15;

    $csv->print($fh_out, [
        # --- Tiempo ---
        $minute,
        $hour,
        $day,
        $month,
        $year,
        # --- Vela (OHLCV, ATR y geometría de la vela) ---
        sprintf("%.4f", $open_pip),
        sprintf("%.4f", $high_pip),
        sprintf("%.4f", $low_pip),
        sprintf("%.4f", $close_pip),
        sprintf("%.4f", $volume),
        sprintf("%.4f", $atr_pct),
        sprintf("%.4f", $body),
        sprintf("%.4f", $upper_wick),
        sprintf("%.4f", $lower_wick),
        $candle_type,
        sprintf("%.4f", $momentum),
        sprintf("%.4f", $length),
        # --- Pivotes ---
        $pivote,
        sprintf("%.4f", $pivote3),
        sprintf("%.4f", $pivote5),
        sprintf("%.4f", $pivote10),
        sprintf("%.4f", $pivote15),
        # --- Estructura de mercado ---
        $trend,
        $bos_ext[$i],
        $bos_int[$i],
        $choch_ext[$i],
        $choch_int[$i],
        $eqh[$i],
        $eql[$i],
        sprintf("%.4f", $bars_since_eqh[$i]),
        sprintf("%.4f", $bars_since_eql[$i]),
        sprintf("%.4f", $distance_eqh[$i]),
        sprintf("%.4f", $distance_eql[$i]),
        sprintf("%.4f", $bars_since_bos[$i]),
        sprintf("%.4f", $distance_bos[$i]),
        sprintf("%.4f", $bars_since_choch[$i]),
        sprintf("%.4f", $distance_choch[$i]),
        # --- Fair Value Gaps ---
        $inside_fvg[$i],
        sprintf("%.4f", $distance_fvg[$i]),
        sprintf("%.4f", $fvg_size[$i]),
        sprintf("%.4f", $bars_since_fvg[$i]),
        # --- Order Blocks ---
        $inside_ob[$i],
        sprintf("%.4f", $distance_ob[$i]),
        $ob_type[$i],
        sprintf("%.4f", $bars_since_ob[$i]),
        # --- Último HH/LL confirmado ---
        sprintf("%.4f", $distance_hh),
        sprintf("%.4f", $distance_ll),
        # --- Fibonacci ---
        sprintf("%.4f", $nearest_fib_level[$i]),
        # --- Niveles MTF ---
        sprintf("%.4f", $distance_daily_high[$i]),
        sprintf("%.4f", $distance_daily_low[$i]),
        sprintf("%.4f", $distance_weekly_high[$i]),
        sprintf("%.4f", $distance_weekly_low[$i]),
        sprintf("%.4f", $distance_monthly_high[$i]),
        sprintf("%.4f", $distance_monthly_low[$i]),
        # --- Liquidez y swings menores ---
        sprintf("%.4f", $distance_bsl[$i]),
        sprintf("%.4f", $distance_ssl[$i]),
        $lq_sweep_bsl[$i],
        $lq_sweep_ssl[$i],
        $lq_grab[$i],
        $lq_run[$i],
        sprintf("%.4f", $bars_since_lq_event[$i]),
        $is_sh[$i],
        $is_sl[$i],
        sprintf("%.4f", $distance_sh[$i]),
        sprintf("%.4f", $distance_sl[$i]),
        # --- Tendencia interna multi-temporalidad ---
        $trend_int_15min->[$i],
        $trend_int_30min->[$i],
        $trend_int_1hr->[$i],
        $trend_int_2hr->[$i],
        $trend_int_4hr->[$i],
        # --- HalfTrend ---
        $half_trend[$i],
        sprintf("%.4f", $distance_high_half_trend[$i]),
        sprintf("%.4f", $distance_low_half_trend[$i]),
        # --- SuperTrend ---
        $super_trend[$i],
        sprintf("%.4f", $distance_high_super_trend[$i]),
        sprintf("%.4f", $distance_low_super_trend[$i]),
        # --- Range Filter ---
        $range_filter[$i],
        sprintf("%.4f", $distance_high_range_filter[$i]),
        sprintf("%.4f", $distance_low_range_filter[$i]),
        # --- VWAP Anclado ---
        sprintf("%.4f", $session_vwap_distance->[$i]),
        sprintf("%.4f", $open_vwap_distance->[$i]),
        sprintf("%.4f", $bos_vwap_distance->[$i]),
        sprintf("%.4f", $choch_vwap_distance->[$i]),
        sprintf("%.4f", $pivot_vwap_distance->[$i]),
        # --- Volume Profile Anclado ---
        sprintf("%.4f", $poc[$i]),
        sprintf("%.4f", $vah[$i]),
        sprintf("%.4f", $val[$i])
    ]);
}
close $fh_out;

print "Proceso finalizado con guardado múltiple de pivotes. Output en $output_file.\n";
