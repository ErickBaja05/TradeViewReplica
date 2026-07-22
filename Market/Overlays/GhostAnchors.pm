package Market::Overlays::GhostAnchors;

use strict;
use warnings;

=head1 NOMBRE

Market::Overlays::GhostAnchors - Capa visual "Ghost Anchors" del indicador
Market::Indicators::Anchors.

Dibuja únicamente los marcadores de los pivotes (regulares ▼/▲ y
perdidos/"missed" 👻, clave C<markers> del resultado del indicador). El
zigzag y los "ghost levels" los dibuja L<Market::Overlays::GhostLines>, y
el VWAP anclado fantasma lo dibuja L<Market::Overlays::GhostVWAP>.

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        result       => $args{result},
        show         => $args{show} // 1,
        color_high   => $args{color_high} // '#ef5350',
        color_low    => $args{color_low}  // '#26a69a',
        radius       => $args{radius} // 3,
    };

    return bless $self, $class;
}

=head2 set_result($result)

Actualiza el resultado calculado por Market::Indicators::Anchors (hashref
con, entre otras, la clave C<markers>; esta capa sólo usa esa clave).

=cut

sub set_result {
    my ($self, $result) = @_;
    $self->{result} = $result;
}

=head2 draw($canvas, $scale, $start, $end)

Dibuja únicamente los pivotes visibles entre los índices [$start, $end].

=cut

sub draw {
    my ($self, $canvas, $scale, $start, $end) = @_;

    return unless $self->{show};
    return unless $self->{result} && $canvas && $scale;

    my $markers = $self->{result}->{markers} || [];

    my $right_limit = ($canvas->Width() || 0) - 2;
    $right_limit = 0 if $right_limit < 0;

    for my $m (@$markers) {

        next if $m->{index} < $start || $m->{index} > $end;

        my $x = $scale->index_to_center_x($m->{index});
        my $y = $scale->value_to_y($m->{price});

        next unless defined $x && defined $y;
        next if $x > $right_limit;

        my $is_high   = ($m->{type} eq 'reg_high' || $m->{type} eq 'missed_high');
        my $is_missed = ($m->{type} eq 'missed_high' || $m->{type} eq 'missed_low');

        my $color = $is_high ? $self->{color_high} : $self->{color_low};
        my $r     = $self->{radius};
        my $dy    = $is_high ? -13 : 13;

        if ($is_missed) {
            # Pivote perdido ("missed"/ghost): marcador 👻 flotante (igual que GhostVWAP)
            $canvas->createText(
                $x, $y + $dy,
                -text   => "\x{1F47B}",
                -fill   => $color,
                -font   => ['Arial', 9, 'normal'],
                -anchor => 'center',
            );
        }
        else {
            # Pivote regular: círculo relleno + flecha ▼/▲
            $canvas->createOval(
                $x - $r, $y - $r, $x + $r, $y + $r,
                -outline => $color,
                -fill    => $color,
            );

            $canvas->createText(
                $x, $y + $dy,
                -text   => $is_high ? "\x{25BC}" : "\x{25B2}",
                -fill   => $color,
                -font   => ['Arial', 8, 'bold'],
                -anchor => 'center',
            );
        }
    }
}

1;
