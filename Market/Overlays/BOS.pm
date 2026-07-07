package Market::Overlays::BOS;

use strict;
use warnings;

=head1 NOMBRE

Market::Overlays::BOS - Capa visual que resalta los eventos de Break of
Structure (BOS) detectados por Market::Indicators::SMC_Structures, dibujando
una línea horizontal desde el nivel estructural roto hasta el punto de
ruptura, más una etiqueta "BOS".

Distingue dos grados de estructura mediante el campo "tier" de cada evento:

  - tier "structural" => BOS externo: línea SÓLIDA.
  - tier "minor"       => BOS interno: línea PUNTEADA.

Se apoya en el resultado (smc_result) que combina ChartEngine a partir de
las instancias externa e interna de Market::Indicators::SMC_Structures,
filtrando y resaltando específicamente los eventos de tipo
BOS_UP / BOS_DOWN (y sus variantes *_CONFIRM, que se tratan igual).

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        smc_result    => $args{smc_result},
        show          => $args{show} // 1,
        show_external => $args{show_external} // 1,
        show_internal => $args{show_internal} // 1,
    };

    return bless $self, $class;
}

=head2 set_result($smc_result)

Actualiza el resultado calculado por el motor de estructura SMC (externo +
interno, ya combinado por ChartEngine).

=cut

sub set_result {
    my ($self, $smc_result) = @_;
    $self->{smc_result} = $smc_result;
}

=head2 draw($canvas, $scale, $start, $end)

Dibuja los eventos BOS visibles entre los índices [$start, $end].

=cut

sub draw {
    my ($self, $canvas, $scale, $start, $end) = @_;

    return unless $self->{show};
    return unless $self->{smc_result} && $self->{smc_result}->{events};
    return unless $canvas && $scale;

    my $right_limit = ($canvas->Width() || 0) - 2;
    $right_limit = 0 if $right_limit < 0;

    for my $ev (@{$self->{smc_result}->{events}}) {

        next unless $ev->{type} =~ /^BOS_(UP|DOWN)(_CONFIRM)?$/;
        my $direction = $1;

        next if $ev->{index} < $start;
        next if defined $ev->{level_index} && $ev->{level_index} > $end;

        my $is_internal = ($ev->{tier} // 'structural') eq 'minor';
        next if $is_internal  && !$self->{show_internal};
        next if !$is_internal && !$self->{show_external};

        my $color = $direction eq 'UP' ? '#089981' : '#f23645';
        my $text  = $direction eq 'UP' ? 'BOS ^' : 'BOS v';
        $text .= ' (int)' if $is_internal;

        my $x2 = $scale->index_to_center_x($ev->{index});
        $x2 = $right_limit if $x2 > $right_limit;

        my $level_index = defined $ev->{level_index} ? $ev->{level_index} : $ev->{index};
        $level_index = $start if $level_index < $start;

        my $x1 = $scale->index_to_center_x($level_index);
        my $y  = $scale->value_to_y($ev->{level_price} // $ev->{price});

        next if $x2 < $x1;

        warn sprintf(
    "BOS: index=%d level_index=%s\n",
    $ev->{index},
    defined $ev->{level_index} ? $ev->{level_index} : "undef",
);

        # BOS externo: línea SÓLIDA. BOS interno: línea PUNTEADA (más fina).
        my %line_opts = (
            -fill  => $color,
            -width => $is_internal ? 1 : 2,
        );
        $line_opts{-dash} = [3, 3] if $is_internal;

        $canvas->createLine($x1, $y, $x2, $y, %line_opts);

        $canvas->createText(
            $x2,
            $y + ($direction eq 'UP' ? -12 : 12),
            -text   => $text,
            -fill   => $color,
            -font   => ['Arial', $is_internal ? 7 : 8, 'bold'],
            -anchor => 'center'
        );
    }
}

1;