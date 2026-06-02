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

sub _draw_y_scale {
    my ($self, $canvas, $axis_canvas) = @_;
    return unless $canvas;

    my $range = $self->{y_max} - $self->{y_min};
    return if $range <= 0;

    my $grid_color = '#1f2933'; 
    my $text_color = '#787b86'; 
    my $plot_width = $self->{width}; 

    # Borde separador derecho en el canvas principal
    $canvas->createLine($plot_width - 1, 0, $plot_width - 1, $self->{height}, -fill => $grid_color);

    # --- MAGIA TRADINGVIEW: CÁLCULO DINÁMICO DE EJES ---
    
    # 1. Definimos una separación cómoda a la vista (aprox. 50 píxeles entre líneas)
    my $target_pixels = 50;
    my $target_lines = $self->{height} / $target_pixels;
    $target_lines = 2 if $target_lines < 2;

    # 2. ¿Cuánto valor de mercado representa ese salto ideal?
    my $raw_step = $range / $target_lines;

    # 3. Matemáticas puras para "redondear" el salto (ej. 1, 2, 5, 10, 50, 100...) usando logaritmos
    my $log10 = log($raw_step) / log(10);
    
    # Emulación de la función matemática "floor" nativa en Perl para evitar importar módulos
    my $mag_power = $log10 < 0 ? int($log10) - 1 : int($log10); 
    $mag_power = int($log10) if $log10 == int($log10);
    
    my $mag = 10 ** $mag_power;
    my $norm_step = $raw_step / $mag;
    
    my $nice_step;
    if    ($norm_step < 1.5) { $nice_step = 1; }
    elsif ($norm_step < 3)   { $nice_step = 2; }
    elsif ($norm_step < 7)   { $nice_step = 5; }
    else                     { $nice_step = 10; }
    
    my $step = $nice_step * $mag;

    # 4. Encontrar el primer valor exacto de la grilla que aparece en pantalla
    my $first_val = int($self->{y_min} / $step) * $step;
    $first_val += $step if $first_val < $self->{y_min};

    # 5. Dibujamos iterando dinámicamente hasta salirnos por arriba de la pantalla
    for (my $value = $first_val; $value <= $self->{y_max}; $value += $step) {
        my $y = $self->value_to_y($value);
        
        # Formateo inteligente según la escala del salto para que los precios pequeños se vean bien
        my $fmt_value;
        if ($step >= 1) {
            $fmt_value = sprintf("%.2f", $value);
        } elsif ($step >= 0.01) {
            $fmt_value = sprintf("%.2f", $value);
        } else {
            $fmt_value = sprintf("%.4f", $value);
        }

        # Cuadrícula horizontal en el lienzo de las velas
        $canvas->createLine(0, $y, $plot_width, $y, -fill => $grid_color, -dash => '.');

        # Los números se envían exclusivamente al lienzo lateral que armamos (si existe)
        if ($axis_canvas) {
            $axis_canvas->createText(
                37, $y, # 37px asegura que el texto esté centrado en el panel derecho de 75px
                -text => $fmt_value,
                -fill => $text_color,
                -font => ['Helvetica', 9]
            );
        }
    }
}

1;