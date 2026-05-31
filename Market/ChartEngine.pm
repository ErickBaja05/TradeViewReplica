package Market::ChartEngine;

use strict;
use warnings;

use Market::Panels::PricePanel;
use Market::Panels::ATRPanel;

=head1 NOMBRE
Market::ChartEngine - Motor gráfico central y orquestador de la interfaz.
=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        # Referencias de los Canvas Principales de Renderizado
        market_data       => $args{market_data},
        indicator_manager => $args{indicator_manager},
        price_canvas      => $args{price_canvas},
        atr_canvas        => $args{atr_canvas},
        widgets           => $args{widgets} || {},

        # NUEVO: Referencias a los Canvas dedicados exclusivamente a los ejes
        price_axis_canvas => $args{price_axis_canvas},
        time_canvas       => $args{time_canvas},
        atr_axis_canvas   => $args{atr_axis_canvas},

        # Estado interno de control visual
        visible_bars      => $args{visible_bars} || 100, 
        offset            => $args{offset} || 0,         
        crosshair         => { x => -1, y => -1 },       
        render_pending    => 0,                          

        # Contenedores para las instancias de los paneles independientes
        price_panel       => undef,
        atr_panel         => undef,

        # Estado de Escalas
        auto_scale        => 1,      
        manual_y_max      => 100,    
        manual_y_min      => 0,      
    };

    bless $self, $class;

    # Instanciación de los paneles correspondientes pasándoles su respectivo canvas principal
    $self->{price_panel} = Market::Panels::PricePanel->new(
        canvas => $self->{price_canvas},
        engine => $self
    );

    $self->{atr_panel} = Market::Panels::ATRPanel->new(
        canvas => $self->{atr_canvas},
        engine => $self
    );

    return $self;
}

sub round {
    my ($self, $value) = @_;
    return int($value + 0.5 * ($value <=> 0));
}

sub compute_window {
    my ($self) = @_;
    my $market_data = $self->{market_data};
    my $total_candles = $market_data->size() || 0;

    return (0, 0) if $total_candles == 0;

    my $end_index = $total_candles - 1 - $self->{offset};
    my $start_index = $end_index - $self->{visible_bars} + 1;

    $start_index = 0 if $start_index < 0;
    $end_index = 0 if $end_index < 0;

    if ($end_index >= $total_candles) {
        $end_index = $total_candles - 1;
        $start_index = $end_index - $self->{visible_bars} + 1;
        $start_index = 0 if $start_index < 0;
    }

    return ($start_index, $end_index);
}

sub request_render {
    my ($self) = @_;
    return if $self->{render_pending};
    $self->{render_pending} = 1;

    if (my $mw = $self->{widgets}->{main_window}) {
        $mw->afterIdle(sub {
            $self->{render_pending} = 0;
            $self->render();
        });
    }
}

sub render {
    my ($self) = @_;

    my ($start, $end) = $self->compute_window();
    my $data_slice = $self->{market_data}->get_slice($start, $end);

    return unless $data_slice && scalar(@$data_slice) > 0;

    # Limpieza total de los 5 Canvas independientes antes de refrescar el frame visual
    $self->{price_canvas}->delete('all');
    $self->{price_axis_canvas}->delete('all') if $self->{price_axis_canvas};
    $self->{time_canvas}->delete('all')       if $self->{time_canvas};
    $self->{atr_canvas}->delete('all');
    $self->{atr_axis_canvas}->delete('all')   if $self->{atr_axis_canvas};

    # Orquestación del dibujo delegando los datos procesados a cada panel
    $self->{price_panel}->render($data_slice) if $self->{price_panel};
    $self->{atr_panel}->render($data_slice)   if $self->{atr_panel};
}

sub bind_all_canvas {
    my ($self) = @_;

    my $price_cv = $self->{price_canvas};
    my $atr_cv   = $self->{atr_canvas};

    # 1. Evento <Configure>: Ajuste elástico sincronizado para todos los Canvas al redimensionar la ventana
    for my $cv ($price_cv, $self->{price_axis_canvas}, $self->{time_canvas}, $atr_cv, $self->{atr_axis_canvas}) {
        next unless $cv;
        $cv->Tk::bind('<Configure>', sub { $self->request_render(); });
    }

    # 2. Evento <Motion>: Seguimiento del cursor para el Crosshair unificado
    $price_cv->Tk::bind('<Motion>', sub { 
        my $widget = shift; my $e = $widget->XEvent; $self->on_mouse_move($e) if $e; 
    });
    $atr_cv->Tk::bind('<Motion>', sub { 
        my $widget = shift; my $e = $widget->XEvent; $self->on_mouse_move($e) if $e; 
    });

    # 3. Lógica de Arrastre Horizontal y Vertical unificado por Canvas principal
    for my $canvas ($price_cv, $atr_cv) {
        
        $canvas->Tk::bind('<Button-1>', sub {
            my $widget = shift;
            my $e = $widget->XEvent;
            if ($e) {
                $self->{last_drag_x} = $e->x;
                $self->{last_drag_y} = $e->y; 
            }
        });

        $canvas->Tk::bind('<B1-Motion>', sub {
            my $widget = shift;
            my $e = $widget->XEvent;
            
            return unless $e && defined $self->{last_drag_x} && defined $self->{last_drag_y};
            return unless defined $self->{price_panel} && defined $self->{price_panel}->{scale};

            my $delta_x = $e->x - $self->{last_drag_x};
            my $delta_y = $e->y - $self->{last_drag_y}; 
            my $needs_render = 0;

            # --- A. ARRASTRE HORIZONTAL (TIEMPO) ---
            my $scale = $self->{price_panel}->{scale};
            my $plot_width = $scale->{width} - $scale->{margin_left} - $scale->{margin_right};
            my $candle_width = ($plot_width / $self->{visible_bars}) || 1;
            my $velas_desplazadas = int($delta_x / $candle_width);

            if ($velas_desplazadas != 0) {
                my $market_data = $self->{market_data};
                my $total_candles = $market_data ? $market_data->size() : 0;
                my $nuevo_offset = $self->{offset} + $velas_desplazadas;

                if ($nuevo_offset >= 0 && $nuevo_offset < $total_candles - $self->{visible_bars}) {
                    $self->{offset} = $nuevo_offset;
                    $self->{last_drag_x} = $e->x; 
                    $needs_render = 1;
                }
            }

            # --- B. ARRASTRE VERTICAL (PRECIO) ---
            if ($delta_y != 0 && $canvas == $price_cv) {
                $self->{auto_scale} = 0; # Rompe escala automática al arrastrar verticalmente

                my $canvas_height = $canvas->Height() || 400;
                my $rango = $self->{manual_y_max} - $self->{manual_y_min};
                my $desplazamiento_precio = ($delta_y / $canvas_height) * $rango;

                $self->{manual_y_max} += $desplazamiento_precio;
                $self->{manual_y_min} += $desplazamiento_precio;

                $self->{last_drag_y} = $e->y; 
                $needs_render = 1;
            }

            $self->request_render() if $needs_render;
        });
        
        $canvas->Tk::bind('<ButtonRelease-1>', sub {
            $self->{last_drag_x} = undef;
            $self->{last_drag_y} = undef;
        });
    }
}

sub bind_events {
    my ($self) = @_;
    my $mw = $self->{widgets}->{main_window};
    return unless $mw;

    # Control de zoom mediante la rueda del ratón (Linux / X11 compatibility)
    $mw->Tk::bind('<Button-4>', sub { 
        my $widget = shift; my $e = $widget->XEvent;
        if ($e) {
            my $has_ctrl = ($e->s & 4) ? 1 : 0; 
            $self->horizontal_zoom(1, $e->x, $has_ctrl); 
        }
    });

    $mw->Tk::bind('<Button-5>', sub { 
        my $widget = shift; my $e = $widget->XEvent;
        if ($e) {
            my $has_ctrl = ($e->s & 4) ? 1 : 0;
            $self->horizontal_zoom(-1, $e->x, $has_ctrl); 
        }
    });

    # Control de desplazamiento fino con las flechas del teclado
    $mw->Tk::bind('<Left>', sub {
        my $market_data = $self->{market_data};
        my $total_candles = $market_data ? $market_data->size() : 0;
        if ($self->{offset} < $total_candles - $self->{visible_bars}) {
            $self->{offset}++;
            $self->request_render();
        }
    });

    $mw->Tk::bind('<Right>', sub {
        if ($self->{offset} > 0) {
            $self->{offset}--;
            $self->request_render();
        }
    });

    # Atajos de teclado nativos para restaurar la vista
    $mw->Tk::bind('<Key-r>', sub { $self->reset_view(); });
    $mw->Tk::bind('<Key-R>', sub { $self->reset_view(); });
}

sub compute_intraday_labels {
    my ($self) = @_;
    my ($start, $end) = $self->compute_window();
    my $velas = $self->{market_data}->get_data();
    my @etiquetas_visibles;

    my $visibles = $self->{visible_bars};
    my $salto = 1;
    $salto = 5  if $visibles > 30;
    $salto = 10 if $visibles > 100;
    $salto = 50 if $visibles > 500;

    my $ultimo_dia_visto = "";
    my $posicion_relativa = 0;

    for my $i ($start .. $end) {
        my $vela = $velas->[$i];
        last unless $vela;
        my $ts = $vela->{time} || "";

        my ($dia_actual) = $ts =~ /^(\d{4}-\d{2}-\d{2})/;
        $dia_actual //= "";

        my $es_cambio_dia = 0;
        if ($dia_actual ne $ultimo_dia_visto && $ultimo_dia_visto ne "") {
            $es_cambio_dia = 1;
        }
        $ultimo_dia_visto = $dia_actual if $dia_actual;

        if ($es_cambio_dia || $posicion_relativa % $salto == 0) {
            push @etiquetas_visibles, {
                indice_relativo => $posicion_relativa,
                timestamp       => $ts,
                es_cambio_dia   => $es_cambio_dia
            };
        }
        $posicion_relativa++;
    }

    return \@etiquetas_visibles;
}

sub _vertical_drag {
    my ($self, $dy) = @_;
    $self->{auto_scale} = 0;
    my $rango = $self->{manual_y_max} - $self->{manual_y_min};
    my $desplazamiento = ($dy / 400) * $rango;

    $self->{manual_y_max} += $desplazamiento;
    $self->{manual_y_min} += $desplazamiento;
    $self->request_render();
}

sub vertical_zoom {
    my ($self, $factor) = @_;
    $self->{auto_scale} = 0;
    my $rango = $self->{manual_y_max} - $self->{manual_y_min};
    my $cambio = $rango * 0.05 * $factor; 

    $self->{manual_y_max} += $cambio;
    $self->{manual_y_min} -= $cambio;
    $self->request_render();
}

sub set_timeframe {
    my ($self, $tf) = @_;
    # Conexión directa con el método de agregación temporal de la capa de datos
    $self->{market_data}->set_timeframe($tf) if $self->{market_data} && $self->{market_data}->can('set_timeframe');
    $self->reset_view(); 
}

sub on_mouse_move {
    my ($self, $event) = @_;
    return unless $event;

    my $x = $event->x;
    my $y = $event->y;
    my $active_widget = $event->W;

    $self->draw_crosshair_all($x, $y, $active_widget);
}

sub draw_crosshair_all {
    my ($self, $x, $y, $active_widget) = @_;

    if ($self->{price_panel}) {
        my $is_active = ($active_widget == $self->{price_canvas}) ? 1 : 0;
        $self->{price_panel}->draw_crosshair($x, $y, $is_active);
    }
    if ($self->{atr_panel}) {
        my $is_active = ($active_widget == $self->{atr_canvas}) ? 1 : 0;
        $self->{atr_panel}->draw_crosshair($x, $y, $is_active);
    }
}

sub horizontal_zoom {
    my ($self, $delta, $mouse_x, $has_ctrl) = @_;
    my $current_bars = $self->{visible_bars} || 100;
    
    my $zoom_factor = 0.10;
    my $bars_change = $current_bars * $zoom_factor;
    $bars_change = 1 if $bars_change < 1;
    
    my $new_bars = $current_bars + ($delta > 0 ? -$bars_change : $bars_change);
    $new_bars = 2 if $new_bars < 2;

    if ($has_ctrl && defined $mouse_x && defined $self->{price_panel}) {
        my $canvas_width = $self->{price_canvas}->Width() || 1;
        my $porcentaje_pantalla = $mouse_x / $canvas_width;
        my $barras_perdidas = $current_bars - $new_bars;
        
        $self->{offset} += ($barras_perdidas * (1 - $porcentaje_pantalla));
        $self->{offset} = 0 if $self->{offset} < 0;
    }

    $self->{visible_bars} = $self->round($new_bars);
    $self->request_render();
}

=head2 reset_view

Restaura la vista del gráfico a su estado original "por defecto" (TradingView Auto-Fit).
Limpia la memoria de arrastres y centra el panorama temporal.
=cut

sub reset_view {
    my ($self) = @_;
    
    # 1. Estándar visual: 150 velas logran la proporción exacta de TradingView 
    # para pantallas HD (puedes subirlo a 200 si quieres que se vea aún más alejado)
    $self->{visible_bars} = 150; 
    
    # 2. Restaurar scroll al presente (vuelve a pegar la última vela a la derecha)
    $self->{offset} = 0;   
    
    # 3. Reactivar el Auto-Scale (Devolverle el control a la cámara del motor)
    $self->{auto_scale} = 1; 

    # 4. BLINDAJE: Limpiar cualquier memoria manual residual 
    # para asegurar un cálculo 100% fresco en los paneles
    $self->{manual_y_max} = undef;
    $self->{manual_y_min} = undef;

    # 5. BLINDAJE: Limpiar memoria del ratón por si se quedó congelado a medio drag
    $self->{last_drag_x}  = undef;
    $self->{last_drag_y}  = undef;

    # 6. Forzar el fotograma en limpio
    $self->request_render();
}

sub get_all_timestamps {
    my ($self) = @_;
    my ($start, $end) = $self->compute_window();
    my $market_data = $self->{market_data};
    my @timestamps;

    for my $i ($start .. $end) {
        my $ts = $market_data->get_timestamp($i);
        push @timestamps, $ts if defined $ts;
    }

    return \@timestamps;
}

1;