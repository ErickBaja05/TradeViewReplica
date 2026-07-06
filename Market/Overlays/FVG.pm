package Market::Overlays::FVG;

use strict;
use warnings;

=head1 NOMBRE

Market::Overlays::FVG - Capa visual que dibuja las zonas de Fair Value Gap
(FVG) calculadas por Market::Indicators::FVG como FRANJAS (rectángulos
semitransparentes vía stipple) sobre el canvas principal de velas, en lugar
de líneas simples.

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        fvg_result => $args{fvg_result},
        show       => $args{show} // 1,
    };

    return bless $self, $class;
}

=head2 set_result($fvg_result)

Actualiza el resultado calculado por el motor de FVG.

=cut

sub set_result {
    my ($self, $fvg_result) = @_;
    $self->{fvg_result} = $fvg_result;
}

=head2 draw($canvas, $scale, $start, $end)

Dibuja las franjas de FVG visibles entre los índices [$start, $end].

=cut

sub draw {
    my ($self, $canvas, $scale, $start, $end) = @_;

    return unless $self->{show};
    return unless $self->{fvg_result} && $self->{fvg_result}->{zones};
    return unless $canvas && $scale;

    my $right_limit = ($canvas->Width() || 0) - 2;
    $right_limit = 0 if $right_limit < 0;

    for my $z (@{$self->{fvg_result}->{zones}}) {

        my $draw_end_index = defined $z->{filled_index} ? $z->{filled_index} : $end;

        next if $draw_end_index < $start;
        next if $z->{left_index} > $end;

        my $x1 = $scale->index_to_x($z->{left_index});
        my $x2 = $scale->index_to_x($draw_end_index + 1);
        $x2 = $right_limit if $x2 > $right_limit;

        next if $x2 <= $x1;

        my $y1 = $scale->value_to_y($z->{top});
        my $y2 = $scale->value_to_y($z->{bottom});

        my ($fill, $outline);
        if ($z->{type} eq 'BULLISH') {
            $fill    = '#26a69a';
            $outline = '#089981';
        } else {
            $fill    = '#ef5350';
            $outline = '#f23645';
        }

        # Franja semitransparente (Tk/Tcl no soporta alpha real en canvas,
        # así que simulamos la transparencia con un patrón "stipple").
        $canvas->createRectangle(
            $x1, $y1, $x2, $y2,
            -fill    => $fill,
            -outline => $outline,
            -stipple => 'gray25',
            -width   => 1
        );

        if (($x2 - $x1) > 24) {
            $canvas->createText(
                $x1 + 4, ($y1 + $y2) / 2,
                -text   => 'FVG',
                -fill   => $outline,
                -font   => ['Arial', 7, 'bold'],
                -anchor => 'w'
            );
        }
    }
}

1;
