package Market::ChartEngine;

use strict;
use warnings;

use Market::Panels::PricePanel;
use Market::Panels::ATRPanel;
use Market::Indicators::Liquidity;
use Market::Overlays::Liquidity;

=head1 NOMBRE
Market::ChartEngine - Motor gráfico central y orquestador de la interfaz.
=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        market_data       => $args{market_data},
        indicator_manager => $args{indicator_manager},
        price_canvas      => $args{price_canvas},
        atr_canvas        => $args{atr_canvas},
        widgets           => $args{widgets} || {},

        price_axis_canvas => $args{price_axis_canvas},
        time_canvas       => $args{time_canvas},
        atr_axis_canvas   => $args{atr_axis_canvas},

        visible_bars      => $args{visible_bars} || 100, 
        offset            => $args{offset} || 0,         
        crosshair         => { x => -1, y => -1 },       
        render_pending    => 0,                          

        price_panel           => undef,
        atr_panel             => undef,
        liquidity_indicator   => undef,
        liquidity_overlay     => undef,

        # Estado de Escalas PRECIO
        auto_scale        => 1,      
        manual_y_max      => 100,    
        manual_y_min      => 0,      

        # Estado de Escalas ATR (Volatilidad)
        atr_auto_scale    => 1,
        atr_manual_y_max  => 10,
        atr_manual_y_min  => 0,
    };

    bless $self, $class;

    $self->{price_panel} = Market::Panels::PricePanel->new(
        canvas => $self->{price_canvas},
        engine => $self
    );

    $self->{atr_panel} = Market::Panels::ATRPanel->new(
        canvas => $self->{atr_canvas},
        engine => $self
    );

    # Indicador de Liquidez (Swing Highs / Lows)
    # Si market.pl lo registró en indicator_manager y también lo pasó como arg,
    # usamos ese; si no, creamos uno propio.
    $self->{liquidity_indicator} = $args{liquidity_indicator}
        // Market::Indicators::Liquidity->new(k_depth => 3, atr_period => 14);

    # Visibilidad del overlay (controlada por el botón en market.pl)
    $self->{liquidity_visible} = 1;

    # Overlay de Liquidez - se inicializa diferido porque scales no existe aún;
    # se completa en render() la primera vez que el PricePanel ya tiene escala.
    $self->{liquidity_overlay} = undef;

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

    if ($end_index < 0) { $end_index = 0; }
    if ($start_index > $end_index) { $start_index = $end_index; }
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

    $self->{price_canvas}->delete('all');
    $self->{time_canvas}->delete('all') if $self->{time_canvas};
    $self->{atr_canvas}->delete('all');
    
    $self->{price_axis_canvas}->delete('all') if exists $self->{price_axis_canvas} && $self->{price_axis_canvas};
    $self->{atr_axis_canvas}->delete('all') if exists $self->{atr_axis_canvas} && $self->{atr_axis_canvas};

    # Bloqueo del scroll nativo
    $self->{price_canvas}->xviewMoveto(0);
    $self->{price_canvas}->yviewMoveto(0);
    $self->{atr_canvas}->xviewMoveto(0);
    $self->{atr_canvas}->yviewMoveto(0);
    $self->{time_canvas}->yviewMoveto(0) if $self->{time_canvas};
    
    $self->{price_panel}->render($data_slice) if $self->{price_panel};
    $self->{atr_panel}->render($data_slice)   if $self->{atr_panel};

    # --- OVERLAY DE LIQUIDEZ ---
    # El PricePanel ya construyó su escala (set_scale se llama dentro de render).
    # La primera vez creamos el overlay; en renders posteriores solo actualizamos
    # la referencia a scales (puede cambiar si el canvas se redimensiona).
    if ($self->{liquidity_visible} && $self->{price_panel} && defined $self->{price_panel}->{scale}) {
        unless (defined $self->{liquidity_overlay}) {
            $self->{liquidity_overlay} = Market::Overlays::Liquidity->new(
                canvas        => $self->{price_canvas},
                scales        => $self->{price_panel}->{scale},
                show_resolved => 1,
                line_width    => 1,
            );
        } else {
            # Actualizar la escala en cada render (puede cambiar con zoom/resize)
            $self->{liquidity_overlay}->{scales} = $self->{price_panel}->{scale};
        }

        my ($liq_start, $liq_end) = $self->compute_window();
        my $liq_zones = $self->{liquidity_indicator}->zones_in_window($liq_start, $liq_end);
        $self->{liquidity_overlay}->render($liq_zones, $liq_start, $liq_end);
    } elsif (!$self->{liquidity_visible}) {
        # Si el usuario desactivó el overlay, asegurarnos de que no queden trazos
        $self->{price_canvas}->delete('liquidity') if $self->{price_canvas};
    }

    if (defined $self->{crosshair_x} && defined $self->{crosshair_y}) {
        $self->draw_crosshair_all(
            $self->{crosshair_x}, 
            $self->{crosshair_y}, 
            $self->{crosshair_w}
        );
    }
}

sub bind_all_canvas {
    my ($self) = @_;

    my $price_cv      = $self->{price_canvas};
    my $time_cv       = $self->{time_canvas};
    my $atr_cv        = $self->{atr_canvas};
    my $price_axis_cv = $self->{price_axis_canvas}; 
    my $atr_axis_cv   = $self->{atr_axis_canvas};   

    # Cursores dinámicos
    $price_axis_cv->configure(-cursor => 'sb_v_double_arrow') if $price_axis_cv; 
    $atr_axis_cv->configure(-cursor => 'sb_v_double_arrow')   if $atr_axis_cv;   
    $time_cv->configure(-cursor => 'sb_h_double_arrow')       if $time_cv;       
    $price_cv->configure(-cursor => 'crosshair')              if $price_cv;      
    $atr_cv->configure(-cursor => 'crosshair')                if $atr_cv;        

    for my $cv (grep { defined } ($price_cv, $time_cv, $atr_cv, $price_axis_cv, $atr_axis_cv)) {
        $cv->Tk::bind('<Configure>', sub { $self->request_render(); });
        $cv->Tk::bind('<Motion>', sub { 
            my $widget = shift; my $e = $widget->XEvent; $self->on_mouse_move($e) if $e; 
        });
    }

    # ==========================================================
    # LÓGICA DE RUEDA DEL RATÓN (ZOOM) AISLADA POR CANVAS
    # ==========================================================
    
    # 1. Zoom Horizontal (Solo si el mouse está sobre las velas o el ATR)
    for my $cv (grep { defined } ($price_cv, $atr_cv)) {
        $cv->Tk::bind('<Button-4>', sub { 
            my $e = shift->XEvent; $self->horizontal_zoom(1, $e->x, ($e->s & 4)?1:0) if $e; 
        });
        $cv->Tk::bind('<Button-5>', sub { 
            my $e = shift->XEvent; $self->horizontal_zoom(-1, $e->x, ($e->s & 4)?1:0) if $e; 
        });
    }

    # 2. Zoom Vertical en Eje de Precios (Solo si está en Manual)
    if ($price_axis_cv) {
        $price_axis_cv->Tk::bind('<Button-4>', sub { 
            $self->vertical_zoom(1, 'price') if $self->{auto_scale} == 0; 
        });
        $price_axis_cv->Tk::bind('<Button-5>', sub { 
            $self->vertical_zoom(-1, 'price') if $self->{auto_scale} == 0; 
        });
    }

    # 3. Zoom Vertical en Eje de Volatilidad ATR (Solo si está en Manual)
    if ($atr_axis_cv) {
        $atr_axis_cv->Tk::bind('<Button-4>', sub { 
            $self->vertical_zoom(1, 'atr') if $self->{atr_auto_scale} == 0; 
        });
        $atr_axis_cv->Tk::bind('<Button-5>', sub { 
            $self->vertical_zoom(-1, 'atr') if $self->{atr_auto_scale} == 0; 
        });
    }


    # ==========================================================
    # LÓGICA 1: ARRASTRE 2D (PANNING)
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
            
            $self->{crosshair_x} = $e->x;
            $self->{crosshair_y} = $e->y;
            $self->{crosshair_w} = $widget;

            my $delta_x = $e->x - $self->{last_drag_x};
            my $delta_y = $e->y - $self->{last_drag_y};
            my $needs_render = 0;

            # A. Panning Horizontal
            if (defined $self->{price_panel} && defined $self->{price_panel}->{scale}) {
                my $plot_width = $self->{price_panel}->{scale}->{width} || 1;
                my $candle_width = ($plot_width / ($self->{visible_bars} || 1)) || 1;
                my $velas_desplazadas = int($delta_x / $candle_width);

                if ($velas_desplazadas != 0) {
                    my $total_candles = $self->{market_data} ? $self->{market_data}->size() : 0;
                    my $nuevo_offset = $self->{offset} + $velas_desplazadas;

                    my $offset_min = -($self->{visible_bars} - 2);
                    my $offset_max = $total_candles - 2;
                    if ($nuevo_offset < $offset_min) { $nuevo_offset = $offset_min; }
                    if ($nuevo_offset > $offset_max) { $nuevo_offset = $offset_max; }

                    if ($self->{offset} != $nuevo_offset) {
                        $self->{offset} = $nuevo_offset;
                        $self->{last_drag_x} = $e->x; 
                        $needs_render = 1;
                    }
                }
            }

            # B. Panning Vertical (Separado por panel)
            if ($delta_y != 0) {
                my $canvas_height = $canvas->Height() || 400;

                if ($canvas == $price_cv && $self->{auto_scale} == 0) {
                    my $rango = $self->{manual_y_max} - $self->{manual_y_min};
                    my $desplazamiento = ($delta_y / $canvas_height) * $rango;
                    $self->{manual_y_max} += $desplazamiento;
                    $self->{manual_y_min} += $desplazamiento;
                    $self->{last_drag_y} = $e->y;
                    $needs_render = 1;
                } 
                elsif ($canvas == $atr_cv && $self->{atr_auto_scale} == 0) {
                    my $rango = $self->{atr_manual_y_max} - $self->{atr_manual_y_min};
                    my $desplazamiento = ($delta_y / $canvas_height) * $rango;
                    $self->{atr_manual_y_max} += $desplazamiento;
                    $self->{atr_manual_y_min} += $desplazamiento;
                    $self->{last_drag_y} = $e->y;
                    $needs_render = 1;
                }
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
                my $factor = 1 - ($dx * 0.005); 
                my $new_bars = $current_bars * $factor;
                $new_bars = 2 if $new_bars < 2; 

                $self->{visible_bars} = $self->round($new_bars);
                $self->{last_axis_x} = $e->x;
                $self->request_render();
            }
        });

        $time_cv->Tk::bind('<ButtonRelease-1>', sub { $self->{last_axis_x} = undef; });
    }

    # ==========================================================
    # LÓGICA 3: ZOOM VERTICAL MANUAL EN EJES Y (Precios y ATR)
    # ==========================================================
    for my $axis_cv (grep { defined } ($price_axis_cv, $atr_axis_cv)) {
        $axis_cv->Tk::bind('<Button-1>', sub {
            my $widget = shift; my $e = $widget->XEvent;
            
            # Solo permitir anclar el arrastre si ya estamos intencionalmente en modo manual
            if ($axis_cv == $price_axis_cv && $self->{auto_scale} == 0) {
                $self->{last_axis_y} = $e->y if $e;
            }
            elsif ($axis_cv == $atr_axis_cv && $self->{atr_auto_scale} == 0) {
                $self->{last_axis_y} = $e->y if $e;
            }
        });
        
        $axis_cv->Tk::bind('<B1-Motion>', sub {
            my $widget = shift; my $e = $widget->XEvent;
            return unless $e && defined $self->{last_axis_y};

            $self->{crosshair_x} = $e->x;
            $self->{crosshair_y} = $e->y;
            $self->{crosshair_w} = $widget;

            my $dy = $e->y - $self->{last_axis_y};
            
            # Aplicar zoom al eje correspondiente SOLO en modo manual
            if (abs($dy) > 0) {
                my $factor = 1 + ($dy * 0.005);
                $factor = 0.01 if $factor < 0.01;

                if ($axis_cv == $price_axis_cv && $self->{auto_scale} == 0) {
                    my $rango = $self->{manual_y_max} - $self->{manual_y_min};
                    my $centro = ($self->{manual_y_max} + $self->{manual_y_min}) / 2;
                    my $nuevo_rango = $rango * $factor;
                    $self->{manual_y_max} = $centro + ($nuevo_rango / 2);
                    $self->{manual_y_min} = $centro - ($nuevo_rango / 2);
                    $self->{last_axis_y} = $e->y;
                    $self->request_render();
                } 
                elsif ($axis_cv == $atr_axis_cv && $self->{atr_auto_scale} == 0) {
                    my $rango = $self->{atr_manual_y_max} - $self->{atr_manual_y_min};
                    my $centro = ($self->{atr_manual_y_max} + $self->{atr_manual_y_min}) / 2;
                    my $nuevo_rango = $rango * $factor;
                    $self->{atr_manual_y_max} = $centro + ($nuevo_rango / 2);
                    $self->{atr_manual_y_min} = $centro - ($nuevo_rango / 2);
                    $self->{last_axis_y} = $e->y;
                    $self->request_render();
                }
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

    # Teclado para flechas
    $mw->Tk::bind('<Left>', sub {
        my $market_data = $self->{market_data};
        my $total_candles = $market_data ? $market_data->size() : 0;
        if ($self->{offset} < $total_candles - 2){
            $self->{offset}++;
            $self->request_render();
        }
    });

    $mw->Tk::bind('<Right>', sub {
        if ($self->{offset} > -($self->{visible_bars} - 2)){
            $self->{offset}--;
            $self->request_render();
        }
    });

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
    my %cambios_de_dia;

    # FASE 1: Identificar índices absolutos donde cambia el día
    for my $i ($start .. $end) {
        my $vela = $velas->[$i];
        last unless $vela;
        my $ts = $vela->{time} || "";
        my ($dia_actual) = $ts =~ /^(\d{4}-\d{2}-\d{2})/;
        $dia_actual //= "";

        if ($dia_actual ne $ultimo_dia_visto && $ultimo_dia_visto ne "") {
            $cambios_de_dia{$i} = 1;
        }
        $ultimo_dia_visto = $dia_actual if $dia_actual;
    }

    $ultimo_dia_visto = "";
    
    # FASE 2: Construir etiquetas ancladas a la vela real (Permite paneo fluido)
    for my $i ($start .. $end) {
        my $vela = $velas->[$i];
        last unless $vela;
        my $ts = $vela->{time} || "";
        my ($dia_actual) = $ts =~ /^(\d{4}-\d{2}-\d{2})/;
        $dia_actual //= "";
        $ultimo_dia_visto = $dia_actual if $dia_actual;

        # Si es un cambio de día, lo dibujamos siempre (en negrita en el PricePanel)
        if ($cambios_de_dia{$i}) {
            push @etiquetas_visibles, {
                indice_relativo => $i - $start, 
                timestamp       => $ts,
                es_cambio_dia   => 1
            };
        } 
        # Si es una etiqueta normal de minutos
        elsif ($i % $salto == 0) {
            # Evitar solapamiento: No dibujar si hay un cambio de día muy cerca
            my $colision = 0;
            my $tolerancia = int($salto * 0.25); # 25% de tolerancia de colisión
            $tolerancia = 1 if $tolerancia < 1;
            
            for my $j ($i - $tolerancia .. $i + $tolerancia) {
                if ($cambios_de_dia{$j}) {
                    $colision = 1;
                    last;
                }
            }

            if (!$colision) {
                push @etiquetas_visibles, {
                    indice_relativo => $i - $start, 
                    timestamp       => $ts,
                    es_cambio_dia   => 0
                };
            }
        }
    }

    return \@etiquetas_visibles;
}

sub vertical_zoom {
    my ($self, $factor, $target) = @_;
    $target ||= 'price';

    if ($target eq 'price') {
        return if $self->{auto_scale} == 1; # Bloquea si no está en modo manual
        my $rango = $self->{manual_y_max} - $self->{manual_y_min};
        my $cambio = $rango * 0.05 * $factor; 
        $self->{manual_y_max} += $cambio;
        $self->{manual_y_min} -= $cambio;
    } else {
        return if $self->{atr_auto_scale} == 1; # Bloquea si no está en modo manual
        my $rango = $self->{atr_manual_y_max} - $self->{atr_manual_y_min};
        my $cambio = $rango * 0.05 * $factor; 
        $self->{atr_manual_y_max} += $cambio;
        $self->{atr_manual_y_min} -= $cambio;
    }
    
    $self->request_render();
}

sub set_timeframe {
    my ($self, $tf) = @_;
    $self->{market_data}->set_timeframe($tf) if $self->{market_data} && $self->{market_data}->can('set_timeframe');
    $self->reset_view(); 
}

sub on_mouse_move {
    my ($self, $event) = @_;
    return unless $event;

    $self->{crosshair_x} = $event->x;
    $self->{crosshair_y} = $event->y;
    $self->{crosshair_w} = $event->W;

    # --- LA MAGIA DE LA MANITO (Hitbox 2D) ---
    if ($event->W == $self->{price_canvas} && $self->{price_panel} && $self->{price_panel}->{scale}) {
        my $scale = $self->{price_panel}->{scale};
        
        # Buscamos qué vela está exactamente bajo la coordenada X del ratón
        my $idx = int($scale->x_to_index($event->x));
        my $candle = $self->{market_data} ? $self->{market_data}->get_candle($idx) : undef;

        my $cursor = 'crosshair'; # Cursor de cruz por defecto

        if ($candle) {
            # Calculamos dónde empiezan y terminan las mechas en el eje Y
            my $y_high = $scale->value_to_y($candle->{high});
            my $y_low  = $scale->value_to_y($candle->{low});

            # En Tk, el eje Y crece hacia abajo (0 es arriba). 
            # Calculamos el límite superior e inferior reales:
            my $min_y = $y_high < $y_low ? $y_high : $y_low;
            my $max_y = $y_high > $y_low ? $y_high : $y_low;

            # Damos +/- 5 píxeles de tolerancia (hitbox) para facilitar la selección
            if ($event->y >= ($min_y - 5) && $event->y <= ($max_y + 5)) {
                $cursor = 'hand2'; # ¡Cambiamos a la manito!
            }
        }
        
        # Aplicamos el cursor instantáneamente
        $self->{price_canvas}->configure(-cursor => $cursor);
    }

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
    $new_bars = 2 if $new_bars < 2;

    if (defined $self->{price_panel} && defined $self->{price_panel}->{scale}) {
        my $scale = $self->{price_panel}->{scale};
        my $total_candles = $self->{market_data} ? $self->{market_data}->size() : 0;

        my $plot_width = $scale->{width} - $scale->{margin_left} - $scale->{margin_right};
        $plot_width = 1 if $plot_width <= 0;
        my $new_candle_width = $plot_width / $new_bars;

        my $nuevo_offset;

        if ($has_ctrl && defined $mouse_x) {
            # CTRL: ancla al índice exacto bajo el cursor del ratón.
            # La vela apuntada se queda estática en la misma posición X de pantalla.
            my $exact_index = $scale->x_to_index_float($mouse_x);
            my $new_scale_offset = $exact_index - (($mouse_x - $scale->{margin_left}) / $new_candle_width);
            $nuevo_offset = $total_candles - $new_bars - $new_scale_offset;
        } else {
            # SIN CTRL (comportamiento TradingView por defecto): ancla la última vela
            # visible al borde derecho del gráfico. El offset actual ya expresa cuántas
            # velas desde el final estamos desplazados; sólo necesitamos preservarlo.
            # La última vela visible tiene índice: total_candles - 1 - offset_actual.
            # Queremos que ese mismo índice siga siendo el último tras el zoom, por lo
            # tanto el nuevo offset es idéntico al actual (el borde derecho no se mueve).
            $nuevo_offset = $self->{offset};
        }

        # Blindaje de límites
        my $offset_min = -($new_bars - 2);
        my $offset_max = $total_candles - 2;
        $nuevo_offset = $offset_min if $nuevo_offset < $offset_min;
        $nuevo_offset = $offset_max if $nuevo_offset > $offset_max;

        $self->{offset} = $nuevo_offset;
    }

    # Aplicamos sin redondear para mantener la fluidez sub-píxel perfecta
    $self->{visible_bars} = $new_bars;
    $self->request_render();
}

sub reset_view {
    my ($self) = @_;
    
    $self->{visible_bars} = 150; 
    $self->{offset} = 0;   
    $self->set_auto_scale(1);
    
    $self->{atr_auto_scale} = 1;
    $self->{manual_y_max} = undef;
    $self->{manual_y_min} = undef;
    $self->{atr_manual_y_max} = undef;
    $self->{atr_manual_y_min} = undef;

    $self->{last_drag_x}  = undef;
    $self->{last_drag_y}  = undef;

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

sub set_auto_scale {
    my ($self, $mode) = @_;
    
    # ¡TRUCO VITAL! Si el usuario presiona el botón para ir a Manual (0), 
    # debemos capturar el rango visual del ATR MIENTRAS AÚN ESTÁ EN AUTO, 
    # para que herede los valores reales en lugar de saltar a 0 - 10.
    if ($mode == 0 && $self->{atr_panel}) {
        my ($min, $max) = $self->{atr_panel}->get_y_range();
        $self->{atr_manual_y_min} = $min;
        $self->{atr_manual_y_max} = $max;
    }

    # Sincronizamos ambas banderas maestras al mismo estado
    $self->{auto_scale} = $mode;
    $self->{atr_auto_scale} = $mode;

    # Actualizamos la estética del botón de la interfaz
    if (my $btn = $self->{widgets}->{scale_btn}) {
        $btn->configure(
            -text => $mode ? "Escala: Auto" : "Escala: Manual",
            -fg   => $mode ? '#3bb3e4' : '#ff9800'
        );
    }
}

1;