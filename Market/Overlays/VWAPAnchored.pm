package Market::Overlays::VWAPAnchored;

use strict;
use warnings;

=head1 NOMBRE

Market::Overlays::VWAPAnchored - Capa visual que dibuja el VWAP Anclado
calculado por Market::Indicators::VWAPAnchored sobre el canvas de precios.

  * Línea central (vwap)         => azul sólido
  * Banda de 1 sigma (upper/lower) => canal semitransparente + líneas punteadas
  * Marcador triangular en la vela de ancla

El indicador sólo se dibuja desde la vela de ancla en adelante (nunca hacia
atrás), tal como en TradingView.

=cut

my $LINE_COLOR   = '#ff8800';   # azul (línea central vwap)
my $BAND_COLOR   = '#ff8800';   # azul (líneas de banda)
my $BAND_FILL    = '#ff8800';   # relleno del canal (semitransparente via stipple)
my $ANCHOR_COLOR = '#fffb00';   # naranja (marcador de ancla)

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

    my $anchor_index = $self->{result}->{anchor_index};
    my $right_limit  = ($canvas->Width() || 0) - 2;
    $right_limit = 0 if $right_limit < 0;

    # Construimos únicamente los puntos visibles (o el punto justo anterior
    # a la ventana, para que la línea entrante se vea conectada).
    my (@upper_pts, @lower_pts, @vwap_pts);

    for my $v (@$values) {
        my $i = $v->{index};
        next if $i < $start - 1 || $i > $end;

        my $x = $scale->index_to_center_x($i);
        next unless defined $x;
        last if $x > $right_limit + 1;

        push @vwap_pts,  [$x, $scale->value_to_y($v->{vwap})];
        push @upper_pts, [$x, $scale->value_to_y($v->{upper})];
        push @lower_pts, [$x, $scale->value_to_y($v->{lower})];
    }

    return unless @vwap_pts >= 1;

    # --- Canal (banda de 1 sigma): polígono semitransparente ---
    if (@upper_pts >= 2) {
        my @poly;
        push @poly, @$_ for @upper_pts;
        push @poly, @$_ for reverse @lower_pts;

        $canvas->createPolygon(
            @poly,
            -fill    => $BAND_FILL,
            -outline => '',
            -stipple => 'gray12',
        );
    }

    # --- Líneas de banda superior/inferior (punteadas) ---
    for my $set ([\@upper_pts], [\@lower_pts]) {
        my ($pts) = @$set;
        next unless @$pts >= 2;
        my @flat;
        push @flat, @$_ for @$pts;
        $canvas->createLine(
            @flat,
            -fill  => $BAND_COLOR,
            -width => 1,
            -dash  => '.',
        );
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
