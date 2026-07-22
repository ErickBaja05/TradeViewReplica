package Market::Overlays::GhostVWAP;

use strict;
use warnings;

=head1 NOMBRE

Market::Overlays::GhostVWAP - Capa visual "Ghost VWAP" y "Regular VWAP" del indicador
Market::Indicators::Anchors.

Dibuja:
  - El VWAP Anclado en el último pivote fantasma / missed (clave C<ghost_vwap> o C<missed_vwap>).
  - El VWAP Anclado en el último pivote regular / confirmado (clave C<regular_vwap> o C<consolidated_vwap>).
  - Las líneas centrales y de bandas sigma (sin relleno de área).
  - El marcador 👻 flotante en el pivote fantasma vivo.

=cut

# Estilos para el VWAP de Pivote Fantasma / Missed (Tonos Violeta)
my %GHOST_SIGMA_STYLE = (
    1 => { color => '#ab47bc' },   # violeta claro
    2 => { color => '#7e57c2' },   # violeta/azulado
    3 => { color => '#5c6bc0' },   # índigo
);
my $GHOST_LINE_COLOR = '#ab47bc';

# Estilos para el VWAP de Pivote Regular / Confirmado (Tonos Naranja/Dorado)
my %REGULAR_SIGMA_STYLE = (
    1 => { color => '#ffa726' },   # naranja claro
    2 => { color => '#fb8c00' },   # naranja medio
    3 => { color => '#ef6c00' },   # naranja oscuro
);
my $REGULAR_LINE_COLOR = '#ff9800';

sub new {
    my ($class, %args) = @_;

    my $self = {
        result      => $args{result},
        show        => $args{show} // 1,
        sigma_range => $args{sigma_range} // 1,
        color_high  => $args{color_high} // '#ef5350',
        color_low   => $args{color_low}  // '#26a69a',
    };

    return bless $self, $class;
}

sub set_result {
    my ($self, $result) = @_;
    $self->{result} = $result;
}

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

Dibuja las líneas de los VWAPs (Pivote Regular y Pivote Fantasma/Missed) y el marcador 👻 flotante
visibles en la ventana [$start, $end].

=cut

sub draw {
    my ($self, $canvas, $scale, $start, $end) = @_;

    return unless $self->{show};
    return unless $self->{result} && $canvas && $scale;

    my $right_limit = ($canvas->Width() || 0) - 2;
    $right_limit = 0 if $right_limit < 0;

    # 1. VWAP del último pivote REGULAR (confirmado)
    my $reg_vwap = $self->{result}->{regular_vwap} // $self->{result}->{consolidated_vwap};
    if ($reg_vwap && $reg_vwap->{values} && @{$reg_vwap->{values}}) {
        $self->_draw_vwap_bands(
            $canvas, $scale, $start, $end, $right_limit,
            $reg_vwap->{values}, \%REGULAR_SIGMA_STYLE, $REGULAR_LINE_COLOR
        );
    }

    # 2. VWAP del último pivote FANTASMA / MISSED
    my $ghost_vwap = $self->{result}->{ghost_vwap} // $self->{result}->{missed_vwap};
    if ($ghost_vwap && $ghost_vwap->{values} && @{$ghost_vwap->{values}}) {
        $self->_draw_vwap_bands(
            $canvas, $scale, $start, $end, $right_limit,
            $ghost_vwap->{values}, \%GHOST_SIGMA_STYLE, $GHOST_LINE_COLOR
        );
    }

    # 3. Marcador 👻 flotante (pivote fantasma "vivo")
    my $live_ghost = $self->{result}->{live_ghost};
    if ($live_ghost && defined $live_ghost->{index}
        && $live_ghost->{index} >= $start && $live_ghost->{index} <= $end) {

        my $x = $scale->index_to_center_x($live_ghost->{index});
        my $y = $scale->value_to_y($live_ghost->{price});

        if (defined $x && defined $y && $x <= $right_limit) {
            my $is_high = ($live_ghost->{dir} // 0) == 1;
            my $color   = $is_high ? $self->{color_high} : $self->{color_low};
            my $dy      = $is_high ? -13 : 13;

            $canvas->createText(
                $x, $y + $dy,
                -text   => "\x{1F47B}",
                -fill   => $color,
                -font   => ['Arial', 9, 'normal'],
                -anchor => 'center',
            );
        }
    }
}

=head2 _draw_vwap_bands

Dibuja exclusivamente las líneas del VWAP (línea central sólida y líneas de bandas sigma punteadas).

=cut

sub _draw_vwap_bands {
    my ($self, $canvas, $scale, $start, $end, $right_limit, $values, $styles, $line_color) = @_;

    my $sigma_range = $self->get_sigma_range();
    my @vwap_pts;
    my %upper_pts = map { $_ => [] } 1 .. $sigma_range;
    my %lower_pts = map { $_ => [] } 1 .. $sigma_range;

    # Recopilar coordenadas
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

    return unless @vwap_pts;

    # Dibujar las líneas de las Bandas Sigma (punteadas, sin polígono de relleno)
    for my $n (reverse 1 .. $sigma_range) {
        my $style = $styles->{$n};
        my $up    = $upper_pts{$n};
        my $low   = $lower_pts{$n};

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

    # Dibujar Línea Central
    if (@vwap_pts >= 2) {
        my @flat;
        push @flat, @$_ for @vwap_pts;
        $canvas->createLine(
            @flat,
            -fill  => $line_color,
            -width => 2,
        );
    } else {
        my ($x, $y) = @{$vwap_pts[0]};
        $canvas->createOval($x - 2, $y - 2, $x + 2, $y + 2, -fill => $line_color, -outline => $line_color);
    }
}

1;
