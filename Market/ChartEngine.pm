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

    # 1. Limpiamos todos los lienzos físicos
    $self->{price_canvas}->delete('all');
    $self->{time_canvas}->delete('all') if $self->{time_canvas};
    $self->{atr_canvas}->delete('all');
    
    # Limpiamos los ejes si existen
    $self->{price_axis_canvas}->delete('all') if exists $self->{price_axis_canvas} && $self->{price_axis_canvas};
    $self->{atr_axis_canvas}->delete('all') if exists $self->{atr_axis_canvas} && $self->{atr_axis_canvas};

    # ==========================================================
    # --- ¡EL TRUCO MAESTRO CONTRA EL DESCUADRE (SCROLL DRIFT)! ---
    # Bloqueamos el scroll nativo secreto de Tk para que las coordenadas
    # lógicas (x,y) jamás se desfasen de los píxeles de la pantalla.
    $self->{price_canvas}->xviewMoveto(0);
    $self->{price_canvas}->yviewMoveto(0);
    $self->{atr_canvas}->xviewMoveto(0);
    $self->{atr_canvas}->yviewMoveto(0);
    # ==========================================================

    # 2. Renderizamos los paneles
    $self->{price_panel}->render($data_slice) if $self->{price_panel};
    $self->{atr_panel}->render($data_slice)   if $self->{atr_panel};

    # 3. Redibujado forzado de la cruz (El arreglo del Lag que te di antes)
    if (defined $self->{crosshair_x} && defined $self->{crosshair_y}) {
        $self->draw_crosshair_all(
            $self->{crosshair_x}, 
            $self->{crosshair_y}, 
            $self->{crosshair_w}
        );
    }
}

=head2 bind_all_canvas

Conecta los eventos físicos del usuario (mouse, arrastre) y separa la lógica
de Panning (arrastrar el gráfico) y Zoom Manual (arrastrar los ejes).
=cut

sub bind_all_canvas {
    my ($self) = @_;

    my $price_cv      = $self->{price_canvas};
    my $time_cv       = $self->{time_canvas};
    my $atr_cv        = $self->{atr_canvas};
    my $price_axis_cv = $self->{price_axis_canvas}; 
    my $atr_axis_cv   = $self->{atr_axis_canvas};   

    # --- ¡MAGIA DE UX! CAMBIAR CURSORES AL PASAR EL RATÓN ---
    $price_axis_cv->configure(-cursor => 'sb_v_double_arrow') if $price_axis_cv; # Flecha vertical
    $atr_axis_cv->configure(-cursor => 'sb_v_double_arrow')   if $atr_axis_cv;   # Flecha vertical
    $time_cv->configure(-cursor => 'sb_h_double_arrow')       if $time_cv;       # Flecha horizontal
    $price_cv->configure(-cursor => 'crosshair')              if $price_cv;      # Cruz estándar
    $atr_cv->configure(-cursor => 'crosshair')                if $atr_cv;        # Cruz estándar
    # --------------------------------------------------------

    # 1. EVENTOS BÁSICOS: Redimensionar ventana y Crosshair (En TODAS las cajas)
    for my $cv (grep { defined } ($price_cv, $time_cv, $atr_cv, $price_axis_cv, $atr_axis_cv)) {
        $cv->Tk::bind('<Configure>', sub { $self->request_render(); });
        $cv->Tk::bind('<Motion>', sub { 
            my $widget = shift; my $e = $widget->XEvent; $self->on_mouse_move($e) if $e; 
        });
    }

    # ==========================================================
    # LÓGICA 1: ARRASTRE 2D (PANNING) - SOLO EN PANELES DE VELAS Y ATR
    # ==========================================================
    for my $canvas (grep { defined } ($price_cv, $atr_cv)) {
        $canvas->Tk::bind('<Button-1>', sub {
            my $widget = shift; my $e = $widget->XEvent;
            if ($e) {
                $self->{last_drag_x} = $e->x;
                $self->{last_drag_y} = $e->y;
            }
        });

        $canvas->Tk::bind('<B1-Motion>', sub {
            my $widget = shift; my $e = $widget->XEvent;
            return unless $e && defined $self->{last_drag_x} && defined $self->{last_drag_y};
            
            # Memoria del crosshair para evitar lag
            $self->{crosshair_x} = $e->x;
            $self->{crosshair_y} = $e->y;
            $self->{crosshair_w} = $widget;

            my $delta_x = $e->x - $self->{last_drag_x};
            my $delta_y = $e->y - $self->{last_drag_y};
            my $needs_render = 0;

            # A. Panning Horizontal (Viajar en el tiempo)
            if (defined $self->{price_panel} && defined $self->{price_panel}->{scale}) {
                my $plot_width = $self->{price_panel}->{scale}->{width} || 1;
                my $candle_width = ($plot_width / ($self->{visible_bars} || 1)) || 1;
                my $velas_desplazadas = int($delta_x / $candle_width);

                if ($velas_desplazadas != 0) {
                    my $total_candles = $self->{market_data} ? $self->{market_data}->size() : 0;
                    my $nuevo_offset = $self->{offset} + $velas_desplazadas;

                    if ($nuevo_offset >= 0 && $nuevo_offset < $total_candles - $self->{visible_bars}) {
                        $self->{offset} = $nuevo_offset;
                        $self->{last_drag_x} = $e->x; 
                        $needs_render = 1;
                    }
                }
            }

            # B. Panning Vertical (Mover la cámara del precio)
            if ($delta_y != 0 && $canvas == $price_cv) {

                if ($self->{auto_scale} == 0)
                {
                    my $canvas_height = $canvas->Height() || 400;
                    my $rango = $self->{manual_y_max} - $self->{manual_y_min};
                    my $desplazamiento = ($delta_y / $canvas_height) * $rango;

                    $self->{manual_y_max} += $desplazamiento;
                    $self->{manual_y_min} += $desplazamiento;
                }

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

    # ==========================================================
    # LÓGICA 2: ZOOM HORIZONTAL MANUAL EN EJE DE TIEMPO
    # ==========================================================
    if ($time_cv) {
        $time_cv->Tk::bind('<Button-1>', sub {
            my $widget = shift; my $e = $widget->XEvent;
            $self->{last_axis_x} = $e->x if $e;
        });

        $time_cv->Tk::bind('<B1-Motion>', sub {
            my $widget = shift; my $e = $widget->XEvent;
            return unless $e && defined $self->{last_axis_x};

            $self->{crosshair_x} = $e->x;
            $self->{crosshair_y} = $e->y;
            $self->{crosshair_w} = $widget;

            my $dx = $e->x - $self->{last_axis_x};
            if (abs($dx) > 0) {
                my $current_bars = $self->{visible_bars} || 100;
                
                # MATEMÁTICA DEL ZOOM X:
                # dx > 0 (arrastrar derecha) = Estirar gráfico (mostrar menos velas)
                # dx < 0 (arrastrar izquierda) = Comprimir gráfico (mostrar más velas)
                my $factor = 1 - ($dx * 0.005); 
                my $new_bars = $current_bars * $factor;
                $new_bars = 2 if $new_bars < 2; # Límite mínimo

                $self->{visible_bars} = $self->round($new_bars);
                $self->{last_axis_x} = $e->x;
                $self->request_render();
            }
        });

        $time_cv->Tk::bind('<ButtonRelease-1>', sub { $self->{last_axis_x} = undef; });
    }

    # ==========================================================
    # LÓGICA 3: ZOOM VERTICAL MANUAL EN EJES Y (Precios)
    # ==========================================================
    for my $axis_cv (grep { defined } ($price_axis_cv, $atr_axis_cv)) {
        $axis_cv->Tk::bind('<Button-1>', sub {
            my $widget = shift; my $e = $widget->XEvent;
            $self->{last_axis_y} = $e->y if $e;
            
            # Pasar a modo manual capturando la escala actual del precio
            if ($axis_cv == $price_axis_cv && $self->{auto_scale}) {
                if ($self->{price_panel}) {
                    my ($min, $max) = $self->{price_panel}->get_y_range();
                    $self->{manual_y_min} = $min;
                    $self->{manual_y_max} = $max;
                }
            }
        });
        
        $axis_cv->Tk::bind('<B1-Motion>', sub {
            my $widget = shift; my $e = $widget->XEvent;
            return unless $e && defined $self->{last_axis_y};

            $self->{crosshair_x} = $e->x;
            $self->{crosshair_y} = $e->y;
            $self->{crosshair_w} = $widget;

            my $dy = $e->y - $self->{last_axis_y};
            
            # Solo aplicamos escala manual al eje de los precios
            if (abs($dy) > 0 && $axis_cv == $price_axis_cv) {
                my $rango = $self->{manual_y_max} - $self->{manual_y_min};
                
                # MATEMÁTICA DEL ZOOM Y (ESTIRAR / APLASTAR):
                # dy > 0 (arrastrar abajo) = Comprimir velas (Aumentar rango numérico)
                # dy < 0 (arrastrar arriba) = Estirar velas (Disminuir rango numérico)
                my $factor = 1 + ($dy * 0.005);
                $factor = 0.01 if $factor < 0.01; # Blindaje matemático
                
                my $centro = ($self->{manual_y_max} + $self->{manual_y_min}) / 2;
                my $nuevo_rango = $rango * $factor;
                
                # Expandir o contraer desde el centro visual exacto
                $self->{manual_y_max} = $centro + ($nuevo_rango / 2);
                $self->{manual_y_min} = $centro - ($nuevo_rango / 2);
                
                $self->{last_axis_y} = $e->y;
                $self->request_render();
            }
        });

        $axis_cv->Tk::bind('<ButtonRelease-1>', sub { $self->{last_axis_y} = undef; });
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

    # 1. MEMORIA: Guardamos las coordenadas exactas todo el tiempo
    $self->{crosshair_x} = $event->x;
    $self->{crosshair_y} = $event->y;
    $self->{crosshair_w} = $event->W; # Guardamos en qué caja está el ratón

    my $x = $event->x;

    # 2. Dibujamos la cruz
    $self->draw_crosshair_all($event->x, $event->y, $event->W);
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
    $new_bars = 5 if $new_bars < 5;

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
    $self->set_auto_scale(1);

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

=head2 set_auto_scale
Cambia el modo de escala y sincroniza visualmente el botón de la interfaz.
=cut

sub set_auto_scale {
    my ($self, $mode) = @_;
    
    $self->{auto_scale} = $mode;

    # Buscamos si nos pasaste el botón desde market.pl y lo actualizamos
    if (my $btn = $self->{widgets}->{scale_btn}) {
        $btn->configure(
            -text => $mode ? "Escala: Auto" : "Escala: Manual",
            -fg   => $mode ? '#3bb3e4' : '#ff9800'
        );
    }
}

1;