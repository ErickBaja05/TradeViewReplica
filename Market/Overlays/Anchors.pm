package Market::Indicators::Anchors;

use strict;
use warnings;

=head1 NOMBRE

Market::Indicators::Anchors - Motor de cálculo de "Dynamic Swing Anchored
VWAP" (réplica de anchors.txt / LuxAlgo + Zeiierman + Aymen Haddaji),
implementando el MISMO CONTRATO incremental que
L<Market::Indicators::Structure> y L<Market::Indicators::Liquidity>:

  my $engine = Market::Indicators::Anchors->new(%args);
  $engine->reset();
  my $result = $engine->update_last($candles, $atr_values, $i);

C<update_last> se alimenta vela a vela (una sola vez por índice C<$i>,
en orden creciente) y devuelve SIEMPRE el estado acumulado completo del
indicador, listo para que las capas visuales (Overlays) lo consuman con
C<set_result($result)>.

=head1 DESCRIPCIÓN

El indicador original produce tres grupos de elementos visuales, que en
este proyecto se reparten en TRES overlays independientes (y por lo tanto
tres opciones de menú independientes):

  - "Ghost Anchors" (Market::Overlays::GhostAnchors)
        Marcadores de pivotes REGULARES (▼/▲) y pivotes PERDIDOS/fantasma
        (👻, "missed reversal levels").  -> clave C<markers>

  - "Ghost Lines" (Market::Overlays::GhostLines)
        El zigzag punteado/sólido que conecta pivote con pivote
        (equivalente a la línea C<zigzag> del PineScript), más el
        "rastro" de niveles horizontales (C<ghost_level>) que deja cada
        pivote fantasma hasta el siguiente evento.
        -> claves C<ghost_lines> y C<ghost_level_segments>

  - "Ghost VWAP" (Market::Overlays::GhostVWAP)
        El VWAP Anclado (con bandas de desviación estándar 1/2/3 sigma)
        que se recalcula en vivo desde el pivote fantasma "vivo" (el
        extremo que se está formando desde el último pivote confirmado),
        junto con el marcador 👻 flotante que lo origina.
        -> claves C<live_ghost> y C<ghost_vwap>

=head1 PARÁMETROS

  length   => longitud del pivote (ta.pivothigh/pivotlow), por defecto 50.
  std_mult => multiplicador base de desviación estándar del Ghost VWAP,
              por defecto 1 (las bandas 1/2/3 sigma siempre se calculan).

=cut

# ─── Colores lógicos (por tipo de pivote) ─────────────────────────────────
use constant TYPE_HIGH => 'high';
use constant TYPE_LOW  => 'low';

sub new {
    my ($class, %args) = @_;

    my $self = {
        length   => $args{length}   // 50,
        std_mult => $args{std_mult} // 1,
    };

    bless $self, $class;
    $self->reset();
    return $self;
}

=head2 reset()

Reinicia todo el estado interno (equivalente a los C<var> del PineScript
original) y las listas acumuladas de salida.

=cut

sub reset {
    my ($self) = @_;

    # Estado de la máquina de extracción de pivotes (idéntico a pivots.txt)
    $self->{max}            = 0.0;
    $self->{min}            = 0.0;
    $self->{max_x1}         = 0;
    $self->{min_x1}         = 0;
    $self->{follow_max}     = 0.0;
    $self->{follow_min}     = 0.0;
    $self->{follow_max_x1}  = 0;
    $self->{follow_min_x1}  = 0;
    $self->{os}             = 0;   # 1 = último pivote confirmado fue un HIGH; 0 = fue un LOW
    $self->{px1}            = 0;   # x del último punto del zigzag (pivote o fantasma)
    $self->{py1}            = 0.0; # y del último punto del zigzag

    # Salidas acumuladas ("Ghost Anchors")
    $self->{markers}        = [];

    # Salidas acumuladas ("Ghost Lines")
    $self->{ghost_lines}          = [];   # segmentos de zigzag ya cerrados
    $self->{ghost_level_segments} = [];   # tramos de "rastro" horizontal ya cerrados
    $self->{ghost_level_open}     = undef; # tramo de rastro aún abierto (se extiende hasta la última vela)

    # Salidas acumuladas ("Ghost VWAP")
    $self->{live_ghost}     = undef;  # { index, price, dir }
    $self->{ghost_vwap}     = undef;  # { anchor_index, values => [...] }

    # Estado interno de recálculo incremental del Ghost VWAP
    $self->{gv_anchor_index} = undef;
    $self->{gv_last_index}   = undef;
    $self->{gv_cum_vol}      = 0.0;
    $self->{gv_cum_pv}       = 0.0;
    $self->{gv_cum_pv2}      = 0.0;
    $self->{gv_values}       = [];

    return;
}

=head2 update_last($candles, $atr_values, $i)

Procesa la vela de índice C<$i> (velas 0..$i ya disponibles en
C<$candles>). C<$atr_values> no es utilizado por este indicador (se
recibe por uniformidad de contrato con Structure/Liquidity) pero se
acepta para no romper la firma común.

Devuelve el hashref de estado acumulado (ver DESCRIPCIÓN).

=cut

sub update_last {
    my ($self, $candles, $atr_values, $i) = @_;

    return $self->_snapshot($candles) unless defined $i && $candles && @$candles;

    my $length = $self->{length};
    my $c      = $i - $length;

    if ($c >= 0 && $c + $length <= $#$candles) {
        $self->_process_bar($candles, $c, $length);
    }

    # "Ghost vivo": recalculado cada vela (equivalente a barstate.islast)
    $self->_update_live_ghost($candles, $i);

    return $self->_snapshot($candles);
}

# ─── Extracción de pivotes (regulares + fantasma) ─────────────────────────

sub _process_bar {
    my ($self, $candles, $c, $length) = @_;

    my $bar = $candles->[$c];
    return unless $bar;

    my $h = $bar->{high};
    my $l = $bar->{low};

    # Captura del estado ANTES de mutarlo (equivalente a los parámetros
    # _max/_min/_os/... que recibía get_swing_pivots() en el PineScript;
    # ambas ramas ph/pl del mismo bar deben leer estos valores "congelados").
    my $orig_max      = $self->{max};
    my $orig_min      = $self->{min};
    my $orig_os       = $self->{os};

    my $prev_max = $self->{max};
    my $prev_min = $self->{min};

    $self->{max} = $h if $h > $self->{max};
    $self->{min} = $l if $l < $self->{min};

    my $prev_follow_max = $self->{follow_max};
    my $prev_follow_min = $self->{follow_min};

    $self->{follow_max} = $h if $h > $self->{follow_max};
    $self->{follow_min} = $l if $l < $self->{follow_min};

    if ($self->{max} > $prev_max) {
        $self->{max_x1}     = $c;
        $self->{follow_min} = $l;
    }
    if ($self->{min} < $prev_min) {
        $self->{min_x1}     = $c;
        $self->{follow_max} = $h;
    }
    if ($self->{follow_min} < $prev_follow_min) {
        $self->{follow_min_x1} = $c;
    }
    if ($self->{follow_max} > $prev_follow_max) {
        $self->{follow_max_x1} = $c;
    }

    my $is_ph = _is_pivot_high($candles, $c, $length);
    my $is_pl = _is_pivot_low($candles, $c, $length);

    return unless $is_ph || $is_pl;

    if ($is_ph) {
        my $ph = $h;

        if ($orig_os == 1) {
            # Ya veníamos de un HIGH confirmado: el mínimo intermedio quedó
            # "perdido" (missed low fantasma) antes de este nuevo high.
            push @{$self->{markers}}, { index => $self->{min_x1}, price => $self->{min}, type => 'missed_low' };
            $self->_push_ghost_line($self->{min_x1}, $self->{min}, TYPE_LOW);
            $self->_open_ghost_level($self->{min_x1}, $self->{min}, TYPE_LOW);
        }
        elsif ($ph < $orig_max) {
            # El nuevo high no supera al máximo previo: tanto ese máximo
            # como el mínimo intermedio quedan como fantasmas.
            push @{$self->{markers}}, { index => $self->{max_x1}, price => $self->{max}, type => 'missed_high' };
            push @{$self->{markers}}, { index => $self->{follow_min_x1}, price => $self->{follow_min}, type => 'missed_low' };

            $self->_push_ghost_line($self->{max_x1}, $self->{max}, TYPE_HIGH);
            $self->_open_ghost_level($self->{max_x1}, $self->{max}, TYPE_HIGH);

            $self->_push_ghost_line($self->{follow_min_x1}, $self->{follow_min}, TYPE_LOW);
            $self->_open_ghost_level($self->{follow_min_x1}, $self->{follow_min}, TYPE_LOW);
        }

        # Pivote regular (siempre se registra al confirmarse ta.pivothigh)
        push @{$self->{markers}}, { index => $c, price => $ph, type => 'reg_high' };

        my $dashed = ($ph < $orig_max) || ($orig_os == 1);
        $self->_push_ghost_line($c, $ph, TYPE_HIGH, $dashed, 1);

        $self->{os}  = 1;
        $self->{max} = $ph;
        $self->{min} = $ph;
    }

    if ($is_pl) {
        my $pl = $l;

        if ($orig_os == 0) {
            push @{$self->{markers}}, { index => $self->{max_x1}, price => $self->{max}, type => 'missed_high' };
            $self->_push_ghost_line($self->{max_x1}, $self->{max}, TYPE_HIGH);
            $self->_open_ghost_level($self->{max_x1}, $self->{max}, TYPE_HIGH);
        }
        elsif ($pl > $orig_min) {
            push @{$self->{markers}}, { index => $self->{follow_max_x1}, price => $self->{follow_max}, type => 'missed_high' };
            push @{$self->{markers}}, { index => $self->{min_x1}, price => $self->{min}, type => 'missed_low' };

            $self->_push_ghost_line($self->{min_x1}, $self->{min}, TYPE_LOW);
            $self->_open_ghost_level($self->{min_x1}, $self->{min}, TYPE_LOW);

            $self->_push_ghost_line($self->{follow_max_x1}, $self->{follow_max}, TYPE_HIGH);
            $self->_open_ghost_level($self->{follow_max_x1}, $self->{follow_max}, TYPE_HIGH);
        }

        push @{$self->{markers}}, { index => $c, price => $pl, type => 'reg_low' };

        my $dashed = ($pl > $orig_min) || ($orig_os == 0);
        $self->_push_ghost_line($c, $pl, TYPE_LOW, $dashed, 1);

        $self->{os}  = 0;
        $self->{max} = $pl;
        $self->{min} = $pl;
    }
}

# ─── Ghost Lines: zigzag + rastro horizontal ("ghost level") ─────────────

# Añade un segmento del zigzag desde el último punto (px1,py1) hasta
# (x,y), y actualiza el "último punto". Por defecto el segmento es
# punteado (dashed=1), salvo que se indique lo contrario explícitamente
# (segmento final hacia un pivote REGULAR "fuerte": dashed se decide en
# la llamada según la condición del PineScript original).
sub _push_ghost_line {
    my ($self, $x, $y, $color_type, $dashed, $explicit) = @_;

    $dashed = 1 unless defined $dashed && $explicit;

    push @{$self->{ghost_lines}}, {
        x1         => $self->{px1},
        y1         => $self->{py1},
        x2         => $x,
        y2         => $y,
        color_type => $color_type,
        dashed     => $dashed ? 1 : 0,
    };

    $self->{px1} = $x;
    $self->{py1} = $y;
}

# Cierra el tramo de "rastro" horizontal abierto (si existe, extendiéndolo
# hasta la posición del nuevo evento) y abre uno nuevo desde (x,y).
sub _open_ghost_level {
    my ($self, $x, $y, $color_type) = @_;

    if (my $open = $self->{ghost_level_open}) {
        push @{$self->{ghost_level_segments}}, {
            x1         => $open->{x1},
            y          => $open->{y},
            x2         => $x,
            color_type => $open->{color_type},
        };
    }

    $self->{ghost_level_open} = { x1 => $x, y => $y, color_type => $color_type };
}

# ─── Ghost VWAP: pivote fantasma "vivo" + VWAP anclado recalculado ───────

sub _update_live_ghost {
    my ($self, $candles, $i) = @_;

    my $px1 = $self->{px1};
    my $os  = $self->{os};

    return if $i <= $px1;   # aún no hay velas nuevas desde el último punto del zigzag

    my ($best_price, $best_idx);
    for my $j (($px1 + 1) .. $i) {
        my $bar = $candles->[$j];
        next unless $bar;
        my $val = ($os == 1) ? $bar->{low} : $bar->{high};
        if (!defined $best_price
            || ($os == 1 ? ($val < $best_price) : ($val > $best_price))) {
            $best_price = $val;
            $best_idx   = $j;
        }
    }
    return unless defined $best_price;

    $self->{live_ghost} = { index => $best_idx, price => $best_price, dir => $os };

    $self->_update_ghost_vwap($candles, $best_idx, $i);
}

# Recalcula el VWAP Anclado (con bandas 1/2/3 sigma) desde el pivote
# fantasma vivo ($anchor_idx) hasta la última vela ($i). Si el ancla no
# cambió respecto a la llamada anterior y la vela procesada es
# consecutiva, extiende el cálculo de forma incremental (O(1)); en caso
# contrario (el ancla "saltó" a un nuevo extremo) recalcula el tramo
# completo desde cero, igual que hace el PineScript original al mover el
# pivote fantasma.
sub _update_ghost_vwap {
    my ($self, $candles, $anchor_idx, $i) = @_;

    my $same_anchor = defined $self->{gv_anchor_index} && $self->{gv_anchor_index} == $anchor_idx;
    my $contiguous  = defined $self->{gv_last_index} && $self->{gv_last_index} == $i - 1;

    if (!$same_anchor || !$contiguous) {
        # Recálculo completo del tramo [anchor_idx .. i]
        $self->{gv_anchor_index} = $anchor_idx;
        $self->{gv_cum_vol}      = 0.0;
        $self->{gv_cum_pv}       = 0.0;
        $self->{gv_cum_pv2}      = 0.0;
        $self->{gv_values}       = [];

        for my $j ($anchor_idx .. $i) {
            $self->_accumulate_ghost_vwap($candles, $j);
        }
    }
    else {
        $self->_accumulate_ghost_vwap($candles, $i);
    }

    $self->{gv_last_index} = $i;
    $self->{ghost_vwap} = {
        anchor_index => $self->{gv_anchor_index},
        values       => $self->{gv_values},
    };
}

sub _accumulate_ghost_vwap {
    my ($self, $candles, $j) = @_;

    my $c = $candles->[$j];
    return unless $c;

    my $tp  = ($c->{high} + $c->{low} + $c->{close}) / 3;   # hlc3
    my $vol = $c->{volume} // 0;
    $vol = 0 if $vol eq '';

    $self->{gv_cum_vol} += $vol;
    $self->{gv_cum_pv}  += $tp * $vol;
    $self->{gv_cum_pv2} += $tp * $tp * $vol;

    my $mult = $self->{std_mult};
    my ($vwap, $stdev, %upper_n, %lower_n);

    if ($self->{gv_cum_vol} > 0) {
        $vwap = $self->{gv_cum_pv} / $self->{gv_cum_vol};
        my $variance = ($self->{gv_cum_pv2} / $self->{gv_cum_vol}) - ($vwap * $vwap);
        $variance = 0 if $variance < 0;
        $stdev = sqrt($variance);
    }
    else {
        $vwap  = $tp;
        $stdev = 0;
    }

    for my $n (1, 2, 3) {
        $upper_n{$n} = $vwap + $n * $stdev;
        $lower_n{$n} = $vwap - $n * $stdev;
    }

    push @{$self->{gv_values}}, {
        index  => $j,
        vwap   => $vwap,
        upper  => $vwap + $mult * $stdev,
        lower  => $vwap - $mult * $stdev,
        upper1 => $upper_n{1}, lower1 => $lower_n{1},
        upper2 => $upper_n{2}, lower2 => $lower_n{2},
        upper3 => $upper_n{3}, lower3 => $lower_n{3},
    };
}

# ─── Snapshot de salida ────────────────────────────────────────────────

sub _snapshot {
    my ($self, $candles) = @_;

    my @level_segments = @{$self->{ghost_level_segments}};
    if (my $open = $self->{ghost_level_open}) {
        push @level_segments, {
            x1         => $open->{x1},
            y          => $open->{y},
            x2         => undef,   # undef => se extiende hasta la última vela visible
            color_type => $open->{color_type},
            open       => 1,
        };
    }

    return {
        markers              => $self->{markers},
        ghost_lines          => $self->{ghost_lines},
        ghost_level_segments => \@level_segments,
        live_ghost           => $self->{live_ghost},
        ghost_vwap           => $self->{ghost_vwap},
        candles              => $candles,
    };
}

# ─── Detección de pivotes estrictos (idéntica a la versión previa) ───────

sub _is_pivot_high {
    my ($candles, $c, $length) = @_;

    return 0 if $c - $length < 0;
    return 0 if $c + $length > $#$candles;

    my $hi = $candles->[$c]{high};

    for my $i ($c - $length .. $c + $length) {
        next if $i == $c;
        return 0 if $candles->[$i]{high} >= $hi;
    }

    return 1;
}

sub _is_pivot_low {
    my ($candles, $c, $length) = @_;

    return 0 if $c - $length < 0;
    return 0 if $c + $length > $#$candles;

    my $lo = $candles->[$c]{low};

    for my $i ($c - $length .. $c + $length) {
        next if $i == $c;
        return 0 if $candles->[$i]{low} <= $lo;
    }

    return 1;
}

1;
