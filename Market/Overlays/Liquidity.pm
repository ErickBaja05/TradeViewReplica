package Market::Overlays::Liquidity;
use strict;
use warnings;
use parent 'Market::Overlays::Base';

sub new {
    my ($class, %args) = @_;

    my $self = $class->SUPER::new(%args);

    # Referencia directa al indicador real de Liquidez (recomendado), para poder
    # leer get_equal_levels(). Si no se provee, se intenta resolver vía el
    # IndicatorManager del engine.
    $self->{liquidity_indicator} = $args{liquidity_indicator};

    # Colores visuales para los niveles de liquidez
    $self->{bsl_color}   = '#ef5350';
    $self->{ssl_color}   = '#26a69a';
    $self->{sweep_color} = '#ff9800';
    $self->{grab_color}  = '#ff9800';
    $self->{run_color}   = '#2962ff';

    # Colores para Equal Highs / Equal Lows (EQH / EQL), portados de Proyecto1BimIA
    $self->{eqh_color}   = '#d32f2f';
    $self->{eql_color}   = '#00796b';

    # Líneas un poco más finas visualmente, parecidas a LuxAlgo
    $self->{dash_style}     = [5, 5];
    $self->{eq_dash_style}  = [2, 3];

    # Toggles de visibilidad (activados por defecto)
    $self->{show_eqh}    = exists $args{show_eqh} ? $args{show_eqh} : 1;
    $self->{show_eql}    = exists $args{show_eql} ? $args{show_eql} : 1;

    return $self;
}

sub render {
    my ($self, $start_index, $end_index, $scale) = @_;

    my $canvas = $self->{canvas};
    return unless $canvas;
    return unless $scale;

    # Limpiar solo la capa de liquidez
    $canvas->delete('liquidity_layer');

    return unless $self->{active} // 1;

    # Validar que exista el engine y el manager
    return unless $self->{engine};
    return unless $self->{engine}->{indicator_manager};

    # IMPORTANTE:
    # IndicatorManager->get('Liquidity') ya devuelve get_values(),
    # es decir, el arreglo de eventos de Liquidity.
    my $events = $self->{engine}->{indicator_manager}->get('Liquidity');

    # Niveles de Equal Highs / Equal Lows (EQH/EQL), obtenidos directamente
    # del objeto indicador (no expuestos vía IndicatorManager->get, que solo
    # devuelve get_values() = liquidity_events).
    $self->_draw_equal_levels($start_index, $end_index, $scale);

    return unless $events && ref($events) eq 'ARRAY';

    foreach my $event (@$events) {
        next unless $event && ref($event) eq 'HASH';

        my $event_index = $event->{index};
        my $price       = $event->{price};
        my $type        = $event->{type}  || '';
        my $state       = $event->{state} || '';

        # Validaciones mínimas para evitar errores de render
        next unless defined $event_index;
        next unless defined $price;
        next unless $type eq 'BSL' || $type eq 'SSL';

        # No dibujar eventos que todavía no deberían existir en Replay
        next if $event_index > $end_index;

        # Opcional: no dibujar eventos muy antiguos fuera de la ventana visible
        # si ya fueron resueltos antes del inicio visible.
        if (defined $event->{resolved_at} && $event->{resolved_at} < $start_index) {
            next;
        }

        my $x_start = $scale->index_to_center_x($event_index);
        my $y       = $scale->value_to_y($price);

        # Si el evento ya fue resuelto, la línea termina en resolved_at.
        # Si aún está activo, se extiende hasta la última vela visible.
        my $end_draw_index = defined $event->{resolved_at}
            ? $event->{resolved_at}
            : $end_index;

        $end_draw_index = $end_index if $end_draw_index > $end_index;

        my $x_end = $scale->index_to_center_x($end_draw_index);

        # Color base según tipo de liquidez
        my $line_color = $type eq 'BSL'
            ? $self->{bsl_color}
            : $self->{ssl_color};

        # Dibujar línea BSL / SSL
        $canvas->createLine(
            $x_start, $y,
            $x_end,   $y,
            -dash => $self->{dash_style},
            -fill => $line_color,
            -width => 1,
            -tags => ['liquidity_layer']
        );

        # Etiqueta base: BSL o SSL mientras está detectado
        my $label_text = $type;

        # Etiquetas según máquina de estados de Ricardo
        if ($state eq 'SWEEP_UP' || $state eq 'SWEEP_DOWN') {
            $label_text = 'SWEEP';
        }
        elsif ($state eq 'SWEEP') {
            $label_text = 'SWEEP';
            $line_color = $self->{sweep_color};
        }
        elsif ($state eq 'GRAB') {
            $label_text = 'LQ GRAB';
            $line_color = $self->{grab_color};
        }
        elsif ($state eq 'RUN') {
            $label_text = 'LQ RUN';
            $line_color = $self->{run_color};
        }

        # Mostrar etiqueta al final de la línea
        my $label_y = $type eq 'BSL' ? $y - 10 : $y + 10;

        $canvas->createText(
            $x_end + 5,
            $label_y,
            -text   => $label_text,
            -fill   => $line_color,
            -font   => ['Helvetica', 6, 'bold'],
            -anchor => 'w',
            -tags   => ['liquidity_layer']
        );
    }
}

# ==========================================================
# Resolver la instancia real del indicador de Liquidez
# ==========================================================
sub _get_liquidity_indicator {
    my ($self) = @_;

    # Opción recomendada: inyectado directamente al crear el overlay.
    return $self->{liquidity_indicator} if $self->{liquidity_indicator};

    # Opción alternativa: resolverlo vía el IndicatorManager del ChartEngine.
    if (
        $self->{engine}
        && $self->{engine}->{indicator_manager}
        && $self->{engine}->{indicator_manager}->can('get_indicator_object')
    ) {
        return $self->{engine}->{indicator_manager}->get_indicator_object('Liquidity');
    }

    return undef;
}

# ==========================================================
# Equal Highs / Equal Lows (EQH / EQL)
# Portado de Market::Overlays::Liquidity::_draw_eqh_eql (Proyecto1BimIA),
# adaptado a la API de escala/canvas de TradeViewReplica.
# ==========================================================
sub _draw_equal_levels {
    my ($self, $start_index, $end_index, $scale) = @_;

    return unless $self->{show_eqh} || $self->{show_eql};

    my $canvas    = $self->{canvas};
    my $indicator = $self->_get_liquidity_indicator();
    return unless $indicator && $indicator->can('get_equal_levels');

    my $equal_levels = $indicator->get_equal_levels();
    return unless $equal_levels && ref($equal_levels) eq 'ARRAY';

    foreach my $eq (@$equal_levels) {
        next unless $eq && ref($eq) eq 'HASH';

        my $type = $eq->{type} || '';
        next unless $type eq 'EQH' || $type eq 'EQL';
        next if $type eq 'EQH' && !$self->{show_eqh};
        next if $type eq 'EQL' && !$self->{show_eql};

        my $index1 = $eq->{index1};
        my $index2 = $eq->{index2};
        my $price  = $eq->{price};

        next unless defined $index1 && defined $index2 && defined $price;

        # No dibujar niveles que aún no existen en el punto de Replay actual
        next if $index2 > $end_index;

        # Fuera de la ventana visible
        next if $index2 < $start_index;

        my $x1 = $scale->index_to_center_x($index1);
        my $x2 = $scale->index_to_center_x($index2);
        my $y  = $scale->value_to_y($price);

        my $color = $type eq 'EQH' ? $self->{eqh_color} : $self->{eql_color};

        $canvas->createLine(
            $x1, $y,
            $x2, $y,
            -dash  => $self->{eq_dash_style},
            -fill  => $color,
            -width => 1,
            -tags  => ['liquidity_layer']
        );

        my $label_x = ($x1 + $x2) / 2;
        my $label_y = $type eq 'EQH' ? $y - 10 : $y + 10;

        $canvas->createText(
            $label_x,
            $label_y,
            -text   => $type,
            -fill   => $color,
            -font   => ['Helvetica', 6, 'bold'],
            -anchor => 'center',
            -tags   => ['liquidity_layer']
        );
    }
}

1;  