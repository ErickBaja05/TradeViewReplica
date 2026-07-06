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

        # Nuevas estructuras para Arquitectura Fase 2
        overlays        => [],       # Arreglo de instancias de Overlays gráficos
        replay_timer_id => undef,    # ID del loop de Tk para Play/Pause
        replay_speed    => 500,      # Milisegundos entre velas durante Play
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
    $self->{time_canvas}->yviewMoveto(0) if $self->{time_canvas};
    
    $self->{price_panel}->render($data_slice) if $self->{price_panel};
    $self->{atr_panel}->render($data_slice)   if $self->{atr_panel};

    # Novedad: Ejecutar renderizado de los overlays gráficos (SMC, Liquidez, etc.)
    if (defined $self->{price_panel} && defined $self->{price_panel}->{scale}) {
        my $scale = $self->{price_panel}->{scale};
        foreach my $overlay (@{$self->{overlays}}) {
            $overlay->render($start, $end, $scale);
        }
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

sub _ceil_int {
    my ($self, $value) = @_;
    my $i = int($value);
    return ($value > $i) ? $i + 1 : $i;
}

sub _parse_timestamp_parts {
    my ($self, $ts) = @_;
    return unless defined $ts;
    if ($ts =~ /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})/) {
        return ($1, $2, $3, $4, $5);
    }
    return;
}

sub _month_short_name {
    my ($self, $month) = @_;
    my @names = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
    my $idx = int($month) - 1;
    return $names[$idx] || $month;
}

sub _format_day_axis_label {
    my ($self, $ts, $prev_date) = @_;
    my ($y, $m, $d, $hh, $mm) = $self->_parse_timestamp_parts($ts);
    return $ts unless defined $d;

    my $label = int($d);
    if (!defined $prev_date || $prev_date eq '' || $prev_date !~ /^$y-$m-/) {
        $label = int($d) . '/' . int($m);
    }
    return $label;
}

sub _time_axis_interval_minutes {
    my ($self, $tf, $visible_bars, $candle_px) = @_;

    # Intervalos cómodos para que el eje no se llene al aumentar la temporalidad.
    # La idea es parecida al proyecto guía: no se dibuja cada vela, sino marcas
    # importantes y separadas visualmente.
    return 15   if $tf eq '1m'  && $visible_bars <= 80;
    return 30   if $tf eq '1m'  && $visible_bars <= 180;
    return 60   if $tf eq '1m';

    return 30   if $tf eq '5m'  && $visible_bars <= 120;
    return 60   if $tf eq '5m'  && $visible_bars <= 260;
    return 120  if $tf eq '5m';

    return 60   if $tf eq '15m' && $visible_bars <= 160;
    return 180  if $tf eq '15m' && $visible_bars <= 320;
    return 360  if $tf eq '15m';

    return 360  if $tf eq '1h'  && $visible_bars <= 160;
    return 720  if $tf eq '1h';

    return 720  if $tf eq '2h';
    return 1440 if $tf eq '4h';

    return 1440;
}

sub compute_intraday_labels {
    my ($self) = @_;
    my ($start, $end) = $self->compute_window();
    my $velas = $self->{market_data}->get_data();
    my @selected;

    return \@selected unless $velas && @$velas && $end >= $start;

    my $tf = $self->{market_data}->{timeframe} || '1m';
    my $visible_bars = $self->{visible_bars} || ($end - $start + 1) || 1;
    my $canvas_width = $self->{price_canvas} ? ($self->{price_canvas}->Width() || 800) : 800;
    my $candle_px = $canvas_width / $visible_bars;
    $candle_px = 1 if $candle_px < 1;

    my $min_px = 72;
    $min_px = 60 if $visible_bars <= 80;
    $min_px = 86 if $visible_bars > 180;
    my $min_bars_between_labels = $self->_ceil_int($min_px / $candle_px);
    $min_bars_between_labels = 1 if $min_bars_between_labels < 1;

    my $interval_minutes = $self->_time_axis_interval_minutes($tf, $visible_bars, $candle_px);
    my $last_date = '';
    my $prev_visible_date = '';

    my @candidates;

    for my $i ($start .. $end) {
        my $vela = $velas->[$i];
        next unless $vela;
        my $ts = $vela->{time} || '';
        my ($y, $m, $d, $hh, $mm) = $self->_parse_timestamp_parts($ts);
        next unless defined $d;

        my $date = "$y-$m-$d";
        my $minute_of_day = int($hh) * 60 + int($mm);
        my $is_first_visible = ($i == $start) ? 1 : 0;
        my $is_new_day = ($last_date ne '' && $date ne $last_date) ? 1 : 0;

        if ($tf eq 'D' || $tf eq 'W') {
            my $txt = int($d) . '/' . int($m);
            $txt = $self->_month_short_name($m) . ' ' . int($d) if $tf eq 'W';
            push @candidates, {
                index          => $i,
                indice_relativo => $i - $start,
                timestamp      => $ts,
                text           => $txt,
                major          => 1,
                es_cambio_dia  => 1,
            };
        }
        elsif ($is_first_visible || $is_new_day) {
            push @candidates, {
                index          => $i,
                indice_relativo => $i - $start,
                timestamp      => $ts,
                text           => $self->_format_day_axis_label($ts, $prev_visible_date),
                major          => 1,
                es_cambio_dia  => 1,
            };
        }
        elsif ($minute_of_day % $interval_minutes == 0) {
            push @candidates, {
                index          => $i,
                indice_relativo => $i - $start,
                timestamp      => $ts,
                text           => sprintf('%02d:%02d', int($hh), int($mm)),
                major          => 0,
                es_cambio_dia  => 0,
            };
        }

        $prev_visible_date = $last_date if $date ne $last_date && $last_date ne '';
        $last_date = $date;
    }

    for my $cand (@candidates) {
        if (!@selected) {
            push @selected, $cand;
            next;
        }

        my $gap = $cand->{index} - $selected[-1]->{index};
        if ($gap >= $min_bars_between_labels) {
            push @selected, $cand;
            next;
        }

        # Si aparece un cambio de día cerca de una hora normal, se conserva el día
        # y se elimina la hora anterior. Así el eje queda limpio y legible.
        if ($cand->{major} && !$selected[-1]->{major}) {
            pop @selected;
            push @selected, $cand;
            next;
        }
    }

    return \@selected;
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


sub recalculate_indicators {
    my ($self) = @_;
    return unless $self->{market_data};

    if ($self->{indicator_manager}) {
        # Recalcular ATR/Liquidez sobre todo el historial activo.
        # Esto mantiene sincronizados ATR, liquidez y SMC al cambiar temporalidad o Replay.
        if ($self->{indicator_manager}->can('recalculate_all')) {
            $self->{indicator_manager}->recalculate_all($self->{market_data});
        } else {
            $self->{indicator_manager}->reset_all() if $self->{indicator_manager}->can('reset_all');
            $self->{indicator_manager}->update_last($self->{market_data});
        }
    }

    if ($self->{smc_indicator} && $self->{smc_indicator}->can('recalculate')) {
        $self->{smc_indicator}->recalculate($self->{market_data});
    }
}


sub fit_all {
    my ($self) = @_;
    my $n = $self->{market_data} ? ($self->{market_data}->size() || 0) : 0;

    my $default_visible = 150;
    if ($n > 0 && $n < $default_visible) {
        # Igual que el proyecto guía: si la temporalidad tiene pocas velas,
        # se ajusta la ventana al total y se deja un pequeño respiro visual.
        $self->{visible_bars} = $n + 4;
    } else {
        $self->{visible_bars} = $default_visible;
    }

    $self->{offset} = 0;
}

sub set_timeframe {
    my ($self, $tf) = @_;
    return unless $self->{market_data} && $self->{market_data}->can('set_timeframe');

    # Al cambiar temporalidad se hace un cambio limpio, como en el proyecto guía:
    # primero se corta cualquier replay, luego se cambia el arreglo activo, se
    # recalculan indicadores desde cero y recién después se redibuja.
    $self->pause_replay() if $self->can('pause_replay');
    $self->{market_data}->set_timeframe($tf);

    $self->fit_all();
    $self->{render_pending} = 0;

    $self->{crosshair_x} = undef;
    $self->{crosshair_y} = undef;
    $self->{crosshair_w} = undef;
    $self->{last_drag_x} = undef;
    $self->{last_drag_y} = undef;

    $self->{auto_scale} = 1;
    $self->{atr_auto_scale} = 1;
    $self->{manual_y_max} = undef;
    $self->{manual_y_min} = undef;
    $self->{atr_manual_y_max} = undef;
    $self->{atr_manual_y_min} = undef;

    # Limpieza inmediata para que no quede ninguna etiqueta/línea de la temporalidad anterior.
    $self->{price_canvas}->delete('all')      if $self->{price_canvas};
    $self->{atr_canvas}->delete('all')        if $self->{atr_canvas};
    $self->{time_canvas}->delete('all')       if $self->{time_canvas};
    $self->{price_axis_canvas}->delete('all') if $self->{price_axis_canvas};
    $self->{atr_axis_canvas}->delete('all')   if $self->{atr_axis_canvas};

    $self->set_auto_scale(1);
    $self->recalculate_indicators();
    $self->request_render();
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

    my $total_candles_for_clamp = $self->{market_data} ? ($self->{market_data}->size() || 0) : 0;
    if ($total_candles_for_clamp > 0) {
        my $max_visible = $total_candles_for_clamp + 4;
        $new_bars = $max_visible if $new_bars > $max_visible;
    }

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
    
    $self->fit_all();
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


# --- 2. NUEVOS MÉTODOS DE GESTIÓN DE OVERLAYS ---
sub add_overlay {
    my ($self, $overlay) = @_;
    push @{$self->{overlays}}, $overlay;
}

# --- 3. NUEVOS MÉTODOS DE REPLAY QUE SE LLAMAN DESDE MARKET.PL ---
sub toggle_replay_mode {
    my ($self, $start_index) = @_;
    my $md = $self->{market_data};
    
    if ($md->is_replay_active()) {
        $self->pause_replay();
        $md->set_replay_mode(0);
    } else {
        # Por defecto, iniciamos el replay 100 velas atrás si no se especifica
        $start_index //= ($md->size() > 100) ? $md->size() - 100 : 0;
        $md->set_replay_mode(1, $start_index);
    }
    
    # Forzamos el offset a 0 para anclarnos a la "vela actual" simulada
    $self->{offset} = 0;
    $self->request_render();
}

sub play_replay {
    my ($self) = @_;
    return unless $self->{market_data}->is_replay_active();
    return if defined $self->{replay_timer_id}; # Evitar múltiples loops
    
    my $mw = $self->{widgets}->{main_window};
    
    # Callback recursivo para el Play
    my $step_cb;
    $step_cb = sub {
        my $advanced = $self->{market_data}->step_forward();
        if ($advanced) {
            $self->request_render();
            # Recalcular indicadores para que el Replay no deje estructuras adelantadas.
            $self->recalculate_indicators();
            
            # Programamos el siguiente tick
            $self->{replay_timer_id} = $mw->after($self->{replay_speed}, $step_cb);
        } else {
            $self->pause_replay(); # Llegamos al final
        }
    };
    
    # Iniciamos el primer tick
    $self->{replay_timer_id} = $mw->after($self->{replay_speed}, $step_cb);
}

sub pause_replay {
    my ($self) = @_;
    if (defined $self->{replay_timer_id}) {
        my $mw = $self->{widgets}->{main_window};
        $mw->afterCancel($self->{replay_timer_id});
        $self->{replay_timer_id} = undef;
    }
}

sub step_forward {
    my ($self) = @_;
    $self->pause_replay(); # El paso manual pausa la reproducción automática
    if ($self->{market_data}->step_forward()) {
        $self->recalculate_indicators();
        $self->request_render();
    }
}

sub step_backward {
    my ($self) = @_;
    $self->pause_replay();
    if ($self->{market_data}->step_backward()) {
        $self->recalculate_indicators();
        $self->request_render();
    }
}

1;