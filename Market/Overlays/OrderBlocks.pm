package Market::Overlays::OrderBlocks;

use strict;
use warnings;

=head1 NOMBRE

Market::Overlays::OrderBlocks - Capa visual que dibuja las zonas
Supply/Demand (Order Blocks) calculadas por Market::Indicators::OrderBlocks
sobre el canvas principal de velas.

=head1 DESCRIPCIÓN

Replica visualmente el bloque "Supply/Demand Zone" del PineScript original:

  * SUPPLY (zona de oferta, formada en un pivote alto) => franja gris clara
  * DEMAND (zona de demanda, formada en un pivote bajo) => franja cian
  * Zonas rotas (BOS) no se dibujan como caja activa (fielmente al original,
    que las colapsa a una línea delgada); aquí simplemente se dejan de
    dibujar más allá del índice de ruptura.
  * Las zonas activas se extienden hasta el borde derecho visible del
    gráfico (extend.right).

=cut

my %COLORS = (
    SUPPLY_FILL    => '#f0d908',
    SUPPLY_OUTLINE => '#ffffff',
    DEMAND_FILL    => '#0b2ce7',
    DEMAND_OUTLINE => '#ffffff',
);

sub new {
    my ($class, %args) = @_;

    my $self = {
        result => $args{result},
        show   => $args{show} // 1,
    };

    return bless $self, $class;
}

sub set_result {
    my ($self, $result) = @_;
    $self->{result} = $result;
}

=head2 draw($canvas, $scale, $start, $end)

Dibuja las zonas Supply/Demand visibles en la ventana [$start, $end].

=cut

sub draw {
    my ($self, $canvas, $scale, $start, $end) = @_;

    return unless $self->{show};
    return unless $self->{result} && $self->{result}->{zones};
    return unless $canvas && $scale;

    my $right_limit = ($canvas->Width() || 0) - 2;
    $right_limit = 0 if $right_limit < 0;

    for my $z (@{$self->{result}->{zones}}) {

        # Las zonas mitigadas (el precio ya regresó a tocarlas) no se
        # dibujan en absoluto, ni siquiera su forma histórica.
        next if $z->{mitigated};

        # Índice derecho de la franja: hasta dónde se dibuja
        my $draw_end_index = defined $z->{right_index} ? $z->{right_index} : $end;

        next if $draw_end_index < $start;
        next if $z->{left_index} > $end;

        my $x1 = $scale->index_to_x($z->{left_index});
        my $x2 = $scale->index_to_x($draw_end_index + 1);
        $x2 = $right_limit if $x2 > $right_limit;

        next if $x2 <= $x1;

        my $y1 = $scale->value_to_y($z->{top});
        my $y2 = $scale->value_to_y($z->{bottom});

        my ($fill, $outline, $label_text);
        if ($z->{type} eq 'SUPPLY') {
            $fill       = $COLORS{SUPPLY_FILL};
            $outline    = $COLORS{SUPPLY_OUTLINE};
            $label_text = 'SUPPLY';
        }
        else {
            $fill       = $COLORS{DEMAND_FILL};
            $outline    = $COLORS{DEMAND_OUTLINE};
            $label_text = 'DEMAND';
        }

        $canvas->createRectangle(
            $x1, $y1, $x2, $y2,
            -fill    => $fill,
            -outline => $outline,
            -stipple => 'gray25',
            -width   => 1,
        );

        if (($x2 - $x1) > 30) {
            $canvas->createText(
                ($x1 + $x2) / 2, ($y1 + $y2) / 2,
                -text   => $label_text,
                -fill   => $z->{type} eq 'SUPPLY' ? '#616161' : '#008b8b',
                -font   => ['Arial', 7, 'bold'],
                -anchor => 'center',
            );
        }
    }
}

1;
