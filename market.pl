
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin"; # Permite a Perl buscar los módulos locales en el directorio de ejecución

use Tk;
use Market::MarketData;
use Market::IndicatorManager;
use Market::ChartEngine;

# =========================================================================
#   FASES DE EJECUCIÓN CENTRAL (MARKET.PL)
# =========================================================================

# 1. Configuración del contenedor principal de la interfaz gráfica (Tk)
my $mw = MainWindow->new();
$mw->title("Replica Financiera TradingView - EPN");
$mw->geometry("1024x768");

# Creación de layouts verticales independientes para los dos paneles
my $price_frame = $mw->Frame()->pack(-fill => 'both', -expand => 1);
my $atr_frame   = $mw->Frame()->pack(-fill => 'both', -expand => 1);

# Inicialización de los lienzos (Canvases) con fondo oscuro estilo TradingView
my $price_canvas = $price_frame->Canvas(-bg => '#131722')->pack(-fill => 'both', -expand => 1);
my $atr_canvas   = $atr_frame->Canvas(-bg => '#131722')->pack(-fill => 'both', -expand => 1);


# 2. Instanciación e interconexión de las capas arquitectónicas
my $market_data       = Market::MarketData->new();       # Capa 1: Datos
my $indicator_manager = Market::IndicatorManager->new(); # Capa 2: Indicadores

# Capa 4: Aplicación (Orquestador Central)
my $chart_engine = Market::ChartEngine->new(
    market_data       => $market_data,
    indicator_manager => $indicator_manager,
    price_canvas      => $price_canvas,
    atr_canvas        => $atr_canvas,
    widgets           => { main_window => $mw }
);


# 3. Tareas secuenciales requeridas por el documento de requerimientos
# Tarea A: Invoca la lectura de los datos (Día 1: Datos Mock/Simulados básicos)

my $candle = {
    time   => '2026-04-01T00:00:00-05:00',
    open   => 24013.75,
    high   => 24013.75,
    low    => 24007.50,
    close  => 24009.25,
    volume => 67
};
$market_data->add_candle($candle); # Agrega la vela al arreglo interno de velas (candles) en MarketData.pm

# # Tarea B: Invoca la actualización del mercado entre distintas temporalidades
# $market_data->build_timeframes();

# # Tarea C: Invoca la actualización de los indicadores desacoplados
# $indicator_manager->update_last($market_data);

# # Tarea D: Dibuja el primer chart visual en pantalla
# $chart_engine->render();


# 4. Lanzamiento del ciclo principal de escucha de eventos de la interfaz
MainLoop;