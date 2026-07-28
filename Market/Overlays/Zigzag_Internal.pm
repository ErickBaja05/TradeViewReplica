package Market::Overlays::Zigzag_Internal;

use strict;
use warnings;

=head1 NOMBRE

Market::Overlays::Zigzag_Internal - Capa visual que dibuja el "Zigzag
Interno" (Internal Structure) calculado por
C<Market::Indicators::ZigzagInternal> a partir de la temporalidad
"Multi Time Frame" (MTF) elegida por el usuario (15m, 1h, 2h, 4h o 1d),
tal como el indicador PineScript de referencia C<zzmtf.txt>.

Los pivotes llegan ya "traducidos" al espacio de índices de la
temporalidad activa del gráfico (ver
C<Market::MarketData::index_for_time> / C<find_pivot_index>), por lo que
se dibuja igual que C<Market::Overlays::Zigzag_External>. Cada tramo
alterna de color según la dirección del pivote de llegada: verde
(C<up_color>) para tramos alcistas (hacia un pivote alto) y rojo
(C<dn_color>) para tramos bajistas (hacia un pivote bajo).

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        result   => $args{result},
        show     => $args{show} // 1,
        up_color => $args{up_color} // '#2bff00',
        dn_color => $args{dn_color} // '#ff0400',
    };

    return bless $self, $class;
}

=head2 set_result($result)

Actualiza el resultado calculado por C<Market::Indicators::ZigzagInternal>
(con los índices ya traducidos a la temporalidad activa).

=cut

sub set_result {
    my ($self, $result) = @_;
    $self->{result} = $result;
}

=head2 draw($canvas, $scale, $start, $end)

Dibuja el zigzag interno visible entre los índices [$start, $end].

=cut

sub draw {
    my ($self, $canvas, $scale, $start, $end) = @_;

    return if !$self->{show};
    return unless $self->{result} && $self->{result}->{pivots};
    return unless $canvas && $scale;

    my $pivots = $self->{result}->{pivots};

    my $right_limit = ($canvas->Width() || 0) - 2;
    $right_limit = 0 if $right_limit < 0;

    my @pivots_to_draw;
    my $prev_pivot;
    my $next_pivot;

    for my $p (@$pivots) {
        if ($p->{index} < $start) {
            $prev_pivot = $p;
            next;
        }

        if ($p->{index} > $end) {
            $next_pivot = $p;
            last;
        }

        push @pivots_to_draw, $p;
    }

    unshift @pivots_to_draw, $prev_pivot if defined $prev_pivot;
    push    @pivots_to_draw, $next_pivot if defined $next_pivot;

    my @visible_points;

    for my $p (@pivots_to_draw) {
        my $x = $scale->index_to_center_x($p->{index});
        my $y = $scale->value_to_y($p->{price});

        next unless defined $x && defined $y;

        push @visible_points, {
            x            => $x,
            y            => $y,
            index        => $p->{index},
            price        => $p->{price},
            dir          => $p->{dir},
            consolidated => $p->{consolidated} // 1,
        };
    }

    return if @visible_points < 2;

    # El ÚLTIMO tramo del zigzag (el que llega hasta el pivote más
    # reciente) es el único que puede no estar consolidado todavía; los
    # anteriores ya son definitivos. Sólo tiene sentido evaluarlo si el
    # último pivote visible es efectivamente el último del resultado
    # completo (si estamos con scroll hacia el pasado, ese punto ya no es
    # el "último" real y por lo tanto sí está consolidado).
    my $all_pivots      = $self->{result}->{pivots};
    my $last_real_pivot = $all_pivots->[-1];
    my $last_visible     = $visible_points[-1];
    my $last_is_open     = defined $last_real_pivot
                         && !$last_real_pivot->{consolidated}
                         && $last_visible->{index} == $last_real_pivot->{index};

    for my $i (1 .. $#visible_points) {
        my $a = $visible_points[$i - 1];
        my $b = $visible_points[$i];

        my ($x1, $y1) = ($a->{x}, $a->{y});
        my ($x2, $y2) = ($b->{x}, $b->{y});

        next if $x1 > $right_limit && $x2 > $right_limit;

        if ($x2 > $right_limit && $x2 != $x1) {
            my $t = ($right_limit - $x1) / ($x2 - $x1);
            $x2 = $right_limit;
            $y2 = $y1 + $t * ($y2 - $y1);
        }

        if ($x1 > $right_limit && $x1 != $x2) {
            my $t = ($right_limit - $x2) / ($x1 - $x2);
            $x1 = $right_limit;
            $y1 = $y2 + $t * ($y1 - $y2);
        }

        # Sólido para todos los tramos, salvo el último si su pivote de
        # llegada todavía no está consolidado.
        my $is_last_segment = ($i == $#visible_points);
        my @dash_opt = ($is_last_segment && $last_is_open) ? (-dash => [4, 2]) : ();

        $canvas->createLine(
            $x1, $y1,
            $x2, $y2,
            -fill  => $b->{dir} == 1 ? $self->{up_color} : $self->{dn_color},
            -width => 2,
            @dash_opt,
        );
    }
}

1;
