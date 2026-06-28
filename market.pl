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

my $mw = MainWindow->new();
$mw->title("Replica Financiera TradingView - EPN (Fase 2)");

my $width  = $mw->screenwidth;
my $height = $mw->screenheight;
$mw->geometry("${width}x${height}+0+0");

# Declaración adelantada
my $chart_engine;

# --- BARRA SUPERIOR DE CONTROL DE INTERFAZ ---
my $control_panel = $mw->Frame(-bg => '#fbfcf8', -relief => 'raised', -bd => 1)
                       ->pack(-side => 'top', -fill => 'x', -ipady => 4);

my $tf_label = $control_panel->Label(-text => "Temporalidad:", -bg => '#fbfcf8', -fg => '#b1b5be', -font => 'Arial 10 bold')
                             ->pack(-side => 'left', -padx => 10);

# 1. Menú Desplegable (OptionMenu) para las temporalidades
my @timeframes = ('1m', '5m', '15m', '1h', '2h', '4h', 'D', 'W');
my $selected_tf = '1m';

my $tf_menu = $control_panel->Optionmenu(
    -options => \@timeframes,
    -textvariable => \$selected_tf,
    -bg => '#ffffff',
    -fg => '#131722',
    -command => sub { 
        if ($chart_engine) {
            $chart_engine->set_timeframe($selected_tf); 
            $chart_engine->reset_view();
        }
    }
)->pack(-side => 'left', -padx => 3);

$control_panel->Label(-text => " | ", -bg => '#fbfcf8', -fg => '#d1d4dc')->pack(-side => 'left', -padx => 10);

# Botones de Vista Originales
my $scale_btn;
$scale_btn = $control_panel->Button(
    -text             => "Escala: Auto",
    -bg               => '#ffffff',
    -fg               => '#75bbfd',
    -relief           => 'flat',
    -cursor           => 'hand2',
    -command          => sub {
        return unless $chart_engine;
        my $nuevo_modo = $chart_engine->{auto_scale} ? 0 : 1;
        $chart_engine->set_auto_scale($nuevo_modo);
        $chart_engine->request_render();
    }
)->pack(-side => 'left', -padx => 5);

$control_panel->Button(
    -text             => "Restablecer Vista (R)",
    -bg               => '#ffffff',
    -fg               => '#131722',
    -relief           => 'flat',
    -cursor           => 'hand2',
    -command          => sub {
        return unless $chart_engine;
        $chart_engine->reset_view();
        $scale_btn->configure(-text => "Escala: Auto", -fg => '#3bb3e4');
    }
)->pack(-side => 'left', -padx => 10);

$control_panel->Label(-text => " | CONTROLES REPLAY: ", -bg => '#fbfcf8', -fg => '#ff9800', -font => 'Arial 10 bold')->pack(-side => 'left', -padx => 10);

# 2. Controles de la Máquina Replay
$control_panel->Button(-text => "Activar/Salir", -bg => '#ffe0b2', -command => sub { $chart_engine->toggle_replay_mode() if $chart_engine; })->pack(-side => 'left', -padx => 2);
$control_panel->Button(-text => "⏮ Step Bwd", -bg => '#e0e0e0', -command => sub { $chart_engine->step_backward() if $chart_engine; })->pack(-side => 'left', -padx => 2);
$control_panel->Button(-text => "▶ Play", -bg => '#c8e6c9', -command => sub { $chart_engine->play_replay() if $chart_engine; })->pack(-side => 'left', -padx => 2);
$control_panel->Button(-text => "⏸ Pause", -bg => '#ffcdd2', -command => sub { $chart_engine->pause_replay() if $chart_engine; })->pack(-side => 'left', -padx => 2);
$control_panel->Button(-text => "Step Fwd ⏭", -bg => '#e0e0e0', -command => sub { $chart_engine->step_forward() if $chart_engine; })->pack(-side => 'left', -padx => 2);


# --- ESTRUCTURA MODULAR DE CONTENEDORES ---
my $price_frame = $mw->Frame(-bg => '#fbfcf8')->pack(-side => 'top', -fill => 'both', -expand => 1);
my $price_main_row = $price_frame->Frame(-bg => '#fbfcf8')->pack(-side => 'top', -fill => 'both', -expand => 1);
my $price_axis_canvas = $price_main_row->Canvas(-bg => '#fbfcf8', -width => 75, -highlightthickness => 0)->pack(-side => 'right', -fill => 'y');
my $price_canvas = $price_main_row->Canvas(-bg => '#fbfcf8', -highlightthickness => 0)->pack(-side => 'left', -fill => 'both', -expand => 1);

my $time_axis_row = $price_frame->Frame(-bg => '#fbfcf8')->pack(-side => 'top', -fill => 'x');
my $price_corner = $time_axis_row->Canvas(-bg => '#fbfcf8', -width => 75, -height => 25, -highlightthickness => 0)->pack(-side => 'right');
my $time_canvas = $time_axis_row->Canvas(-bg => '#fbfcf8', -height => 25, -highlightthickness => 0)->pack(-side => 'left', -fill => 'x', -expand => 1);

my $atr_frame = $mw->Frame(-bg => '#fbfcf8', -height => 160)->pack(-side => 'top', -fill => 'both', -expand => 0);
my $atr_main_row = $atr_frame->Frame(-bg => '#fbfcf8')->pack(-side => 'top', -fill => 'both', -expand => 1);
my $atr_axis_canvas = $atr_main_row->Canvas(-bg => '#fbfcf8', -width => 75, -highlightthickness => 0)->pack(-side => 'right', -fill => 'y');
my $atr_canvas = $atr_main_row->Canvas(-bg => '#fbfcf8', -highlightthickness => 0)->pack(-side => 'left', -fill => 'both', -expand => 1);


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
    widgets           => { main_window => $mw, scale_btn => $scale_btn }
);

# --- LECTURA DE DATOS ---
my $archivo_csv = 'datos.csv';
open(my $fh, '<', $archivo_csv) or die "No se pudo abrir el archivo '$archivo_csv' $!\n";
my $encabezado = <$fh>;

my $atr_real = Market::Indicators::ATR->new(14);
$indicator_manager->register('ATR', $atr_real);

while (my $linea = <$fh>) {
    chomp $linea;
    my ($time, $open, $high, $low, $close, $volume) = split(',', $linea);
    
    $market_data->add_candle({
        time   => $time, open => $open, high => $high, low => $low, close => $close, volume => $volume
    });
}
close($fh);

# Inicializamos temporalidades (aquí deberías agregar las lógicas de HTF luego)
$market_data->build_timeframes();
$indicator_manager->update_last($market_data);

# Inicialización gráfica
$chart_engine->bind_all_canvas();
$chart_engine->bind_events();
$chart_engine->render();

MainLoop;