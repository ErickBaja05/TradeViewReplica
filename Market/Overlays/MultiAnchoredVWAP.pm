package Market::Overlays::MultiAnchoredVWAP;

use strict;
use warnings;

=head1 NOMBRE

Market::Overlays::MultiAnchoredVWAP - Capa visual que dibuja múltiples VWAP
Anclados (uno por cada pivote de Market::Indicators::Anchors), calculados
por Market::Indicators::MultiAnchoredVWAP.

Cada línea de VWAP se colorea según el tipo de pivote que la ancla:
  * Pivotes altos (reg_high / missed_high)  => tonos rojos
  * Pivotes bajos  (reg_low  / missed_low)   => tonos verdes/teal

Cada serie sólo se dibuja desde su propia ancla hasta justo antes de la
ancla siguiente (nunca hasta el final del gráfico), de forma que el
indicador se perciba como un ÚNICO VWAP que se va "reanclando" cada vez
que el precio cruza un nuevo pivote, en lugar de mostrar N líneas de VWAP
superpuestas.

El rango de sigmas visible (1, 2 o 3) se controla con {sigma_range}, igual
que en Market::Overlays::VWAPAnchored.

=cut

my %STYLE = (
    high => { line => '#ef5350', sigma1 => '#ef5350', sigma2 => '#ff8a80', sigma3 => '#ffcdd2', stipple => 'gray12' },
    low  => { line => '#26a69a', sigma1 => '#26a69a', sigma2 => '#80cbc4', sigma3 => '#b2dfdb', stipple => 'gray12' },
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

Configura cuántas bandas de desviación estándar se dibujan (1, 2 o 3) para
TODAS las líneas de VWAP ancladas dibujadas por esta capa.

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

Dibuja cada serie de VWAP anclado visible en la ventana [$start, $end].

=cut

sub draw {
    my ($self, $canvas, $scale, $start, $end) = @_;

    return unless $self->{show};
    return unless $self->{result} && $self->{result}->{series};
    return unless $canvas && $scale;

    my $sigma_range = $self->get_sigma_range();
    my $right_limit = ($canvas->Width() || 0) - 2;
    $right_limit = 0 if $right_limit < 0;

    # Las series ya vienen ordenadas de ancla más antigua a más reciente
    # (Market::Indicators::MultiAnchoredVWAP las construye en ese orden).
    # Para que el indicador se vea como un ÚNICO VWAP que se reancla cada
    # vez que el precio cruza un nuevo pivote (en lugar de N líneas
    # superpuestas desde cada ancla hasta el final), recortamos cada serie
    # para que sólo se dibuje desde su propia ancla hasta justo antes de la
    # siguiente ancla. La última serie (la más reciente) sí se dibuja hasta
    # el final, ya que todavía no fue "reemplazada" por un nuevo pivote.
    my @series = @{ $self->{result}->{series} };

    for my $idx (0 .. $#series) {

        my $serie  = $series[$idx];
        my $values = $serie->{values};
        next unless $values && @$values;

        my $segment_end = ($idx < $#series) ? $series[$idx + 1]{anchor_index} - 1 : undef;

        my $is_high = ($serie->{type} eq 'reg_high' || $serie->{type} eq 'missed_high');
        my $style   = $is_high ? $STYLE{high} : $STYLE{low};

        my @vwap_pts;
        my %upper_pts = map { $_ => [] } 1 .. $sigma_range;
        my %lower_pts = map { $_ => [] } 1 .. $sigma_range;

        for my $v (@$values) {
            my $i = $v->{index};
            next if defined $segment_end && $i > $segment_end;
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

        next unless @vwap_pts >= 1;

        # --- Canales rellenos (franjas semitransparentes) y líneas de
        # banda, de la más externa a la más interna, para que la banda de
        # 1 sigma quede siempre nítida por encima ---
        for my $n (reverse 1 .. $sigma_range) {
            my $band_color = $style->{"sigma$n"};
            my $up   = $upper_pts{$n};
            my $low  = $lower_pts{$n};

            # Canal semitransparente entre banda superior e inferior
            if (@$up >= 2 && @$low >= 2) {
                my @poly;
                push @poly, @$_ for @$up;
                push @poly, @$_ for reverse @$low;

                $canvas->createPolygon(
                    @poly,
                    -fill    => $band_color,
                    -outline => '',
                    -stipple => $style->{stipple},
                );
            }

            for my $pts ($up, $low) {
                next unless @$pts >= 2;
                my @flat;
                push @flat, @$_ for @$pts;
                $canvas->createLine(
                    @flat,
                    -fill  => $band_color,
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
                -fill  => $style->{line},
                -width => 2,
            );
        }
        elsif (@vwap_pts == 1) {
            my ($x, $y) = @{$vwap_pts[0]};
            $canvas->createOval($x - 2, $y - 2, $x + 2, $y + 2, -fill => $style->{line}, -outline => $style->{line});
        }

        # --- Marcador del pivote de ancla ---
        my $anchor_index = $serie->{anchor_index};
        if (defined $anchor_index && $anchor_index >= $start && $anchor_index <= $end) {
            my $ax = $scale->index_to_center_x($anchor_index);
            my $av = $values->[0];
            if (defined $ax && $av) {
                my $ay = $scale->value_to_y($av->{vwap});
                my $r  = 3;
                $canvas->createOval(
                    $ax - $r, $ay - $r, $ax + $r, $ay + $r,
                    -fill    => $style->{line},
                    -outline => '#ffffff',
                );
            }
        }
    }
}

1;
