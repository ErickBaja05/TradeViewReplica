package Market::Overlays::SMC_Structures;
use strict;
use warnings;
use parent 'Market::Overlays::Base';

sub new {
    my ($class, %args) = @_;

    # 1. Llamamos al constructor de la clase padre (Base.pm)
    my $self = $class->SUPER::new(%args);

    # 2. Referencia directa al indicador SMC
    # Esto evita depender de IndicatorManager->get(), porque SMC usa getters propios.
    $self->{smc_indicator} = $args{smc_indicator};

    # 3. Propiedades visuales específicas
    $self->{fvg_max_lifetime} = $args{fvg_max_lifetime} || 50;

    $self->{bg_color}   = [251, 252, 248]; # Fondo del Canvas: #fbfcf8
    $self->{bull_color} = [38, 166, 154];  # Verde institucional
    $self->{bear_color} = [239, 83, 80];   # Rojo institucional

    $self->{bos_color}       = '#131722';
    $self->{choch_color}     = '#8e24aa';
    $self->{bull_text_color} = '#00897b';
    $self->{bear_text_color} = '#d32f2f';

    $self->{label_bg_color}  = '#fbfcf8';
    $self->{show_fvg}        = exists $args{show_fvg}        ? $args{show_fvg}        : 1;
    $self->{show_structure}  = exists $args{show_structure}  ? $args{show_structure}  : 1;
    $self->{show_swings}     = exists $args{show_swings}     ? $args{show_swings}     : 1;

    # Evita saturar demasiado el gráfico
    $self->{max_swing_labels} = $args{max_swing_labels} || 30;

    return $self;
}

sub render {
    my ($self, $start_index, $end_index, $scale) = @_;

    my $canvas = $self->{canvas};
    return unless $canvas;
    return unless $scale;

    $canvas->delete('smc_layer');

    my $indicator = $self->_get_smc_indicator();
    return unless $indicator;

    # Dibujar primero las zonas FVG para que queden como fondo.
    $self->_render_fvg($indicator, $start_index, $end_index, $scale)
        if $self->{show_fvg};

    # Dibujar BOS / CHOCH encima de FVG.
    $self->_render_structure($indicator, $start_index, $end_index, $scale)
        if $self->{show_structure};

    # Dibujar HH / HL / LH / LL como etiquetas pequeñas.
    $self->_render_swing_labels($indicator, $start_index, $end_index, $scale)
        if $self->{show_swings};
}

# ==========================================================
# Obtener instancia real del indicador SMC
# ==========================================================
sub _get_smc_indicator {
    my ($self) = @_;

    # Opción recomendada: pasar smc_indicator directamente al crear el overlay.
    return $self->{smc_indicator} if $self->{smc_indicator};

    # Opción alternativa: si luego guardan el objeto en el ChartEngine.
    if ($self->{engine} && $self->{engine}->{smc_indicator}) {
        return $self->{engine}->{smc_indicator};
    }

    # Opción alternativa: si luego agregan get_indicator_object() al IndicatorManager.
    if (
        $self->{engine}
        && $self->{engine}->{indicator_manager}
        && $self->{engine}->{indicator_manager}->can('get_indicator_object')
    ) {
        return $self->{engine}->{indicator_manager}->get_indicator_object('SMC_Structures');
    }

    return undef;
}

# ==========================================================
# 1. FVG
# ==========================================================
sub _render_fvg {
    my ($self, $indicator, $start_index, $end_index, $scale) = @_;

    return unless $indicator->can('get_fvg');

    my $canvas = $self->{canvas};
    my $fvgs = $indicator->get_fvg();
    return unless $fvgs && ref($fvgs) eq 'ARRAY';

    foreach my $fvg (@$fvgs) {
        next unless $fvg && ref($fvg) eq 'HASH';

        my $created_index = $fvg->{created_index};
        my $top           = $fvg->{top};
        my $bottom        = $fvg->{bottom};
        my $type          = $fvg->{type} || '';

        next unless defined $created_index;
        next unless defined $top;
        next unless defined $bottom;

        # No mostrar FVG que aún no existen en replay.
        next if $created_index > $end_index;

        my $age = $end_index - $created_index;
        next if $age >= $self->{fvg_max_lifetime};

        my $end_fvg_index = $end_index;

        if (
            defined $fvg->{state}
            && $fvg->{state} eq 'MITIGATED'
            && defined $fvg->{mitigated_index}
            && $fvg->{mitigated_index} <= $end_index
        ) {
            $end_fvg_index = $fvg->{mitigated_index};
        }

        # No dibujar si ya quedó completamente antes de la ventana visible.
        next if $end_fvg_index < $start_index;

        my $x1 = $scale->index_to_center_x($created_index);
        my $x2 = $scale->index_to_center_x($end_fvg_index);

        my $y_top    = $scale->value_to_y($top);
        my $y_bottom = $scale->value_to_y($bottom);

        # En Tk, Y crece hacia abajo, así que ordenamos coordenadas.
        my $y1 = $y_top < $y_bottom ? $y_top : $y_bottom;
        my $y2 = $y_top > $y_bottom ? $y_top : $y_bottom;

        my $base_rgb = $type eq 'BULLISH'
            ? $self->{bull_color}
            : $self->{bear_color};

        my $ratio = $age / $self->{fvg_max_lifetime};
        $ratio = 1 if $ratio > 1;

        my $r = int($base_rgb->[0] + ($self->{bg_color}->[0] - $base_rgb->[0]) * $ratio);
        my $g = int($base_rgb->[1] + ($self->{bg_color}->[1] - $base_rgb->[1]) * $ratio);
        my $b = int($base_rgb->[2] + ($self->{bg_color}->[2] - $base_rgb->[2]) * $ratio);

        my $fade_color = sprintf("#%02x%02x%02x", $r, $g, $b);

        $canvas->createRectangle(
            $x1, $y1,
            $x2, $y2,
            -fill    => $fade_color,
            -outline => $fade_color,
            -stipple => 'gray25',
            -tags    => ['smc_layer', 'smc_fvg']
        );

        # Etiqueta pequeña del FVG solo cerca del inicio.
        my $label = $type eq 'BULLISH' ? 'FVG+' : 'FVG-';

        $canvas->createText(
            $x1 + 4,
            $y1 + 9,
            -text   => $label,
            -fill   => $type eq 'BULLISH' ? $self->{bull_text_color} : $self->{bear_text_color},
            -font   => ['Helvetica', 6, 'bold'],
            -anchor => 'w',
            -tags   => ['smc_layer', 'smc_fvg_label']
        );
    }
}

# ==========================================================
# 2. BOS / CHOCH
# ==========================================================
sub _render_structure {
    my ($self, $indicator, $start_index, $end_index, $scale) = @_;

    my $canvas = $self->{canvas};

    my $bos_list   = $indicator->can('get_bos')   ? $indicator->get_bos()   : [];
    my $choch_list = $indicator->can('get_choch') ? $indicator->get_choch() : [];

    $bos_list   = [] unless $bos_list   && ref($bos_list)   eq 'ARRAY';
    $choch_list = [] unless $choch_list && ref($choch_list) eq 'ARRAY';

    my @structural_events = (@$bos_list, @$choch_list);

    foreach my $struct (@structural_events) {
        next unless $struct && ref($struct) eq 'HASH';

        my $type        = $struct->{type} || '';
        my $direction   = $struct->{direction} || '';
        my $break_index = $struct->{break_index};
        my $break_price = $struct->{break_price};
        my $swing_index = $struct->{swing_index};

        next unless defined $break_index;
        next unless defined $break_price;
        next unless defined $swing_index;

        # No mostrar eventos futuros en Replay
        next if $break_index > $end_index;

        # No dibujar si queda completamente fuera de la ventana visible
        next if $break_index < $start_index && $swing_index < $start_index;

        my $x_start = $scale->index_to_center_x($swing_index);
        my $x_end   = $scale->index_to_center_x($break_index);
        my $y       = $scale->value_to_y($break_price);

        # Estilo tipo LuxAlgo:
        # verde para estructura alcista, rojo para bajista.
        my $color = '#26a69a';
        if ($direction eq 'BEARISH') {
            $color = '#ef5350';
        }

        # CHoCH un poco más visible que BOS
        my $line_width = $type eq 'CHOCH' ? 1 : 1;
        my $dash_style = [5, 5];

        $canvas->createLine(
            $x_start, $y,
            $x_end,   $y,
            -fill  => $color,
            -width => $line_width,
            -dash  => $dash_style,
            -tags  => ['smc_layer', 'smc_structure']
        );

        # Etiqueta centrada, pequeña y limpia
        my $x_center = $x_start + (($x_end - $x_start) / 2);

        my $label = $type eq 'CHOCH' ? 'CHoCH' : 'BOS';

        my $label_y = $direction eq 'BEARISH'
            ? $y + 9
            : $y - 9;

        $canvas->createText(
            $x_center,
            $label_y,
            -text   => $label,
            -fill   => $color,
            -font   => ['Helvetica', 6, 'bold'],
            -anchor => 'center',
            -tags   => ['smc_layer', 'smc_structure_label']
        );
    }
}

# ==========================================================
# 3. HH / HL / LH / LL desde swings
# ==========================================================
sub _render_swing_labels {
    my ($self, $indicator, $start_index, $end_index, $scale) = @_;

    return unless $indicator->can('get_swings');

    my $swings = $indicator->get_swings();
    return unless $swings && ref($swings) eq 'HASH';

    my $highs = $swings->{highs} || [];
    my $lows  = $swings->{lows}  || [];

    $highs = [] unless ref($highs) eq 'ARRAY';
    $lows  = [] unless ref($lows)  eq 'ARRAY';

    my $drawn = 0;

    # Swing highs: HH / LH
    my $previous_high;
    foreach my $swing (@$highs) {
        next unless $swing && ref($swing) eq 'HASH';

        my $index = $swing->{index};
        my $price = $swing->{price};

        next unless defined $index;
        next unless defined $price;
        next if $index < $start_index || $index > $end_index;

        my $label = 'SH';

        if (defined $previous_high && defined $previous_high->{price}) {
            $label = $price > $previous_high->{price} ? 'HH' : 'LH';
        }

        my $x = $scale->index_to_center_x($index);
        my $y = $scale->value_to_y($price) - 12;

        $self->_draw_label(
            x     => $x,
            y     => $y,
            text  => $label,
            color => $self->{bear_text_color},
            anchor => 'center',
            font_size => 7
        );

        $drawn++;
        last if $drawn >= $self->{max_swing_labels};

        $previous_high = $swing;
    }

    # Swing lows: HL / LL
    my $previous_low;
    foreach my $swing (@$lows) {
        next unless $swing && ref($swing) eq 'HASH';

        my $index = $swing->{index};
        my $price = $swing->{price};

        next unless defined $index;
        next unless defined $price;
        next if $index < $start_index || $index > $end_index;

        my $label = 'SL';

        if (defined $previous_low && defined $previous_low->{price}) {
            $label = $price > $previous_low->{price} ? 'HL' : 'LL';
        }

        my $x = $scale->index_to_center_x($index);
        my $y = $scale->value_to_y($price) + 12;

        $self->_draw_label(
            x     => $x,
            y     => $y,
            text  => $label,
            color => $self->{bull_text_color},
            anchor => 'center',
            font_size => 7
        );

        $drawn++;
        last if $drawn >= $self->{max_swing_labels};

        $previous_low = $swing;
    }
}

# ==========================================================
# Utilidad para etiquetas con fondo
# ==========================================================
sub _draw_label {
    my ($self, %args) = @_;

    my $canvas = $self->{canvas};

    my $x         = $args{x};
    my $y         = $args{y};
    my $text      = $args{text} || '';
    my $color     = $args{color} || '#131722';
    my $anchor    = $args{anchor} || 'center';
    my $font_size = $args{font_size} || 8;

    return unless defined $x && defined $y;
    return unless length $text;

    my $text_width = length($text) * ($font_size * 0.65);
    my $text_height = $font_size + 6;

    my ($x1, $x2);

    if ($anchor eq 'center') {
        $x1 = $x - ($text_width / 2) - 4;
        $x2 = $x + ($text_width / 2) + 4;
    }
    elsif ($anchor eq 'w') {
        $x1 = $x - 4;
        $x2 = $x + $text_width + 4;
    }
    else {
        $x1 = $x - $text_width - 4;
        $x2 = $x + 4;
    }

    my $y1 = $y - ($text_height / 2);
    my $y2 = $y + ($text_height / 2);

    $canvas->createRectangle(
        $x1, $y1,
        $x2, $y2,
        -fill    => $self->{label_bg_color},
        -outline => '',
        -stipple => 'gray50',
        -tags    => ['smc_layer', 'smc_fvg']
    );

    $canvas->createText(
        $x,
        $y,
        -text   => $text,
        -fill   => $color,
        -font   => ['Helvetica', $font_size, 'bold'],
        -anchor => $anchor,
        -tags   => ['smc_layer', 'smc_label']
    );
}

1;