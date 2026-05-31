package Market::Panels::PricePanel;

use strict;
use warnings;
use Market::Panels::Scales;

sub new {
    my ($class, %args) = @_;
    my $self = {
        canvas => $args{canvas},
        engine => $args{engine},
        scale  => undef,
    };
    die "[ERROR PricePanel]: Objeto Canvas de Tk no recibido.\n" unless $self->{canvas};
    $self->{canvas}->configure(-bg => '#131722');
    $self->{canvas}->pack(-side => 'top', -fill => 'both', -expand => 1);
    return bless $self, $class;
}

sub get_y_range {
    my ($self) = @_;
    if (defined $self->{engine}->{auto_scale} && $self->{engine}->{auto_scale} == 0) {
        return ($self->{engine}->{manual_y_min}, $self->{engine}->{manual_y_max});
    }

    my ($start, $end) = $self->{engine}->compute_window();
    my $candles = $self->{engine}->{market_data}->get_data();
    return (0, 100) if !defined $candles || scalar @$candles == 0;

    my $min_y = undef;
    my $max_y = undef;

    for my $i ($start .. $end) {
        my $candle = $candles->[$i];
        next unless defined $candle && defined $candle->{low} && $candle->{low} =~ /^[\d\.]+$/;
        $min_y = $candle->{low}  if !defined $min_y || $candle->{low}  < $min_y;
        $max_y = $candle->{high} if !defined $max_y || $candle->{high} > $max_y;
    }

    return (0, 100) if !defined $min_y;

    if ($max_y == $min_y) { $max_y += 1.0; $min_y -= 1.0; }

    my $padding = ($max_y - $min_y) * 0.05;
    $max_y += $padding;
    $min_y -= $padding;

    $self->{engine}->{manual_y_min} = $min_y;
    $self->{engine}->{manual_y_max} = $max_y;

    return ($min_y, $max_y);
}

sub set_scale {
    my ($self) = @_;
    my ($min_y, $max_y) = $self->get_y_range();
    my $width  = $self->{canvas}->Width();
    my $height = $self->{canvas}->Height();
    my ($start_index, $end_index) = $self->{engine}->compute_window();
    my $visible_bars = $self->{engine}->{visible_bars} || 100;
    my $scale_offset = $end_index - $visible_bars + 1;

    $self->{scale} = Market::Panels::Scales->new(
        width        => $width,
        height       => $height,
        visible_bars => $visible_bars,
        offset       => $scale_offset, 
        y_min        => $min_y,
        y_max        => $max_y,
        # Como los ejes son paneles independientes, anulamos los márgenes internos
        margin_right  => 0,  
        margin_bottom => 15, # <-- CAMBIAR DE 0 a 15 (Respiro inferior para el texto)
        margin_left   => 0,
        margin_top    => 15  # <-- CAMBIAR DE 10 a 15 (Respiro superior para el texto)
    );
    return $self->{scale};
}

sub render {
    my ($self, $data_slice) = @_;
    return unless $data_slice && scalar(@$data_slice) > 0;

    my $scale = $self->set_scale();
    
    # Pasamos el canvas secundario para que pinte ahí los números
    $scale->_draw_y_scale($self->{canvas}, $self->{engine}->{price_axis_canvas});

    my $canvas_width = $self->{canvas}->Width();
    my $visible_bars = $self->{engine}->{visible_bars} || 100;
    
    # El área de dibujo ahora es el 100% del canvas
    my $plot_width = $canvas_width; 
    my $candle_width = ($plot_width / $visible_bars) * 0.8;
    $candle_width = 1 if $candle_width < 1;

    my ($start_index, $end_index) = $self->{engine}->compute_window();
    my $i = $start_index;

    for my $candle (@$data_slice) {
        last if $i > $end_index; 
        my $x_center = $scale->index_to_center_x($i);
        my $y_open  = $scale->value_to_y($candle->{open});
        my $y_high  = $scale->value_to_y($candle->{high});
        my $y_low   = $scale->value_to_y($candle->{low});
        my $y_close = $scale->value_to_y($candle->{close});

        my $color = ($candle->{close} >= $candle->{open}) ? '#26a69a' : '#ef5350';

        $self->{canvas}->createLine($x_center, $y_high, $x_center, $y_low, -fill => $color, -width => 1);

        my $x1 = $x_center - ($candle_width / 2);
        my $x2 = $x_center + ($candle_width / 2);
        my $y_top = $y_open < $y_close ? $y_open : $y_close;
        my $y_bot = $y_open > $y_close ? $y_open : $y_close;

        $self->{canvas}->createRectangle($x1, $y_top, $x2, $y_bot, -fill => $color, -outline => $color);
        $i++;
    }
    
    $self->draw_time_axis();
    $self->_init_crosshair_objects();
    $self->render_last_visible_price($data_slice, $scale);
}

sub _init_crosshair_objects {
    my ($self) = @_;
    my $crosshair_color = '#555555'; 
    my $label_bg_color  = '#659c39'; 
    my $label_txt_color = '#ffffff'; 

    # Referencias a los paneles periféricos
    my $time_cv = $self->{engine}->{time_canvas};
    my $axis_cv = $self->{engine}->{price_axis_canvas};

    # Líneas guía en el canvas principal
    $self->{crosshair_v_id} = $self->{canvas}->createLine(0, 0, 0, 0, -fill => $crosshair_color, -dash => '.');
    $self->{crosshair_h_id} = $self->{canvas}->createLine(0, 0, 0, 0, -fill => $crosshair_color, -dash => '.');

    # Etiqueta X (Tiempo) renderizada en el canvas de tiempo inferior
    if ($time_cv) {
        $self->{crosshair_x_bg} = $time_cv->createRectangle(0, 0, 0, 0, -fill => $label_bg_color, -outline => $label_bg_color, -state => 'hidden');
        $self->{crosshair_x_txt} = $time_cv->createText(0, 0, -fill => $label_txt_color, -font => ['Helvetica', 10, 'bold'], -state => 'hidden');
    }

    # Etiqueta Y (Precio) renderizada en el canvas del eje derecho
    if ($axis_cv) {
        $self->{crosshair_y_bg} = $axis_cv->createRectangle(0, 0, 0, 0, -fill => $label_bg_color, -outline => $label_bg_color, -state => 'hidden');
        $self->{crosshair_y_txt} = $axis_cv->createText(0, 0, -fill => $label_txt_color, -font => ['Helvetica', 10, 'bold'], -state => 'hidden');
    }
}

sub draw_crosshair {
    my ($self, $x, $y, $is_active) = @_;

    my $canvas_height = $self->{canvas}->Height();
    my $canvas_width  = $self->{canvas}->Width();
    my $scale         = $self->{scale};
    
    my $time_cv = $self->{engine}->{time_canvas};
    my $axis_cv = $self->{engine}->{price_axis_canvas};

    return if $canvas_width <= 1 || $canvas_height <= 1 || !defined $scale;

    # --- Eje X (Tiempo) ---
    if (defined $self->{crosshair_v_id} && $time_cv) {
        $self->{canvas}->coords($self->{crosshair_v_id}, $x, 0, $x, $canvas_height);
        
        my $indice_global = $scale->x_to_index($x);
        my $velas = $self->{engine}->{market_data}->get_data();

        if (defined $indice_global && $indice_global >= 0 && $indice_global < scalar(@$velas)) {
            my $ts = $velas->[$indice_global]->{time} || "";
            my $etiqueta_tiempo = $ts; 
            if (my ($anio, $mes, $dia, $hora) = $ts =~ /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}:\d{2})/) {
                my @nombres_meses = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
                $etiqueta_tiempo = "$dia " . $nombres_meses[$mes - 1] . " $anio $hora";
            }

            # Posicionamos en el medio del canvas temporal (12px)
            $time_cv->coords($self->{crosshair_x_txt}, $x, 12);
            $time_cv->itemconfigure($self->{crosshair_x_txt}, -text => $etiqueta_tiempo, -state => 'normal');

            my @bbox = $time_cv->bbox($self->{crosshair_x_txt});
            if (@bbox) {
                $time_cv->coords($self->{crosshair_x_bg}, $bbox[0]-6, $bbox[1]-2, $bbox[2]+6, $bbox[3]+2);
                $time_cv->itemconfigure($self->{crosshair_x_bg}, -state => 'normal');
                $time_cv->raise($self->{crosshair_x_bg});
                $time_cv->raise($self->{crosshair_x_txt});
            }
        } else {
            $time_cv->itemconfigure($self->{crosshair_x_bg}, -state => 'hidden');
            $time_cv->itemconfigure($self->{crosshair_x_txt}, -state => 'hidden');
        }
    }

    # --- Eje Y (Precio) ---
    if (defined $self->{crosshair_h_id} && $axis_cv) {
        if ($is_active) {
            $self->{canvas}->coords($self->{crosshair_h_id}, 0, $y, $canvas_width, $y);
            
            my $valor_y = $scale->y_to_value($y);
            my $valor_fmt = sprintf("%.2f", $valor_y);

            # Centrado fijo en el eje lateral (37px)
            $axis_cv->coords($self->{crosshair_y_txt}, 37, $y);
            $axis_cv->itemconfigure($self->{crosshair_y_txt}, -text => $valor_fmt, -state => 'normal');

            my @bbox_y = $axis_cv->bbox($self->{crosshair_y_txt});
            if (@bbox_y) {
                $axis_cv->coords($self->{crosshair_y_bg}, $bbox_y[0]-6, $bbox_y[1]-2, $bbox_y[2]+6, $bbox_y[3]+2);
                $axis_cv->itemconfigure($self->{crosshair_y_bg}, -state => 'normal');
                $axis_cv->raise($self->{crosshair_y_bg});
                $axis_cv->raise($self->{crosshair_y_txt});
            }
        } else {
            $self->{canvas}->coords($self->{crosshair_h_id}, 0, 0, 0, 0);
            $axis_cv->itemconfigure($self->{crosshair_y_bg}, -state => 'hidden');
            $axis_cv->itemconfigure($self->{crosshair_y_txt}, -state => 'hidden');
        }
    }
}

sub draw_time_axis {
    my ($self) = @_;
    my $etiquetas = $self->{engine}->compute_intraday_labels();
    return unless $etiquetas && scalar(@$etiquetas) > 0;

    # Recuperar el lienzo exclusivo para el tiempo
    my $time_cv = $self->{engine}->{time_canvas};
    return unless $time_cv;

    my $scale = $self->{scale};
    my ($start_index, $end_index) = $self->{engine}->compute_window();

    for my $etiqueta (@$etiquetas) {
        my $pos_relativa = $etiqueta->{indice_relativo} // 0;
        my $absolute_index = $start_index + $pos_relativa;
        my $x = $scale->index_to_center_x($absolute_index);
        
        my $texto = $etiqueta->{timestamp};
        my ($hora) = $texto =~ /T(\d{2}:\d{2})/;
        $hora //= $texto; 

        my $color_texto = '#787b86';
        my $font_weight = 'normal';
        
        if ($etiqueta->{es_cambio_dia}) {
            $color_texto = '#d1d4dc';
            $font_weight = 'bold';
            ($hora) = $texto =~ /^(\d{4}-\d{2}-\d{2})/; 
        }
        
        # Se inyecta en la mitad del canvas temporal
        $time_cv->createText(
            $x, 12,
            -text => $hora,
            -fill => $color_texto,
            -font => ['Helvetica', 9, $font_weight]
        );
    }
}

sub render_last_visible_price {
    my ($self, $data_slice, $scale) = @_;
    my $last_candle = $data_slice->[-1];
    return unless defined $last_candle;

    my $last_close = $last_candle->{close};
    my $y = $scale->value_to_y($last_close);
    my $canvas_width = $self->{canvas}->Width();
    my $color = ($last_close >= $last_candle->{open}) ? '#26a69a' : '#ef5350';

    # 1. Línea indicadora cruza todo el canvas principal
    $self->{canvas}->createLine(
        0, $y, $canvas_width, $y,
        -fill => $color, -dash => '.'
    );

    # 2. La etiqueta viaja directo al canvas del eje
    my $axis_cv = $self->{engine}->{price_axis_canvas};
    if ($axis_cv) {
        my $valor_fmt = sprintf("%.2f", $last_close);
        my $txt_id = $axis_cv->createText(
            37, $y,
            -text => $valor_fmt,
            -fill => '#ffffff',
            -font => ['Helvetica', 10, 'bold']
        );

        my @bbox = $axis_cv->bbox($txt_id);
        if (@bbox) {
            my $bg_id = $axis_cv->createRectangle(
                $bbox[0]-6, $bbox[1]-2, $bbox[2]+6, $bbox[3]+2,
                -fill    => $color,
                -outline => $color
            );
            $axis_cv->lower($bg_id, $txt_id);
        }
    }
}
1;