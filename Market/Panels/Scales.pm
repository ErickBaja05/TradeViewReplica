package Market::Panels::Scales;
use strict;
use warnings;

sub new
{
    my ($class, %args) = @_;
    my $self =
    {
        width         => $args{width}         || 800,
        height        => $args{height}        || 400,
        visible_bars  => $args{visible_bars}  || 100,
        offset        => $args{offset}        || 0,
        y_min         => $args{y_min}         || 0,
        y_max         => $args{y_max}         || 1,
        
        # CORRECCIÓN VITAL: Usar 'defined' en lugar de '||' para permitir márgenes de valor 0
        margin_left   => defined $args{margin_left}   ? $args{margin_left}   : 0,
        margin_right  => defined $args{margin_right}  ? $args{margin_right}  : 65,
        margin_top    => defined $args{margin_top}    ? $args{margin_top}    : 10,
        margin_bottom => defined $args{margin_bottom} ? $args{margin_bottom} : 25,
    };
    bless $self, $class;
    return $self;
}

sub index_to_x {
    my ($self, $index) = @_;
    my $offset = $index - $self->{offset};
    my $plot_width = $self->{width} - $self->{margin_left} - $self->{margin_right};
    my $candle_width = $plot_width / $self->{visible_bars};
    return $self->{margin_left} + $offset * $candle_width;
}

sub x_to_index {
    my ($self, $x) = @_;
    my $plot_width = $self->{width} - $self->{margin_left} - $self->{margin_right};
    my $candle_width = $plot_width / $self->{visible_bars};
    my $offset = ($x - $self->{margin_left}) / $candle_width;
    return int($offset + 0.5) + $self->{offset};
}

sub x_to_index_float {
    my ($self, $x) = @_;
    my $plot_width = $self->{width} - $self->{margin_left} - $self->{margin_right};
    my $candle_width = $plot_width / $self->{visible_bars};
    my $offset = ($x - $self->{margin_left}) / $candle_width;
    return $offset + $self->{offset};
}

sub index_to_center_x {
    my ($self, $index) = @_;
    my $offset = $index - $self->{offset};
    my $plot_width = $self->{width} - $self->{margin_left} - $self->{margin_right};
    my $candle_width = $plot_width / $self->{visible_bars};
    return $self->{margin_left} + $offset * $candle_width + $candle_width / 2;
}

sub value_to_y {
    my ($self, $value) = @_;
    my $plot_height = $self->{height} - $self->{margin_top} - $self->{margin_bottom};
    my $range = $self->{y_max} - $self->{y_min};
    return 0 if $range == 0;
    
    my $normalized = ($value - $self->{y_min}) / $range;
    return $self->{height} - $self->{margin_bottom} - ($normalized * $plot_height);
}

sub y_to_value {
    my ($self, $y) = @_;
    my $plot_height = $self->{height} - $self->{margin_top} - $self->{margin_bottom};
    my $range = $self->{y_max} - $self->{y_min};
    return 0 if $range == 0;

    my $normalized = ($self->{height} - $self->{margin_bottom} - $y) / $plot_height;
    return ($normalized * $range) + $self->{y_min};
}

# Modificado para recibir el canvas independiente del eje Y
sub _draw_y_scale {
    my ($self, $canvas, $axis_canvas) = @_;
    return unless $canvas;

    my $range = $self->{y_max} - $self->{y_min};
    return if $range <= 0;

    my $grid_color = '#1f2933'; 
    my $text_color = '#787b86'; 
    my $num_lines  = 6;         
    my $step       = $range / $num_lines;

    my $plot_width = $self->{width}; 

    # Borde separador derecho en el canvas principal
    $canvas->createLine($plot_width - 1, 0, $plot_width - 1, $self->{height}, -fill => $grid_color);

    for my $i (1 .. $num_lines - 1) {
        my $value = $self->{y_min} + ($i * $step);
        my $y = $self->value_to_y($value);
        my $fmt_value = ($range < 10) ? sprintf("%.4f", $value) : sprintf("%.2f", $value);

        # Cuadrícula horizontal en el lienzo de las velas
        $canvas->createLine(0, $y, $plot_width, $y, -fill => $grid_color, -dash => '.');

        # Los números se envían exclusivamente al lienzo lateral (si existe)
        if ($axis_canvas) {
            $axis_canvas->createText(
                37, $y, # 37 = Centro del canvas lateral de 75px
                -text => $fmt_value,
                -fill => $text_color,
                -font => ['Helvetica', 9]
            );
        }
    }
}
1;