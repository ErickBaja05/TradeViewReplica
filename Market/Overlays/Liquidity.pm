package Market::Overlays::Liquidity;
use strict;
use warnings;
use parent 'Market::Overlays::Base';

sub new {
    my ($class, %args) = @_;

    my $self = $class->SUPER::new(%args);

    # Colores visuales para los niveles de liquidez
    $self->{bsl_color}   = '#ef5350';
    $self->{ssl_color}   = '#26a69a';
    $self->{sweep_color} = '#ff9800';
    $self->{grab_color}  = '#ff9800';
    $self->{run_color}   = '#2962ff';

    # Líneas un poco más finas visualmente, parecidas a LuxAlgo
    $self->{dash_style}  = [5, 5];

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

1;  