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

        price_panel       => undef,
        atr_panel         => undef,

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

    $self->{price_panel}->render($data_slice) if $self->{price_panel};
    $self->{atr_panel}->render($data_slice)   if $self->{atr_panel};

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

        if ($es_cambio_dia || $i % $salto == 0) {
            push @etiquetas_visibles, {
                indice_relativo => $i - $start, 
                timestamp       => $ts,
                es_cambio_dia   => $es_cambio_dia
            };
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

    if ($has_ctrl && defined $mouse_x && defined $self->{price_panel}) {
        my $canvas_width = $self->{price_canvas}->Width() || 1;
        my $porcentaje_pantalla = $mouse_x / $canvas_width;
        my $barras_perdidas = $current_bars - $new_bars;
        
        $self->{offset} += ($barras_perdidas * (1 - $porcentaje_pantalla));
    }

    $self->{visible_bars} = $self->round($new_bars);
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
    
    $self->{auto_scale} = $mode;

    if (my $btn = $self->{widgets}->{scale_btn}) {
        $btn->configure(
            -text => $mode ? "Escala: Auto" : "Escala: Manual",
            -fg   => $mode ? '#3bb3e4' : '#ff9800'
        );
    }
}

1;