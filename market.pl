
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

# =========================================================================
# Tarea A: Lectura del archivo CSV real e inyección de datos (Día 4)
# =========================================================================

# Abrimos el archivo de forma segura. (Asegúrate de tener el archivo datos.csv en la misma carpeta)
my $archivo_csv = 'datos.csv';
open(my $fh, '<', $archivo_csv) or die "No se pudo abrir el archivo '$archivo_csv' $!\n";

# Descartamos la primera línea si el CSV tiene encabezados (Time, Open, High, Low, Close, Volume)
my $encabezado = <$fh>;

# Leemos línea por línea de forma eficiente (No satura la RAM de golpe)
while (my $linea = <$fh>) {
    chomp $linea;
    
    # Separamos los valores por comas
    my ($time, $open, $high, $low, $close, $volume) = split(',', $linea);
    
    # Inyectamos la vela directamente al contenedor de Josué
    $market_data->add_candle({
        time   => $time,
        open   => $open,
        high   => $high,
        low    => $low,
        close  => $close,
        volume => $volume
    });
}

close($fh);
print "Datos del CSV cargados exitosamente. Total de velas: " . $market_data->size() . "\n";

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