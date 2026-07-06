# use strict;
# use warnings;
# use FindBin;
# use lib "$FindBin::Bin"; 

# use Tk;
# use Tk::BrowseEntry; # Para el menú desplegable (Drop-down)
# use Market::MarketData;
# use Market::IndicatorManager;
# use Market::ChartEngine;
# use Market::Indicators::ATR;
# use Market::Indicators::Liquidity;
# use Market::Indicators::SMC_Structures;
# use Market::Overlays::Liquidity;
# use Market::Overlays::SMC_Structures;

# my $mw = MainWindow->new();
# $mw->title("Replica Financiera TradingView - EPN (Fase 2)");

# my $width  = $mw->screenwidth;
# my $height = $mw->screenheight;
# $mw->geometry("${width}x${height}+0+0");

# # Declaración adelantada
# my $chart_engine;
# my $liquidity_overlay;
# my $smc_overlay;

# # --- BARRA SUPERIOR DE CONTROL DE INTERFAZ ---
# my $control_panel = $mw->Frame(-bg => '#fbfcf8', -relief => 'raised', -bd => 1)
#                        ->pack(-side => 'top', -fill => 'x', -ipady => 4);

# my $tf_label = $control_panel->Label(
#     -text => "Temporalidad:",
#     -bg   => '#fbfcf8',
#     -fg   => '#b1b5be',
#     -font => 'Arial 10 bold'
# )->pack(-side => 'left', -padx => 10);

# my @timeframes = ('1m', '5m', '15m', '1h', '2h', '4h', 'D', 'W');
# my $selected_tf = '1m';
# my @vista_opciones = ('BSL/SSL', 'Sweep', 'Grab', 'ZZ-Externo', 'ZZ-Interno', 'FVG', 'Swings');
# my $selected_vista = 'ZZ-Externo';
# # --- 1. Menú Desplegable para Temporalidades (BrowseEntry) ---
# my $tf_menu = $control_panel->BrowseEntry(
#     -choices      => \@timeframes,
#     -variable     => \$selected_tf,
#     -bg           => '#ffffff',
#     -fg           => '#131722',
#     -state        => 'readonly',
#     -width        => 5,
#     -browsecmd    => sub {
#         my ($widget, $tf) = @_;
        
#         if (defined $chart_engine) {
#             $chart_engine->set_timeframe($tf); 
#             $chart_engine->reset_view();
#             $chart_engine->render();
#         }
#     }
# )->pack(-side => 'left', -padx => 3);

# $control_panel->Label(-text => " | ", -bg => '#fbfcf8', -fg => '#d1d4dc')->pack(-side => 'left', -padx => 10);

# $tf_menu->insert('end', @timeframes); # Insertamos las opciones de tu array @timeframes


# $control_panel->Label(
#     -text => " | Vista:",
#     -bg   => '#fbfcf8',
#     -fg   => '#b1b5be',
#     -font => 'Arial 10 bold'
# )->pack(-side => 'left');

# my $capas_menubutton = $control_panel->Menubutton(
#     -text       => "Indicadores",
#     -bg         => '#ffffff',
#     -fg         => '#131722',
#     -relief     => 'raised',
#     -bd         => 1,
#     -cursor     => 'hand2',
#     -tearoff    => 0 # Evita que el menú se pueda desprender en una ventana flotante
# )->pack(-side => 'left', -padx => 3);


# # Creamos un widget Menu hijo explícito asociado al Menubutton
# my $capas_menu = $capas_menubutton->Menu(-tearoff => 0);
# $capas_menubutton->configure(-menu => $capas_menu);

# # Definimos la configuración mapeando los campos internos de tus Overlays
# my @config_botones = (
#     { texto => 'BSL/SSL',      ref => \$liquidity_overlay->{show_bsl_ssl} },
#     { texto => 'Sweep',        ref => \$liquidity_overlay->{show_sweep} },
#     { texto => 'Grab',         ref => \$liquidity_overlay->{show_grab} },
#     { texto => 'ZZ-Externo',   ref => \$liquidity_overlay->{show_zz_ext} },
#     { texto => 'ZZ-Interno',   ref => \$liquidity_overlay->{show_zz_int} },
#     { texto => 'FVG',          ref => \$smc_overlay->{show_fvg} },
#     { texto => 'Swings',       ref => \$smc_overlay->{show_swings} },
# );

# # Construimos las opciones añadiéndolas directamente al objeto Menu creado arriba
# foreach my $btn (@config_botones) {
#     # Inicializamos por defecto en 1 (Habilitado) si no tiene valor asignado aún
#     ${$btn->{ref}} //= 1; 

#     # Inyectamos una entrada tipo checkbutton en el menú
#     $capas_menu->checkbutton(
#         -label     => $btn->{texto},
#         -variable  => $btn->{ref},
#         -onvalue   => 1,
#         -offvalue  => 0,
#         -command   => sub {
#             # Lógica reactiva para activar/desactivar la bandera global del overlay de Liquidez
#             if ($btn->{texto} =~ /BSL|Sweep|Grab|ZZ/) {
#                 $liquidity_overlay->{active} = (
#                     ($liquidity_overlay->{show_bsl_ssl} // 0) == 1 ||
#                     ($liquidity_overlay->{show_sweep}   // 0) == 1 ||
#                     ($liquidity_overlay->{show_grab}    // 0) == 1 ||
#                     ($liquidity_overlay->{show_zz_ext}  // 0) == 1 ||
#                     ($liquidity_overlay->{show_zz_int}  // 0) == 1
#                 ) ? 1 : 0;
#             }

#             # Redibujar el gráfico inmediatamente con los nuevos estados visibles en pantalla
#             if (defined $chart_engine) {
#                 $chart_engine->request_render();
#             }
#         }
#     );
# }


# # Botones de Vista
# my $scale_btn;
# $scale_btn = $control_panel->Button(
#     -text    => "Escala: Auto",
#     -bg      => '#ffffff',
#     -fg      => '#75bbfd',
#     -relief  => 'flat',
#     -cursor  => 'hand2',
#     -command => sub {
#         return unless $chart_engine;
#         my $nuevo_modo = $chart_engine->{auto_scale} ? 0 : 1;
#         $chart_engine->set_auto_scale($nuevo_modo);
#         $chart_engine->request_render();
#     }
# )->pack(-side => 'left', -padx => 5);

# $control_panel->Button(
#     -text    => "Restablecer Vista (R)",
#     -bg      => '#ffffff',
#     -fg      => '#131722',
#     -relief  => 'flat',
#     -cursor  => 'hand2',
#     -command => sub {
#         return unless $chart_engine;
#         $chart_engine->reset_view();
#         $scale_btn->configure(-text => "Escala: Auto", -fg => '#3bb3e4');
#     }
# )->pack(-side => 'left', -padx => 10);

# $control_panel->Label(
#     -text => " | CONTROLES REPLAY: ",
#     -bg   => '#fbfcf8',
#     -fg   => '#ff9800',
#     -font => 'Arial 10 bold'
# )->pack(-side => 'left', -padx => 10);

# # 2. Controles de la Máquina Replay
# $control_panel->Button(
#     -text    => "Activar/Salir",
#     -bg      => '#ffe0b2',
#     -command => sub { $chart_engine->toggle_replay_mode() if $chart_engine; }
# )->pack(-side => 'left', -padx => 2);

# $control_panel->Button(
#     -text    => "Step Bwd",
#     -bg      => '#e0e0e0',
#     -command => sub { $chart_engine->step_backward() if $chart_engine; }
# )->pack(-side => 'left', -padx => 2);

# $control_panel->Button(
#     -text    => "Play",
#     -bg      => '#c8e6c9',
#     -command => sub { $chart_engine->play_replay() if $chart_engine; }
# )->pack(-side => 'left', -padx => 2);

# $control_panel->Button(
#     -text    => "Pause",
#     -bg      => '#ffcdd2',
#     -command => sub { $chart_engine->pause_replay() if $chart_engine; }
# )->pack(-side => 'left', -padx => 2);

# $control_panel->Button(
#     -text    => "Step Fwd",
#     -bg      => '#e0e0e0',
#     -command => sub { $chart_engine->step_forward() if $chart_engine; }
# )->pack(-side => 'left', -padx => 2);

# # --- ESTRUCTURA MODULAR DE CONTENEDORES ---
# my $price_frame = $mw->Frame(-bg => '#fbfcf8')
#                      ->pack(-side => 'top', -fill => 'both', -expand => 1);

# my $price_main_row = $price_frame->Frame(-bg => '#fbfcf8')
#                                  ->pack(-side => 'top', -fill => 'both', -expand => 1);

# my $price_axis_canvas = $price_main_row->Canvas(
#     -bg                 => '#fbfcf8',
#     -width              => 75,
#     -highlightthickness => 0
# )->pack(-side => 'right', -fill => 'y');

# my $price_canvas = $price_main_row->Canvas(
#     -bg                 => '#fbfcf8',
#     -highlightthickness => 0
# )->pack(-side => 'left', -fill => 'both', -expand => 1);

# my $time_axis_row = $price_frame->Frame(-bg => '#fbfcf8')
#                                 ->pack(-side => 'top', -fill => 'x');

# my $price_corner = $time_axis_row->Canvas(
#     -bg                 => '#fbfcf8',
#     -width              => 75,
#     -height             => 25,
#     -highlightthickness => 0
# )->pack(-side => 'right');

# my $time_canvas = $time_axis_row->Canvas(
#     -bg                 => '#fbfcf8',
#     -height             => 25,
#     -highlightthickness => 0
# )->pack(-side => 'left', -fill => 'x', -expand => 1);

# my $atr_frame = $mw->Frame(
#     -bg     => '#fbfcf8',
#     -height => 160
# )->pack(-side => 'top', -fill => 'both', -expand => 0);

# my $atr_main_row = $atr_frame->Frame(-bg => '#fbfcf8')
#                              ->pack(-side => 'top', -fill => 'both', -expand => 1);

# my $atr_axis_canvas = $atr_main_row->Canvas(
#     -bg                 => '#fbfcf8',
#     -width              => 75,
#     -highlightthickness => 0
# )->pack(-side => 'right', -fill => 'y');

# my $atr_canvas = $atr_main_row->Canvas(
#     -bg                 => '#fbfcf8',
#     -highlightthickness => 0
# )->pack(-side => 'left', -fill => 'both', -expand => 1);

# # --- INSTANCIACIÓN MAESTRA ---
# my $market_data       = Market::MarketData->new();       
# my $indicator_manager = Market::IndicatorManager->new(); 

# $chart_engine = Market::ChartEngine->new(
#     market_data       => $market_data,
#     indicator_manager => $indicator_manager,
#     price_canvas      => $price_canvas,
#     price_axis_canvas => $price_axis_canvas,
#     time_canvas       => $time_canvas,
#     atr_canvas        => $atr_canvas,
#     atr_axis_canvas   => $atr_axis_canvas,
#     widgets           => {
#         main_window => $mw,
#         scale_btn   => $scale_btn
#     }
# );

# # --- INDICADORES ANALÍTICOS ---
# my $atr_real = Market::Indicators::ATR->new(14);
# $indicator_manager->register('ATR', $atr_real);

# # Indicador de Liquidez (ZigZag)
# my $liquidity_real = Market::Indicators::Liquidity->new(
#     atr_period => 14,
# );
# $indicator_manager->register('Liquidity', $liquidity_real);

# # Indicador Estructural SMC (Consumidor de Liquidez)
# my $smc_real = Market::Indicators::SMC_Structures->new(
#     min_fvg_atr_mult   => 0.5,
#     min_pivot_strength => 0.8,
# );
# $indicator_manager->{smc} = $smc_real; # Enlazado vital para Overlays


# # --- OVERLAYS VISUALES ---
# $liquidity_overlay = Market::Overlays::Liquidity->new(
#     canvas => $price_canvas,
#     engine => $chart_engine
# );
# $chart_engine->add_overlay($liquidity_overlay);

# $smc_overlay = Market::Overlays::SMC_Structures->new(
#     canvas             => $price_canvas,
#     engine             => $chart_engine,
#     smc_indicator      => $smc_real,
#     show_fvg           => 1,
#     show_ext_structure => 1,
#     show_int_structure => 1,
#     show_swings        => 0,
# );
# $chart_engine->add_overlay($smc_overlay);

# # --- LECTURA DE DATOS Y FLUJO ALGORÍTMICO ---
# my $archivo_csv = 'datos.csv';
# open(my $fh, '<', $archivo_csv) or die "No se pudo abrir el archivo '$archivo_csv' $!\n";

# my @todas_las_lineas = <$fh>;
# close($fh);

# my $limite_velas = 3000;
# my $inicio = scalar(@todas_las_lineas) > $limite_velas ? scalar(@todas_las_lineas) - $limite_velas : 1;

# for my $i ($inicio .. $#todas_las_lineas) {
#     my $linea = $todas_las_lineas[$i];
#     chomp $linea;

#     my ($time, $open, $high, $low, $close, $volume) = split(',', $linea);
    
#     $market_data->add_candle({
#         time   => $time, open => 0.0 + $open, high => 0.0 + $high,
#         low    => 0.0 + $low, close => 0.0 + $close, volume => 0.0 + $volume
#     });

#     # ORDEN ESTRATÉGICO: 
#     # 1. Indicadores base y motor de liquidez (ZigZag y niveles)
#     $indicator_manager->update_last($market_data);
    
#     # 2. SMC evalúa la acción del precio actual contra la liquidez recién generada
#     $smc_real->update($market_data, $liquidity_real);
# }

# # Inicializamos temporalidades
# $market_data->build_timeframes();

# # Inicialización gráfica
# $chart_engine->bind_all_canvas();
# $chart_engine->bind_events();
# $chart_engine->render();

# MainLoop;

#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin";

use Tk;
use Tk::BrowseEntry;

use Market::MarketData;
use Market::IndicatorManager;
use Market::ChartEngine;
use Market::Indicators::ATR;
use Market::Indicators::Liquidity;
use Market::Indicators::SMC_Structures;
use Market::Overlays::Liquidity;
use Market::Overlays::SMC_Structures;

=head1 NOMBRE

market.pl - Punto de entrada de la aplicación de gráficos financieros.

=head1 DESCRIPCIÓN

Este script se encarga únicamente de la orquestación de alto nivel:

  1. Configuración   -> qué indicadores están activos y con qué parámetros.
  2. Interfaz gráfica -> construcción de la ventana, canvases y controles.
  3. Motor           -> instanciación de MarketData / IndicatorManager / ChartEngine.
  4. Indicadores     -> instanciación condicional según la configuración.
  5. Overlays        -> capas visuales enlazadas a cada indicador activo.
  6. Datos           -> carga del CSV y cálculo incremental inicial.
  7. Arranque        -> bindings de eventos y primer render.

Toda la lógica de cálculo/renderizado vive en los módulos de Market::*;
aquí solo se conecta todo en el orden correcto.

=cut

# ============================================================
# 1. CONFIGURACIÓN DE INDICADORES
# ============================================================
# Para deshabilitar por completo un indicador (incluyendo su cómputo)
# basta con poner enabled => 0 aquí. Ni el indicador ni su overlay
# se instanciarán, ahorrando trabajo durante la carga y el replay.
#
# NOTA: 'SMC' depende causalmente de 'Liquidity' (usa sus swings /
# eventos de liquidez para confirmar BOS/CHOCH/MSS). Si Liquidity está
# deshabilitado, SMC se deshabilita automáticamente (ver validate_config()).
my %INDICATOR_CONFIG = (
    ATR => {
        enabled => 1,
        params  => {
            period => 14,
        },
    },
    Liquidity => {
        enabled => 1,
        params  => {
            atr_period        => 14,
            atr_multiplier    => 4.0,
            minor_atr_mult    => 1.5,
            eq_tolerance      => 0.10,
            confirm_bars      => 3,
            min_bars_pivot    => 2,
            max_history_items => 1000, # límite anti-crecimiento (ver Liquidity.pm)
        },
    },
    SMC => {
        enabled => 1,
        params  => {
            min_fvg_atr_mult       => 0.5,
            min_pivot_strength     => 0.8,
            min_bootstrap_atr_mult => 0.25, # confirmación mínima de "nacimiento" de tendencia
            min_bars_after_break   => 2,    # barras de protección antes de promover un swing
            max_fvg_event_gap_bars => 10,   # ventana de atribución FVG -> evento estructural
            max_pivot_history      => 500,
            max_event_history      => 500,
            max_fvg_history        => 500,
        },
    },
);

# Capas visuales por defecto de cada overlay (se pueden alternar en
# caliente desde el menú "Indicadores" una vez arrancada la app).
my %OVERLAY_DEFAULTS = (
    Liquidity => {
        show_zz_ext => 1, show_zz_int => 1, show_candidates => 1,
        show_eqh    => 1, show_eql    => 1,
        show_bsl    => 1, show_ssl    => 1,
        show_sweep  => 1, show_grab   => 1, show_run => 1,
    },
    SMC => {
        show_fvg           => 1,
        show_ext_structure => 1,
        show_int_structure => 1,
        show_swings        => 0,
    },
);

# ============================================================
# 2. CONFIGURACIÓN DE DATOS
# ============================================================
my $CSV_PATH     = 'datos.csv';
my $CANDLE_LIMIT = 3000;

# ============================================================
# 3. ESTADO GLOBAL DE LA APLICACIÓN
# ============================================================
# (Declarados aquí para que todas las subrutinas de abajo puedan
# capturarlos por closure, sin pasar media docena de parámetros.)
my $mw;
my $control_panel;
my $scale_btn;

my $price_canvas;
my $price_axis_canvas;
my $time_canvas;
my $atr_canvas;
my $atr_axis_canvas;

my $chart_engine;
my $market_data;
my $indicator_manager;

my %indicators = ();  # nombre lógico ('ATR' | 'Liquidity' | 'SMC') => instancia
my %overlays   = ();  # nombre lógico ('Liquidity' | 'SMC')          => instancia

my @timeframes  = ('1m', '5m', '15m', '1h', '2h', '4h', 'D', 'W');
my $selected_tf = '1m';


# ============================================================
# PUNTO DE ENTRADA
# ============================================================
validate_config();

build_main_window();
build_control_panel();
build_chart_containers();

init_engine();
init_indicators();
init_overlays();
build_indicator_menu();

load_market_data();

start_application();

MainLoop;


# ============================================================
# SECCIÓN: VALIDACIÓN DE CONFIGURACIÓN
# ============================================================

=head2 validate_config()

Resuelve dependencias entre indicadores antes de instanciar nada.
Actualmente la única regla es: SMC requiere Liquidity.

=cut

sub validate_config {
    if ($INDICATOR_CONFIG{SMC}{enabled} && !$INDICATOR_CONFIG{Liquidity}{enabled}) {
        warn "[market.pl] SMC_Structures requiere Liquidity; deshabilitando SMC.\n";
        $INDICATOR_CONFIG{SMC}{enabled} = 0;
    }
    return;
}


# ============================================================
# SECCIÓN: INTERFAZ GRÁFICA
# ============================================================

sub build_main_window {
    $mw = MainWindow->new();
    $mw->title("Replica Financiera TradingView - EPN (Fase 2)");

    my $width  = $mw->screenwidth;
    my $height = $mw->screenheight;
    $mw->geometry("${width}x${height}+0+0");
    return;
}

=head2 build_control_panel()

Construye la barra superior: selector de temporalidad, botón de
escala y controles de replay. El menú de indicadores/capas se
construye aparte, en build_indicator_menu(), una vez que los
overlays ya existen (ver esa función para el porqué).

=cut

sub build_control_panel {
    $control_panel = $mw->Frame(-bg => '#fbfcf8', -relief => 'raised', -bd => 1)
                        ->pack(-side => 'top', -fill => 'x', -ipady => 4);

    $control_panel->Label(
        -text => "Temporalidad:",
        -bg   => '#fbfcf8',
        -fg   => '#b1b5be',
        -font => 'Arial 10 bold'
    )->pack(-side => 'left', -padx => 10);

    my $tf_menu = $control_panel->BrowseEntry(
        -choices   => \@timeframes,
        -variable  => \$selected_tf,
        -bg        => '#ffffff',
        -fg        => '#131722',
        -state     => 'readonly',
        -width     => 5,
        -browsecmd => sub {
            my ($widget, $tf) = @_;
            return unless defined $chart_engine;
            # set_timeframe() ya llama internamente a reset_view().
            $chart_engine->set_timeframe($tf);
            sync_indicators_to_timeframe($tf);
            $chart_engine->render();
        }
    )->pack(-side => 'left', -padx => 3);
    $tf_menu->insert('end', @timeframes);

    $control_panel->Label(-text => " | ", -bg => '#fbfcf8', -fg => '#d1d4dc')
                  ->pack(-side => 'left', -padx => 10);

    # El Menubutton "Indicadores" se crea aquí (vacío); sus entradas
    # se rellenan luego en build_indicator_menu().
    my $indicators_menubutton = $control_panel->Menubutton(
        -text    => "Indicadores",
        -bg      => '#ffffff',
        -fg      => '#131722',
        -relief  => 'raised',
        -bd      => 1,
        -cursor  => 'hand2',
        -tearoff => 0,
    )->pack(-side => 'left', -padx => 3);

    my $indicators_menu = $indicators_menubutton->Menu(-tearoff => 0);
    $indicators_menubutton->configure(-menu => $indicators_menu);

    # Se guarda el widget del menú en el estado global para poder
    # poblarlo más adelante, cuando los overlays ya existan.
    $control_panel->{indicators_menu} = $indicators_menu;

    $control_panel->Label(-text => " | ", -bg => '#fbfcf8', -fg => '#d1d4dc')
                  ->pack(-side => 'left', -padx => 10);

    # --- Botones de vista/escala ---
    $scale_btn = $control_panel->Button(
        -text   => "Escala: Auto",
        -bg     => '#ffffff',
        -fg     => '#75bbfd',
        -relief => 'flat',
        -cursor => 'hand2',
        -command => sub {
            return unless $chart_engine;
            my $nuevo_modo = $chart_engine->{auto_scale} ? 0 : 1;
            $chart_engine->set_auto_scale($nuevo_modo);
            $chart_engine->request_render();
        }
    )->pack(-side => 'left', -padx => 5);

    $control_panel->Button(
        -text   => "Restablecer Vista (R)",
        -bg     => '#ffffff',
        -fg     => '#131722',
        -relief => 'flat',
        -cursor => 'hand2',
        -command => sub {
            return unless $chart_engine;
            $chart_engine->reset_view();
            $scale_btn->configure(-text => "Escala: Auto", -fg => '#3bb3e4');
        }
    )->pack(-side => 'left', -padx => 10);

    # --- Controles de Replay ---
    $control_panel->Label(
        -text => " | CONTROLES REPLAY: ",
        -bg   => '#fbfcf8',
        -fg   => '#ff9800',
        -font => 'Arial 10 bold'
    )->pack(-side => 'left', -padx => 10);

    $control_panel->Button(
        -text    => "Activar/Salir",
        -bg      => '#ffe0b2',
        -command => sub { $chart_engine->toggle_replay_mode() if $chart_engine; }
    )->pack(-side => 'left', -padx => 2);

    $control_panel->Button(
        -text    => "Step Bwd",
        -bg      => '#e0e0e0',
        -command => sub { $chart_engine->step_backward() if $chart_engine; }
    )->pack(-side => 'left', -padx => 2);

    $control_panel->Button(
        -text    => "Play",
        -bg      => '#c8e6c9',
        -command => sub { $chart_engine->play_replay() if $chart_engine; }
    )->pack(-side => 'left', -padx => 2);

    $control_panel->Button(
        -text    => "Pause",
        -bg      => '#ffcdd2',
        -command => sub { $chart_engine->pause_replay() if $chart_engine; }
    )->pack(-side => 'left', -padx => 2);

    $control_panel->Button(
        -text    => "Step Fwd",
        -bg      => '#e0e0e0',
        -command => sub { $chart_engine->step_forward() if $chart_engine; }
    )->pack(-side => 'left', -padx => 2);

    return;
}

=head2 build_chart_containers()

Construye los frames y canvases: panel de precio (+ eje Y + eje de
tiempo) y panel de ATR (+ su propio eje Y). Puramente estructural;
el contenido se pinta en ChartEngine/PricePanel/ATRPanel.

=cut

sub build_chart_containers {
    my $price_frame = $mw->Frame(-bg => '#fbfcf8')
                         ->pack(-side => 'top', -fill => 'both', -expand => 1);

    my $price_main_row = $price_frame->Frame(-bg => '#fbfcf8')
                                     ->pack(-side => 'top', -fill => 'both', -expand => 1);

    $price_axis_canvas = $price_main_row->Canvas(
        -bg                 => '#fbfcf8',
        -width              => 75,
        -highlightthickness => 0
    )->pack(-side => 'right', -fill => 'y');

    $price_canvas = $price_main_row->Canvas(
        -bg                 => '#fbfcf8',
        -highlightthickness => 0
    )->pack(-side => 'left', -fill => 'both', -expand => 1);

    my $time_axis_row = $price_frame->Frame(-bg => '#fbfcf8')
                                    ->pack(-side => 'top', -fill => 'x');

    $time_axis_row->Canvas(
        -bg                 => '#fbfcf8',
        -width              => 75,
        -height             => 25,
        -highlightthickness => 0
    )->pack(-side => 'right');

    $time_canvas = $time_axis_row->Canvas(
        -bg                 => '#fbfcf8',
        -height             => 25,
        -highlightthickness => 0
    )->pack(-side => 'left', -fill => 'x', -expand => 1);

    my $atr_frame = $mw->Frame(
        -bg     => '#fbfcf8',
        -height => 160
    )->pack(-side => 'top', -fill => 'both', -expand => 0);

    my $atr_main_row = $atr_frame->Frame(-bg => '#fbfcf8')
                                 ->pack(-side => 'top', -fill => 'both', -expand => 1);

    $atr_axis_canvas = $atr_main_row->Canvas(
        -bg                 => '#fbfcf8',
        -width              => 75,
        -highlightthickness => 0
    )->pack(-side => 'right', -fill => 'y');

    $atr_canvas = $atr_main_row->Canvas(
        -bg                 => '#fbfcf8',
        -highlightthickness => 0
    )->pack(-side => 'left', -fill => 'both', -expand => 1);

    return;
}


# ============================================================
# SECCIÓN: MOTOR (MarketData / IndicatorManager / ChartEngine)
# ============================================================

sub init_engine {
    $market_data       = Market::MarketData->new();
    $indicator_manager = Market::IndicatorManager->new();

    $chart_engine = Market::ChartEngine->new(
        market_data       => $market_data,
        indicator_manager => $indicator_manager,
        price_canvas      => $price_canvas,
        price_axis_canvas => $price_axis_canvas,
        time_canvas       => $time_canvas,
        atr_canvas        => $atr_canvas,
        atr_axis_canvas   => $atr_axis_canvas,
        widgets           => {
            main_window => $mw,
            scale_btn   => $scale_btn,
        },
    );
    return;
}


# ============================================================
# SECCIÓN: INDICADORES (cómputo)
# ============================================================

=head2 init_indicators()

Instancia únicamente los indicadores marcados como enabled => 1 en
%INDICATOR_CONFIG y los registra en el IndicatorManager. Los que
estén deshabilitados simplemente no existen: no consumen memoria ni
tiempo de cómputo durante la carga ni el replay.

=cut

sub init_indicators {
    if ($INDICATOR_CONFIG{ATR}{enabled}) {
        my $atr = Market::Indicators::ATR->new(
            $INDICATOR_CONFIG{ATR}{params}{period} || 14
        );
        $indicator_manager->register('ATR', $atr);
        $indicators{ATR} = $atr;
    }

    if ($INDICATOR_CONFIG{Liquidity}{enabled}) {
        my $liquidity = Market::Indicators::Liquidity->new(
            %{ $INDICATOR_CONFIG{Liquidity}{params} }
        );
        $indicator_manager->register('Liquidity', $liquidity);
        $indicators{Liquidity} = $liquidity;
    }

    if ($INDICATOR_CONFIG{SMC}{enabled}) {
        my $smc = Market::Indicators::SMC_Structures->new(
            %{ $INDICATOR_CONFIG{SMC}{params} }
        );
        # SMC no pasa por el ciclo genérico update_last() del manager
        # porque su update() necesita recibir explícitamente el
        # indicador de Liquidity (causalidad: Liquidity -> SMC).
        # Se registra igual para que get_smc_structures() lo exponga
        # a los overlays / futuras estrategias.
        $indicator_manager->register('SMC', $smc);
        $indicators{SMC} = $smc;
    }

    return;
}


# ============================================================
# SECCIÓN: OVERLAYS (renderizado)
# ============================================================

=head2 init_overlays()

Crea el overlay visual de cada indicador que esté activo. Un overlay
nunca se crea si su indicador subyacente está deshabilitado (no
tendría datos que dibujar).

=cut

sub init_overlays {
    if ($indicators{Liquidity}) {
        my $liquidity_overlay = Market::Overlays::Liquidity->new(
            canvas             => $price_canvas,
            engine             => $chart_engine,
            liquidity_indicator => $indicators{Liquidity},
            %{ $OVERLAY_DEFAULTS{Liquidity} },
        );
        $chart_engine->add_overlay($liquidity_overlay);
        $overlays{Liquidity} = $liquidity_overlay;
    }

    if ($indicators{SMC}) {
        my $smc_overlay = Market::Overlays::SMC_Structures->new(
            canvas        => $price_canvas,
            engine        => $chart_engine,
            smc_indicator => $indicators{SMC},
            %{ $OVERLAY_DEFAULTS{SMC} },
        );
        $chart_engine->add_overlay($smc_overlay);
        $overlays{SMC} = $smc_overlay;
    }

    return;
}

=head2 build_indicator_menu()

Puebla el Menubutton "Indicadores" creado en build_control_panel().
Se hace en un paso separado -y después de init_overlays()- a
propósito: los checkbuttons apuntan directamente a los atributos de
los objetos overlay ya instanciados (\$overlays{Liquidity}{active},
etc.). Si se construyeran antes de crear los overlays, Perl
autovivificaría esas referencias como hashes sueltos que luego
quedarían desconectados al asignarles el objeto real.

Estructura del menú:
  - Un checkbutton maestro por indicador activo (activa/desactiva
    todo el overlay de un golpe).
  - Un submenú en cascada con las capas visuales finas de cada
    overlay (BSL/SSL, Sweep, FVG, Swings, etc.).
  - Una entrada informativa (deshabilitada) por cada indicador que
    esté apagado en %INDICATOR_CONFIG, para que quede claro por qué
    no aparece en el gráfico.

=cut

sub build_indicator_menu {
    my $menu = $control_panel->{indicators_menu};
    return unless $menu;

    if (my $liquidity_overlay = $overlays{Liquidity}) {
        $menu->checkbutton(
            -label    => 'Liquidez (BSL/SSL/ZigZag)',
            -variable => \$liquidity_overlay->{active},
            -onvalue  => 1,
            -offvalue => 0,
            -command  => sub { $chart_engine->request_render(); },
        );

        my $liquidity_submenu = $menu->cascade(
            -label => '   Capas de Liquidez',
            -tearoff => 0,
        );

        my @liquidity_layers = (
            { label => 'BSL / SSL',        key => 'show_bsl' },
            { label => 'Equal Highs (EQH)', key => 'show_eqh' },
            { label => 'Equal Lows (EQL)',  key => 'show_eql' },
            { label => 'Sweep',             key => 'show_sweep' },
            { label => 'Grab',              key => 'show_grab' },
            { label => 'Run',               key => 'show_run' },
            { label => 'ZigZag Externo',    key => 'show_zz_ext' },
            { label => 'ZigZag Interno',    key => 'show_zz_int' },
            { label => 'Candidatos',        key => 'show_candidates' },
        );
        foreach my $layer (@liquidity_layers) {
            $liquidity_overlay->{ $layer->{key} } //= 1;
            $liquidity_submenu->checkbutton(
                -label    => $layer->{label},
                -variable => \$liquidity_overlay->{ $layer->{key} },
                -onvalue  => 1,
                -offvalue => 0,
                -command  => sub { $chart_engine->request_render(); },
            );
        }
    } else {
        $menu->command(
            -label => 'Liquidez (deshabilitada en configuración)',
            -state => 'disabled',
        );
    }

    if (my $smc_overlay = $overlays{SMC}) {
        $menu->checkbutton(
            -label    => 'SMC Structures (BOS/CHOCH/FVG)',
            -variable => \$smc_overlay->{active},
            -onvalue  => 1,
            -offvalue => 0,
            -command  => sub { $chart_engine->request_render(); },
        );

        my $smc_submenu = $menu->cascade(
            -label   => '   Capas SMC',
            -tearoff => 0,
        );

        my @smc_layers = (
            { label => 'Fair Value Gaps (FVG)', key => 'show_fvg' },
            { label => 'Estructura Externa',    key => 'show_ext_structure' },
            { label => 'Estructura Interna',    key => 'show_int_structure' },
            { label => 'Swings (HH/HL/LH/LL)',  key => 'show_swings' },
        );
        foreach my $layer (@smc_layers) {
            $smc_overlay->{ $layer->{key} } //= 1;
            $smc_submenu->checkbutton(
                -label    => $layer->{label},
                -variable => \$smc_overlay->{ $layer->{key} },
                -onvalue  => 1,
                -offvalue => 0,
                -command  => sub { $chart_engine->request_render(); },
            );
        }
    } else {
        $menu->command(
            -label => 'SMC Structures (deshabilitado en configuración)',
            -state => 'disabled',
        );
    }

    return;
}


# ============================================================
# SECCIÓN: CARGA DE DATOS
# ============================================================

=head2 load_market_data()

Lee el CSV, alimenta MarketData vela por vela y actualiza cada
indicador ACTIVO en el orden causal correcto:

    1. ATR         (independiente)
    2. Liquidity   (independiente, pero SMC depende de ella)
    3. SMC         (consume el estado ya actualizado de Liquidity)

Un indicador deshabilitado simplemente no aparece en %indicators y
por lo tanto se saltea con el "next unless" de cada bloque; no hace
falta tocar este bucle al activar/desactivar indicadores, basta con
editar %INDICATOR_CONFIG al principio del archivo.

=cut

sub load_market_data {
    open(my $fh, '<', $CSV_PATH)
        or die "No se pudo abrir el archivo '$CSV_PATH': $!\n";

    my @todas_las_lineas = <$fh>;
    close($fh);

    my $total_lineas = scalar @todas_las_lineas;
    my $inicio = $total_lineas > $CANDLE_LIMIT
               ? $total_lineas - $CANDLE_LIMIT
               : 1; # se salta la línea 0 (encabezado del CSV)

    for my $i ($inicio .. $#todas_las_lineas) {
        my $linea = $todas_las_lineas[$i];
        chomp $linea;
        next unless length $linea;

        my ($time, $open, $high, $low, $close, $volume) = split(',', $linea);

        $market_data->add_candle({
            time   => $time,
            open   => 0.0 + $open,
            high   => 0.0 + $high,
            low    => 0.0 + $low,
            close  => 0.0 + $close,
            volume => 0.0 + $volume,
        });

        update_indicators_for_last_candle();
    }

    # Construcción de temporalidades superiores (5m, 15m, 1h, ... W)
    $market_data->build_timeframes();

    return;
}

=head2 update_indicators_for_last_candle()

Aplica el orden estratégico de ejecución (causalidad SMC) sobre la
última vela cargada. Se usa tanto en la carga inicial como podría
reutilizarse desde el replay si en el futuro se requiere actualizar
SMC también durante el Play/Step (ver nota en ChartEngine).

=cut

sub update_indicators_for_last_candle {
    $indicators{ATR}->update_last($market_data)
        if $indicators{ATR};

    $indicators{Liquidity}->update_last($market_data)
        if $indicators{Liquidity};

    $indicators{SMC}->update($market_data, $indicators{Liquidity})
        if $indicators{SMC} && $indicators{Liquidity};

    return;
}

=head2 sync_indicators_to_timeframe($tf)

Market::Indicators::Liquidity y Market::Indicators::SMC_Structures
mantienen su propio estado aislado POR TEMPORALIDAD (active_timeframe,
set_active_timeframe()). Cuando el usuario cambia el selector de
temporalidad, MarketData apunta a un arreglo de velas distinto, así
que hay que decirle a cada indicador que cambie también de "carril"
y recalcule su historial para esa temporalidad:

  - Liquidity expone build_history($market_data), que es incremental/
    reanudable (usa last_processed_index): si el usuario vuelve a una
    temporalidad ya visitada, no recalcula desde cero.
  - SMC_Structures NO tiene build_history propio, pero su update()
    también es incremental internamente (checkpoints processed->{...}
    por tier y por vela), así que basta con llamarlo una vez tras el
    cambio de temporalidad para que "se ponga al día" con todo el
    histórico pendiente de esa temporalidad. Por eso debe llamarse
    DESPUÉS de que Liquidity ya haya reconstruido su historial: SMC
    lee get_structural_pivots()/get_minor_pivots() de Liquidity.

LIMITACIÓN CONOCIDA: Market::Indicators::ATR no implementa el patrón
set_active_timeframe()/multi-timeframe (su estado -tr_sum, last_atr,
wilder_phase- es una sola serie secuencial, ver ATR.pm). Por eso aquí
se filtra con `can('set_active_timeframe')`: a ATR simplemente no se
le pide resincronizar, y el panel de volatilidad seguirá reflejando
la serie calculada sobre la temporalidad base (1m) hasta que ATR.pm
reciba el mismo tratamiento multi-timeframe que Liquidity/SMC.

=cut

sub sync_indicators_to_timeframe {
    my ($tf) = @_;

    # 1. Liquidity primero: SMC depende de sus pivots/eventos ya frescos.
    if (my $liquidity = $indicators{Liquidity}) {
        if ($liquidity->can('set_active_timeframe')) {
            $liquidity->set_active_timeframe($tf);
            $liquidity->build_history($market_data) if $liquidity->can('build_history');
        }
    }

    # 2. SMC después: su update() se pone al día solo (checkpoints internos).
    if (my $smc = $indicators{SMC}) {
        if ($smc->can('set_active_timeframe')) {
            $smc->set_active_timeframe($tf);
            $smc->update($market_data, $indicators{Liquidity}) if $indicators{Liquidity};
        }
    }

    return;
}


# ============================================================
# SECCIÓN: ARRANQUE FINAL
# ============================================================

sub start_application {
    $chart_engine->bind_all_canvas();
    $chart_engine->bind_events();
    $chart_engine->render();
    return;
}