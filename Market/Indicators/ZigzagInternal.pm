package Market::Indicators::ZigzagInternal;

use strict;
use warnings;

=head1 NOMBRE

Market::Indicators::ZigzagInternal - "Zigzag Interno" (Internal Structure).

Es la adaptación a Perl del indicador PineScript de referencia
C<zzmtf.txt> ("ZigZag Multi Time Frame with Fibonacci Retracement" de
LonesomeTheBlue). Conserva la parte central del algoritmo original:

  * Un período configurable (C<prd>, por defecto 2, igual que el script
    original) determina la ventana de velas usada para detectar un pivote.
  * Un pivote alto (C<ph>) se confirma cuando el máximo (C<high>) de la
    vela actual es el más alto dentro de la ventana de las últimas C<prd>
    velas; análogamente para un pivote bajo (C<pl>) con el mínimo.
  * C<dir> sólo cambia cuando exactamente uno de los dos (C<ph> o C<pl>)
    se confirma en la vela actual (igual que
    C<dir := iff(ph and na(pl), 1, iff(pl and na(ph), -1, dir))> en Pine).
  * Cuando la dirección cambia se agrega un nuevo pivote al zigzag
    (C<add_to_zigzag>); si la dirección se mantiene, se extiende el último
    pivote existente sólo si el nuevo extremo es más favorable
    (C<update_zigzag>).

El algoritmo original tampoco mira hacia adelante (no hay repintado), por
lo que es equivalente calcularlo vela a vela (streaming) o de una sola
vez sobre el historial completo.

=head1 CONTRATO

Sigue el mismo contrato incremental que Market::Indicators::FVG,
Liquidity, OrderBlocks, SMC_Structures y Structure:

  new(%args)                              -> instancia
  reset()                                 -> limpia el estado interno
  update_last($candles, $atr_values, $i)  -> procesa SÓLO la vela $i
  get_values()                            -> devuelve los pivotes (alias
                                              de get_pivots(), por
                                              uniformidad con el resto)

C<$candles> debe ser el arrayref COMPLETO de velas de la temporalidad MTF
elegida (no sólo hasta $i), ya que la ventana de C<prd> velas mira hacia
atrás usando índices absolutos sobre ese arrayref, igual que en
C<Market::Indicators::HalfTrend>. C<$atr_values> no se usa (el ZigZag no
depende del ATR); se recibe únicamente para mantener la firma uniforme
con el resto de indicadores y permitir que ChartEngine los invoque desde
el mismo patrón de bucle incremental.

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        # Período del ZigZag ("ZigZag Period" en el indicador original).
        period => $args{period} // 2,

        # --- Estado incremental ---
        pivots => [],   # oldest -> newest: { index, time, price, dir, consolidated }
        dir    => 0,
    };

    return bless $self, $class;
}

=head2 set_period($prd)

Permite cambiar el período del ZigZag en caliente. Como cambia la
ventana de detección de pivotes, invalida cualquier cálculo ya hecho
(hace falta un reset() + recálculo completo tras llamarlo).

=cut

sub set_period {
    my ($self, $prd) = @_;
    $self->{period} = $prd if defined $prd && $prd >= 2;
}

sub reset {
    my ($self) = @_;
    $self->{pivots} = [];
    $self->{dir}    = 0;
}

=head2 get_values()

Devuelve el arrayref de pivotes acumulados hasta ahora (alias de
get_pivots(), por uniformidad de nombres con el resto de indicadores
incrementales).

=cut

sub get_values {
    my ($self) = @_;
    return $self->{pivots};
}

=head2 get_pivots()

Alias explícito de get_values(), se conserva por claridad semántica ya
que este indicador no trabaja con "valores" por vela sino con una lista
de pivotes.

=cut

sub get_pivots {
    my ($self) = @_;
    return $self->{pivots};
}

=head2 update_last($candles, $atr_values, $i)

Procesa incrementalmente la vela $i (en orden estrictamente creciente
desde 0 tras un reset()). $candles debe ser el arrayref completo de
velas MTF (se necesita para mirar atrás $period-1 velas). Actualiza
$self->{pivots} y devuelve C<{ pivots => [...] }>, con el mismo formato
que antes producía calculate():

    { pivots => [ { index, time, price, dir, consolidated }, ... ] }

C<index> es la posición del pivote DENTRO del arreglo C<$candles>
recibido (espacio de índices de la temporalidad MTF, no de la
temporalidad activa del gráfico -- la traducción la sigue haciendo
ChartEngine). C<dir> es C<1> para un pivote alto y C<-1> para un pivote
bajo. Sólo el último pivote de la lista puede tener C<consolidated == 0>
(sigue "abierto", puede ser extendido por velas futuras en la misma
dirección); todos los anteriores están consolidados.

=cut

sub update_last {
    my ($self, $candles, $atr_values, $i) = @_;

    return { pivots => $self->{pivots} } if !defined $i || $i < 0 || !$candles;

    my $prd = $self->{period} // 2;
    $prd = 2 if $prd < 2;

    my $c = $candles->[$i];
    return { pivots => $self->{pivots} } unless $c;

    # No hay suficiente historial todavía para evaluar una ventana completa
    # (equivalente a que calculate() empezaba el bucle en $i = $prd - 1).
    return { pivots => $self->{pivots} } if $i < $prd - 1;

    my $win_start = $i - $prd + 1;
    $win_start = 0 if $win_start < 0;

    my ($hi_idx, $hi_val) = (-1, undef);
    my ($lo_idx, $lo_val) = (-1, undef);

    for (my $j = $win_start; $j <= $i; $j++) {
        my $h = $candles->[$j]->{high};
        my $l = $candles->[$j]->{low};

        if (!defined $hi_val || $h > $hi_val) { $hi_val = $h; $hi_idx = $j; }
        if (!defined $lo_val || $l < $lo_val) { $lo_val = $l; $lo_idx = $j; }
    }

    my $is_ph = ($hi_idx == $i); # highestbars(high, len) == 0
    my $is_pl = ($lo_idx == $i); # lowestbars(low, len)   == 0

    return { pivots => $self->{pivots} } unless $is_ph || $is_pl;

    my $prev_dir = $self->{dir};

    if ($is_ph && !$is_pl) {
        $self->{dir} = 1;
    } elsif ($is_pl && !$is_ph) {
        $self->{dir} = -1;
    }
    # Si ambos o ninguno se confirman, dir se conserva (igual que Pine).

    my $dir        = $self->{dir};
    my $dirchanged = ($dir != $prev_dir);
    my $value      = ($dir == 1) ? $c->{high} : $c->{low};

    my $pivots = $self->{pivots};

    if (@$pivots == 0 || $dirchanged) {
        # El pivote anterior (si existe) queda definitivamente consolidado
        # en cuanto aparece uno nuevo en la dirección opuesta.
        $pivots->[-1]->{consolidated} = 1 if @$pivots;

        push @$pivots, {
            index        => $i,
            time         => $c->{time},
            price        => $value,
            dir          => $dir,
            consolidated => 0,   # sigue "abierto" hasta el próximo cambio de dir
        };
    } else {
        my $last = $pivots->[-1];

        if (($dir == 1 && $value > $last->{price})
         || ($dir == -1 && $value < $last->{price})) {
            $last->{price} = $value;
            $last->{index} = $i;
            $last->{time}  = $c->{time};
        }
    }

    return { pivots => $self->{pivots} };
}

=head2 calculate($candles)

Compatibilidad hacia atrás: recalcula el zigzag completo desde cero
sobre C<$candles>, reseteando el estado interno y llamando a
C<update_last()> vela a vela. Devuelve el mismo hashref que antes.
Se conserva para no romper código externo que aún invoque C<calculate()>
directamente, pero la integración con ChartEngine ahora usa el patrón
incremental C<reset() + update_last()>.

=cut

sub calculate {
    my ($self, $candles) = @_;

    $self->reset();

    my @c = defined $candles ? @$candles : ();
    my $result;
    for my $i (0 .. $#c) {
        $result = $self->update_last(\@c, undef, $i);
    }

    return $result // { pivots => [] };
}

1;
