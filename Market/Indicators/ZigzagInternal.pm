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

A diferencia del script de TradingView (que corre vela a vela en un
motor de streaming), aquí se recibe el historial completo de velas de la
temporalidad elegida ("Multi Time Frame") y se calcula el zigzag de una
sola vez sobre ese arreglo, lo cual es equivalente en resultado porque el
algoritmo original tampoco mira hacia adelante (no hay repintado).

=cut

sub new {
    my ($class, %args) = @_;

    return bless {
        # Período del ZigZag ("ZigZag Period" en el indicador original).
        period => $args{period} // 2,
    }, $class;
}

=head2 set_period($prd)

Permite cambiar el período del ZigZag en caliente.

=cut

sub set_period {
    my ($self, $prd) = @_;
    $self->{period} = $prd if defined $prd && $prd >= 2;
}

=head2 calculate($candles)

Recibe un arrayref de velas (con al menos C<high>, C<low> y C<time>) de
la temporalidad "Multi Time Frame" elegida por el usuario, y devuelve un
hashref:

    { pivots => [ { index, time, price, dir }, ... ] }

C<index> es la posición del pivote DENTRO del arreglo C<$candles>
recibido (es decir, en el espacio de índices de esa temporalidad, no de
la temporalidad activa del gráfico). C<dir> es C<1> para un pivote alto y
C<-1> para un pivote bajo.

=cut

sub calculate {
    my ($self, $candles) = @_;

    my $prd = $self->{period} // 2;
    $prd = 2 if $prd < 2;

    my @c = defined $candles ? @$candles : ();
    my $n = scalar @c;

    return { pivots => [] } if $n < ($prd * 2);

    my @zigzag; # oldest -> newest: { index, time, price, dir }
    my $dir = 0;

    for (my $i = $prd - 1; $i < $n; $i++) {

        my $win_start = $i - $prd + 1;
        $win_start = 0 if $win_start < 0;

        my ($hi_idx, $hi_val) = (-1, undef);
        my ($lo_idx, $lo_val) = (-1, undef);

        for (my $j = $win_start; $j <= $i; $j++) {
            my $h = $c[$j]->{high};
            my $l = $c[$j]->{low};

            if (!defined $hi_val || $h > $hi_val) { $hi_val = $h; $hi_idx = $j; }
            if (!defined $lo_val || $l < $lo_val) { $lo_val = $l; $lo_idx = $j; }
        }

        my $is_ph = ($hi_idx == $i); # highestbars(high, len) == 0
        my $is_pl = ($lo_idx == $i); # lowestbars(low, len)   == 0

        next unless $is_ph || $is_pl;

        my $prev_dir = $dir;

        if ($is_ph && !$is_pl) {
            $dir = 1;
        } elsif ($is_pl && !$is_ph) {
            $dir = -1;
        }
        # Si ambos o ninguno se confirman, dir se conserva (igual que Pine).

        my $dirchanged = ($dir != $prev_dir);
        my $value = ($dir == 1) ? $c[$i]->{high} : $c[$i]->{low};

        if (@zigzag == 0 || $dirchanged) {
            push @zigzag, {
                index => $i,
                time  => $c[$i]->{time},
                price => $value,
                dir   => $dir,
            };
        } else {
            my $last = $zigzag[-1];

            if (($dir == 1 && $value > $last->{price})
             || ($dir == -1 && $value < $last->{price})) {
                $last->{price} = $value;
                $last->{index} = $i;
                $last->{time}  = $c[$i]->{time};
            }
        }
    }

    # Un pivote queda "consolidado" quiere decir que ya no puede ser
    # modificado por velas futuras: eso ocurre en cuanto aparece un pivote
    # posterior (la dirección cambió y update_zigzag() dejó de tocarlo).
    # El ÚLTIMO pivote de la serie, en cambio, sigue "abierto": mientras no
    # llegue una vela que confirme el pivote opuesto, cada nueva vela en la
    # misma dirección puede seguir extendiéndolo (ver update_zigzag()
    # arriba). Por lo tanto, sólo el último pivote puede no estar
    # consolidado; todos los anteriores sí lo están.
    for my $i (0 .. $#zigzag) {
        $zigzag[$i]->{consolidated} = ($i == $#zigzag) ? 0 : 1;
    }

    return { pivots => \@zigzag };
}

1;
