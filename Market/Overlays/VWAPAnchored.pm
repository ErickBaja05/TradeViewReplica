package Market::Overlays::VWAPAnchored;

use strict;
use warnings;

=head1 NOMBRE

Market::Overlays::VWAPAnchored - Capa visual que dibuja el VWAP Anclado
calculado por Market::Indicators::VWAPAnchored sobre el canvas de precios.

  * Línea central (vwap)              => línea sólida naranja
  * Banda de 1 sigma (upper1/lower1)  => canal + líneas punteadas naranja
  * Banda de 2 sigma (upper2/lower2)  => canal + líneas punteadas azul (si sigma_range >= 2)
  * Banda de 3 sigma (upper3/lower3)  => canal + líneas punteadas violeta (si sigma_range >= 3)
  * Marcador triangular en la vela de ancla

El rango de sigmas visible se controla con {sigma_range} (1, 2 o 3), lo que
replica el comportamiento del indicador nativo de TradingView cuando se
configuran múltiples desviaciones estándar.

El indicador sólo se dibuja desde la vela de ancla en adelante (nunca hacia
atrás), tal como en TradingView.

=cut

my $LINE_COLOR   = '#ff8800';   # naranja (línea central vwap)
my $ANCHOR_COLOR = '#fffb00';   # amarillo (marcador de ancla)

# Colores por banda de sigma: [color de línea/relleno, patrón de stipple]
my %SIGMA_STYLE = (
    1 => { color => '#ff8800', stipple => 'gray12' },   # naranja
    2 => { color => '#2962ff', stipple => 'gray12' },   # azul
    3 => { color => '#9c27b0', stipple => 'gray12' },   # violeta
);

sub new {
    my ($class, %args) = @_;

    my $self = {
        result      => $args{result},
        show        => $args{show} // 1,
        sigma_range => $args{sigma_range} // 1,   # 1, 2 o 3 sigmas a mostrar
    };

    return bless $self, $class;
}

sub set_result {
    my ($self, $result) = @_;
    $self->{result} = $result;
}

=head2 set_sigma_range($n)

Configura cuántas bandas de desviación estándar se dibujan (1, 2 o 3).
Valores fuera de ese rango se ajustan al límite más cercano.

=cut

sub set_sigma_range {
    my ($self, $n) = @_;
    return unless defined $n;
    $n = 1 if $n < 1;
    $n = 3 if $n > 3;
    $self->{sigma_range} = $n;
}

sub get_sigma_range {
    my ($self) = @_;
    return $self->{sigma_range} // 1;
}

=head2 draw($canvas, $scale, $start, $end)

Dibuja el VWAP Anclado (línea central + banda de 1 sigma) visible en la
ventana [$start, $end]. Si la vela de ancla está fuera (a la izquierda) de
la ventana visible, el trazo simplemente continúa desde el borde izquierdo.

=cut

sub draw {
    my ($self, $canvas, $scale, $start, $end) = @_;

    return unless $self->{show};
    return unless $self->{result} && $self->{result}->{values};
    return unless $canvas && $scale;

    my $values = $self->{result}->{values};
    return unless @$values;

    my $sigma_range  = $self->get_sigma_range();
    my $anchor_index = $self->{result}->{anchor_index};
    my $right_limit  = ($canvas->Width() || 0) - 2;
    $right_limit = 0 if $right_limit < 0;

    # Construimos únicamente los puntos visibles (o el punto justo anterior
    # a la ventana, para que la línea entrante se vea conectada). Guardamos
    # los puntos de cada banda de sigma habilitada (1..sigma_range) además
    # de la línea central del vwap.
    my @vwap_pts;
    my %upper_pts = map { $_ => [] } 1 .. $sigma_range;
    my %lower_pts = map { $_ => [] } 1 .. $sigma_range;

    for my $v (@$values) {
        my $i = $v->{index};
        next if $i < $start - 1 || $i > $end;

        my $x = $scale->index_to_center_x($i);
        next unless defined $x;
        last if $x > $right_limit + 1;

        push @vwap_pts, [$x, $scale->value_to_y($v->{vwap})];

        for my $n (1 .. $sigma_range) {
            push @{$upper_pts{$n}}, [$x, $scale->value_to_y($v->{"upper$n"})];
            push @{$lower_pts{$n}}, [$x, $scale->value_to_y($v->{"lower$n"})];
        }
    }

    return unless @vwap_pts >= 1;

    # --- Canales y líneas de banda, desde la más externa (3 sigma) hacia la
    # más interna (1 sigma), así la banda de 1 sigma queda dibujada encima y
    # se ve siempre nítida. ---
    for my $n (reverse 1 .. $sigma_range) {
        my $style = $SIGMA_STYLE{$n};
        my $up    = $upper_pts{$n};
        my $low   = $lower_pts{$n};

        # Canal semitransparente
        if (@$up >= 2) {
            my @poly;
            push @poly, @$_ for @$up;
            push @poly, @$_ for reverse @$low;

            $canvas->createPolygon(
                @poly,
                -fill    => $style->{color},
                -outline => '',
                -stipple => $style->{stipple},
            );
        }

        # Líneas de banda superior/inferior (punteadas)
        for my $pts ($up, $low) {
            next unless @$pts >= 2;
            my @flat;
            push @flat, @$_ for @$pts;
            $canvas->createLine(
                @flat,
                -fill  => $style->{color},
                -width => 1,
                -dash  => '.',
            );
        }
    }

    # --- Línea central VWAP ---
    if (@vwap_pts >= 2) {
        my @flat;
        push @flat, @$_ for @vwap_pts;
        $canvas->createLine(
            @flat,
            -fill  => $LINE_COLOR,
            -width => 2,
        );
    }
    elsif (@vwap_pts == 1) {
        # Sólo la vela de ancla visible: dibujamos un punto para que el
        # indicador no desaparezca por completo.
        my ($x, $y) = @{$vwap_pts[0]};
        $canvas->createOval($x - 2, $y - 2, $x + 2, $y + 2, -fill => $LINE_COLOR, -outline => $LINE_COLOR);
    }

    # --- Marcador de la vela de ancla (triángulo naranja) ---
    if (defined $anchor_index && $anchor_index >= $start && $anchor_index <= $end) {
        my $ax = $scale->index_to_center_x($anchor_index);
        my $av = $values->[0];
        if (defined $ax && $av) {
            my $ay = $scale->value_to_y($av->{vwap});
            my $r  = 5;
            $canvas->createPolygon(
                $ax,     $ay - $r,
                $ax - $r, $ay + $r,
                $ax + $r, $ay + $r,
                -fill    => $ANCHOR_COLOR,
                -outline => '#ffffff',
            );
        }
    }
}

1;
