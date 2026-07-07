use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin"; 

use Tk;
use Tk::BrowseEntry; # Para el menú desplegable (Drop-down)
use Market::MarketData;
use Market::IndicatorManager;
use Market::ChartEngine;
use Market::Indicators::ATR;
use Market::Indicators::Liquidity;
use Market::Indicators::SMC_Structures;
use Market::Overlays::Liquidity;
use Market::Overlays::SMC_Structures;

my $mw = MainWindow->new();
$mw->title("Replica Financiera TradingView - EPN (Fase 2)");

my $width  = $mw->screenwidth;
my $height = $mw->screenheight;
$mw->geometry("${width}x${height}+0+0");

# Declaración adelantada
my $chart_engine;
my $liquidity_overlay;
my $smc_overlay;

# --- BARRA SUPERIOR DE CONTROL DE INTERFAZ ---
my $control_panel = $mw->Frame(-bg => '#fbfcf8', -relief => 'raised', -bd => 1)
                       ->pack(-side => 'top', -fill => 'x', -ipady => 4);

# Control de Temporalidades (1m, 5m, 15m, 1h, 2h, 4h, 1d) mediante un menú
# desplegable único, en lugar de un botón por cada temporalidad.
my $tf_label = $control_panel->Label(-text => "Temporalidad:", -bg => '#fbfcf8', -fg => '#b1b5be', -font => 'Arial 10 bold')
                             ->pack(-side => 'left', -padx => 10);

# Declaración adelantada de la referencia del motor para usar en los callbacks
my $chart_engine;

my @temporalidades = ('1m', '5m', '15m', '1h', '2h', '4h', '1d');
my $tf_seleccionada = '1m';

my $tf_menu = $control_panel->Optionmenu(
    -options          => \@temporalidades,
    -variable         => \$tf_seleccionada,
    -bg               => '#ffffff',
    -fg               => '#131722',
    -activebackground => '#75bbfd',
    -activeforeground => 'white',
    -relief           => 'raised',
    -cursor           => 'hand2',
    -command          => sub {
        my ($valor) = @_;
        $chart_engine->set_timeframe($valor) if $chart_engine && defined $valor;
    },
)->pack(-side => 'left', -padx => 3);

# Espaciador estético intermedio
$control_panel->Label(-text => " | ", -bg => '#fbfcf8', -fg => '#d1d4dc')->pack(-side => 'left', -padx => 10);

my $indicator_label = $control_panel->Label(-text => "Indicadores:", -bg => '#fbfcf8', -fg => '#b1b5be', -font => 'Arial 10 bold')
                             ->pack(-side => 'left', -padx => 10);

my $indicator_menu = $control_panel->Menubutton(
    -text             => "Indicators",
    -bg               => '#ffffff',
    -fg               => '#131722',
    -activebackground => '#75bbfd',
    -activeforeground => 'white',
    -relief           => 'raised',
    -cursor           => 'hand2',
)->pack(-side => 'left', -padx => 5);

my $menu = $indicator_menu->Menu(-tearoff => 0);
$indicator_menu->configure(-menu => $menu);

my %vars = (
    show_liquidity    => 1,
    show_smc          => 1,
    show_choch        => 1,
    show_bos          => 1,
    show_lq_events    => 1,
    show_swing        => 0,
    show_fvg          => 1,
    show_ob           => 1,
);

my @items = (
    ["Liquidity",    "show_liquidity", "#0e5e50"],
    ["SMC",          "show_smc",       "#2962ff"],
    ["ChoCH",        "show_choch",     "#3f0202"],
    ["BOS",          "show_bos",       "#0c3f02"],
    ["LQ_Events",    "show_lq_events", "#06023f"],
    ["Swing",        "show_swing",     "#4d0a47"],
    ["FVG",          "show_fvg",       "#aa2424"],
    ["Order Blocks", "show_ob",        "#ff9800"],
);

for my $item (@items) {
    my ($label, $key, $color) = @$item;

    $menu->checkbutton(
        -label            => $label,
        -variable         => \$vars{$key},
        -foreground       => $color,
        -activeforeground => $color,
        -selectcolor      => $color,
        -command          => sub {
            return unless $chart_engine;
            $chart_engine->{$key} = $vars{$key};
            $chart_engine->request_render();
        },
    );
}

$control_panel->Label(
    -text => " | ",
    -bg   => '#fbfcf8',
    -fg   => '#d1d4dc'
)->pack(-side => 'left', -padx => 10);

# Botones de Vista Originales
my $scale_btn;
$scale_btn = $control_panel->Button(
    -text    => "Escala: Auto",
    -bg      => '#ffffff',
    -fg      => '#75bbfd',
    -relief  => 'flat',
    -cursor  => 'hand2',
    -command => sub {
        return unless $chart_engine;
        my $nuevo_modo = $chart_engine->{auto_scale} ? 0 : 1;
        $chart_engine->set_auto_scale($nuevo_modo);
        $chart_engine->request_render();
    }
)->pack(-side => 'left', -padx => 5);

$control_panel->Button(
    -text    => "Restablecer Vista (R)",
    -bg      => '#ffffff',
    -fg      => '#131722',
    -relief  => 'flat',
    -cursor  => 'hand2',
    -command => sub {
        return unless $chart_engine;
        $chart_engine->reset_view();
        $scale_btn->configure(-text => "Escala: Auto", -fg => '#3bb3e4');
    }
)->pack(-side => 'left', -padx => 10);

$control_panel->Label(
    -text => " | CONTROLES REPLAY: ",
    -bg   => '#fbfcf8',
    -fg   => '#ff9800',
    -font => 'Arial 10 bold'
)->pack(-side => 'left', -padx => 10);

# 2. Controles de la Máquina Replay
$control_panel->Button(
    -text    => "Activar/Salir",
    -bg      => '#ffe0b2',
    -command => sub { $chart_engine->toggle_replay_mode() if $chart_engine; }
)->pack(-side => 'left', -padx => 2);

$control_panel->Button(
    -text    => "⏮ Step Bwd",
    -bg      => '#e0e0e0',
    -command => sub { $chart_engine->step_backward() if $chart_engine; }
)->pack(-side => 'left', -padx => 2);

$control_panel->Button(
    -text    => "▶ Play",
    -bg      => '#c8e6c9',
    -command => sub { $chart_engine->play_replay() if $chart_engine; }
)->pack(-side => 'left', -padx => 2);

$control_panel->Button(
    -text    => "⏸ Pause",
    -bg      => '#ffcdd2',
    -command => sub { $chart_engine->pause_replay() if $chart_engine; }
)->pack(-side => 'left', -padx => 2);

$control_panel->Button(
    -text    => "Step Fwd ⏭",
    -bg      => '#e0e0e0',
    -command => sub { $chart_engine->step_forward() if $chart_engine; }
)->pack(-side => 'left', -padx => 2);


# --- ESTRUCTURA MODULAR DE CONTENEDORES ---
my $price_frame = $mw->Frame(-bg => '#fbfcf8')
                     ->pack(-side => 'top', -fill => 'both', -expand => 1);

my $price_main_row = $price_frame->Frame(-bg => '#fbfcf8')
                                 ->pack(-side => 'top', -fill => 'both', -expand => 1);

my $price_axis_canvas = $price_main_row->Canvas(
    -bg                 => '#fbfcf8',
    -width              => 75,
    -highlightthickness => 0
)->pack(-side => 'right', -fill => 'y');

my $price_canvas = $price_main_row->Canvas(
    -bg                 => '#fbfcf8',
    -highlightthickness => 0
)->pack(-side => 'left', -fill => 'both', -expand => 1);

my $time_axis_row = $price_frame->Frame(-bg => '#fbfcf8')
                                ->pack(-side => 'top', -fill => 'x');

my $price_corner = $time_axis_row->Canvas(
    -bg                 => '#fbfcf8',
    -width              => 75,
    -height             => 25,
    -highlightthickness => 0
)->pack(-side => 'right');

my $time_canvas = $time_axis_row->Canvas(
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

my $atr_axis_canvas = $atr_main_row->Canvas(
    -bg                 => '#fbfcf8',
    -width              => 75,
    -highlightthickness => 0
)->pack(-side => 'right', -fill => 'y');

my $atr_canvas = $atr_main_row->Canvas(
    -bg                 => '#fbfcf8',
    -highlightthickness => 0
)->pack(-side => 'left', -fill => 'both', -expand => 1);


# --- INSTANCIACIÓN ---
my $market_data       = Market::MarketData->new();       
my $indicator_manager = Market::IndicatorManager->new(); 

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
        scale_btn   => $scale_btn
    }
);


# --- INDICADORES ANALÍTICOS ---
my $atr_real = Market::Indicators::ATR->new(14);
$indicator_manager->register('ATR', $atr_real);

# Indicador de Liquidez: detecta BSL, SSL, Sweeps, Grabs y Runs
my $liquidity_real = Market::Indicators::Liquidity->new(
    atr_period => 14,
    k_depth    => 3
);
$indicator_manager->register('Liquidity', $liquidity_real);

# Indicador SMC:
# No se registra en IndicatorManager porque SMC_Structures usa update($candle_index),
# mientras que IndicatorManager llama update_last($market_data).
my $smc_real = Market::Indicators::SMC_Structures->new(
    market_data      => $market_data,
    liquidity_engine => $liquidity_real,
    atr_indicator    => $atr_real,
    settings         => {
        recent_events_limit => 50,
    }
);


# --- OVERLAYS VISUALES ---
# Overlay de Liquidez: dibuja BSL, SSL y etiquetas de la máquina de estados
$liquidity_overlay = Market::Overlays::Liquidity->new(
    canvas => $price_canvas,
    engine => $chart_engine
);
$chart_engine->add_overlay($liquidity_overlay);

# Overlay SMC:
# Para esta primera entrega se activa FVG + BOS/CHOCH.
# Se desactivan HH/HL/LH/LL para evitar saturación visual y carga excesiva.
$smc_overlay = Market::Overlays::SMC_Structures->new(
    canvas           => $price_canvas,
    engine           => $chart_engine,
    smc_indicator    => $smc_real,

    # Opciones visuales para Sprint 1
    show_fvg         => 1,
    show_structure   => 1,
    show_swings      => 0,
    max_swing_labels => 0,
);
$chart_engine->add_overlay($smc_overlay);



# --- LECTURA DE DATOS OPTIMIZADA PARA LA PRESENTACIÓN ---
my $archivo_csv = 'datos.csv';
open(my $fh, '<', $archivo_csv) or die "No se pudo abrir el archivo '$archivo_csv' $!\n";

my @todas_las_lineas = <$fh>;
close($fh);

my $limite_velas = 3000; # <--- Esto hace que cargue en 2 segundos en vez de 20 minutos
my $inicio = scalar(@todas_las_lineas) > $limite_velas ? scalar(@todas_las_lineas) - $limite_velas : 1;

for my $i ($inicio .. $#todas_las_lineas) {
    my $linea = $todas_las_lineas[$i];
    chomp $linea;

    my ($time, $open, $high, $low, $close, $volume) = split(',', $linea);
    
    $market_data->add_candle({
        time   => $time, open => 0.0 + $open, high => 0.0 + $high,
        low    => 0.0 + $low, close => 0.0 + $close, volume => 0.0 + $volume
    });

    $indicator_manager->update_last($market_data);
    
    my $current_index = $market_data->last_index();
    $smc_real->update($current_index) if defined $current_index && $current_index >= 0;
}

# # --- LECTURA DE DATOS ---
# my $archivo_csv = 'datos.csv';

# open(my $fh, '<', $archivo_csv) or die "No se pudo abrir el archivo '$archivo_csv' $!\n";

# my $encabezado = <$fh>;

# while (my $linea = <$fh>) {
#     chomp $linea;

#     my ($time, $open, $high, $low, $close, $volume) = split(',', $linea);
    
#     $market_data->add_candle({
#         time   => $time,
#         open   => 0.0 + $open,
#         high   => 0.0 + $high,
#         low    => 0.0 + $low,
#         close  => 0.0 + $close,
#         volume => 0.0 + $volume
#     });

#     # Actualización incremental:
#     # ATR y Liquidity necesitan actualizarse vela por vela para generar historial completo.
#     $indicator_manager->update_last($market_data);

#     # SMC se actualiza después de Liquidity porque consume eventos resueltos de liquidez.
#     # Esto permite que FVG, BOS y CHOCH se vayan generando según avanza el historial.
#     my $current_index = $market_data->last_index();
#     $smc_real->update($current_index) if defined $current_index && $current_index >= 0;
# }

# close($fh);


# Inicializamos temporalidades (aquí deberías agregar las lógicas de HTF luego)
$market_data->build_timeframes();


# Inicialización gráfica
$chart_engine->bind_all_canvas();
$chart_engine->bind_events();
$chart_engine->render();

MainLoop;