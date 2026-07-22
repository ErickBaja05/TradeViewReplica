package Market::Overlays::GhostLines;

use strict;
use warnings;

=head1 NOMBRE

Market::Overlays::GhostLines - Capa visual "Ghost Lines" del indicador
Market::Indicators::Anchors.

Dibuja:

  - El zigzag que conecta cada pivote (regular o fantasma/"missed") con el
    siguiente (clave C<ghost_lines>: segmentos {x1,y1,x2,y2,color_type,
    dashed}). Los tramos marcados C<dashed> se dibujan punteados (el
    "rastro" que deja un pivote fantasma hasta el próximo evento).

  - La línea punteada viva que conecta el último pivote confirmado con
    el pivote fantasma en formación (C<live_ghost>).

  - El "rastro" horizontal (C<ghost_level_segments>: {x1,y,x2,color_type,
    open}) que cada pivote fantasma deja hasta el siguiente evento
    confirmado. El tramo con C<open =E<gt> 1> es el más reciente y se
    extiende hasta el borde derecho de la ventana visible.

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        result       => $args{result},
        show         => $args{show} // 1,
        color_high   => $args{color_high} // '#ef5350',
        color_low    => $args{color_low}  // '#26a69a',
    };

    return bless $self, $class;
}

=head2 set_result($result)

Actualiza el resultado calculado por Market::Indicators::Anchors (hashref
con las claves C<ghost_lines>, C<live_ghost> y C<ghost_level_segments> usadas por esta
capa).

=cut

sub set_result {
    my ($self, $result) = @_;
    $self->{result} = $result;
}

=head2 draw($canvas, $scale, $start, $end)

Dibuja el zigzag, la línea hacia el pivote fantasma vivo y los tramos de
"rastro" horizontal visibles entre los índices [$start, $end].

=cut

sub draw {
    my ($self, $canvas, $scale, $start, $end) = @_;

    return unless $self->{show};
    return unless $self->{result} && $canvas && $scale;

    my $right_limit = ($canvas->Width() || 0) - 2;
    $right_limit = 0 if $right_limit < 0;

    my $color_for = sub {
        my ($type) = @_;
        return ($type && $type eq 'high') ? $self->{color_high} : $self->{color_low};
    };

    # --- Zigzag (pivote a pivote) ---
    my $ghost_lines = $self->{result}->{ghost_lines} || [];

    for my $seg (@$ghost_lines) {
        next if $seg->{x2} < $start || $seg->{x1} > $end;

        my $x1 = $scale->index_to_center_x($seg->{x1});
        my $x2 = $scale->index_to_center_x($seg->{x2});
        my $y1 = $scale->value_to_y($seg->{y1});
        my $y2 = $scale->value_to_y($seg->{y2});

        next unless defined $x1 && defined $x2 && defined $y1 && defined $y2;
        next if $x1 > $right_limit && $x2 > $right_limit;

        $canvas->createLine(
            $x1, $y1, $x2, $y2,
            -fill  => $color_for->($seg->{color_type}),
            -width => 1,
            ($seg->{dashed} ? (-dash => '.') : ()),
        );
    }

    # --- Línea punteada viva (desde el último pivote hasta el fantasma vivo) ---
    my $live_ghost = $self->{result}->{live_ghost};
    if ($live_ghost && defined $live_ghost->{index} && @$ghost_lines) {
        my $last_pivot = $ghost_lines->[-1];
        my $x1_idx     = $last_pivot->{x2};
        my $y1_val     = $last_pivot->{y2};
        my $x2_idx     = $live_ghost->{index};
        my $y2_val     = $live_ghost->{price};

        if ($x2_idx >= $start && $x1_idx <= $end) {
            my $x1 = $scale->index_to_center_x($x1_idx);
            my $x2 = $scale->index_to_center_x($x2_idx);
            my $y1 = $scale->value_to_y($y1_val);
            my $y2 = $scale->value_to_y($y2_val);

            if (defined $x1 && defined $x2 && defined $y1 && defined $y2) {
                if ($x1 <= $right_limit || $x2 <= $right_limit) {
                    # dir == 1 indica que el pivote previo fue HIGH, por lo que el fantasma vivo busca un LOW
                    my $color_type = ($live_ghost->{dir} // 0) == 1 ? 'low' : 'high';

                    $canvas->createLine(
                        $x1, $y1, $x2, $y2,
                        -fill  => $color_for->($color_type),
                        -width => 1,
                        -dash  => '.',
                    );
                }
            }
        }
    }

    # --- Ghost levels (rastro horizontal punteado) ---
    my $level_segments = $self->{result}->{ghost_level_segments} || [];

    for my $seg (@$level_segments) {
        my $x1_idx = $seg->{x1};
        my $x2_idx = $seg->{open} ? $end : $seg->{x2};

        next unless defined $x2_idx;
        next if $x2_idx < $start || $x1_idx > $end;

        my $x1 = $scale->index_to_center_x($x1_idx < $start ? $start : $x1_idx);
        my $x2 = $scale->index_to_center_x($x2_idx > $end ? $end : $x2_idx);
        my $y  = $scale->value_to_y($seg->{y});

        next unless defined $x1 && defined $x2 && defined $y;
        next if $x1 > $right_limit;

        $canvas->createLine(
            $x1, $y, $x2, $y,
            -fill  => $color_for->($seg->{color_type}),
            -width => 1,
            -dash  => '.',
        );
    }
}

1;
