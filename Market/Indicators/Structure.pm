package Market::Indicators::Structure;

use strict;
use warnings;

=head1 NOMBRE

Market::Indicators::Structure - Motor de detección de BOS y CHoCH externo e
interno, replicando fielmente la lógica del indicador PineScript
"Smart Money Concepts [LuxAlgo]".

=head1 DESCRIPCIÓN

El PineScript original detecta pivotes usando la función leg(size):

  leg(size) => high[size] > ta.highest(size) ? BEARISH_LEG
             : low[size]  < ta.lowest(size)  ? BULLISH_LEG

  Un nuevo pivote ocurre cuando cambia el valor del "leg".
  - pivotHigh  => cambio de BULLISH_LEG a BEARISH_LEG (se registra el high[size])
  - pivotLow   => cambio de BEARISH_LEG a BULLISH_LEG (se registra el low[size])

Hay dos tiers:
  - SWING (externo): size = swingsLengthInput (50 en el original)
  - INTERNAL:        size = 5

Para cada tier, displayStructure() detecta:
  - BOS:   cuando close cruza el último pivote HIGH/LOW en la dirección del
           trend actual (confirma la tendencia).
  - CHoCH: cuando close cruza el último pivote HIGH/LOW en dirección OPUESTA
           al trend actual (cambio de carácter).

Además, se detectan los eventos EQH/EQL (Equal Highs / Equal Lows),
replicando la lógica del PineScript original. A diferencia de BOS/CHoCH,
LuxAlgo NO usa los pivotes swing (50 barras) para esto: usa una detección de
pivotes propia y mucho más corta (ta.pivothigh/pivotlow con longitud
eq_len, 3 barras a cada lado por defecto), ya que con una ventana de 50
barras el precio recorre demasiado terreno entre pivote y pivote como para
que dos lleguen a coincidir dentro del umbral de ATR.

  Un pivote HIGH corto se confirma en la barra $p+eq_len si high[$p] es
  estrictamente mayor que los highs de las $eq_len barras a cada lado.
  Cada vez que se confirma un nuevo pivote HIGH corto, se compara con el
  pivote HIGH corto inmediatamente anterior. Si la diferencia absoluta
  entre ambos es menor o igual que (eq_threshold * ATR[del pivote]), se
  registra un evento "EQH". Análogamente para los pivotes LOW y "EQL".

Parámetros:
  swing_size    => ventana para pivotes estructurales/externos (def: 50)
  internal_size => ventana para pivotes internos (def: 5)
  eq_len        => longitud del pivote corto usado sólo para EQH/EQL (def: 3)
  eq_threshold  => múltiplo de ATR usado como tolerancia para EQH/EQL (def: 0.1)

=cut

use constant BULLISH_LEG => 1;
use constant BEARISH_LEG => 0;
use constant BULLISH     => 1;
use constant BEARISH     => -1;
use constant UNKNOWN     => 0;

sub new {
    my ($class, %args) = @_;

    my $self = {
        swing_size    => $args{swing_size}    // 50,
        internal_size => $args{internal_size} // 5,
        eq_len        => $args{eq_len}        // 3,
        eq_threshold  => $args{eq_threshold}  // 0.1,
        events        => [],
    };

    return bless $self, $class;
}

sub reset {
    my ($self) = @_;
    $self->{events} = [];
}

=head2 calculate_until($candles, $atr_values, $until_index)

Recalcula desde cero todos los eventos de estructura hasta $until_index.
Devuelve un hashref con la clave C<events>, lista de hashrefs con campos:
  type       => 'BOS_UP' | 'BOS_DOWN' | 'CHoCH_UP' | 'CHoCH_DOWN' | 'EQH' | 'EQL'
  tier       => 'external' | 'internal'
  index      => índice de la barra de ruptura (o del pivote más reciente en EQH/EQL)
  level_index => índice donde se originó el nivel roto (o del pivote previo en EQH/EQL)
  level_price => precio del nivel roto

Para los eventos "EQH"/"EQL" (sólo tier "external") se agregan además:
  price1 => precio del primer pivote (el más antiguo de los dos)
  price2 => precio del segundo pivote (el más reciente)

=cut

sub calculate_until {
    my ($self, $candles, $atr_values, $until_index) = @_;

    $self->reset();
    return { events => $self->{events} }
        if !defined $until_index || $until_index < 2;

    # ---- Estado para el tier SWING (externo) ----
    my $swing_leg     = BEARISH_LEG;   # leg actual del tier swing
    my $swing_pivot_h = undef;         # { price, index }
    my $swing_pivot_l = undef;
    my $swing_trend   = UNKNOWN;
    my $swing_h_crossed = 0;
    my $swing_l_crossed = 0;

    # ---- Estado para el tier INTERNAL ----
    my $int_leg     = BEARISH_LEG;
    my $int_pivot_h = undef;
    my $int_pivot_l = undef;
    my $int_trend   = UNKNOWN;
    my $int_h_crossed = 0;
    my $int_l_crossed = 0;

    # ---- Estado para EQH/EQL (pivotes cortos independientes) ----
    my $eq_pivot_h = undef;
    my $eq_pivot_l = undef;

    # Necesitamos acceso eficiente a sliding-window max/min.
    # Mantenemos un buffer circular para cada size.
    my $sw     = $self->{swing_size};
    my $is     = $self->{internal_size};
    my $eq_len = $self->{eq_len};
    my $eqth   = $self->{eq_threshold};

    for my $i (0 .. $until_index) {
        my $bar = $candles->[$i];
        next unless $bar;

        my $high  = $bar->{high};
        my $low   = $bar->{low};
        my $close = $bar->{close};

        # ----------------------------------------------------------------
        # Calcular leg para cada tier
        # ----------------------------------------------------------------
        my ($sw_leg_new, $is_leg_new);

        # Swing leg
        {
            my $size   = $sw;
            my $start  = $i >= $size ? $i - $size + 1 : 0;

            # ta.highest/lowest en PineScript excluye la barra [size],
            # es decir mira las últimas $size barras SIN incluir la de [size].
            # En nuestro array: highest de ($i-$size+1 .. $i-1), es decir $size-1 barras.
            my $win_start = ($i >= $size) ? $i - $size + 1 : 0;
            my $win_end   = $i - 1;  # excluye la barra actual

            my ($win_high, $win_low) = _window_high_low($candles, $win_start, $win_end);

            # high[$size] = high del índice ($i - $size)
            my $pivot_bar = ($i >= $size) ? $candles->[$i - $size] : undef;
            my $ph = defined $pivot_bar ? $pivot_bar->{high} : undef;
            my $pl = defined $pivot_bar ? $pivot_bar->{low}  : undef;

            if (defined $ph && defined $win_high && $ph > $win_high) {
                $sw_leg_new = BEARISH_LEG;
            } elsif (defined $pl && defined $win_low && $pl < $win_low) {
                $sw_leg_new = BULLISH_LEG;
            } else {
                $sw_leg_new = $swing_leg;
            }
        }

        # Internal leg
        {
            my $size      = $is;
            my $win_start = ($i >= $size) ? $i - $size + 1 : 0;
            my $win_end   = $i - 1;

            my ($win_high, $win_low) = _window_high_low($candles, $win_start, $win_end);

            my $pivot_bar = ($i >= $size) ? $candles->[$i - $size] : undef;
            my $ph = defined $pivot_bar ? $pivot_bar->{high} : undef;
            my $pl = defined $pivot_bar ? $pivot_bar->{low}  : undef;

            if (defined $ph && defined $win_high && $ph > $win_high) {
                $is_leg_new = BEARISH_LEG;
            } elsif (defined $pl && defined $win_low && $pl < $win_low) {
                $is_leg_new = BULLISH_LEG;
            } else {
                $is_leg_new = $int_leg;
            }
        }

        # ----------------------------------------------------------------
        # Detectar nuevos pivotes cuando cambia el leg
        # ----------------------------------------------------------------

        # SWING tier
        if ($sw_leg_new != $swing_leg) {
            my $prev_leg = $swing_leg;
            $swing_leg = $sw_leg_new;

            if ($prev_leg == BULLISH_LEG && $sw_leg_new == BEARISH_LEG) {
                # startOfBearishLeg => pivotHigh at high[$swing_size]
                my $pivot_i   = $i - $sw;
                my $pivot_bar = ($pivot_i >= 0) ? $candles->[$pivot_i] : undef;
                if (defined $pivot_bar) {
                    $swing_pivot_h = { price => $pivot_bar->{high}, index => $pivot_i };
                    $swing_h_crossed = 0;
                }
            } elsif ($prev_leg == BEARISH_LEG && $sw_leg_new == BULLISH_LEG) {
                # startOfBullishLeg => pivotLow at low[$swing_size]
                my $pivot_i   = $i - $sw;
                my $pivot_bar = ($pivot_i >= 0) ? $candles->[$pivot_i] : undef;
                if (defined $pivot_bar) {
                    $swing_pivot_l = { price => $pivot_bar->{low}, index => $pivot_i };
                    $swing_l_crossed = 0;
                }
            }
        }

        # INTERNAL tier
        if ($is_leg_new != $int_leg) {
            my $prev_leg = $int_leg;
            $int_leg = $is_leg_new;

            if ($prev_leg == BULLISH_LEG && $is_leg_new == BEARISH_LEG) {
                my $pivot_i   = $i - $is;
                my $pivot_bar = ($pivot_i >= 0) ? $candles->[$pivot_i] : undef;
                if (defined $pivot_bar) {
                    $int_pivot_h = { price => $pivot_bar->{high}, index => $pivot_i };
                    $int_h_crossed = 0;
                }
            } elsif ($prev_leg == BEARISH_LEG && $is_leg_new == BULLISH_LEG) {
                my $pivot_i   = $i - $is;
                my $pivot_bar = ($pivot_i >= 0) ? $candles->[$pivot_i] : undef;
                if (defined $pivot_bar) {
                    $int_pivot_l = { price => $pivot_bar->{low}, index => $pivot_i };
                    $int_l_crossed = 0;
                }
            }
        }

        # ----------------------------------------------------------------
        # EQH / EQL — pivotes cortos e independientes de los pivotes swing.
        # Usan ta.pivothigh/pivotlow(eq_len, eq_len): el pivote en el índice
        # $p = $i - $eq_len se confirma en $i cuando su high/low es
        # estrictamente el extremo entre las $eq_len barras a cada lado.
        # ----------------------------------------------------------------
        if ($i >= 2 * $eq_len) {
            my $p      = $i - $eq_len;
            my $center = $candles->[$p];

            if ($center) {
                my $is_pivot_high = 1;
                my $is_pivot_low  = 1;

                for my $j (($p - $eq_len) .. ($p + $eq_len)) {
                    next if $j == $p;
                    my $cj = $candles->[$j];
                    next unless $cj;
                    $is_pivot_high = 0 if $cj->{high} >= $center->{high};
                    $is_pivot_low  = 0 if $cj->{low}  <= $center->{low};
                }

                if ($is_pivot_high) {
                    if (defined $eq_pivot_h) {
                        my $atr = $atr_values->[$p] // $atr_values->[$i];
                        if (defined $atr
                            && abs($center->{high} - $eq_pivot_h->{price}) <= $eqth * $atr) {
                            push @{$self->{events}}, {
                                type        => 'EQH',
                                tier        => 'external',
                                index       => $p,
                                level_index => $eq_pivot_h->{index},
                                level_price => $eq_pivot_h->{price},
                                price1      => $eq_pivot_h->{price},
                                price2      => $center->{high},
                            };
                        }
                    }
                    $eq_pivot_h = { price => $center->{high}, index => $p };
                }

                if ($is_pivot_low) {
                    if (defined $eq_pivot_l) {
                        my $atr = $atr_values->[$p] // $atr_values->[$i];
                        if (defined $atr
                            && abs($center->{low} - $eq_pivot_l->{price}) <= $eqth * $atr) {
                            push @{$self->{events}}, {
                                type        => 'EQL',
                                tier        => 'external',
                                index       => $p,
                                level_index => $eq_pivot_l->{index},
                                level_price => $eq_pivot_l->{price},
                                price1      => $eq_pivot_l->{price},
                                price2      => $center->{low},
                            };
                        }
                    }
                    $eq_pivot_l = { price => $center->{low}, index => $p };
                }
            }
        }

        # ----------------------------------------------------------------
        # displayStructure — detectar BOS / CHoCH por crossover del close
        # ----------------------------------------------------------------

        # SWING TIER — bullish cross (close sube sobre pivot high)
        if (defined $swing_pivot_h && !$swing_h_crossed) {
            my $prev_close = ($i > 0 && $candles->[$i-1]) ? $candles->[$i-1]->{close} : $close;

            if ($prev_close <= $swing_pivot_h->{price} && $close > $swing_pivot_h->{price}) {
                my $tag = ($swing_trend == BEARISH) ? 'CHoCH_UP' : 'BOS_UP';
                $swing_trend    = BULLISH;
                $swing_h_crossed = 1;

                push @{$self->{events}}, {
                    type        => $tag,
                    tier        => 'external',
                    index       => $i,
                    level_index => $swing_pivot_h->{index},
                    level_price => $swing_pivot_h->{price},
                };
            }
        }

        # SWING TIER — bearish cross (close baja bajo pivot low)
        if (defined $swing_pivot_l && !$swing_l_crossed) {
            my $prev_close = ($i > 0 && $candles->[$i-1]) ? $candles->[$i-1]->{close} : $close;

            if ($prev_close >= $swing_pivot_l->{price} && $close < $swing_pivot_l->{price}) {
                my $tag = ($swing_trend == BULLISH) ? 'CHoCH_DOWN' : 'BOS_DOWN';
                $swing_trend    = BEARISH;
                $swing_l_crossed = 1;

                push @{$self->{events}}, {
                    type        => $tag,
                    tier        => 'external',
                    index       => $i,
                    level_index => $swing_pivot_l->{index},
                    level_price => $swing_pivot_l->{price},
                };
            }
        }

        # INTERNAL TIER — bullish cross
        if (defined $int_pivot_h && !$int_h_crossed) {
            # Filtro de confluencia del PineScript (internalHigh != swingHigh)
            my $same_as_swing = defined $swing_pivot_h
                && defined $int_pivot_h
                && $int_pivot_h->{price} == $swing_pivot_h->{price};
            unless ($same_as_swing) {
                my $prev_close = ($i > 0 && $candles->[$i-1]) ? $candles->[$i-1]->{close} : $close;

                if ($prev_close <= $int_pivot_h->{price} && $close > $int_pivot_h->{price}) {
                    my $tag = ($int_trend == BEARISH) ? 'CHoCH_UP' : 'BOS_UP';
                    $int_trend    = BULLISH;
                    $int_h_crossed = 1;

                    push @{$self->{events}}, {
                        type        => $tag,
                        tier        => 'internal',
                        index       => $i,
                        level_index => $int_pivot_h->{index},
                        level_price => $int_pivot_h->{price},
                    };
                }
            }
        }

        # INTERNAL TIER — bearish cross
        if (defined $int_pivot_l && !$int_l_crossed) {
            my $same_as_swing = defined $swing_pivot_l
                && defined $int_pivot_l
                && $int_pivot_l->{price} == $swing_pivot_l->{price};
            unless ($same_as_swing) {
                my $prev_close = ($i > 0 && $candles->[$i-1]) ? $candles->[$i-1]->{close} : $close;

                if ($prev_close >= $int_pivot_l->{price} && $close < $int_pivot_l->{price}) {
                    my $tag = ($int_trend == BULLISH) ? 'CHoCH_DOWN' : 'BOS_DOWN';
                    $int_trend    = BEARISH;
                    $int_l_crossed = 1;

                    push @{$self->{events}}, {
                        type        => $tag,
                        tier        => 'internal',
                        index       => $i,
                        level_index => $int_pivot_l->{index},
                        level_price => $int_pivot_l->{price},
                    };
                }
            }
        }
    }

    return { events => $self->{events} };
}

# Retorna (max_high, min_low) de las velas en el rango [$start_i .. $end_i].
# Retorna (undef, undef) si el rango es vacío.
sub _window_high_low {
    my ($candles, $start_i, $end_i) = @_;

    return (undef, undef) if $start_i > $end_i || $start_i < 0;

    my ($max_h, $min_l);
    for my $j ($start_i .. $end_i) {
        my $c = $candles->[$j];
        next unless $c;
        $max_h = $c->{high} if !defined $max_h || $c->{high} > $max_h;
        $min_l = $c->{low}  if !defined $min_l || $c->{low}  < $min_l;
    }
    return ($max_h, $min_l);
}

1;
