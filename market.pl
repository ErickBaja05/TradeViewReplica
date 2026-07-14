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

# CAMBIAR ARCHIVO DE DATOS AQUI
my $filepath = '2026_07_13.csv';

my $mw = MainWindow->new();
$mw->title("Replica Financiera TradingView - EPN");

my $width  = $mw->screenwidth;
my $height = $mw->screenheight;

$mw->geometry("${width}x${height}+0+0");

# --- BARRA SUPERIOR DE CONTROL DE INTERFAZ ---
my $control_panel = $mw->Frame(-bg => '#fbfcf8', -relief => 'raised', -bd => 1)
                       ->pack(-side => 'top', -fill => 'x', -ipady => 4);

# Control de Temporalidades (1m, 5m, 15m, 1h, 2h, 4h, 1d) mediante un menú
# desplegable único, en lugar de un botón por cada temporalidad.
my $tf_label = $control_panel->Label(-text => "Temporalidad:", -bg => '#fbfcf8', -fg => '#b1b5be', -font => 'Arial 10 bold')
                             ->pack(-side => 'left', -padx => 10);

# Declaración adelantada de la referencia del motor para usar en los callbacks
my $chart_engine;

# Declaración adelantada de la etiqueta de estado del VWAP Anclado (se crea
# más abajo, pero se usa desde callbacks definidos antes en el archivo)
my $vwap_status_label;

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
    show_zigzag_ext   => 0,
    show_bos_ext      => 0,
    show_choch_ext    => 0,
    show_eqh          => 0,
    show_eql          => 0,
    show_fibonacci    => 0,
    show_levels       => 0,

    show_swing        => 0,
    show_zigzag_int   => 0,
    show_bos_int      => 0,
    show_choch_int    => 0,

    show_bsl          => 0,
    show_ssl          => 0,
    show_lq_sweep     => 0,
    show_lq_grab      => 0,
    show_lq_run       => 0,

    show_supertrend   => 0,
    show_halftrend    => 0,
    show_fvg          => 0,
    show_orderblocks  => 0,
    show_channel      => 0,

    show_vwap_anchored => 0,
    show_volume_profile_anchored => 0,
);

# Estructura agrupada: cada grupo tiene un nombre visible, una "master var"
# propia que controla el checkbutton maestro, y la lista de items (label, key, color)
# que pertenecen a ese grupo.
my %master_vars = (
    Structure            => 0,
    'Internal Structure' => 0,
    Liquidity            => 0,
    Strategy             => 0,
);

my @groups = (
    {
        name  => 'Structure',
        items => [
            ["ZigZag Externo",            "show_zigzag_ext",  "#2962ff"],
            ["BOS Externo",               "show_bos_ext",     "#089981"],
            ["CHoCH Externo",             "show_choch_ext",   "#F23645"],
            ["EQH",                       "show_eqh",         "#26a69a"],
            ["EQL",                       "show_eql",         "#ef5350"],
            ["Fibonacci",                 "show_fibonacci",   "#9c27b0"],
            ["Levels",                    "show_levels",      "#2962ff"],
        ],
    },
    {
        name  => 'Internal Structure',
        items => [
            ["SH y SL",                   "show_swing",  "#00ff0d"],
            ["BOS Interno",               "show_bos_int",     "#26a69a"],
            ["CHoCH Interno",             "show_choch_int",   "#ef5350"],
            ["Zigzag Interno",            "show_zigzag_int",  "#787b86"],
        ],
    },
    {
        name  => 'Liquidity',
        items => [
            ["BSL (Buy Side Liquidity)",  "show_bsl",         "#ef5350"],
            ["SSL (Sell Side Liquidity)", "show_ssl",         "#26a69a"],
            ["LQ Sweep",                  "show_lq_sweep",    "#FF0044"],
            ["LQ Grab",                   "show_lq_grab",     "#FF8C00"],
            ["LQ Run",                    "show_lq_run",      "#2962FF"],
        ],
    },
    {
        name  => 'Strategy',
        items => [
            ["SuperTrend",                "show_supertrend",  "#26a69a"],
            ["HalfTrend",                 "show_halftrend",   "#2962ff"],
            ["FVG",                       "show_fvg",         "#e91e63"],
            ["Order Blocks",              "show_orderblocks", "#f0d908"],
            ["Channel",                   "show_channel",     "#337c4f"],
        ],
    },
);

# Sincroniza el estado del checkbutton maestro de un grupo en función de si
# todos sus items individuales están activados (1) o no (0). Un estado mixto
# se representa como 0 para evitar inducir a error visual.
sub sync_master {
    my ($group) = @_;
    my $all_on = 1;
    for my $item (@{ $group->{items} }) {
        my (undef, $key) = @$item;
        $all_on = 0 unless $vars{$key};
    }
    $master_vars{ $group->{name} } = $all_on ? 1 : 0;
}

for my $group (@groups) {
    my $gname = $group->{name};

    # ── Checkbutton maestro del grupo ───────────────────────────────
    $menu->checkbutton(
        -label            => "\x{25B8} $gname",
        -variable         => \$master_vars{$gname},
        -font             => 'Arial 9 bold',
        -foreground       => '#131722',
        -activeforeground => '#131722',
        -selectcolor      => '#131722',
        -command          => sub {
            my $nuevo_estado = $master_vars{$gname};

            # Propagamos el nuevo estado a todos los checkbuttons del grupo
            for my $item (@{ $group->{items} }) {
                my (undef, $key) = @$item;
                $vars{$key} = $nuevo_estado;
                if ($chart_engine) {
                    $chart_engine->{$key} = $vars{$key};
                }
            }

            $chart_engine->request_render() if $chart_engine;
        },
    );

    $menu->separator;

    for my $item (@{ $group->{items} }) {
        my ($label, $key, $color) = @$item;

        $menu->checkbutton(
            -label            => "    $label",
            -variable         => \$vars{$key},
            -foreground       => $color,
            -activeforeground => $color,
            -selectcolor      => $color,
            -command          => sub {
                return unless $chart_engine;
                $chart_engine->{$key} = $vars{$key};

                # Reflejamos el nuevo estado individual en el checkbutton maestro
                sync_master($group);

                $chart_engine->request_render();
            },
        );
    }

    # ── Selector de temporalidad "Multi Time Frame" del Zigzag Interno ──
    # Réplica del input "ZigZag Resolution" del indicador PineScript de
    # referencia (zzmtf.txt): permite calcular el zigzag interno sobre una
    # temporalidad distinta a la que se está graficando en pantalla.
    if ($gname eq 'Internal Structure') {

        my @zz_int_timeframes = ('15m', '1h', '2h', '4h', '1d');
        my $zz_int_tf_seleccionada = '1h';

        my $cascade_index;
        my $zz_int_submenu = $menu->Menu(-tearoff => 0);

        for my $tf_opt (@zz_int_timeframes) {
            $zz_int_submenu->radiobutton(
                -label     => "    $tf_opt",
                -variable  => \$zz_int_tf_seleccionada,
                -value     => $tf_opt,
                -command   => sub {
                    $zz_int_tf_seleccionada = $tf_opt;

                        $menu->entryconfigure(
                        $cascade_index,
                            -label => "    Temporalidad de Zigzag Interno ($zz_int_tf_seleccionada)"
                        );

                    $chart_engine->set_zigzag_internal_timeframe($tf_opt) if $chart_engine;
                },
            );
        }

        $cascade_index = $menu->index('end') + 1;

        $menu->cascade(
            -label     => "    Temporalidad de Zigzag Interno ($zz_int_tf_seleccionada)",
            -menu      => $zz_int_submenu,
            -foreground => '#787b86',
        );
    }

    $menu->separator unless $gname eq $groups[-1]->{name};
}

# Espaciador estético intermedio
$control_panel->Label(-text => " | ", -bg => '#fbfcf8', -fg => '#d1d4dc')->pack(-side => 'left', -padx => 10);

my $anchored_indicator_label = $control_panel->Label(-text => "Indicadores Anclados:", -bg => '#fbfcf8', -fg => '#b1b5be', -font => 'Arial 10 bold')
                             ->pack(-side => 'left', -padx => 10);


my $anchor_menu = $control_panel->Menubutton(
    -text             => "Anchored Indicators",
    -bg               => '#ffffff',
    -fg               => '#131722',
    -activebackground => '#75bbfd',
    -activeforeground => 'white',
    -relief           => 'raised',
    -cursor           => 'hand2',
)->pack(-side => 'left', -padx => 5);

my $menu2 = $anchor_menu->Menu(-tearoff => 0);
$anchor_menu->configure(-menu => $menu2);

# ── VWAP Anclado (Anchored VWAP) ────────────────────────────────────
# A diferencia del resto de indicadores, este no se activa/desactiva de
# forma directa: al marcarlo, el usuario debe hacer click sobre la vela
# que quiere usar como ancla (igual que la herramienta de TradingView).

$menu2->checkbutton(
    -label            => "    VWAP Anclado (click en vela)",
    -variable         => \$vars{show_vwap_anchored},
    -foreground       => '#ff8800',
    -activeforeground => '#ff8800',
    -selectcolor      => '#ff8800',
    -command          => sub {
        return unless $chart_engine;

        if ($vars{show_vwap_anchored}) {
            # El usuario acaba de marcarlo: en vez de activarlo de inmediato,
            # entramos en modo de selección y esperamos su click sobre una vela.
            $vwap_status_label->configure(-text => "VWAP: haz click en una vela para anclar (Esc/click-derecho cancela)")
                if $vwap_status_label;
            $chart_engine->activate_vwap_anchor_selection();
        }
        else {
            # El usuario lo desmarcó: se oculta el indicador por completo.
            $chart_engine->{show_vwap_anchored}         = 0;
            $chart_engine->{vwap_anchor_selection_mode} = 0;
            $vwap_status_label->configure(-text => "") if $vwap_status_label;
            $chart_engine->request_render();
        }
    },
);

# ── Rango de sigmas del VWAP Anclado (1, 2 o 3) ─────────────────────
# Submenú (cascade) con opciones de radiobutton que define cuántas bandas de
# desviación estándar se dibujan alrededor de la línea central del VWAP:
#   1 sigma => vwap + rango de 1 sigma
#   2 sigma => vwap + rango de 1 sigma + rango de 2 sigma (colores distintos)
#   3 sigma => vwap + rango de 1 sigma + rango de 2 sigma + rango de 3 sigma
my $vwap_sigma_seleccionada = 1;

my $vwap_sigma_submenu = $menu2->Menu(-tearoff => 0);

for my $n (1, 2, 3) {
    $vwap_sigma_submenu->radiobutton(
        -label            => "    $n sigma" . ($n == 1 ? '' : 's'),
        -variable         => \$vwap_sigma_seleccionada,
        -value            => $n,
        -foreground       => '#ff8800',
        -activeforeground => '#ff8800',
        -selectcolor      => '#ff8800',
        -command          => sub {
            $chart_engine->set_vwap_sigma_range($n) if $chart_engine;
        },
    );
}

$menu2->cascade(
    -label      => "    Rango de Sigma (VWAP Anclado)",
    -menu       => $vwap_sigma_submenu,
    -foreground => '#ff8800',
);

# ── Volume Profile Anclado (Anchored Volume Profile, 1 sigma) ──────
# Igual que el VWAP Anclado: al marcarlo, el usuario debe hacer click sobre
# la vela que quiere usar como ancla del histograma de volumen.
$menu2->checkbutton(
    -label            => "    Volume Profile Anclado (click en vela)",
    -variable         => \$vars{show_volume_profile_anchored},
    -foreground       => '#2962ff',
    -activeforeground => '#2962ff',
    -selectcolor      => '#2962ff',
    -command          => sub {
        return unless $chart_engine;

        if ($vars{show_volume_profile_anchored}) {
            # El usuario acaba de marcarlo: entramos en modo de selección y
            # esperamos su click sobre una vela.
            $vwap_status_label->configure(-text => "Volume Profile: haz click en una vela para anclar (Esc/click-derecho cancela)")
                if $vwap_status_label;
            $chart_engine->activate_volume_profile_anchor_selection();
        }
        else {
            # El usuario lo desmarcó: se oculta el indicador por completo.
            $chart_engine->{show_volume_profile_anchored}         = 0;
            $chart_engine->{volume_profile_anchor_selection_mode} = 0;
            $vwap_status_label->configure(-text => "") if $vwap_status_label;
            $chart_engine->request_render();
        }
    },
);

# ── Rango de sigmas del Volume Profile Anclado (1, 2 o 3) ──────────
# Igual que el submenú del VWAP Anclado, pero aquí los rangos de sigma se
# dibujan siempre como líneas VAH/VAL sueltas (nunca como bandas/canales
# rellenos).
my $vp_sigma_seleccionada = 1;

my $vp_sigma_submenu = $menu2->Menu(-tearoff => 0);

for my $n (1, 2, 3) {
    $vp_sigma_submenu->radiobutton(
        -label            => "    $n sigma" . ($n == 1 ? '' : 's'),
        -variable         => \$vp_sigma_seleccionada,
        -value            => $n,
        -foreground       => '#2962ff',
        -activeforeground => '#2962ff',
        -selectcolor      => '#2962ff',
        -command          => sub {
            $chart_engine->set_volume_profile_sigma_range($n) if $chart_engine;
        },
    );
}

$menu2->cascade(
    -label      => "    Rango de Sigma (Volume Profile)",
    -menu       => $vp_sigma_submenu,
    -foreground => '#2962ff',
);

# Espaciador estético intermedio
$control_panel->Label(-text => " | ", -bg => '#fbfcf8', -fg => '#d1d4dc')->pack(-side => 'left', -padx => 10);

# Checkbutton para mostrar/ocultar la línea + etiqueta del último precio visible
my $show_last_price_var = 1;
$control_panel->Checkbutton(
    -text             => "Ultimo Precio",
    -variable         => \$show_last_price_var,
    -bg               => '#fbfcf8',
    -fg               => '#000000',
    -activebackground => '#fbfcf8',
    -activeforeground => '#000000',
    -selectcolor      => '#000000',
    -font             => 'Arial 10 bold',
    -cursor           => 'hand2',
    -command          => sub {
        return unless $chart_engine;
        $chart_engine->{show_last_price} = $show_last_price_var;
        $chart_engine->request_render();
    },
)->pack(-side => 'left', -padx => 5);

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

# Etiqueta de estado para guiar al usuario mientras selecciona la vela de
# ancla del VWAP (queda vacía el resto del tiempo)
$vwap_status_label = $control_panel->Label(
    -text => "", -bg => '#fbfcf8', -fg => '#2962ff', -font => 'Arial 9 bold'
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

# Callback invocado por el motor cuando la selección de ancla del VWAP se
# cancela (tecla Escape o click-derecho) sin haber elegido ninguna vela:
# sincronizamos el checkbutton y limpiamos el mensaje de estado.
$chart_engine->{on_vwap_selection_cancelled} = sub {
    $vars{show_vwap_anchored} = 0;
    $vwap_status_label->configure(-text => "") if $vwap_status_label;
};

# Callback invocado cuando el usuario efectivamente ancla el VWAP en una
# vela: limpiamos el mensaje de estado (el checkbutton ya queda marcado).
$chart_engine->{on_vwap_anchor_set} = sub {
    $vwap_status_label->configure(-text => "") if $vwap_status_label;
};

# Mismos callbacks para el Volume Profile Anclado, reutilizando la etiqueta
# de estado compartida (sólo uno de los dos modos de selección puede estar
# activo a la vez).
$chart_engine->{on_volume_profile_selection_cancelled} = sub {
    $vars{show_volume_profile_anchored} = 0;
    $vwap_status_label->configure(-text => "") if $vwap_status_label;
};

$chart_engine->{on_volume_profile_anchor_set} = sub {
    $vwap_status_label->configure(-text => "") if $vwap_status_label;
};


# 3. Tareas secuenciales requeridas por el documento de requerimientos
my $archivo_csv = $filepath;
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
