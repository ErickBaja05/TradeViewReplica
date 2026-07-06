package Market::Overlays::Swing;

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
        color_high => $args{color_high} // '#4d0a47',
        color_low  => $args{color_low}  // '#059baf',
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

    for my $p (@$pivots) {

        next if $p->{index} < $start || $p->{index} > $end;

        my $is_high = $p->{type} eq 'HIGH';
        next if $is_high  && !$self->{show_high};
        next if !$is_high && !$self->{show_low};

        my $x = $scale->index_to_center_x($p->{index});
        my $y = $scale->value_to_y($p->{price});

        next unless defined $x && defined $y;
        next if $x > $right_limit;

        my $color = $is_high ? $self->{color_high} : $self->{color_low};
        my $r = $self->{radius};

        $canvas->createOval(
            $x - $r, $y - $r,
            $x + $r, $y + $r,
            -outline => $color,
            -width   => 1.5,
        );

        my $dy = $is_high ? -14 : 14;

        $canvas->createText(
            $x,
            $y + $dy,
            -text   => $is_high ? 'SH' : 'SL',
            -fill   => $color,
            -font   => ['Arial', 7, 'bold'],
            -anchor => 'center'
        );
    }
}

1;