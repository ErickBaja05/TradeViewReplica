package Market::Overlays::FVG;

use strict;
use warnings;

=head1 NOMBRE

Market::Overlays::FVG2 - Capa visual que dibuja las zonas FVG calculadas por
Market::Indicators::FVG2 sobre el canvas principal de velas.

=head1 DESCRIPCIÓN

Replica visualmente el indicador PineScript "SMC Structures and FVG":

  * FVG ALCISTA (BULLISH, Open)      => franja verde semitransparente
  * FVG BAJISTA (BEARISH, Open)      => franja roja semitransparente
  * Cualquier FVG parcialmente
    mitigado (estado 'Mitigated')    => franja gris semitransparente
  * FVG totalmente mitigado (Filled) => no se dibuja (ya eliminado del motor)

Las franjas se extienden hasta la barra en que fueron totalmente mitigadas
o, si siguen abiertas, hasta el borde derecho del canvas.

=cut

# Colores fieles al PineScript original
my %COLORS = (
    BULLISH_FILL    => '#26a69a',   # verde teal (bullishFvgColor)
    BULLISH_OUTLINE => '#089981',
    BEARISH_FILL    => '#ef5350',   # rojo (bearishFvgColor)
    BEARISH_OUTLINE => '#f23645',
    MITIGATED_FILL  => '#9e9e9e',   # gris (mitigatedFvgColor)
    MITIGATED_OUTLINE => '#757575',
);

sub new {
    my ($class, %args) = @_;

    my $self = {
        fvg2_result => $args{fvg2_result},
        show        => $args{show} // 1,
    };

    return bless $self, $class;
}

=head2 set_result($fvg2_result)

Actualiza el resultado calculado por el motor FVG2.

=cut

sub set_result {
    my ($self, $fvg2_result) = @_;
    $self->{fvg2_result} = $fvg2_result;
}

=head2 draw($canvas, $scale, $start, $end)

Dibuja las franjas FVG2 visibles en la ventana [$start, $end].

=cut

sub draw {
    my ($self, $canvas, $scale, $start, $end) = @_;

    return unless $self->{show};
    return unless $self->{fvg2_result} && $self->{fvg2_result}->{zones};
    return unless $canvas && $scale;

    my $right_limit = ($canvas->Width() || 0) - 2;
    $right_limit = 0 if $right_limit < 0;

    for my $z (@{$self->{fvg2_result}->{zones}}) {

        # Zonas desalojadas por el límite de historial o totalmente mitigadas
        # y fuera del rango visible no se dibujan.
        next if $z->{evicted};

        # Índice derecho de la franja: hasta dónde se dibuja
        my $draw_end_index = defined $z->{filled_index}
            ? $z->{filled_index}
            : $end;

        next if $draw_end_index < $start;
        next if $z->{left_index} > $end;

        my $x1 = $scale->index_to_x($z->{left_index} + 2);
        my $x2 = $scale->index_to_x($draw_end_index + 1);
        $x2 = $right_limit if $x2 > $right_limit;

        next if $x2 <= $x1;

        # Precio superior e inferior de la zona (pueden haber sido recortados
        # si reduce_mitigated estaba activo en el motor)
        my $y1 = $scale->value_to_y($z->{top});
        my $y2 = $scale->value_to_y($z->{bottom});

        # Elegir colores según estado
        my ($fill, $outline, $label_text);
        next if ($z->{state} eq 'Mitigated' || $z->{state} eq 'Filled');
        
        if ($z->{type} eq 'BULLISH') {
            $fill    = $COLORS{BULLISH_FILL};
            $outline = $COLORS{BULLISH_OUTLINE};
            $label_text = '^ FVG';
        }
        else {
            $fill    = $COLORS{BEARISH_FILL};
            $outline = $COLORS{BEARISH_OUTLINE};
            $label_text = 'v FVG';
        }

        # Franja semitransparente con stipple (Tk no tiene alpha real)
        $canvas->createRectangle(
            $x1, $y1, $x2, $y2,
            -fill    => $fill,
            -outline => $outline,

            -width   => 1,
        );

        # Etiqueta "FVG" centrada si la franja tiene suficiente ancho
        if (($x2 - $x1) > 24) {
            my $label_color = $z->{state} eq 'Mitigated'
                ? $COLORS{MITIGATED_OUTLINE}
                : $outline;

            $canvas->createText(
                $x1 + 4, ($y1 + $y2) / 2,
                -text   => $label_text,
                -fill   => '#000000',
                -font   => ['Arial', 10, 'bold'],
                -anchor => 'w',
            );
        }
    }
}

1;
