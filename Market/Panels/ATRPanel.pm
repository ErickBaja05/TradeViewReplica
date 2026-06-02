package Market::Panels::ATRPanel;

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
    die "[ERROR ATRPanel]: Objeto Canvas de Tk no recibido.\n" unless $self->{canvas};
    $self->{canvas}->configure(-bg => '#131722');
    $self->{canvas}->pack(-side => 'bottom', -fill => 'both', -expand => 0);
    return bless $self, $class;
}

sub round {
    my ($self, $value) = @_;
    return int($value + 0.5 * ($value <=> 0));
}

sub get_y_range {
    my ($self) = @_;
    my ($start, $end) = $self->{engine}->compute_window();
    my $atr_values = [];
    if (defined $self->{engine}->{indicator_manager}) {
        my $atr_indicator = $self->{engine}->{indicator_manager}->get('ATR');
        if (defined $atr_indicator) {
            if (ref($atr_indicator) eq 'ARRAY') {
                $atr_values = $atr_indicator;
            } elsif (ref($atr_indicator) eq 'HASH') {
                $atr_values = $atr_indicator->{values} || [];
            }
        }
    }
    
    $atr_values //= [];
    return (0.0, 10.0) if scalar @$atr_values == 0;

    my $min_y = defined $atr_values->[$start] ? $atr_values->[$start] : 0.0;
    my $max_y = defined $atr_values->[$start] ? $atr_values->[$start] : 1.0;

    for my $i ($start .. $end) {
        my $val = $atr_values->[$i];
        if (defined $val) {
            $min_y = $val if $val < $min_y;
            $max_y = $val if $val > $max_y;
        }
    }

    $min_y = 0.0 if $min_y < 0.0;
    $max_y += 1.0 if ($max_y == $min_y);

    my $padding = ($max_y - $min_y) * 0.05;
    $max_y += $padding;
    $min_y = ($min_y - $padding < 0) ? 0.0 : ($min_y - $padding);

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
        height       => $height / 2,
        visible_bars => $visible_bars,
        offset       => $scale_offset, 
        y_min        => $min_y,
        y_max        => $max_y,
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
    
    # Renderizamos los números del grid en su propio eje dedicado
    $scale->_draw_y_scale($self->{canvas}, $self->{engine}->{atr_axis_canvas});

    my $atr_values = [];
    if (defined $self->{engine}->{indicator_manager}) {
        my $atr_indicator = $self->{engine}->{indicator_manager}->get('ATR');
        if (defined $atr_indicator) {
            if (ref($atr_indicator) eq 'ARRAY') { $atr_values = $atr_indicator; }
            elsif (ref($atr_indicator) eq 'HASH') { $atr_values = $atr_indicator->{values} || []; }
        }
    }
    $atr_values //= [];

    my ($start_index, $end_index) = $self->{engine}->compute_window();
    my $i = $start_index;
    my ($last_x, $last_y);

    for my $candle (@$data_slice) {
        last if $i > $end_index;
        my $atr_val = $atr_values->[$i];
        if (defined $atr_val) {
            my $x_current = $scale->index_to_center_x($i);
            my $y_current = $scale->value_to_y($atr_val);

            if (defined $last_x && defined $last_y) {
                $self->{canvas}->createLine($last_x, $last_y, $x_current, $y_current, -fill => '#2196f3', -width => 2);
            }
            $last_x = $x_current;
            $last_y = $y_current;
        }
        $i++;
    }

    $self->init_crosshair();
    $self->render_last_visible_value($data_slice, $scale, $atr_values);
}

sub init_crosshair {
    my ($self) = @_;
    my $crosshair_color = '#555555';

    $self->{crosshair_v_id} = $self->{canvas}->createLine(0, 0, 0, 0, -fill => $crosshair_color, -dash => '.');
    $self->{crosshair_h_id} = $self->{canvas}->createLine(0, 0, 0, 0, -fill => $crosshair_color, -dash => '.');
}

sub draw_crosshair {
    my ($self, $x, $y, $is_active) = @_;
    my $canvas_height = $self->{canvas}->Height();
    my $canvas_width  = $self->{canvas}->Width();

    return if $canvas_width <= 1 || $canvas_height <= 1;

    if (defined $self->{crosshair_v_id}) {
        $self->{canvas}->coords($self->{crosshair_v_id}, $x, 0, $x, $canvas_height);
    }
    if (defined $self->{crosshair_h_id}) {
        if ($is_active) { $self->{canvas}->coords($self->{crosshair_h_id}, 0, $y, $canvas_width, $y); } 
        else { $self->{canvas}->coords($self->{crosshair_h_id}, 0, 0, 0, 0); }
    }
}

sub render_last_visible_value {
    my ($self, $data_slice, $scale, $atr_values) = @_;

    my ($start_index, $end_index) = $self->{engine}->compute_window();
    my $last_atr_val = $atr_values->[$end_index];
    return unless defined $last_atr_val;

    my $y = $scale->value_to_y($last_atr_val);
    my $canvas_width = $self->{canvas}->Width();
    my $color = '#2196f3'; 

    # La línea guía viaja en el main canvas
    $self->{canvas}->createLine(0, $y, $canvas_width, $y, -fill => $color, -dash => '.');

    # Etiqueta en el canvas del eje lateral exclusivo
    my $axis_cv = $self->{engine}->{atr_axis_canvas};
    if ($axis_cv) {
        my $valor_fmt = sprintf("%.4f", $last_atr_val); 
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