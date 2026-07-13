package Market::Indicators::FVG;

use strict;
use warnings;

=head1 NOMBRE

Market::Indicators::FVG2 - Motor de cálculo de Fair Value Gaps estilo
"SMC Structures and FVG" (LudoGH68, PineScript v5).

=head1 DESCRIPCIÓN

Replica fielmente la lógica del indicador PineScript original:

  * FVG ALCISTA (BULLISH): high[3] < low[1]
      zona = [ high[3], low[1] ]   (vela central = [2])

  * FVG BAJISTA (BEARISH): low[3] > high[1]
      zona = [ high[1], low[3] ]

Los índices de PineScript (barra actual = 0, pasado = offset positivo)
se traducen a índices de array de la siguiente forma:
  - En la vela i, "la vela actual" es i
  - high[3] => high del array en i-3
  - low[1]  => low  del array en i-1

La mitigación es dinámica:
  - BULLISH: mitigada parcialmente cuando low < top de la zona (vuelve gris)
             mitigada totalmente cuando low <= bottom de la zona (se elimina)
  - BEARISH: mitigada parcialmente cuando high > bottom de la zona (vuelve gris)
             mitigada totalmente cuando high >= top de la zona (se elimina)

Parámetros configurables:
  fvg_history_nbr      => número máximo de FVG visibles a la vez (def: 5)
  min_gap_atr_mult     => tamaño mínimo del gap en múltiplos de ATR (def: 0.0)
  reduce_mitigated     => si es verdadero, recorta la zona al precio de reingreso (def: 0)

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        fvg_history_nbr  => $args{fvg_history_nbr}  // 5,
        min_gap_atr_mult => $args{min_gap_atr_mult}  // 0.0,
        reduce_mitigated => $args{reduce_mitigated}  // 0,
        zones            => [],
    };

    return bless $self, $class;
}

sub reset {
    my ($self) = @_;
    $self->{zones} = [];
}

=head2 calculate_until($candles, $atr_values, $until_index)

Recalcula desde cero todas las zonas FVG2 hasta el índice indicado,
aplicando la lógica de detección y mitigación barra a barra tal y como
lo hace el PineScript original.

=cut

sub calculate_until {
    my ($self, $candles, $atr_values, $until_index) = @_;

    $self->reset();
    return { zones => $self->{zones} }
        if !defined $until_index || $until_index < 3;

    # Lista de zonas "abiertas" (aún no mitigadas totalmente) que se van
    # actualizando barra a barra, igual que los arrays del PineScript.
    my @open_zones;

    # Cola FIFO de índices en $self->{zones} para respetar fvg_history_nbr.
    # Guardamos referencias directas a los hashes de zona.
    my @visible_queue;

    for my $i (0 .. $until_index) {
        my $bar = $candles->[$i];
        next unless $bar;

        my $bar_high = $bar->{high};
        my $bar_low  = $bar->{low};

        # ---------------------------------------------------------------
        # 1. Actualizar mitigación de zonas abiertas con la vela actual
        #    (replica el bucle FVGDraw del PineScript)
        # ---------------------------------------------------------------
        my @still_open;
        for my $z (@open_zones) {
            if ($z->{type} eq 'BULLISH') {
                if ($bar_low <= $z->{bottom}) {
                    # Mitigación total: la zona desaparece
                    $z->{state}        = 'Filled';
                    $z->{filled_index} = $i;
                    # NO la añadimos a still_open
                }
                else {
                    if ($bar_low < $z->{top}) {
                        # Mitigación parcial: cambia a gris
                        $z->{state} = 'Mitigated' unless $z->{state} eq 'Mitigated';

                        # Reducir la zona si la opción está activa
                        if ($self->{reduce_mitigated}) {
                            $z->{top} = $bar_low if $bar_low < $z->{top};
                        }
                    }
                    # Extendemos el borde derecho hasta la barra actual
                    $z->{right_index} = $i;
                    push @still_open, $z;
                }
            }
            else {  # BEARISH
                if ($bar_high >= $z->{top}) {
                    # Mitigación total
                    $z->{state}        = 'Filled';
                    $z->{filled_index} = $i;
                }
                else {
                    if ($bar_high > $z->{bottom}) {
                        $z->{state} = 'Mitigated' unless $z->{state} eq 'Mitigated';

                        if ($self->{reduce_mitigated}) {
                            $z->{bottom} = $bar_high if $bar_high > $z->{bottom};
                        }
                    }
                    $z->{right_index} = $i;
                    push @still_open, $z;
                }
            }
        }
        @open_zones = @still_open;

        # ---------------------------------------------------------------
        # 2. Detectar nuevo FVG usando las velas (i-3, i-2, i-1, i)
        #    El PineScript usa offsets sobre la barra actual:
        #      isBullishFVG = high[3] < low[1]   => vela i: c_{i-3} y c_{i-1}
        #      isBearishFVG = low[3] > high[1]   => vela i: c_{i-3} y c_{i-1}
        # ---------------------------------------------------------------
        next if $i < 3;

        my $c_prev3 = $candles->[$i - 3];   # [3] en PineScript
        my $c_prev1 = $candles->[$i - 1];   # [1] en PineScript
        next unless $c_prev3 && $c_prev1;

        my $atr     = $atr_values->[$i] // 0;
        my $min_gap = $atr * $self->{min_gap_atr_mult};

        # --- BULLISH FVG ---
        if ($c_prev3->{high} < $c_prev1->{low}) {
            my $gap = $c_prev1->{low} - $c_prev3->{high};
            if ($gap > $min_gap) {
                my $zone = {
                    type          => 'BULLISH',
                    top           => $c_prev1->{low},
                    bottom        => $c_prev3->{high},
                    left_index    => $i - 3,   # lado izquierdo de la franja
                    created_index => $i,
                    right_index   => $i,
                    state         => 'Open',
                    filled_index  => undef,
                };

                push @{$self->{zones}}, $zone;
                push @open_zones,       $zone;
                push @visible_queue,    $zone;

                # Respetar fvg_history_nbr: eliminar la zona más antigua si
                # la cola supera el límite (el PineScript usa fvgHistoryNbr + 1)
                if (scalar(@visible_queue) > $self->{fvg_history_nbr} + 1) {
                    my $oldest = shift @visible_queue;
                    $oldest->{evicted} = 1;   # marcamos para no dibujarla
                }
            }
        }
        # --- BEARISH FVG ---
        elsif ($c_prev3->{low} > $c_prev1->{high}) {
            my $gap = $c_prev3->{low} - $c_prev1->{high};
            if ($gap > $min_gap) {
                my $zone = {
                    type          => 'BEARISH',
                    top           => $c_prev3->{low},
                    bottom        => $c_prev1->{high},
                    left_index    => $i - 3,
                    created_index => $i,
                    right_index   => $i,
                    state         => 'Open',
                    filled_index  => undef,
                };

                push @{$self->{zones}}, $zone;
                push @open_zones,       $zone;
                push @visible_queue,    $zone;

                if (scalar(@visible_queue) > $self->{fvg_history_nbr} + 1) {
                    my $oldest = shift @visible_queue;
                    $oldest->{evicted} = 1;
                }
            }
        }
    }

    return { zones => $self->{zones} };
}

1;
