use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin"; # Permite a Perl buscar los módulos locales en el directorio de ejecución

use Tk;
use Market::MarketData;
use Market::IndicatorManager;
use Market::ChartEngine;
use Market::Indicators::ATR;

# =========================================================================
#   FASES DE EJECUCIÓN CENTRAL (MARKET.PL)
# =========================================================================

# 1. Configuración del contenedor principal de la interfaz gráfica (Tk)
my $mw = MainWindow->new();
$mw->title("Replica Financiera TradingView - EPN");
$mw->geometry("1720x900");

# --- BARRA SUPERIOR DE CONTROL DE INTERFAZ ---
my $control_panel = $mw->Frame(-bg => '#fbfcf8', -relief => 'raised', -bd => 1)
                       ->pack(-side => 'top', -fill => 'x', -ipady => 4);

# Control de Temporalidades (Requerimiento Avanzado del documento: 1m, 5m, 15m)
my $tf_label = $control_panel->Label(-text => "Temporalidad:", -bg => '#fbfcf8', -fg => '#b1b5be', -font => 'Arial 10 bold')
                             ->pack(-side => 'left', -padx => 10);

# Declaración adelantada de la referencia del motor para usar en los callbacks de los botones
my $chart_engine;

for my $tf ('1m', '5m', '15m') {
    $control_panel->Button(
        -text             => $tf,
        -bg               => '#ffffff',
        -fg               => '#131722',
        -activebackground => '#75bbfd',
        -activeforeground => 'white',
        -relief           => 'flat',
        -cursor           => 'hand2',
        -command          => sub { $chart_engine->set_timeframe($tf) if $chart_engine; }
    )->pack(-side => 'left', -padx => 3);
}

# Espaciador estético intermedio
$control_panel->Label(-text => " | ", -bg => '#fbfcf8', -fg => '#d1d4dc')->pack(-side => 'left', -padx => 10);

# Botón dinámico para conmutar el Modo de Escala (Auto / Manual)
my $scale_btn;
$scale_btn = $control_panel->Button(
    -text             => "Escala: Auto",
    -bg               => '#ffffff',
    -fg               => '#75bbfd',
    -activebackground => '#e0e0e0',
    -activeforeground => '#3bb3e4',
    -relief           => 'flat',
    -cursor           => 'hand2',
    -command          => sub {
        return unless $chart_engine;
        # Solo le decimos al motor que invierta la escala, él se encarga del resto
        my $nuevo_modo = $chart_engine->{auto_scale} ? 0 : 1;
        $chart_engine->set_auto_scale($nuevo_modo);
        $chart_engine->request_render();
    }
)->pack(-side => 'left', -padx => 5);

# Botón para restablecer los parámetros visuales (Reset View)
$control_panel->Button(
    -text             => "Restablecer Vista (R)",
    -bg               => '#ffffff',
    -fg               => '#131722',
    -activebackground => '#ff4a4a',
    -activeforeground => 'white',
    -relief           => 'flat',
    -cursor           => 'hand2',
    -command          => sub {
        return unless $chart_engine;
        $chart_engine->reset_view();
        # Sincronizamos el texto del botón de escala al volver a modo automático
        $scale_btn->configure(-text => "Escala: Auto", -fg => '#3bb3e4');
    }
)->pack(-side => 'left', -padx => 10);


# --- ESTRUCTURA MODULAR DE CONTENEDORES PARA EVITAR DEFORMACIÓN ---

# A. PANEL PRINCIPAL DE PRECIOS Y VELAS
my $price_frame = $mw->Frame(-bg => '#fbfcf8')->pack(-side => 'top', -fill => 'both', -expand => 1);

my $price_main_row = $price_frame->Frame(-bg => '#fbfcf8')->pack(-side => 'top', -fill => 'both', -expand => 1);

# ¡EL TRUCO TK! Empaquetamos PRIMERO el eje vertical (fijo a la derecha)
my $price_axis_canvas = $price_main_row->Canvas(-bg => '#fbfcf8', -width => 75, -highlightthickness => 0)
                                       ->pack(-side => 'right', -fill => 'y');

# LUEGO empaquetamos las velas para que se expandan en el espacio sobrante
my $price_canvas = $price_main_row->Canvas(-bg => '#fbfcf8', -highlightthickness => 0)
                                  ->pack(-side => 'left', -fill => 'both', -expand => 1);


# Fila inferior de Tiempos
my $time_axis_row = $price_frame->Frame(-bg => '#fbfcf8')->pack(-side => 'top', -fill => 'x');

# Empaquetamos PRIMERO la esquina muerta a la derecha
my $price_corner = $time_axis_row->Canvas(-bg => '#fbfcf8', -width => 75, -height => 25, -highlightthickness => 0)
                                 ->pack(-side => 'right');

# LUEGO el eje del tiempo a la izquierda
my $time_canvas = $time_axis_row->Canvas(-bg => '#fbfcf8', -height => 25, -highlightthickness => 0)
                                ->pack(-side => 'left', -fill => 'x', -expand => 1);


# B. PANEL INFERIOR DEL INDICADOR ATR
my $atr_frame = $mw->Frame(-bg => '#fbfcf8', -height => 160)->pack(-side => 'top', -fill => 'both', -expand => 0);

my $atr_main_row = $atr_frame->Frame(-bg => '#fbfcf8')->pack(-side => 'top', -fill => 'both', -expand => 1);

# Empaquetamos PRIMERO el eje del ATR a la derecha
my $atr_axis_canvas = $atr_main_row->Canvas(-bg => '#fbfcf8', -width => 75, -highlightthickness => 0)
                                    ->pack(-side => 'right', -fill => 'y');

# LUEGO el lienzo de la curva ATR a la izquierda
my $atr_canvas = $atr_main_row->Canvas(-bg => '#fbfcf8', -highlightthickness => 0)
                               ->pack(-side => 'left', -fill => 'both', -expand => 1);


# 2. Instanciación e interconexión de las capas arquitectónicas
my $market_data       = Market::MarketData->new();       
my $indicator_manager = Market::IndicatorManager->new(); 

# Capa 4: Aplicación (Orquestador Central - Inyectamos las nuevas referencias de ejes)
$chart_engine = Market::ChartEngine->new(
    market_data       => $market_data,
    indicator_manager => $indicator_manager,
    price_canvas      => $price_canvas,
    price_axis_canvas => $price_axis_canvas, # Inyección del eje vertical de precios
    time_canvas       => $time_canvas,       # Inyección del eje horizontal de tiempo
    atr_canvas        => $atr_canvas,
    atr_axis_canvas   => $atr_axis_canvas,   # Inyección del eje vertical de volatilidad
    widgets           => { main_window => $mw, scale_btn => $scale_btn }
);


# 3. Tareas secuenciales requeridas por el documento de requerimientos
my $archivo_csv = 'datos.csv';
open(my $fh, '<', $archivo_csv) or die "No se pudo abrir el archivo '$archivo_csv' $!\n";
my $encabezado = <$fh>;

my $atr_real = Market::Indicators::ATR->new(14);
$indicator_manager->register('ATR', $atr_real);

while (my $linea = <$fh>) {
    chomp $linea;
    my ($time, $open, $high, $low, $close, $volume) = split(',', $linea);
    
    $market_data->add_candle({
        time   => $time,
        open   => $open,
        high   => $high,
        low    => $low,
        close  => $close,
        volume => $volume
    });
    $indicator_manager->update_last($market_data);
}
close($fh);
print "Datos del CSV cargados exitosamente. Total de velas: " . $market_data->size() . "\n";

$market_data->build_timeframes();
$indicator_manager->update_last($market_data);
# ---------------------------------------------------------------------

# Inicialización y renderizado del entorno visual
$chart_engine->bind_all_canvas();
$chart_engine->bind_events();
$chart_engine->render();

# 4. Lanzamiento del ciclo principal de escucha de eventos de la interfaz
MainLoop;