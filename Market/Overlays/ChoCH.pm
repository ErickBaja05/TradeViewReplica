package Market::Overlays::ChoCH;

use strict;
use warnings;

=head1 NOMBRE

Market::Overlays::ChoCH - Capa visual que resalta los eventos de Change of
Character (CHoCH) detectados por Market::Indicators::SMC_Structures,
dibujando una línea horizontal desde el nivel estructural roto hasta el
punto de ruptura, más una etiqueta "CHoCH".

Distingue dos grados de estructura mediante el campo "tier" de cada evento:

  - tier "structural" => CHoCH externo: línea PUNTEADA (comportamiento ya
                          existente).
  - tier "minor"       => CHoCH interno: también punteada, con etiqueta
                           "CHoCH (int)" para diferenciarla del externo.

Se apoya en el resultado (smc_result) que combina ChartEngine a partir de
las instancias externa e interna de Market::Indicators::SMC_Structures,
sólo que filtra y resalta específicamente los eventos de tipo
CHoCH_UP / CHoCH_DOWN.

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        smc_result     => $args{smc_result},
        show           => $args{show} // 1,
        show_external  => $args{show_external} // 1,
        show_internal  => $args{show_internal} // 1,
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

        my $is_internal = ($ev->{tier} // 'structural') eq 'minor';
        next if $is_internal  && !$self->{show_internal};
        next if !$is_internal && !$self->{show_external};

        my $color = $ev->{type} eq 'CHoCH_UP' ? '#0f4b03' : '#6e0909';
        my $text  = $ev->{type} eq 'CHoCH_UP' ? 'CHoCH ^' : 'CHoCH v';
        $text .= ' (int)' if $is_internal;

        my $x2 = $scale->index_to_center_x($ev->{index});
        $x2 = $right_limit if $x2 > $right_limit;

        my $level_index = defined $ev->{level_index} ? $ev->{level_index} : $ev->{index};
        $level_index = $start if $level_index < $start;

        my $x1 = $scale->index_to_center_x($level_index);
        my $y  = $scale->value_to_y($ev->{level_price} // $ev->{price});

        next if $x2 < $x1;

        # CHoCH externo e interno: ambos con línea PUNTEADA. El interno se
        # dibuja más fino para distinguirlo visualmente del externo.
        $canvas->createLine(
            $x1, $y, $x2, $y,
            -fill  => $color,
            -width => $is_internal ? 1 : 2,
            -dash  => $is_internal ? [2, 2] : [5, 3],
        );

        $canvas->createText(
            $x2,
            $y + ($ev->{type} eq 'CHoCH_UP' ? -12 : 12),
            -text   => $text,
            -fill   => $color,
            -font   => ['Arial', $is_internal ? 7 : 8, 'bold'],
            -anchor => 'center'
        );
    }
}

1;