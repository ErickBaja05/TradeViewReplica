package Market::Indicators::OrderBlocks;

use strict;
use warnings;

=head1 NOMBRE

Market::Indicators::OrderBlocks - Motor de cálculo de zonas Supply/Demand
(Order Blocks), replicando fielmente la lógica PineScript de strategy.txt
(sección "Supply/Demand POI", líneas ~3027-3259).

=head1 DESCRIPCIÓN

Lógica original:

  * Se detectan pivotes con ta.pivothigh(swing_length, swing_length) y
    ta.pivotlow(swing_length, swing_length): el pivote en la barra
    $i - swing_length se confirma en $i cuando su high/low es estrictamente
    el extremo entre las swing_length barras a cada lado.

  * Cada pivote HIGH genera una zona SUPPLY:
      box_top    = precio del pivote (high)
      box_bottom = box_top - atr_buffer          (atr_buffer = ATR(50) * box_width/10)
      poi        = (box_top + box_bottom) / 2
    Cada pivote LOW genera una zona DEMAND:
      box_bottom = precio del pivote (low)
      box_top    = box_bottom + atr_buffer
      poi        = (box_top + box_bottom) / 2

  * f_check_overlapping: una nueva zona sólo se dibuja si su POI no cae
    dentro de +/- (ATR(50)*2) del POI de ninguna zona existente del mismo
    tipo (evita solapamientos).

  * Se mantiene un historial acotado (history_of_demand_to_keep) por tipo,
    tipo FIFO (la más antigua se descarta al agregar una nueva).

  * f_sd_to_bos: una zona SUPPLY se invalida ("rompe") cuando close >= su
    tope; una zona DEMAND se invalida cuando close <= su piso. Al romperse
    pasa a la lista de "BOS" (queda marcada como rota, no se sigue
    dibujando como zona activa).

  * Las zonas activas se extienden visualmente hasta el borde derecho del
    gráfico (equivalente a extend.right en PineScript); aquí se modela
    dejando "right" como undef mientras la zona esté activa, y fijando
    "right" al índice de ruptura cuando se invalida.

=head1 PARÁMETROS

  swing_length             => longitud de pivote alto/bajo (def: 10)
  history_to_keep          => historial máximo de zonas activas por tipo (def: 20)
  box_width                => ancho de la caja en fracción de ATR*box_width/10 (def: 2.5)
  atr_period               => período del ATR usado para buffer/overlap (def: 50)

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        swing_length    => $args{swing_length}    // 10,
        history_to_keep => $args{history_to_keep} // 20,
        box_width       => $args{box_width}       // 2.5,
        atr_period      => $args{atr_period}      // 50,
        zones           => [],   # todas las zonas alguna vez creadas (activas o rotas)
    };

    return bless $self, $class;
}

sub reset {
    my ($self) = @_;
    $self->{zones} = [];
}

sub get_values {
    my ($self) = @_;
    return $self->{zones};
}

sub _true_range {
    my ($candles, $i) = @_;
    my $c = $candles->[$i];
    if ($i == 0 || !$candles->[$i - 1]) {
        return $c->{high} - $c->{low};
    }
    my $prev_close = $candles->[$i - 1]->{close};
    my $hl = $c->{high} - $c->{low};
    my $hc = abs($c->{high} - $prev_close);
    my $lc = abs($c->{low}  - $prev_close);
    my $tr = $hl;
    $tr = $hc if $hc > $tr;
    $tr = $lc if $lc > $tr;
    return $tr;
}

# Serie completa de ATR Wilder (ta.atr) para el período dado.
sub _atr_series {
    my ($candles, $until_index, $period) = @_;
    my (@tr, @atr);
    for my $i (0 .. $until_index) {
        push @tr, _true_range($candles, $i);
        if ($i < $period - 1) {
            push @atr, undef;
        }
        elsif ($i == $period - 1) {
            my $s = 0;
            $s += $tr[$_] for (0 .. $period - 1);
            push @atr, $s / $period;
        }
        else {
            push @atr, ($atr[$i - 1] * ($period - 1) + $tr[$i]) / $period;
        }
    }
    return \@atr;
}

# Comprueba si un nuevo POI se solapa (dentro de +/- atr*2) con el POI de
# alguna zona ACTIVA (no rota) del mismo tipo.
sub _overlaps {
    my ($active_zones, $new_poi, $atr_threshold) = @_;
    for my $z (@$active_zones) {
        my $upper = $z->{poi} + $atr_threshold;
        my $lower = $z->{poi} - $atr_threshold;
        return 1 if $new_poi >= $lower && $new_poi <= $upper;
    }
    return 0;
}

=head2 calculate_until($candles, $until_index)

Recalcula desde cero todas las zonas Supply/Demand hasta $until_index
(inclusive).

Devuelve un hashref { zones => [...] } donde cada zona es un hashref:
  type        => 'SUPPLY' | 'DEMAND'
  top         => precio superior de la zona
  bottom      => precio inferior de la zona
  poi         => punto de interés (línea media)
  left_index  => índice donde se originó (bar_index del pivote)
  right_index => undef si sigue activa (se dibuja hasta el borde del
                 gráfico), o el índice en que fue mitigada, en cuyo caso
                 ya no se considera activa ni se debe dibujar
  mitigated   => 0 = activa, 1 = mitigada (el precio regresó a la zona)

=cut

sub calculate_until {
    my ($self, $candles, $until_index) = @_;

    $self->reset();
    return { zones => $self->{zones} }
        if !defined $until_index || $until_index < 0 || !$candles;

    my $swing_length = $self->{swing_length};
    my $history      = $self->{history_to_keep};
    my $box_width    = $self->{box_width};
    my $atr_period   = $self->{atr_period};

    my $atr_series = _atr_series($candles, $until_index, $atr_period);

    # Colas FIFO de zonas activas por tipo (para respetar history_to_keep,
    # igual que el array circular del PineScript original)
    my @active_supply;
    my @active_demand;

    for my $i (0 .. $until_index) {

        # -------------------------------------------------------------
        # Primero: comprobar MITIGACIÓN de zonas activas con la vela
        # actual. Una zona se mitiga apenas el precio vuelve a tocarla
        # (entra en su rango [bottom, top]), no sólo cuando la rompe por
        # completo con el cierre. Esto replica el concepto estándar de
        # "mitigated order block": una vez que el precio regresa a la
        # zona, ésta deja de considerarse válida y deja de dibujarse.
        # -------------------------------------------------------------
        my $bar_high = $candles->[$i]->{high};
        my $bar_low  = $candles->[$i]->{low};

        for my $z (@active_supply) {
            next if $z->{mitigated};
            # Se mitiga si la mecha alta de la vela toca dentro de la
            # zona [bottom, top] (o la atraviesa por completo).
            if ($bar_high >= $z->{bottom}) {
                $z->{mitigated}   = 1;
                $z->{right_index} = $i;
            }
        }
        for my $z (@active_demand) {
            next if $z->{mitigated};
            # Se mitiga si la mecha baja de la vela toca dentro de la
            # zona [bottom, top] (o la atraviesa por completo).
            if ($bar_low <= $z->{top}) {
                $z->{mitigated}   = 1;
                $z->{right_index} = $i;
            }
        }
        @active_supply = grep { !$_->{mitigated} } @active_supply;
        @active_demand = grep { !$_->{mitigated} } @active_demand;

        # -------------------------------------------------------------
        # Detectar pivote confirmado en la barra $p = $i - swing_length
        # (ta.pivothigh/pivotlow(swing_length, swing_length))
        # -------------------------------------------------------------
        next if $i < 2 * $swing_length;

        my $p = $i - $swing_length;
        my $center = $candles->[$p];
        next unless $center;

        my $atr = $atr_series->[$p] // $atr_series->[$i];
        next unless defined $atr;

        my $atr_buffer    = $atr * ($box_width / 10);
        my $atr_threshold = $atr * 2;

        my $is_pivot_high = 1;
        my $is_pivot_low  = 1;
        for my $j (($p - $swing_length) .. ($p + $swing_length)) {
            next if $j == $p;
            my $cj = $candles->[$j];
            next unless $cj;
            $is_pivot_high = 0 if $cj->{high} >= $center->{high};
            $is_pivot_low  = 0 if $cj->{low}  <= $center->{low};
        }

        if ($is_pivot_high) {
            my $top    = $center->{high};
            my $bottom = $top - $atr_buffer;
            my $poi    = ($top + $bottom) / 2;

            if (!_overlaps(\@active_supply, $poi, $atr_threshold)) {
                my $zone = {
                    type        => 'SUPPLY',
                    top         => $top,
                    bottom      => $bottom,
                    poi         => $poi,
                    left_index  => $p,
                    right_index => undef,
                    mitigated   => 0,
                };
                push @{$self->{zones}}, $zone;

                # La zona nace en la barra $p, pero recién sabemos que
                # existe en $i. Verificamos retroactivamente si alguna
                # vela entre $p+1 y $i ya la hubiera mitigado (por
                # ejemplo si el precio volvió a tocarla mientras se
                # confirmaba el pivote).
                for my $k (($p + 1) .. $i) {
                    my $ck = $candles->[$k];
                    next unless $ck;
                    if ($ck->{high} >= $bottom) {
                        $zone->{mitigated}   = 1;
                        $zone->{right_index} = $k;
                        last;
                    }
                }

                unless ($zone->{mitigated}) {
                    push @active_supply, $zone;

                    # FIFO: descartar la más antigua si excede el historial
                    if (@active_supply > $history) {
                        shift @active_supply;
                    }
                }
            }
        }

        if ($is_pivot_low) {
            my $bottom = $center->{low};
            my $top    = $bottom + $atr_buffer;
            my $poi    = ($top + $bottom) / 2;

            if (!_overlaps(\@active_demand, $poi, $atr_threshold)) {
                my $zone = {
                    type        => 'DEMAND',
                    top         => $top,
                    bottom      => $bottom,
                    poi         => $poi,
                    left_index  => $p,
                    right_index => undef,
                    mitigated   => 0,
                };
                push @{$self->{zones}}, $zone;

                for my $k (($p + 1) .. $i) {
                    my $ck = $candles->[$k];
                    next unless $ck;
                    if ($ck->{low} <= $top) {
                        $zone->{mitigated}   = 1;
                        $zone->{right_index} = $k;
                        last;
                    }
                }

                unless ($zone->{mitigated}) {
                    push @active_demand, $zone;

                    if (@active_demand > $history) {
                        shift @active_demand;
                    }
                }
            }
        }
    }

    return { zones => $self->{zones} };
}

1;
