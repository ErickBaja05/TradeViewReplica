package Market::Overlays::Zigzag_Internal;

use strict;
use warnings;

=head1 NOMBRE

Market::Overlays::Swing - Capa visual que marca los puntos de giro (swing
points) calculados por Market::Indicators::Liquidity (pivotes "minor"),
dibujando un pequeño círculo sobre cada uno junto con la etiqueta:

  - "SH" (Swing High) para pivotes de tipo HIGH.
  - "SL" (Swing Low)  para pivotes de tipo LOW.

Se apoya en el mismo resultado (liq_result) que ya calcula
Market::Indicators::Liquidity, usando el arreglo minor_pivots.

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        liq_result => $args{liq_result},
        show       => $args{show} // 1,
        show_high  => $args{show_high} // 1,
        show_low   => $args{show_low} // 1,
        color_high => $args{color_high} // '#00ff0d',
        color_low  => $args{color_low}  // '#ff0000',
        radius     => $args{radius} // 4,
    };

    return bless $self, $class;
}

=head2 set_result($liq_result)

Actualiza el resultado calculado por el motor de liquidez.

=cut

sub set_result {
    my ($self, $liq_result) = @_;
    $self->{liq_result} = $liq_result;
}

=head2 draw($canvas, $scale, $start, $end)

Dibuja los swing points visibles entre los índices [$start, $end].

=cut

sub draw {
    my ($self, $canvas, $scale, $start, $end) = @_;

    return unless $self->{show};
    return unless $self->{liq_result} && $canvas && $scale;

    my $pivots = $self->{liq_result}->{minor_pivots} || [];

    my $right_limit = ($canvas->Width() || 0) - 2;
    $right_limit = 0 if $right_limit < 0;

    #
    # Igual que SMC_Structures:
    # incluir el pivote inmediatamente anterior y el siguiente
    # para que el zigzag no se corte al hacer scroll.
    #
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

        my $is_high = $p->{type} eq 'HIGH';

        next if $is_high  && !$self->{show_high};
        next if !$is_high && !$self->{show_low};

        my $x = $scale->index_to_center_x($p->{index});
        my $y = $scale->value_to_y($p->{price});

        next unless defined $x && defined $y;

        push @visible_points, {
            x     => $x,
            y     => $y,
            index => $p->{index},
            price => $p->{price},
            type  => $p->{type},
        };
    }

    #
    # Zigzag
    #
    if (@visible_points >= 2) {

        for my $i (1 .. $#visible_points) {

            my $a = $visible_points[$i-1];
            my $b = $visible_points[$i];

            my ($x1,$y1)=($a->{x},$a->{y});
            my ($x2,$y2)=($b->{x},$b->{y});

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

            my $color;

            if ($a->{type} eq 'LOW' && $b->{type} eq 'HIGH') {
                # Upswing
                $color = '#00ff0d';   # Green
            }
            elsif ($a->{type} eq 'HIGH' && $b->{type} eq 'LOW') {
                # Downswing
                $color = '#ff0000';   # Red
            }
            else {
                # Shouldn't happen if pivots alternate correctly
                $color = '#808080';
            }
            
            $canvas->createLine(
                $x1, $y1,
                $x2, $y2,
                -fill  => $color,
                -width => 2,
            );
        }
    }

    
    #Dibujar pivotes y etiquetas
    
    for my $p (@visible_points) {

        next if $p->{x} > $right_limit;

        my $is_high = $p->{type} eq 'HIGH';

        my $color = $is_high
            ? $self->{color_high}
            : $self->{color_low};

        my $r = $self->{radius};

        $canvas->createOval(
            $p->{x} - $r,
            $p->{y} - $r,
            $p->{x} + $r,
            $p->{y} + $r,
            -outline => $color,
            -fill    => $color,
        );

        my $dy = $is_high ? -14 : 14;

        $canvas->createText(
            $p->{x},
            $p->{y} + $dy,
            -text   => $is_high ? 'SH' : 'SL',
            -fill   => $color,
            -font   => ['Arial', 7, 'bold'],
            -anchor => 'center',
        );
    }
}

1;
