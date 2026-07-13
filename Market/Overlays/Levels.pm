package Market::Overlays::Levels;

use strict;
use warnings;

=head1 NOMBRE

Market::Overlays::Levels - Capa visual que dibuja los niveles de Soporte y
Resistencia calculados por Market::Indicators::Levels sobre el canvas de
precios.

Las resistencias se dibujan en rojo y los soportes en azul, como línea
horizontal sólida desde la barra donde se originó el pivote hasta el borde
derecho visible del gráfico (o, si el nivel ya fue roto, hasta la barra de
ruptura, con línea punteada).

=cut

my $COLOR_RESISTANCE = '#F23645';
my $COLOR_SUPPORT    = '#2962ff';

sub new {
    my ($class, %args) = @_;

    my $self = {
        result      => $args{result},
        show        => $args{show}       // 1,
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

Dibuja los niveles de Soporte/Resistencia visibles entre los índices
[$start, $end].

=cut

sub draw {
    my ($self, $canvas, $scale, $start, $end) = @_;

    return if !$self->{show};
    return unless $self->{result} && $self->{result}->{levels} && @{ $self->{result}->{levels} };
    return unless $canvas && $scale;

    my $right_limit = ($canvas->Width() || 0) - 2;
    $right_limit = 0 if $right_limit < 0;

    for my $lvl (@{ $self->{result}->{levels} }) {
        # Si el nivel se originó completamente a la derecha de la ventana
        # visible, todavía no hay nada que trazar.
        next if $lvl->{start_index} > $end;

        # Si el nivel ya se rompió antes del inicio de la ventana visible,
        # no queda nada visible de esta línea.
        next if $lvl->{broken} && $lvl->{end_index} < $start;

        my $y = $scale->value_to_y($lvl->{price});
        next unless defined $y;

        my $x_start = $scale->index_to_center_x($lvl->{start_index});
        $x_start = 0 if !defined $x_start || $x_start < 0;

        my $x_end;
        if ($lvl->{broken}) {
            $x_end = $scale->index_to_center_x($lvl->{end_index});
            next unless defined $x_end;
        }
        else {
            $x_end = $right_limit;
        }

        next if $x_end < $x_start;

        my $color = ($lvl->{type} eq 'RESISTANCE') ? $COLOR_RESISTANCE : $COLOR_SUPPORT;

        $canvas->createLine(
            $x_start, $y, $x_end, $y,
            -fill  => $color,
            -width => 1,
            ($lvl->{broken} ? (-dash => '.') : ()),
        );

        # Sólo etiquetamos los niveles vigentes (no rotos), pegados al
        # borde derecho visible, igual que hace el overlay de Fibonacci.
        next unless $self->{show_labels} && !$lvl->{broken};

        $canvas->createText(
            $right_limit - 4,
            $y - 8,
            -text   => _fmt_price($lvl->{price}),
            -fill   => $color,
            -font   => ['Arial', 8, 'bold'],
            -anchor => 'e',
        );
    }
}

sub _fmt_price {
    my ($p) = @_;
    return '' unless defined $p;
    return sprintf('%.5f', $p);
}

1;
