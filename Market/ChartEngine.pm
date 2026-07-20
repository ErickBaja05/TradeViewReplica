package Market::ChartEngine;

use strict;
use warnings;

use Market::Panels::PricePanel;
use Market::Panels::ATRPanel;
use Market::Indicators::Liquidity;
use Market::Indicators::SMC_Structures;
use Market::Indicators::FVG;
use Market::Indicators::Structure;
use Market::Indicators::Supertrend;
use Market::Indicators::HalfTrend;
use Market::Indicators::TrendChannel;
use Market::Indicators::OrderBlocks;
use Market::Indicators::VWAPAnchored;
use Market::Indicators::VolumeProfileAnchored;
use Market::Indicators::Fibonacci;
use Market::Indicators::Levels;
use Market::Indicators::ZigzagInternal;
use Market::Indicators::Anchors;
use Market::Indicators::MultiAnchoredVWAP;

use Market::Overlays::Zigzag_External;
use Market::Overlays::Zigzag_Internal;
use Market::Overlays::Swing;
use Market::Overlays::FVG;
use Market::Overlays::BOS_External;
use Market::Overlays::BOS_Internal;
use Market::Overlays::ChoCH_External;
use Market::Overlays::ChoCH_Internal;
use Market::Overlays::EQH;
use Market::Overlays::EQL;
use Market::Overlays::Liquidity;
use Market::Overlays::Supertrend;
use Market::Overlays::HalfTrend;
use Market::Overlays::TrendChannel;
use Market::Overlays::OrderBlocks;
use Market::Overlays::VWAPAnchored;
use Market::Overlays::VolumeProfileAnchored;
use Market::Overlays::Fibonacci;
use Market::Overlays::Levels;
use Market::Overlays::Anchors;
use Market::Overlays::MultiAnchoredVWAP;

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

        # Mostrar/ocultar la línea + etiqueta del último precio visible
        show_last_price   => 1,

        # Estado de Escalas ATR (Volatilidad)
        atr_auto_scale    => 1,
        atr_manual_y_max  => 10,
        atr_manual_y_min  => 0,

        # --- Funcionalidad de Liquidez y SMC (Smart Money Concepts) ---
        show_zigzag_ext   => 0,
        show_zigzag_int   => 0,
        # Temporalidad "Multi Time Frame" usada por el Zigzag Interno,
        # independiente de la temporalidad activa del gráfico (igual que el
        # input "ZigZag Resolution" del indicador PineScript de referencia).
        zigzag_internal_tf   => '1h',
        zigzag_internal_cache_key => undef,
        show_swing   => 0,
        show_bos_ext      => 0,
        show_bos_int      => 0,
        show_choch_ext    => 0,
        show_choch_int    => 0,
        show_eqh          => 0,
        show_eql          => 0,
        show_fibonacci    => 0,
        show_levels       => 0,

        show_bsl          => 0,
        show_ssl          => 0,
        show_lq_sweep     => 0,
        show_lq_grab      => 0,
        show_lq_run       => 0,
        show_supertrend   => 0,
        show_halftrend    => 0,
        show_fvg          => 0,
        show_orderblocks  => 0,
        show_trendchannel => 0,
        smc_cache_key     => undef,

        # --- Anchors (sección Volume): pivotes altos/bajos + pivotes
        #     perdidos ("missed"), réplica parcial de pivots.txt sin las
        #     líneas de conexión ---
        show_anchors      => 0,

        # --- Multi Anchored VWAP: un VWAP Anclado (con bandas) por cada
        #     pivote detectado por el motor de Anchors, en lugar de un único
        #     ancla elegida manualmente con click ---
        show_multi_vwap         => 0,
        multi_vwap_sigma_range  => 1,   # cuántas bandas de sigma se dibujan (1, 2 o 3)

        # --- VWAP Anclado (Anchored VWAP + banda de 2 sigma) ---
        show_vwap_anchored         => 0,
        vwap_anchor_index          => undef,
        # Modo de anclaje: 'session_start' (inicio de sesión / primera vela),
        # 'session_open' (apertura: primera vela de la última apertura de
        # mercado), 'bos_confirmed' (último BOS externo cerrado),
        # 'choch_confirmed' (último CHoCH externo cerrado) o 'pivot' (elegir
        # pivote: selección manual por click, lógica clásica). Por defecto
        # "inicio de sesión".
        vwap_anchor_mode           => 'session_start',
        vwap_anchor_selection_mode => 0,   # 1 mientras se espera el click sobre la vela de ancla
        vwap_cache_key             => undef,
        vwap_sigma_range           => 1,   # cuántas bandas de sigma se dibujan (1, 2 o 3)

        # --- Volume Profile Anclado (histograma de volumen por precio con
        #     zona de valor de 1 sigma) ---
        show_volume_profile_anchored         => 0,
        volume_profile_anchor_index          => undef,
        # Mismo esquema de modos de anclaje que el VWAP Anclado (ver
        # vwap_anchor_mode más arriba). Por defecto "inicio de sesión".
        volume_profile_anchor_mode           => 'session_start',
        volume_profile_anchor_selection_mode => 0, # 1 mientras se espera el click sobre la vela de ancla
        volume_profile_cache_key             => undef,
        volume_profile_sigma_range           => 1,   # cuántos rangos de sigma (líneas VAH/VAL) se dibujan (1, 2 o 3)

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
        fvg_engine       => Market::Indicators::FVG->new(
            fvg_history_nbr  => 5,
            min_gap_atr_mult => 0.0,
            reduce_mitigated => 0,
        ),
        structure_engine  => Market::Indicators::Structure->new(
            swing_size    => 50,
            internal_size => 5,
            eq_len        => 3,
            eq_threshold  => 0.1,
        ),
        # Niveles de Fibonacci calculados sobre la altura del último tramo
        # (leg) del ZigZag Externo (smc_engine).
        fibonacci_engine  => Market::Indicators::Fibonacci->new(),
        # Niveles de Soporte/Resistencia calculados sobre los mismos
        # pivotes estructurales del ZigZag Externo (smc_engine).
        levels_engine     => Market::Indicators::Levels->new(
            max_levels => 6,
        ),
        supertrend_engine => Market::Indicators::Supertrend->new(
            period     => 10,
            multiplier => 3.0,
            change_atr => 1,
        ),
        halftrend_engine  => Market::Indicators::HalfTrend->new(
            amplitude         => 2,
            channel_deviation => 2,
            atr_period        => 100,
        ),
        orderblocks_engine => Market::Indicators::OrderBlocks->new(
            swing_length    => 10,
            history_to_keep => 20,
            box_width       => 2.5,
            atr_period      => 50,
        ),
        trendchannel_engine => Market::Indicators::TrendChannel->new(
            length    => 100,
            deviation => 2,
        ),
        vwap_anchored_engine => Market::Indicators::VWAPAnchored->new(
            std_mult => 3,
        ),
        volume_profile_anchored_engine => Market::Indicators::VolumeProfileAnchored->new(
            num_bins => 24,
        ),
        # ZigZag Interno (Internal Structure) — Multi Time Frame, réplica de
        # zzmtf.txt.
        zigzag_internal_engine   => Market::Indicators::ZigzagInternal->new(
            period => 2,
        ),
        anchors_engine           => Market::Indicators::Anchors->new(
            length => 50,
        ),
        multi_vwap_engine        => Market::Indicators::MultiAnchoredVWAP->new(
            std_mult    => 1,
            max_anchors => 20,
        ),
        zigzag_ext_overlay       => Market::Overlays::Zigzag_External->new(),
        zigzag_internal_overlay  => Market::Overlays::Zigzag_Internal->new(),
        swing_overlay       => Market::Overlays::Swing->new(),
        bos_ext_overlay          => Market::Overlays::BOS_External->new(),
        bos_int_overlay          => Market::Overlays::BOS_Internal->new(),
        choch_ext_overlay        => Market::Overlays::ChoCH_External->new(),
        choch_int_overlay        => Market::Overlays::ChoCH_Internal->new(),
        eqh_overlay              => Market::Overlays::EQH->new(),
        eql_overlay              => Market::Overlays::EQL->new(),
        fibonacci_overlay        => Market::Overlays::Fibonacci->new(),
        levels_overlay           => Market::Overlays::Levels->new(),
        anchors_overlay          => Market::Overlays::Anchors->new(),
        multi_vwap_overlay       => Market::Overlays::MultiAnchoredVWAP->new(
            sigma_range => 1,
        ),
        
        liquidity_overlay        => Market::Overlays::Liquidity->new(),
        supertrend_overlay       => Market::Overlays::Supertrend->new(),
        halftrend_overlay        => Market::Overlays::HalfTrend->new(),
        fvg_overlay              => Market::Overlays::FVG->new(),
        orderblocks_overlay      => Market::Overlays::OrderBlocks->new(),
        trendchannel_overlay     => Market::Overlays::TrendChannel->new(),
        vwap_anchored_overlay    => Market::Overlays::VWAPAnchored->new(
            sigma_range => 1,
        ),
        volume_profile_anchored_overlay => Market::Overlays::VolumeProfileAnchored->new(
            sigma_range => 1,
        ),
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
    if ($self->{show_zigzag_ext} || $self->{show_zigzag_int} || $self->{show_swing}
     || $self->{show_bos_ext} || $self->{show_bos_int}
     || $self->{show_choch_ext} || $self->{show_choch_int}
     || $self->{show_eqh} || $self->{show_eql}
     || $self->{show_fibonacci}
     || $self->{show_levels}
     || $self->{show_fvg}
     || $self->{show_bsl} || $self->{show_ssl}
     || $self->{show_lq_sweep} || $self->{show_lq_grab} || $self->{show_lq_run}
     || $self->{show_supertrend} || $self->{show_halftrend} 
     || $self->{show_orderblocks} || $self->{show_trendchannel}
     || $self->{show_anchors} || $self->{show_multi_vwap}) {
        $self->update_smc_overlay($self->{market_data}->last_index());
        $self->update_zigzag_internal_overlay() if $self->{show_zigzag_int};

        my $scale = $self->{price_panel} ? $self->{price_panel}->{scale} : undef;

        if ($scale) {
            # Las franjas (FVG/OB) se dibujan primero, para que las líneas de
            # estructura (SMC/CHoCH/Liquidez) queden siempre visibles por encima.

            # Liquidez: líneas BSL/SSL y eventos Sweep/Grab/Run
            # Se dibuja primero (bajo las demás capas) para que las
            # líneas de estructura queden siempre por encima.
            if ($self->{show_bsl} || $self->{show_ssl}
             || $self->{show_lq_sweep} || $self->{show_lq_grab} || $self->{show_lq_run}) {
                $self->{liquidity_overlay}->{show_bsl}   = $self->{show_bsl};
                $self->{liquidity_overlay}->{show_ssl}   = $self->{show_ssl};
                $self->{liquidity_overlay}->{show_sweep} = $self->{show_lq_sweep};
                $self->{liquidity_overlay}->{show_grab}  = $self->{show_lq_grab};
                $self->{liquidity_overlay}->{show_run}   = $self->{show_lq_run};
                $self->{liquidity_overlay}->draw($self->{price_canvas}, $scale, $start, $end);
            }

            $self->{trendchannel_overlay}->draw($self->{price_canvas}, $scale, $start, $end)
                if $self->{show_trendchannel};
            $self->{fvg_overlay}->draw($self->{price_canvas}, $scale, $start, $end)
                if $self->{show_fvg};
            
            $self->{swing_overlay}->draw($self->{price_canvas}, $scale, $start, $end)
                if $self->{show_swing};

            $self->{zigzag_ext_overlay}->draw($self->{price_canvas}, $scale, $start, $end)
                if $self->{show_zigzag_ext};

            $self->{zigzag_internal_overlay}->draw($self->{price_canvas}, $scale, $start, $end)
                if $self->{show_zigzag_int};

            $self->{bos_ext_overlay}->draw($self->{price_canvas}, $scale, $start, $end)
                if $self->{show_bos_ext};

            $self->{bos_int_overlay}->draw($self->{price_canvas}, $scale, $start, $end)
                if $self->{show_bos_int};

            $self->{choch_ext_overlay}->draw($self->{price_canvas}, $scale, $start, $end)
                if $self->{show_choch_ext};

            $self->{choch_int_overlay}->draw($self->{price_canvas}, $scale, $start, $end)
                if $self->{show_choch_int};

            $self->{eqh_overlay}->draw($self->{price_canvas}, $scale, $start, $end)
                if $self->{show_eqh};

            $self->{eql_overlay}->draw($self->{price_canvas}, $scale, $start, $end)
                if $self->{show_eql};

            $self->{fibonacci_overlay}->draw($self->{price_canvas}, $scale, $start, $end)
                if $self->{show_fibonacci};

            $self->{levels_overlay}->draw($self->{price_canvas}, $scale, $start, $end)
                if $self->{show_levels};

            # Order Blocks (Supply/Demand): franjas, se dibujan junto a las
            # demás cajas (FVG) para quedar bajo las líneas de estructura.
            $self->{orderblocks_overlay}->draw($self->{price_canvas}, $scale, $start, $end)
                if $self->{show_orderblocks};

            # SuperTrend y HalfTrend: líneas de tendencia, se dibujan al
            # final para quedar por encima de zonas y estructura.
            $self->{supertrend_overlay}->draw($self->{price_canvas}, $scale, $start, $end)
                if $self->{show_supertrend};

            $self->{halftrend_overlay}->draw($self->{price_canvas}, $scale, $start, $end)
                if $self->{show_halftrend};

            $self->{anchors_overlay}->draw($self->{price_canvas}, $scale, $start, $end)
                if $self->{show_anchors};

            $self->{multi_vwap_overlay}->draw($self->{price_canvas}, $scale, $start, $end)
                if $self->{show_multi_vwap};

        }
    }

    # --- VWAP Anclado: independiente de la caché de Liquidez/SMC, ya que
    # depende de un ancla elegida manualmente por el usuario en lugar de la
    # temporalidad o el último índice. ---
    if ($self->{show_vwap_anchored} && defined $self->{vwap_anchor_index}) {
        $self->update_vwap_anchored_overlay($self->{market_data}->last_index());

        my $scale = $self->{price_panel} ? $self->{price_panel}->{scale} : undef;
        if ($scale) {
            $self->{vwap_anchored_overlay}->draw($self->{price_canvas}, $scale, $start, $end);
        }
    }

    # --- Volume Profile Anclado: igual que el VWAP Anclado, es
    # independiente de la caché de Liquidez/SMC porque depende de un ancla
    # elegida manualmente por el usuario. ---
    if ($self->{show_volume_profile_anchored} && defined $self->{volume_profile_anchor_index}) {
        $self->update_volume_profile_anchored_overlay($self->{market_data}->last_index());

        my $scale = $self->{price_panel} ? $self->{price_panel}->{scale} : undef;
        if ($scale) {
            $self->{volume_profile_anchored_overlay}->draw($self->{price_canvas}, $scale, $start, $end);
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

    my $structure_result = $self->{structure_engine}->calculate_until(
        $candles_full,
        $atr_values,
        $until_index
    );

    my $supertrend_result = $self->{supertrend_engine}->calculate_until(
        $candles_full,
        $until_index
    );

    my $halftrend_result = $self->{halftrend_engine}->calculate_until(
        $candles_full,
        $until_index
    );

    my $orderblocks_result = $self->{orderblocks_engine}->calculate_until(
        $candles_full,
        $until_index
    );

    my $trendchannel_result = $self->{trendchannel_engine}->calculate_until(
        $candles_full,
        $until_index
    );

    my $anchors_result = $self->{anchors_engine}->calculate_until(
        $candles_full,
        $until_index
    );

    # Multi Anchored VWAP: un VWAP Anclado por cada pivote de Anchors
    my $multi_vwap_result = $self->{multi_vwap_engine}->calculate_until(
        $candles_full,
        $anchors_result->{markers},
        $until_index
    );

    # Fibonacci: se calcula sobre la altura del último tramo (leg) del
    # ZigZag Externo, es decir, entre los dos últimos pivotes de
    # $smc_result->{structure} (la misma serie que dibuja zigzag_ext_overlay).
    my $fibonacci_result = $self->{fibonacci_engine}->calculate(
        $smc_result->{structure}
    );

    # Levels: Soporte/Resistencia sobre los mismos pivotes estructurales
    # ($smc_result->{structure}), usando el historial completo de velas
    # para detectar rupturas por cierre.
    my $levels_result = $self->{levels_engine}->calculate_until(
        $smc_result->{structure},
        $candles_full,
        $until_index
    );

    $self->{zigzag_ext_overlay}->set_result($smc_result);
    $self->{swing_overlay}->set_result($liq_result);
    $self->{liquidity_overlay}->set_result($liq_result);

    $self->{bos_ext_overlay}->set_result($structure_result);
    $self->{bos_int_overlay}->set_result($structure_result);

    $self->{choch_ext_overlay}->set_result($structure_result);
    $self->{choch_int_overlay}->set_result($structure_result);

    $self->{eqh_overlay}->set_result($structure_result);
    $self->{eql_overlay}->set_result($structure_result);

    $self->{fibonacci_overlay}->set_result($fibonacci_result);
    $self->{levels_overlay}->set_result($levels_result);

    $self->{fvg_overlay}->set_result($fvg_result);

    $self->{supertrend_overlay}->set_result($supertrend_result);
    $self->{halftrend_overlay}->set_result($halftrend_result);
    $self->{orderblocks_overlay}->set_result($orderblocks_result);
    $self->{trendchannel_overlay}->set_result($trendchannel_result);
    $self->{anchors_overlay}->set_result($anchors_result);
    $self->{multi_vwap_overlay}->set_result($multi_vwap_result);

    # Guardamos el resultado de Structure (eventos BOS/CHoCH) para que los
    # modos de anclaje 'bos_confirmed'/'choch_confirmed' del VWAP Anclado
    # puedan consultarlo sin depender de que sus capas visuales (BOS/CHoCH
    # Externo) estén activas.
    $self->{structure_result} = $structure_result;

    $self->{smc_cache_key} = $cache_key;
}

=head2 update_zigzag_internal_overlay()

Calcula (con caché) el "Zigzag Interno" (Multi Time Frame, réplica de
zzmtf.txt). A diferencia del resto de indicadores de estructura, éste NO
se calcula sobre la temporalidad activa del gráfico, sino sobre la
temporalidad elegida en C<zigzag_internal_tf> (15m/1h/2h/4h/1d). Los
pivotes resultantes se "traducen" al espacio de índices de la
temporalidad activa mediante C<MarketData::index_for_time> para poder
dibujarse con la misma escala que el resto del gráfico.

=cut

sub update_zigzag_internal_overlay {
    my ($self) = @_;

    my $market_data = $self->{market_data};
    return unless $market_data;

    my $mtf = $self->{zigzag_internal_tf} // '1h';
    my $chart_tf = $market_data->{timeframe} // '1m';

    my $mtf_candles = $market_data->get_timeframe_candles($mtf);
    my $mtf_count   = scalar @$mtf_candles;

    my $cache_key = join(':', $chart_tf, $mtf, $mtf_count, $market_data->last_index());
    return if defined $self->{zigzag_internal_cache_key}
           && $self->{zigzag_internal_cache_key} eq $cache_key;

    my $result = $self->{zigzag_internal_engine}->calculate($mtf_candles);

    # Traducimos cada pivote (calculado en el espacio de índices/tiempo de
    # $mtf) a una vela REAL y visible de la temporalidad activa del gráfico:
    # buscamos, dentro del bloque horario de esa vela MTF, cuál vela de la
    # temporalidad activa tiene el high/low exacto que originó el pivote.
    # Esto evita que el punto quede "flotando" sin tocar ninguna mecha.
    my @translated;
    for my $p (@{ $result->{pivots} }) {
        my $mtf_idx  = $p->{index};
        my $time_from = $p->{time};
        my $time_to   = (defined $mtf_candles->[$mtf_idx + 1])
                       ? $mtf_candles->[$mtf_idx + 1]->{time}
                       : undef;
        my $ptype = ($p->{dir} == 1) ? 'high' : 'low';

        my ($idx, $exact_price) = $market_data->find_pivot_index($time_from, $time_to, $ptype);
        next unless defined $idx;

        push @translated, {
            index => $idx,
            time  => $p->{time},
            price => $exact_price,
            dir   => $p->{dir},
        };
    }

    $self->{zigzag_internal_overlay}->set_result({ pivots => \@translated });
    $self->{zigzag_internal_cache_key} = $cache_key;
}

=head2 set_zigzag_internal_timeframe($tf)

Cambia la temporalidad "Multi Time Frame" usada por el Zigzag Interno
(15m, 1h, 2h, 4h o 1d) e invalida su caché para forzar el recálculo.

=cut

sub set_zigzag_internal_timeframe {
    my ($self, $tf) = @_;
    return unless defined $tf;

    $self->{zigzag_internal_tf} = $tf;
    $self->{zigzag_internal_cache_key} = undef;

    $self->request_render();
}

=head2 update_vwap_anchored_overlay($until_index)

Calcula (con caché) la serie del VWAP Anclado desde la vela de ancla
($self->{vwap_anchor_index}) hasta $until_index, y actualiza la capa visual.
El caché evita recalcular en cada render (por ejemplo al mover el
crosshair), recalculando sólo cuando cambia la temporalidad, el ancla o el
índice de la última vela disponible (nueva vela recibida).

=cut

sub update_vwap_anchored_overlay {
    my ($self, $until_index) = @_;
    return unless defined $until_index && $until_index >= 0;

    my $mode = $self->{vwap_anchor_mode} // 'pivot';
    if ($mode ne 'pivot') {
        # Los modos automáticos ('session_start', 'session_open',
        # 'bos_confirmed', 'choch_confirmed') se recalculan en cada render
        # para que el ancla siga a la última sesión/BOS/CHoCH confirmado a
        # medida que llegan velas nuevas.
        if ($mode eq 'bos_confirmed' || $mode eq 'choch_confirmed') {
            $self->update_smc_overlay($until_index);
        }

        my $idx = $self->compute_vwap_anchor_index($mode, $until_index);
        $self->{vwap_anchor_index} = $idx if defined $idx;
    }

    my $anchor_index = $self->{vwap_anchor_index};
    return unless defined $anchor_index;

    my $market_data = $self->{market_data};
    my $tf = $market_data->{timeframe} // '1m';

    my $cache_key = join(':', $tf, $anchor_index, $until_index);
    return if defined $self->{vwap_cache_key} && $self->{vwap_cache_key} eq $cache_key;

    my $candles_full = $market_data->get_slice(0, $until_index);

    my $vwap_result = $self->{vwap_anchored_engine}->calculate_until(
        $candles_full,
        $anchor_index,
        $until_index
    );

    $self->{vwap_anchored_overlay}->set_result($vwap_result);
    $self->{vwap_cache_key} = $cache_key;
}

=head2 activate_vwap_anchor_selection()

Activa el "modo de selección de ancla": la próxima vez que el usuario haga
click sobre una vela del panel de precios, esa vela se usará como ancla del
VWAP (igual que la herramienta "Anchored VWAP" de TradingView). Mientras
este modo está activo, el arrastre normal (panning) queda desactivado y el
cursor cambia para indicar que se espera un click de selección.

=cut

sub activate_vwap_anchor_selection {
    my ($self) = @_;
    $self->{vwap_anchor_selection_mode} = 1;

    if (my $cv = $self->{price_canvas}) {
        $cv->configure(-cursor => 'target');
    }
}

=head2 cancel_vwap_anchor_selection()

Cancela el modo de selección de ancla sin activar el indicador (por ejemplo
al pulsar Escape). Devuelve el cursor del panel de precios a su estado
normal.

=cut

sub cancel_vwap_anchor_selection {
    my ($self) = @_;
    $self->{vwap_anchor_selection_mode} = 0;

    if (my $cv = $self->{price_canvas}) {
        $cv->configure(-cursor => 'crosshair');
    }
}

=head2 set_vwap_anchor($index)

Fija la vela de ancla del VWAP a partir del índice global recibido (por
ejemplo, resultado de un click sobre el panel de precios), activa el
indicador y fuerza su recálculo.

=cut

sub set_vwap_anchor {
    my ($self, $index) = @_;
    return unless defined $index;

    my $market_data = $self->{market_data};
    my $last_index  = $market_data ? $market_data->last_index() : undef;
    return unless defined $last_index;

    $index = 0          if $index < 0;
    $index = $last_index if $index > $last_index;

    $self->{vwap_anchor_index}  = $index;
    $self->{vwap_anchor_mode}   = 'pivot';
    $self->{show_vwap_anchored} = 1;
    $self->{vwap_cache_key}     = undef;   # fuerza recálculo inmediato

    $self->cancel_vwap_anchor_selection();
    $self->{on_vwap_anchor_set}->($index)
        if ref($self->{on_vwap_anchor_set}) eq 'CODE';
    $self->request_render();
}

=head2 set_vwap_anchor_mode($mode)

Cambia el modo de anclaje del VWAP Anclado. Modos soportados:

  'session_start'   => primera vela de todo el historial ("inicio de sesión")
  'session_open'    => primera vela de la última apertura de mercado
                        detectada (tras el mayor hueco de tiempo reciente)
  'bos_confirmed'   => vela de confirmación (cierre) del último BOS externo
  'choch_confirmed' => vela de confirmación (cierre) del último CHoCH externo
  'pivot'           => selección manual por click ("elegir pivote", lógica
                        clásica)

Para los modos automáticos (todos salvo 'pivot'), el ancla se calcula de
inmediato con la última vela disponible (sin esperar un click), se activa
el indicador y se fuerza su recálculo. Para 'pivot' sólo se guarda el modo;
es el checkbutton/click del usuario el que efectivamente fija el ancla.

=cut

sub set_vwap_anchor_mode {
    my ($self, $mode) = @_;
    return unless defined $mode;

    $self->{vwap_anchor_mode} = $mode;
    $self->cancel_vwap_anchor_selection();

    if ($mode ne 'pivot') {
        my $market_data = $self->{market_data};
        my $last_index  = $market_data ? $market_data->last_index() : undef;

        if (defined $last_index) {
            $self->update_smc_overlay($last_index)
                if $mode eq 'bos_confirmed' || $mode eq 'choch_confirmed';

            my $idx = $self->compute_vwap_anchor_index($mode, $last_index);
            $self->{vwap_anchor_index} = $idx if defined $idx;
        }

        $self->{show_vwap_anchored} = 1;
        $self->{vwap_cache_key}     = undef;   # fuerza recálculo inmediato
    }

    $self->request_render();
}

=head2 compute_vwap_anchor_index($mode, $until_index)

Calcula el índice de ancla correspondiente a C<$mode> (ver
C<set_vwap_anchor_mode>), evaluado hasta C<$until_index>. Devuelve C<undef>
si el modo es 'pivot' (anclaje manual, no se recalcula solo).

=cut

sub compute_vwap_anchor_index {
    my ($self, $mode, $until_index) = @_;
    return undef unless defined $until_index;

    if ($mode eq 'session_start') {
        return 0;
    }
    elsif ($mode eq 'session_open') {
        my $market_data = $self->{market_data};
        my $idx = $market_data ? $market_data->find_last_session_open_index($until_index) : undef;
        return defined $idx ? $idx : 0;
    }
    elsif ($mode eq 'bos_confirmed') {
        my $idx = $self->find_last_structure_event_index($until_index, 'BOS');
        return defined $idx ? $idx : 0;
    }
    elsif ($mode eq 'choch_confirmed') {
        my $idx = $self->find_last_structure_event_index($until_index, 'CHoCH');
        return defined $idx ? $idx : 0;
    }

    return undef;
}

=head2 find_last_structure_event_index($until_index, $prefix)

Busca, entre los eventos de estructura EXTERNA calculados por
C<update_smc_overlay> ($self->{structure_result}{events}), el de mayor
índice cuyo tipo empieza con C<$prefix> ('BOS' o 'CHoCH') y cuyo índice no
supera C<$until_index>. Devuelve el índice de esa vela (la vela de
confirmación/cierre del BOS o CHoCH) o C<undef> si todavía no se detectó
ninguno.

=cut

sub find_last_structure_event_index {
    my ($self, $until_index, $prefix) = @_;
    return undef unless defined $until_index && defined $prefix;

    my $events = ($self->{structure_result} && $self->{structure_result}->{events})
        ? $self->{structure_result}->{events}
        : [];

    my $best;
    for my $ev (@$events) {
        next unless defined $ev->{tier} && $ev->{tier} eq 'external';
        next unless defined $ev->{type} && index($ev->{type}, $prefix) == 0;
        next unless defined $ev->{index};
        next if $ev->{index} > $until_index;

        $best = $ev->{index} if !defined $best || $ev->{index} > $best;
    }

    return $best;
}

=head2 set_vwap_sigma_range($n)

Configura cuántas bandas de desviación estándar se muestran para el VWAP
Anclado (1, 2 o 3 sigmas). Actualiza la capa visual y redibuja de inmediato
si el indicador está activo; no requiere recalcular el indicador, ya que
éste siempre calcula las tres bandas.

=cut

sub set_vwap_sigma_range {
    my ($self, $n) = @_;
    return unless defined $n;

    $n = 1 if $n < 1;
    $n = 3 if $n > 3;

    $self->{vwap_sigma_range} = $n;
    $self->{vwap_anchored_overlay}->set_sigma_range($n)
        if $self->{vwap_anchored_overlay};

    $self->request_render();
}

=head2 set_volume_profile_sigma_range($n)

Configura cuántos rangos de desviación estándar (líneas VAH/VAL) se
muestran para el Volume Profile Anclado (1, 2 o 3 sigmas). A diferencia del
VWAP Anclado, estos rangos se dibujan siempre como líneas sueltas, nunca
como bandas/canales rellenos. Actualiza la capa visual y redibuja de
inmediato si el indicador está activo; no requiere recalcular el
indicador, ya que éste siempre calcula los tres rangos.

=cut

sub set_volume_profile_sigma_range {
    my ($self, $n) = @_;
    return unless defined $n;

    $n = 1 if $n < 1;
    $n = 3 if $n > 3;

    $self->{volume_profile_sigma_range} = $n;
    $self->{volume_profile_anchored_overlay}->set_sigma_range($n)
        if $self->{volume_profile_anchored_overlay};

    $self->request_render();
}

=head2 set_multi_vwap_sigma_range($n)

Configura cuántas bandas de desviación estándar (1, 2 o 3 sigmas) se
muestran para TODAS las líneas del Multi Anchored VWAP. Actualiza la capa
visual y redibuja de inmediato; no requiere recalcular el indicador, ya
que éste siempre calcula las tres bandas para cada ancla.

=cut

sub set_multi_vwap_sigma_range {
    my ($self, $n) = @_;
    return unless defined $n;

    $n = 1 if $n < 1;
    $n = 3 if $n > 3;

    $self->{multi_vwap_sigma_range} = $n;
    $self->{multi_vwap_overlay}->set_sigma_range($n)
        if $self->{multi_vwap_overlay};

    $self->request_render();
}

=head2 update_volume_profile_anchored_overlay($until_index)

Calcula (con caché) el histograma del Volume Profile Anclado desde la vela
de ancla ($self->{volume_profile_anchor_index}) hasta $until_index, y
actualiza la capa visual. El caché evita recalcular en cada render (por
ejemplo al mover el crosshair), recalculando sólo cuando cambia la
temporalidad, el ancla o el índice de la última vela disponible (nueva vela
recibida).

=cut

sub update_volume_profile_anchored_overlay {
    my ($self, $until_index) = @_;
    return unless defined $until_index && $until_index >= 0;

    my $mode = $self->{volume_profile_anchor_mode} // 'pivot';
    if ($mode ne 'pivot') {
        # Los modos automáticos ('session_start', 'session_open',
        # 'bos_confirmed', 'choch_confirmed') se recalculan en cada render
        # para que el ancla siga a la última sesión/BOS/CHoCH confirmado a
        # medida que llegan velas nuevas.
        if ($mode eq 'bos_confirmed' || $mode eq 'choch_confirmed') {
            $self->update_smc_overlay($until_index);
        }

        my $idx = $self->compute_vwap_anchor_index($mode, $until_index);
        $self->{volume_profile_anchor_index} = $idx if defined $idx;
    }

    my $anchor_index = $self->{volume_profile_anchor_index};
    return unless defined $anchor_index;

    my $market_data = $self->{market_data};
    my $tf = $market_data->{timeframe} // '1m';

    my $cache_key = join(':', $tf, $anchor_index, $until_index);
    return if defined $self->{volume_profile_cache_key} && $self->{volume_profile_cache_key} eq $cache_key;

    my $candles_full = $market_data->get_slice(0, $until_index);

    my $vp_result = $self->{volume_profile_anchored_engine}->calculate_until(
        $candles_full,
        $anchor_index,
        $until_index
    );

    $self->{volume_profile_anchored_overlay}->set_result($vp_result);
    $self->{volume_profile_cache_key} = $cache_key;
}

=head2 activate_volume_profile_anchor_selection()

Activa el "modo de selección de ancla" del Volume Profile: la próxima vez
que el usuario haga click sobre una vela del panel de precios, esa vela se
usará como ancla del histograma (igual que la herramienta "Anchored Volume
Profile" de TradingView). Mientras este modo está activo, el arrastre
normal (panning) queda desactivado y el cursor cambia para indicar que se
espera un click de selección.

=cut

sub activate_volume_profile_anchor_selection {
    my ($self) = @_;
    $self->{volume_profile_anchor_selection_mode} = 1;

    if (my $cv = $self->{price_canvas}) {
        $cv->configure(-cursor => 'target');
    }
}

=head2 cancel_volume_profile_anchor_selection()

Cancela el modo de selección de ancla sin activar el indicador (por ejemplo
al pulsar Escape). Devuelve el cursor del panel de precios a su estado
normal.

=cut

sub cancel_volume_profile_anchor_selection {
    my ($self) = @_;
    $self->{volume_profile_anchor_selection_mode} = 0;

    if (my $cv = $self->{price_canvas}) {
        $cv->configure(-cursor => 'crosshair');
    }
}

=head2 set_volume_profile_anchor($index)

Fija la vela de ancla del Volume Profile a partir del índice global
recibido (por ejemplo, resultado de un click sobre el panel de precios),
activa el indicador y fuerza su recálculo.

=cut

sub set_volume_profile_anchor {
    my ($self, $index) = @_;
    return unless defined $index;

    my $market_data = $self->{market_data};
    my $last_index  = $market_data ? $market_data->last_index() : undef;
    return unless defined $last_index;

    $index = 0          if $index < 0;
    $index = $last_index if $index > $last_index;

    $self->{volume_profile_anchor_index}  = $index;
    $self->{volume_profile_anchor_mode}   = 'pivot';
    $self->{show_volume_profile_anchored} = 1;
    $self->{volume_profile_cache_key}     = undef;   # fuerza recálculo inmediato

    $self->cancel_volume_profile_anchor_selection();
    $self->{on_volume_profile_anchor_set}->($index)
        if ref($self->{on_volume_profile_anchor_set}) eq 'CODE';
    $self->request_render();
}

=head2 set_volume_profile_anchor_mode($mode)

Cambia el modo de anclaje del Volume Profile Anclado. Mismos modos que
C<set_vwap_anchor_mode>: 'session_start', 'session_open', 'bos_confirmed',
'choch_confirmed' o 'pivot' (selección manual por click).

Para los modos automáticos, el ancla se calcula de inmediato con la última
vela disponible (sin esperar un click), se activa el indicador y se fuerza
su recálculo. Para 'pivot' sólo se guarda el modo.

=cut

sub set_volume_profile_anchor_mode {
    my ($self, $mode) = @_;
    return unless defined $mode;

    $self->{volume_profile_anchor_mode} = $mode;
    $self->cancel_volume_profile_anchor_selection();

    if ($mode ne 'pivot') {
        my $market_data = $self->{market_data};
        my $last_index  = $market_data ? $market_data->last_index() : undef;

        if (defined $last_index) {
            $self->update_smc_overlay($last_index)
                if $mode eq 'bos_confirmed' || $mode eq 'choch_confirmed';

            my $idx = $self->compute_vwap_anchor_index($mode, $last_index);
            $self->{volume_profile_anchor_index} = $idx if defined $idx;
        }

        $self->{show_volume_profile_anchored} = 1;
        $self->{volume_profile_cache_key}     = undef;   # fuerza recálculo inmediato
    }

    $self->request_render();
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

    # Click derecho: cancela la selección de vela de ancla del VWAP o del
    # Volume Profile, si alguna está activa
    if ($price_cv) {
        $price_cv->Tk::bind('<Button-3>', sub {
            if ($self->{vwap_anchor_selection_mode}) {
                $self->cancel_vwap_anchor_selection();
                $self->{on_vwap_selection_cancelled}->()
                    if ref($self->{on_vwap_selection_cancelled}) eq 'CODE';
            }
            if ($self->{volume_profile_anchor_selection_mode}) {
                $self->cancel_volume_profile_anchor_selection();
                $self->{on_volume_profile_selection_cancelled}->()
                    if ref($self->{on_volume_profile_selection_cancelled}) eq 'CODE';
            }
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
            return unless $e;

            # --- Selección de vela de ancla para el VWAP Anclado ---
            # Si estamos esperando el click de anclaje (activado desde el
            # menú de indicadores), el click sobre el panel de precios elige
            # la vela y NO debe iniciar un arrastre/panning normal.
            if ($self->{vwap_anchor_selection_mode} && $canvas == $price_cv) {
                my $scale = $self->{price_panel} ? $self->{price_panel}->{scale} : undef;
                if ($scale) {
                    my $index = $scale->x_to_index($e->x);
                    $self->set_vwap_anchor($index);
                }
                return;
            }

            # --- Selección de vela de ancla para el Volume Profile Anclado ---
            if ($self->{volume_profile_anchor_selection_mode} && $canvas == $price_cv) {
                my $scale = $self->{price_panel} ? $self->{price_panel}->{scale} : undef;
                if ($scale) {
                    my $index = $scale->x_to_index($e->x);
                    $self->set_volume_profile_anchor($index);
                }
                return;
            }

            $self->{last_drag_x} = $e->x;
            $self->{last_drag_y} = $e->y;
        });

        $canvas->Tk::bind('<B1-Motion>', sub {
            my $widget = shift; my $e = $widget->XEvent;
            return if $self->{vwap_anchor_selection_mode};
            return if $self->{volume_profile_anchor_selection_mode};
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

    # Escape cancela la selección de vela de ancla del VWAP o del Volume
    # Profile, si alguna está activa
    $mw->Tk::bind('<Key-Escape>', sub {
        if ($self->{vwap_anchor_selection_mode}) {
            $self->cancel_vwap_anchor_selection();
            $self->{on_vwap_selection_cancelled}->()
                if ref($self->{on_vwap_selection_cancelled}) eq 'CODE';
        }
        if ($self->{volume_profile_anchor_selection_mode}) {
            $self->cancel_volume_profile_anchor_selection();
            $self->{on_volume_profile_selection_cancelled}->()
                if ref($self->{on_volume_profile_selection_cancelled}) eq 'CODE';
        }
    });
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

    # compute_window() puede devolver un $end más allá del último índice
    # real del array (por ejemplo al desplazarse totalmente hacia la
    # derecha, dejando espacio vacío para velas futuras). Si no se
    # recorta, $velas->[$end] queda undef, no se genera el pivote de
    # cierre y, como fill_between_pivots() exige al menos 2 pivotes,
    # se pierden TODAS las etiquetas de tiempo. Recortamos siempre
    # contra los límites reales de datos para evitarlo.
    my $max_idx = $#$velas;
    return [] if $max_idx < 0;

    $start = 0        if $start < 0;
    $end   = $max_idx if $end > $max_idx;
    return [] if $start > $end;

    my @pivots;
    my $ultimo_dia = "";

    # Incluimos un pivote sintético al inicio de la ventana para que
    # fill_between_pivots() pueda rellenar desde el borde izquierdo.
    #
    # BUG CORREGIDO: si la ventana visible empieza JUSTO en la primera
    # vela de un día nuevo (ej. el usuario se desplaza hasta dejar como
    # primera vela visible el open del día 12), este pivote inicial
    # tomaba ese día como "$ultimo_dia" desde el arranque, así que el
    # bucle de abajo nunca detectaba el cambio de día (no hay una vela
    # anterior *visible* con la que comparar) y la etiqueta de ese día
    # jamás se generaba — el pivote se marcaba 'start' (no dibujable) en
    # vez de 'day'. Esto explica por qué el número de día "a veces"
    # desaparecía: dependía de que el cambio de día cayera exactamente
    # en el borde izquierdo de la ventana visible.
    #
    # Para corregirlo, miramos la vela justo ANTERIOR a la ventana
    # (fuera de lo visible, pero existente en los datos) para saber si
    # el día ya había cambiado antes de $start. Si es así, el pivote
    # inicial se marca como 'day' (dibujable) en vez de 'start'.
    {
        my $primera = $velas->[$start];
        if ($primera) {
            ($ultimo_dia) = ($primera->{time} // "") =~ /^(\d{4}-\d{2}-\d{2})/;
            $ultimo_dia //= "";

            my $es_cambio_de_dia_en_el_borde = 0;
            if ($start > 0) {
                my $anterior = $velas->[$start - 1];
                if ($anterior) {
                    my ($dia_anterior) = ($anterior->{time} // "") =~ /^(\d{4}-\d{2}-\d{2})/;
                    $es_cambio_de_dia_en_el_borde = 1
                        if defined $dia_anterior && $dia_anterior ne "" && $dia_anterior ne $ultimo_dia;
                }
            }

            push @pivots, {
                indice_absoluto => $start,
                indice_relativo => 0,
                timestamp       => $primera->{time} // "",
                type            => $es_cambio_de_dia_en_el_borde ? 'day' : 'start',
            };
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

    # Pivote sintético al final para cerrar el último intervalo. Al estar
    # $end ya recortado a $max_idx, esto siempre corresponde a una vela
    # real (la última vela visible, o la última vela de todo el
    # histórico si la ventana se desplazó más allá de los datos).
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
#   2. Elige el intervalo "bonito" más fino que quepa sin saturar, de entre
#      un set reducido y limpio: 1 día, 3 h, 1 h 30, 1 h, 30 min, 15 min,
#      5 min, 1 min (igual que TradingView).
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

    my $has_day = grep { $_->{type} eq 'day' } @$pivots;

    unless ($has_day) {
        $pivots->[0]{type}  = 'hour';
        $pivots->[-1]{type} = 'hour';
    }

    # Pasos "bonitos" en minutos, de más fino a más grueso. Este conjunto
    # reducido evita pasos "raros" (7, 9, 20 min...) y usa únicamente
    # intervalos que un trader reconoce al vuelo, igual que TradingView:
    # 1 min, 5 min, 15 min, 30 min, 1 h, 1 h 30, 3 h, 1 día.
    my @steps = (1, 5, 15, 30, 60, 90, 180, 1440);

    # Espacio mínimo entre etiquetas en píxeles. Debe reflejar el ancho
    # REAL que ocupa una etiqueta de tiempo renderizada (mismo criterio
    # que usa remove_overlaps(): "HH:MM" son 5 caracteres × 8px + 12px de
    # margen = 52px; redondeamos a 60px de margen de seguridad).
    #
    # Con un valor de 1px (el anterior) esta comprobación no filtraba
    # casi nada, así que casi siempre se elegía el paso más fino posible
    # (1 minuto) y se generaba una etiqueta por cada vela del intervalo.
    # remove_overlaps() terminaba recortando ese exceso según el espacio
    # en pantalla, pero al filtrar por posición X en vez de por minutos
    # "bonitos" el resultado eran horas arbitrarias (02:24, 04:48, ...)
    # en vez de marcas limpias (03:00, 06:00, ...). Al usar aquí el
    # ancho real, el paso "bonito" correcto (1h, 3h, 1 día, etc.) se
    # elige desde el principio y remove_overlaps() sólo actúa como red
    # de seguridad ante casos límite, no como filtro principal.
    my $min_spacing = 45;

    my @result;

    for my $k (0 .. $#$pivots - 1) {
        my $p1 = $pivots->[$k];
        my $p2 = $pivots->[$k + 1];

        # Añadir el pivote p1 si es dibujable (day)
        push @result, $p1 if $p1->{type} ne 'start';

        my $x1 = $scale->index_to_center_x($p1->{indice_absoluto});
        my $x2 = $scale->index_to_center_x($p2->{indice_absoluto});
        my $pixel_distance = $x2 - $x1;

        next if $pixel_distance <= 0;

        # ¿Cuántas etiquetas intermedias caben?
        my $max_labels = int($pixel_distance / $min_spacing);
        next if $max_labels < 1;

        # Elegir el menor paso que produzca <= max_labels etiquetas.
        # Para estimarlo necesitamos cuántos minutos "reales" hay entre los
        # pivotes.
        #
        # BUG CORREGIDO: antes se usaba _ts_diff_minutes() para calcular la
        # diferencia de CALENDARIO entre los dos timestamps. Eso se rompe en
        # cuanto hay un hueco real en los datos (fin de semana, sesión de
        # mercado cerrada, feriado): p.ej. el viernes cierra a las 15:59 y
        # el domingo reabre a las 17:00 — calendario dice "~1650 minutos de
        # diferencia", pero en realidad solo hay ~159 velas reales en ese
        # tramo. Con ese span inflado se elegía un paso demasiado grueso
        # (90 min) y sólo sobrevivía UNA etiqueta suelta en vez de la serie
        # completa cada 15 min.
        #
        # La cantidad de velas REALES entre los pivotes (indice_absoluto)
        # es siempre la medida correcta del espacio de tiempo "denso" que
        # hay que repartir en píxeles, sin importar los huecos de calendario
        # que haya por fuera. La multiplicamos por la duración de cada vela
        # según la temporalidad activa para obtener minutos.
        my $bar_minutes  = $self->_bar_minutes();
        my $index_span   = $p2->{indice_absoluto} - $p1->{indice_absoluto};
        my $minutos_span = $index_span * $bar_minutes;
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

    # Añadir el último pivote. El pivote final es siempre sintético
    # (type => 'end', "marcador interno") porque se genera para poder
    # calcular el relleno del último intervalo, pero su timestamp SÍ
    # corresponde a una vela real (la última visible) y por tanto debe
    # dibujarse igualmente; de lo contrario la etiqueta de tiempo del
    # borde derecho del gráfico nunca aparece en pantalla. Lo
    # convertimos a tipo 'hour' para que se renderice como el resto de
    # etiquetas horarias.
    my $last = $pivots->[-1];
    if ($last) {
        if ($last->{type} eq 'end') {
            push @result, { %$last, type => 'hour' };
        }
        else {
            push @result, $last;
        }
    }

    # Ordenar por posición
    @result = sort { $a->{indice_absoluto} <=> $b->{indice_absoluto} } @result;

    return \@result;
}

# -----------------------------------------------------------------------------
# label_display_text($lbl)
#
# Devuelve el texto CORTO que realmente se dibuja para una etiqueta del eje
# de tiempo: el número de día para los pivotes 'day' (ej. "9"), o "HH:MM"
# para el resto. Debe ser la ÚNICA fuente de verdad para ese texto, usada
# tanto para medir anchos reales (remove_overlaps) como para dibujar
# (PricePanel::draw_time_axis) — así ambos sitios están siempre de acuerdo.
# -----------------------------------------------------------------------------
sub label_display_text {
    my ($self, $lbl) = @_;
    my $texto = $lbl->{timestamp} // "";

    if ($lbl->{type} && $lbl->{type} eq 'day' && $texto =~ /^\d{4}-\d{2}-(\d{2})/) {
        return "" . int($1);
    }

    my ($hora) = $texto =~ /T?(\d{2}:\d{2})/;
    return defined $hora ? $hora : $texto;
}

# -----------------------------------------------------------------------------
# remove_overlaps(\@labels)
#
# Descarta etiquetas cuya posición X esté demasiado cerca de la anterior.
# La anchura de cada texto se estima sobre el texto REALMENTE dibujado
# (label_display_text): caracteres × 8 px + margen 12 px. Antes se medía
# la longitud del timestamp completo ("2026-07-09 00:00:00", 19
# caracteres) en vez del "9" que se ve en pantalla, lo que sobreestimaba
# muchísimo el ancho de los pivotes de día y descartaba etiquetas de más
# — sobre todo notorio al hacer zoom out, donde predominan los pivotes
# de día muy próximos entre sí en píxeles.
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

        # Estimar anchura del texto REALMENTE dibujado
        my $text  = $self->label_display_text($lbl);
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
# _bar_minutes()
#
# Duración en minutos de cada vela según la temporalidad activa del
# gráfico (usa el mismo mapa %BLOCK_MINUTES que Market::MarketData).
# Por defecto asume 1 minuto (temporalidad '1m') si no se puede determinar.
# -----------------------------------------------------------------------------
sub _bar_minutes {
    my ($self) = @_;
    my $tf = $self->{market_data} ? ($self->{market_data}->{timeframe} // '1m') : '1m';
    return $Market::MarketData::BLOCK_MINUTES{$tf} || 1;
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
