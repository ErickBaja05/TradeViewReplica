
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
$mw->geometry("1720x900");

# Creación de layouts verticales independientes para los dos paneles
my $price_frame = $mw->Frame()->pack(-fill => 'both', -expand => 1);
my $atr_frame   = $mw->Frame()->pack(-fill => 'both', -expand => 1);

# Inicialización de los lienzos (Canvases)
my $price_canvas = $price_frame->Canvas()->pack(-fill => 'both', -expand => 1);
my $atr_canvas   = $atr_frame->Canvas()->pack(-fill => 'both', -expand => 1);


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

# Tarea A: Invoca la lectura de los datos (Mock de 150 velas)
my $precio_actual = 24000;

#$market_data->get_data(); DESCOMENTAR Y BORRAR EL BUCLE FOR CUANDO EN GET DATA YA SE HAYA IMPLEMENTADO LA LECTURA DE DATOS REALES DESDE ARCHIVO O API. ESTE BUCLE SOLO SIRVE PARA SIMULAR DATOS EN ESTA FASE INICIAL.

for my $i (0 .. 150) {
    # Generamos variaciones aleatorias para simular el mercado
    my $open  = $precio_actual + (rand(20) - 10);
    my $close = $open + (rand(20) - 10);
    my $high  = ($open > $close ? $open : $close) + rand(10);
    my $low   = ($open < $close ? $open : $close) - rand(10);
    
    $market_data->add_candle({
        time   => "2026-04-01T00:00:$i",
        open   => $open,
        high   => $high,
        low    => $low,
        close  => $close,
        volume => int(rand(100)) + 10
    });
    
    # Actualizamos el precio base para la siguiente vela
    $precio_actual = $close;
}

#Tarea B: Invoca la actualización del mercado entre distintas temporalidades
$market_data->build_timeframes();

#Tarea C: Invoca la actualización de los indicadores desacoplados
$indicator_manager->update_last($market_data);

#Tarea D: Dibuja el primer chart visual en pantalla

# Activación de los escuchadores de eventos para el Día 3
$chart_engine->bind_all_canvas();
$chart_engine->bind_events();
$chart_engine->render();


# 4. Lanzamiento del ciclo principal de escucha de eventos de la interfaz
MainLoop;