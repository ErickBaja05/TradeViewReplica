package Market::ChartEngine;

use strict;
use warnings;

use Market::Panels::PricePanel;
use Market::Panels::ATRPanel;
use Market::Indicators::Liquidity;
use Market::Indicators::SMC_Structures;
use Market::Indicators::FVG;
use Market::Indicators::OrderBlock;
use Market::Overlays::Liquidity;
use Market::Overlays::SMC_Structures;
use Market::Overlays::ChoCH;
use Market::Overlays::BOS;
use Market::Overlays::LiquidityEvents;
use Market::Overlays::Swing;
use Market::Overlays::FVG;
use Market::Overlays::OrderBlock;

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

        # --- Funcionalidad de Liquidez y SMC (Smart Money Concepts) ---
        show_liquidity    => 1,
        show_smc          => 1,
        show_choch        => 1,
        show_bos          => 1,
        show_lq_events    => 1,
        show_swing        => 0,
        show_fvg          => 1,
        show_ob           => 1,
        smc_cache_key     => undef,

        liquidity_engine  => Market::Indicators::Liquidity->new(
            atr_mult       => 4.0,
            minor_atr_mult => 1.5,
            confirm_bars   => 3,
        ),
        # Estructura EXTERNA (BOS/CHoCH externos), calculada sobre los
        # pivotes estructurales (tier "structural").
        smc_engine        => Market::Indicators::SMC_Structures->new(
            choch_atr_mult => 2.0,
        ),
        # Estructura INTERNA (BOS/CHoCH internos), calculada sobre los
        # pivotes "minor" (swing points de menor grado). Usa un múltiplo de
        # ATR menor para que el CHoCH interno sea alcanzable a esa escala.
        smc_internal_engine => Market::Indicators::SMC_Structures->new(
            choch_atr_mult => 0.5,
        ),
        fvg_engine        => Market::Indicators::FVG->new(
            min_gap_atr_mult => 0.05,
        ),
        ob_engine         => Market::Indicators::OrderBlock->new(
            impulse_atr_mult => 1.5,
            max_lookback      => 15,
        ),
        liquidity_overlay        => Market::Overlays::Liquidity->new(),
        smc_overlay              => Market::Overlays::SMC_Structures->new(),
        choch_overlay            => Market::Overlays::ChoCH->new(),
        bos_overlay              => Market::Overlays::BOS->new(),
        liquidity_events_overlay => Market::Overlays::LiquidityEvents->new(),
        swing_overlay            => Market::Overlays::Swing->new(),
        fvg_overlay              => Market::Overlays::FVG->new(),
        ob_overlay               => Market::Overlays::OrderBlock->new(),
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

    # --- Capas de Liquidez, SMC, ChoCH, FVG y Order Blocks ---
    # Se dibujan sobre el canvas de precios, apoyándose en la misma escala
    # ($self->{price_panel}->{scale}) que ya fue calculada por PricePanel::render().
    if ($self->{show_liquidity} || $self->{show_smc} || $self->{show_choch} 
     || $self->{show_fvg} || $self->{show_ob} || $self->{show_bos} 
     || $self->{show_lq_events} || $self->{show_swing}) {
        $self->update_smc_overlay($self->{market_data}->last_index());

        my $scale = $self->{price_panel} ? $self->{price_panel}->{scale} : undef;

        if ($scale) {
            # Las franjas (FVG/OB) se dibujan primero, para que las líneas de
            # estructura (SMC/CHoCH/Liquidez) queden siempre visibles por encima.
            $self->{fvg_overlay}->draw($self->{price_canvas}, $scale, $start, $end)
                if $self->{show_fvg};

            $self->{ob_overlay}->draw($self->{price_canvas}, $scale, $start, $end)
                if $self->{show_ob};

            $self->{liquidity_overlay}->draw($self->{price_canvas}, $scale, $start, $end)
                if $self->{show_liquidity};

            $self->{smc_overlay}->draw($self->{price_canvas}, $scale, $start, $end)
                if $self->{show_smc};

            $self->{choch_overlay}->draw($self->{price_canvas}, $scale, $start, $end)
                if $self->{show_choch};
            
            $self->{bos_overlay}->draw($self->{price_canvas}, $scale, $start, $end)
                if $self->{show_bos};

            $self->{swing_overlay}->draw($self->{price_canvas}, $scale, $start, $end)
                if $self->{show_swing};

            $self->{liquidity_events_overlay}->draw($self->{price_canvas}, $scale, $start, $end)
                if $self->{show_lq_events};
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

=head2 update_smc_overlay($until_index)

Calcula (con caché) los resultados de Liquidez y de Estructura SMC hasta el
índice indicado, y actualiza las capas visuales correspondientes. El caché
evita recalcular ambos motores en cada render (por ejemplo al mover el
crosshair), recalculando sólo cuando cambia la temporalidad activa o el
índice de la última vela disponible.

=cut

sub update_smc_overlay {
    my ($self, $until_index) = @_;
    return unless defined $until_index && $until_index >= 0;

    my $market_data = $self->{market_data};
    my $tf = $market_data->{timeframe} // '1m';

    my $cache_key = join(':', $tf, $until_index);
    return if defined $self->{smc_cache_key} && $self->{smc_cache_key} eq $cache_key;

    my $atr_values = $self->{indicator_manager} ? $self->{indicator_manager}->get('ATR') : undef;
    return unless $atr_values;

    my $liq_result = $self->{liquidity_engine}->calculate_until(
        $market_data->get_slice(0, $until_index),
        $atr_values,
        $until_index
    );

    my $smc_result = $self->{smc_engine}->calculate(
        $liq_result->{structural_pivots}
    );

    my $candles_full = $market_data->get_slice(0, $until_index);

    my $fvg_result = $self->{fvg_engine}->calculate_until(
        $candles_full,
        $atr_values,
        $until_index
    );

    my $ob_result = $self->{ob_engine}->calculate_until(
        $candles_full,
        $atr_values,
        $until_index
    );

    $self->{liquidity_overlay}->set_result($liq_result);
    $self->{smc_overlay}->set_result($smc_result);
    $self->{choch_overlay}->set_result($smc_result);
    $self->{fvg_overlay}->set_result($fvg_result);
    $self->{ob_overlay}->set_result($ob_result);

    $self->{bos_overlay}->set_result($smc_result);
    $self->{liquidity_events_overlay}->set_result($liq_result);
    $self->{swing_overlay}->set_result($liq_result);


    $self->{smc_cache_key} = $cache_key;
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

# =============================================================================
# compute_intraday_labels  —  Orquestador principal del eje de tiempo
#
# Arquitectura:
#   1. find_pivot_labels()      → etiquetas "ancla" (cambios de día)
#   2. fill_between_pivots()    → etiquetas horarias entre cada par de pivotes
#   3. remove_overlaps()        → filtro final anti-solapamiento
# =============================================================================
sub compute_intraday_labels {
    my ($self) = @_;

    my $pivots  = $self->find_pivot_labels();
    my $labels  = $self->fill_between_pivots($pivots);
    $labels     = $self->remove_overlaps($labels);

    return $labels;
}

# -----------------------------------------------------------------------------
# find_pivot_labels()
#
# Recorre las velas visibles y devuelve una etiqueta "ancla" por cada
# cambio de día detectado.  Resultado: type => 'day'.
# -----------------------------------------------------------------------------
sub find_pivot_labels {
    my ($self) = @_;
    my ($start, $end) = $self->compute_window();
    my $velas = $self->{market_data}->get_data();

    my @pivots;
    my $ultimo_dia = "";

    # Incluimos un pivote sintético al inicio de la ventana para que
    # fill_between_pivots() pueda rellenar desde el borde izquierdo.
    {
        my $primera = $velas->[$start];
        if ($primera) {
            push @pivots, {
                indice_absoluto => $start,
                indice_relativo => 0,
                timestamp       => $primera->{time} // "",
                type            => 'start',   # marcador interno, no se dibuja
            };
            ($ultimo_dia) = ($primera->{time} // "") =~ /^(\d{4}-\d{2}-\d{2})/;
            $ultimo_dia //= "";
        }
    }

    for my $i ($start + 1 .. $end) {
        my $vela = $velas->[$i];
        next unless $vela;
        my $ts = $vela->{time} // "";
        my ($dia) = $ts =~ /^(\d{4}-\d{2}-\d{2})/;
        $dia //= "";

        if ($dia ne $ultimo_dia && $ultimo_dia ne "") {
            push @pivots, {
                indice_absoluto => $i,
                indice_relativo => $i - $start,
                timestamp       => $ts,
                type            => 'day',
            };
        }
        $ultimo_dia = $dia if $dia;
    }

    # Pivote sintético al final para cerrar el último intervalo
    {
        my $ultima = $velas->[$end];
        if ($ultima) {
            push @pivots, {
                indice_absoluto => $end,
                indice_relativo => $end - $start,
                timestamp       => $ultima->{time} // "",
                type            => 'end',    # marcador interno, no se dibuja
            };
        }
    }

    return \@pivots;
}

# -----------------------------------------------------------------------------
# fill_between_pivots(\@pivots)
#
# Para cada par de pivotes consecutivos:
#   1. Mide el espacio en píxeles disponible entre ellos.
#   2. Elige el intervalo de minutos más "bonito" que quepa sin saturar.
#   3. Genera etiquetas horarias (type => 'hour') en los timestamps exactos.
# Devuelve la lista completa (pivotes dibujables + relleno), ordenada por x.
# -----------------------------------------------------------------------------
sub fill_between_pivots {
    my ($self, $pivots) = @_;
    return [] unless $pivots && @$pivots >= 2;

    my ($start, $end) = $self->compute_window();
    my $velas         = $self->{market_data}->get_data();
    my $scale         = $self->{price_panel} ? $self->{price_panel}->{scale} : undef;

    # Sin escala todavía (primer render) devolvemos sólo los pivotes reales
    unless ($scale) {
        return [ grep { $_->{type} eq 'day' } @$pivots ];
    }

    # Pasos "bonitos" en minutos
    my @steps = (1, 2, 4, 5, 6, 8, 10, 12, 15, 20, 30, 60, 120, 240, 480);

    # Espacio mínimo entre etiquetas en píxeles (evita solapamiento visual)
    my $min_spacing = 10;

    my @result;

    for my $k (0 .. $#$pivots - 1) {
        my $p1 = $pivots->[$k];
        my $p2 = $pivots->[$k + 1];

        # Añadir el pivote p1 si es dibujable (day)
        push @result, $p1 if $p1->{type} eq 'day';

        my $x1 = $scale->index_to_center_x($p1->{indice_absoluto});
        my $x2 = $scale->index_to_center_x($p2->{indice_absoluto});
        my $pixel_distance = $x2 - $x1;

        next if $pixel_distance <= 0;

        # ¿Cuántas etiquetas intermedias caben?
        my $max_labels = int($pixel_distance / $min_spacing);
        next if $max_labels < 1;

        # Elegir el menor paso que produzca <= max_labels etiquetas
        # Para estimarlo necesitamos cuántos minutos hay entre los pivotes.
        my $ts1 = $p1->{timestamp};
        my $ts2 = $p2->{timestamp};
        my $minutos_span = $self->_ts_diff_minutes($ts1, $ts2);
        next if $minutos_span <= 0;

        my $chosen_step = undef;
        for my $step (@steps) {
            my $estimated = int($minutos_span / $step);
            if ($estimated <= $max_labels) {
                $chosen_step = $step;
                last;
            }
        }
        next unless defined $chosen_step;

        # Generar etiquetas intermedias recorriendo las velas del intervalo
        for my $i ($p1->{indice_absoluto} + 1 .. $p2->{indice_absoluto} - 1) {
            my $vela = $velas->[$i];
            next unless $vela;
            my $ts = $vela->{time} // "";

            # Extraer hora y minuto
            my ($h, $m) = $ts =~ /[T ](\d{2}):(\d{2})/;
            next unless defined $h && defined $m;

            my $total_min = $h * 60 + $m;

            # ¿Cae exactamente en un múltiplo del paso elegido?
            next unless $total_min % $chosen_step == 0;

            push @result, {
                indice_absoluto => $i,
                indice_relativo => $i - $start,
                timestamp       => $ts,
                type            => 'hour',
            };
        }
    }

    # Añadir el último pivote si es dibujable
    my $last = $pivots->[-1];
    push @result, $last if $last && $last->{type} eq 'day';

    # Ordenar por posición
    @result = sort { $a->{indice_absoluto} <=> $b->{indice_absoluto} } @result;

    return \@result;
}

# -----------------------------------------------------------------------------
# remove_overlaps(\@labels)
#
# Descarta etiquetas cuya posición X esté demasiado cerca de la anterior.
# La anchura de cada texto se estima como: caracteres × 8 px + margen 12 px.
# Los pivotes 'day' tienen prioridad: si colisionan con una 'hour' anterior,
# es la 'hour' la que se elimina (ya se hizo).  Si colisionan entre sí,
# se mantiene la primera que apareció.
# -----------------------------------------------------------------------------
sub remove_overlaps {
    my ($self, $labels) = @_;
    return $labels unless $labels && @$labels;

    my $scale = $self->{price_panel} ? $self->{price_panel}->{scale} : undef;
    return $labels unless $scale;

    my @kept;
    my $last_x_right = -9999;   # borde derecho de la última etiqueta aceptada

    for my $lbl (@$labels) {
        my $x = $scale->index_to_center_x($lbl->{indice_absoluto});

        # Estimar anchura del texto
        my $text  = $lbl->{timestamp} // "";
        my $chars = length($text) > 0 ? length($text) : 5;
        my $ancho = $chars * 8 + 12;     # 8 px/carácter + 12 px de margen
        my $x_left  = $x - int($ancho / 2);
        my $x_right = $x + int($ancho / 2);

        if ($x_left > $last_x_right) {
            push @kept, $lbl;
            $last_x_right = $x_right;
        }
        # Si colisiona pero es 'day', reemplaza la anterior si ésta era 'hour'
        elsif ($lbl->{type} eq 'day' && @kept && $kept[-1]{type} eq 'hour') {
            pop @kept;
            push @kept, $lbl;
            $last_x_right = $x_right;
        }
        # En cualquier otro caso de colisión se descarta silenciosamente
    }

    return \@kept;
}

# -----------------------------------------------------------------------------
# _ts_diff_minutes($ts1, $ts2)
#
# Diferencia en minutos entre dos timestamps ISO-8601 / "YYYY-MM-DD HH:MM".
# Solo toma en cuenta hora y minuto dentro del mismo día para rapidez;
# si cruzan medianoche devuelve la suma de minutos restantes + los del nuevo.
# Para el propósito de elegir el step esto es suficientemente preciso.
# -----------------------------------------------------------------------------
sub _ts_diff_minutes {
    my ($self, $ts1, $ts2) = @_;

    my ($d1, $h1, $m1) = $ts1 =~ /(\d{4}-\d{2}-\d{2})[T ](\d{2}):(\d{2})/;
    my ($d2, $h2, $m2) = $ts2 =~ /(\d{4}-\d{2}-\d{2})[T ](\d{2}):(\d{2})/;

    return 0 unless defined $h1 && defined $h2;

    my $min1 = $h1 * 60 + $m1;
    my $min2 = $h2 * 60 + $m2;

    if ($d1 eq $d2) {
        return abs($min2 - $min1);
    }
    else {
        # Cruza medianoche: minutos restantes del día 1 + minutos del día 2
        return (1440 - $min1) + $min2;
    }
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

    # El ATR incremental sólo conoce la última vela agregada; al cambiar de
    # temporalidad hace falta recalcular la serie completa para que la nueva
    # cantidad de velas quede correctamente indexada. Esto es indispensable
    # para que Liquidez y SMC (que dependen del ATR por índice) sigan siendo
    # coherentes en 1m/5m/15m.
    if ($self->{indicator_manager} && $self->{indicator_manager}->can('recompute_all')) {
        $self->{indicator_manager}->recompute_all($self->{market_data});
    }

    # Invalidamos el caché de Liquidez/SMC para forzar su recálculo con la
    # nueva serie de velas y de ATR.
    $self->{smc_cache_key} = undef;

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