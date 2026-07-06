package Market::Overlays::ChoCH;

use strict;
use warnings;

=head1 NOMBRE

Market::Overlays::ChoCH - Capa visual que resalta los eventos de Change of
Character (CHoCH) detectados por Market::Indicators::SMC_Structures,
dibujando una línea horizontal punteada desde el nivel estructural roto
hasta el punto de ruptura, más una etiqueta "CHoCH".

Se apoya en el mismo resultado (smc_result) que ya calcula
Market::Overlays::SMC_Structures, sólo que filtra y resalta específicamente
los eventos de tipo CHoCH_UP / CHoCH_DOWN.

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        smc_result => $args{smc_result},
        show       => $args{show} // 1,
    };

    return bless $self, $class;
}

=head2 set_result($smc_result)

Actualiza el resultado calculado por el motor de estructura SMC.

=cut

sub set_result {
    my ($self, $smc_result) = @_;
    $self->{smc_result} = $smc_result;
}

=head2 draw($canvas, $scale, $start, $end)

Dibuja los eventos CHoCH visibles entre los índices [$start, $end].

=cut

sub draw {
    my ($self, $canvas, $scale, $start, $end) = @_;

    return unless $self->{show};
    return unless $self->{smc_result} && $self->{smc_result}->{events};
    return unless $canvas && $scale;

    my $right_limit = ($canvas->Width() || 0) - 2;
    $right_limit = 0 if $right_limit < 0;

    for my $ev (@{$self->{smc_result}->{events}}) {

        next unless $ev->{type} eq 'CHoCH_UP' || $ev->{type} eq 'CHoCH_DOWN';
        next if $ev->{index} < $start;
        next if defined $ev->{level_index} && $ev->{level_index} > $end;

        my $color = $ev->{type} eq 'CHoCH_UP' ? '#ff9800' : '#ab47bc';

        my $x2 = $scale->index_to_center_x($ev->{index});
        $x2 = $right_limit if $x2 > $right_limit;

        my $level_index = defined $ev->{level_index} ? $ev->{level_index} : $ev->{index};
        $level_index = $start if $level_index < $start;

        my $x1 = $scale->index_to_center_x($level_index);
        my $y  = $scale->value_to_y($ev->{level_price} // $ev->{price});

        next if $x2 < $x1;

        $canvas->createLine(
            $x1, $y, $x2, $y,
            -fill  => $color,
            -dash  => [6, 3],
            -width => 2
        );

        $canvas->createText(
            $x2,
            $y + ($ev->{type} eq 'CHoCH_UP' ? -12 : 12),
            -text   => 'CHoCH',
            -fill   => $color,
            -font   => ['Arial', 8, 'bold'],
            -anchor => 'center'
        );
    }
}

1;
