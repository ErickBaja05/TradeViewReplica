package Market::Overlays::Levels;

use strict;
use warnings;

=head1 NOMBRE

Market::Overlays::Levels - Capa visual que dibuja los niveles MTF 
(Previous Daily/Weekly/Monthly High & Low).

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        result      => $args{result},
        show        => $args{show}        // 1,
        show_labels => $args{show_labels} // 1,
    };

    return bless $self, $class;
}

=head2 set_result($levels_result)

Actualiza el resultado calculado por Market::Indicators::Levels.

=cut

sub set_result {
    my ($self, $levels_result) = @_;
    $self->{result} = $levels_result;
}

=head2 draw($canvas, $scale, $start, $end)

Dibuja los niveles MTF visibles en el canvas.

=cut

sub draw {
    my ($self, $canvas, $scale, $start, $end) = @_;

    return if !$self->{show};
    return unless $self->{result} && $self->{result}->{mtf_levels} && @{ $self->{result}->{mtf_levels} };
    return unless $canvas && $scale;

    my $right_limit = ($canvas->Width() || 0) - 2;
    $right_limit = 0 if $right_limit < 0;

    for my $lvl (@{ $self->{result}->{mtf_levels} }) {
        # Si el nivel termina antes de la ventana visible, no lo dibujamos
        next if $lvl->{end_index} < $start;

        my $y = $scale->value_to_y($lvl->{price});
        next unless defined $y;

        my $x_start = $scale->index_to_center_x($lvl->{start_index});
        $x_start = 0 if !defined $x_start || $x_start < 0;

        my $x_end = $scale->index_to_center_x($lvl->{end_index});
        # Si la vela final del nivel cae fuera del gráfico, extendemos la línea
        $x_end = $right_limit if !defined $x_end || $lvl->{end_index} >= $end;

        next if $x_end < $x_start;

        # Asignamos colores estilo Neon/SMC Pro según la temporalidad
        my $color = $lvl->{tf} eq 'D' ? '#00d4ff' :   # Cyan para Daily
                    $lvl->{tf} eq 'W' ? '#ff3a8c' :   # Pink para Weekly
                                        '#39ff14';    # Lime para Monthly

        $canvas->createLine(
            $x_start, $y, $x_end, $y,
            -fill  => $color,
            -width => 2,
        );

        if ($self->{show_labels}) {
            $canvas->createText(
                $x_end - 4,
                $y - 8,
                -text   => $lvl->{label}, # PDH, PDL, PWH, etc.
                -fill   => $color,
                -font   => ['Arial', 8, 'bold'],
                -anchor => 'e',
            );
        }
    }
}

1;
