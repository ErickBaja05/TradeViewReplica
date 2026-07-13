package Market::Overlays::Channel;

use strict;
use warnings;

=head1 NOMBRE

Market::Overlays::Channel - Capa visual que dibuja únicamente la FRANJA
INTERNA del canal calculado por Market::Indicators::Channel (la banda entre
mid_top y mid_bottom, alrededor de la línea center). No se dibujan las
líneas top/bottom ni la franja exterior del script original.

Los colores se alternan entre canales consecutivos (según su orden de
creación) para poder distinguirlos visualmente cuando dos canales se
solapan en pantalla.

=cut

# Dos paletas que alternan por creación de canal, una para canales alcistas
# y otra para bajistas, de forma que además de alternar por solape se siga
# distinguiendo la polaridad del canal.
my @UP_COLORS   = ('#337c4f', '#2ecc71');
my @DOWN_COLORS = ('#a52d2d', '#e74c3c');

sub new {
    my ($class, %args) = @_;

    my $self = {
        result => $args{result},
        show   => $args{show} // 1,
        alpha  => $args{alpha} // 'gray50', # patrón "stipple" para simular transparencia
    };

    return bless $self, $class;
}

sub set_result {
    my ($self, $result) = @_;
    $self->{result} = $result;
}

=head2 draw($canvas, $scale, $start, $end)

Dibuja, para cada canal visible en la ventana [$start, $end], un polígono
relleno que sigue la pendiente de mid_top/mid_bottom entre su barra de
inicio y su barra final (recortado a la ventana visible).

=cut

sub draw {
    my ($self, $canvas, $scale, $start, $end) = @_;

    return unless $self->{show};
    return unless $self->{result} && $self->{result}->{channels};
    return unless $canvas && $scale;

    my $right_limit = ($canvas->Width() || 0) - 2;
    $right_limit = 0 if $right_limit < 0;

    for my $ch (@{$self->{result}->{channels}}) {
        next if $ch->{end} < $start;
        next if $ch->{start} > $end;

        my $draw_start = $ch->{start} < $start ? $start : $ch->{start};
        my $draw_end   = $ch->{end}   > $end   ? $end   : $ch->{end};
        next if $draw_end <= $draw_start;

        my $span = $ch->{end} - $ch->{start};
        $span = 1 if $span == 0;

        # Interpolación lineal de mid_top / mid_bottom en los bordes visibles,
        # replicando la pendiente de las líneas del canal original.
        my $frac_l = ($draw_start - $ch->{start}) / $span;
        my $frac_r = ($draw_end   - $ch->{start}) / $span;

        my $mt_l = $ch->{mid_top_y1}    + ($ch->{mid_top_y2}    - $ch->{mid_top_y1})    * $frac_l;
        my $mt_r = $ch->{mid_top_y1}    + ($ch->{mid_top_y2}    - $ch->{mid_top_y1})    * $frac_r;
        my $mb_l = $ch->{mid_bottom_y1} + ($ch->{mid_bottom_y2} - $ch->{mid_bottom_y1}) * $frac_l;
        my $mb_r = $ch->{mid_bottom_y1} + ($ch->{mid_bottom_y2} - $ch->{mid_bottom_y1}) * $frac_r;

        my $x1 = $scale->index_to_x($draw_start);
        my $x2 = $scale->index_to_x($draw_end + 1);
        $x2 = $right_limit if $x2 > $right_limit;
        next if $x2 <= $x1;

        my $y_top_l    = $scale->value_to_y($mt_l);
        my $y_top_r    = $scale->value_to_y($mt_r);
        my $y_bottom_l = $scale->value_to_y($mb_l);
        my $y_bottom_r = $scale->value_to_y($mb_r);

        # Alterna color según el orden de creación del canal (seq), para
        # que dos canales solapados en pantalla se distingan entre sí.
        my $palette = $ch->{polarity} ? \@UP_COLORS : \@DOWN_COLORS;
        my $color   = $palette->[$ch->{seq} % scalar(@$palette)];

        $canvas->createPolygon(
            $x1, $y_top_l,
            $x2, $y_top_r,
            $x2, $y_bottom_r,
            $x1, $y_bottom_l,
            -fill    => $color,
            -outline => $color,
            -stipple => $self->{alpha},
            -width   => 1,
        );
    }
}

1;
