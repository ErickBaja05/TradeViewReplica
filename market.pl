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

# Declaración adelantada de la referencia del motor para usar en los callbacks
my $chart_engine;

# --- MENÚ DESPLEGABLE "CONFIGURACIÓN" ---
# Agrupa ajustes generales de la vista que antes eran controles sueltos en
# la barra: mostrar/ocultar el último precio, alternar la escala
# Auto/Manual y restablecer la vista a sus valores por defecto.
my $show_last_price_var = 1;
my $auto_scale_var      = 1;

my $config_menu_btn = $control_panel->Menubutton(
    -text             => "Configuracion",
    -bg               => '#ffffff',
    -fg               => '#131722',
    -activebackground => '#75bbfd',
    -activeforeground => 'white',
    -relief           => 'raised',
    -cursor           => 'hand2',
)->pack(-side => 'left', -padx => 5);

my $config_menu = $config_menu_btn->Menu(-tearoff => 0);
$config_menu_btn->configure(-menu => $config_menu);

# Checkbutton: mostrar/ocultar la línea + etiqueta del último precio visible
$config_menu->checkbutton(
    -label            => "    Ultimo Precio",
    -variable         => \$show_last_price_var,
    -foreground       => '#131722',
    -activeforeground => '#131722',
    -selectcolor      => '#131722',
    -command          => sub {
        return unless $chart_engine;
        $chart_engine->{show_last_price} = $show_last_price_var;
        $chart_engine->request_render();
    },
);

# Checkbutton: alterna el Modo de Escala (Auto / Manual). La casilla se
# mantiene sincronizada aunque el modo cambie desde otro lugar (por
# ejemplo al "Restablecer Vista"), ya que ChartEngine::set_auto_scale
# actualiza directamente esta misma variable.
$config_menu->checkbutton(
    -label            => "    Escala Automatica",
    -variable         => \$auto_scale_var,
    -foreground       => '#131722',
    -activeforeground => '#131722',
    -selectcolor      => '#131722',
    -command          => sub {
        return unless $chart_engine;
        $chart_engine->set_auto_scale($auto_scale_var);
        $chart_engine->request_render();
    },
);

$config_menu->separator;

# Comando: restablece los parámetros visuales (Reset View)
$config_menu->command(
    -label            => "    Restablecer Vista (R)",
    -foreground       => '#131722',
    -activeforeground => '#131722',
    -command          => sub {
        return unless $chart_engine;
        $chart_engine->reset_view();
    },
);

# Espaciador estético intermedio
$control_panel->Label(-text => "|", -bg => '#fbfcf8', -fg => '#d1d4dc')->pack(-side => 'left', -padx => 10);

# Control de Temporalidades (1m, 5m, 15m, 1h, 2h, 4h, 1d) mediante un menú
# desplegable único, en lugar de un botón por cada temporalidad.
my $tf_label = $control_panel->Label(-text => "Temporalidad:", -bg => '#fbfcf8', -fg => '#b1b5be', -font => 'Arial 10 bold')
                             ->pack(-side => 'left', -padx => 10);

# Declaración adelantada de la etiqueta de estado del VWAP Anclado (se crea
# más abajo, pero se usa desde callbacks definidos antes en el archivo)
my $vwap_status_label;

my @temporalidades = ('1m', '5m', '15m', '30m', '1h', '2h', '4h', '1d', '1w');
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
$control_panel->Label(-text => "|", -bg => '#fbfcf8', -fg => '#d1d4dc')->pack(-side => 'left', -padx => 10);

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
    show_range_filter => 0,
    show_fvg          => 0,
    show_orderblocks  => 0,
    show_trendchannel => 0,

    show_channel      => 0,

    show_vwap_anchored => 0,
    show_volume_profile_anchored => 0,

    show_ghost_anchors => 0,
    show_ghost_lines   => 0,
    show_ghost_vwap    => 0,
    show_multi_vwap    => 0,
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
            #["Range Filter",              "show_range_filter","#ff9800"],
            ["FVG",                       "show_fvg",         "#e91e63"],
            ["Order Blocks",              "show_orderblocks", "#f0d908"],
            #["Trend Channel",             "show_trendchannel","#2196f3"],
            ["Channel",                   "show_channel",     "#9c27b0"],
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

        my @zz_int_timeframes = ('15m', '30m', '1h', '2h', '4h', '1d', '1w');
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
# $control_panel->Label(-text => "|", -bg => '#fbfcf8', -fg => '#d1d4dc')->pack(-side => 'left', -padx => 10);

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
# que quiere usar como ancla (igual que la herramienta de TradingView),
# salvo que el modo de ancla elegido sea uno de los automáticos.

# Modo de ancla actualmente seleccionado en el submenú "Ancla (VWAP
# Anclado)" (ver más abajo). Declarado aquí arriba porque el checkbutton
# principal ya lo necesita en su -command. Por defecto "inicio de sesión".
my $vwap_anchor_mode_seleccionada = 'session_start';

$menu2->checkbutton(
    -label            => "    VWAP Anclado",
    -variable         => \$vars{show_vwap_anchored},
    -foreground       => '#ff8800',
    -activeforeground => '#ff8800',
    -selectcolor      => '#ff8800',
    -command          => sub {
        return unless $chart_engine;

        if ($vars{show_vwap_anchored}) {
            if ($vwap_anchor_mode_seleccionada eq 'pivot') {
                # Modo "Elegir pivote": en vez de activarlo de inmediato,
                # entramos en modo de selección y esperamos su click sobre
                # una vela (comportamiento clásico).
                $vwap_status_label->configure(-text => "VWAP: haz click en una vela para anclar")
                    if $vwap_status_label;
                $chart_engine->activate_vwap_anchor_selection();
            }
            else {
                # Resto de modos: el ancla se calcula sola (inicio de
                # sesión, apertura, BOS o CHoCH confirmados), sin necesidad
                # de click.
                $chart_engine->set_vwap_anchor_mode($vwap_anchor_mode_seleccionada);
            }
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

# ── Ancla del VWAP Anclado (igual que el submenú de sigmas) ────────
# Define de dónde parte el cálculo del VWAP Anclado:
#   "Inicio de sesión"  => primera vela de todo el historial (por defecto)
#   "Apertura"           => primera vela de la última apertura de mercado
#                            (tras el mayor hueco de tiempo detectado)
#   "BOS confirmado"     => vela de cierre del último BOS externo
#   "CHoCH confirmado"   => vela de cierre del último CHoCH externo
#   "Elegir pivote"       => selección manual por click (lógica actual)

my @vwap_anchor_modes = (
    { value => 'session_start',   label => 'Inicio de sesion' },
    { value => 'session_open',    label => 'Apertura' },
    { value => 'bos_confirmed',   label => 'BOS confirmado' },
    { value => 'choch_confirmed', label => 'CHoCH confirmado' },
    { value => 'pivot',           label => 'Elegir pivote' },
);

my $vwap_anchor_mode_submenu = $menu2->Menu(-tearoff => 0);

for my $opt (@vwap_anchor_modes) {
    my $value = $opt->{value};

    $vwap_anchor_mode_submenu->radiobutton(
        -label            => "    $opt->{label}",
        -variable         => \$vwap_anchor_mode_seleccionada,
        -value            => $value,
        -foreground       => '#ff8800',
        -activeforeground => '#ff8800',
        -selectcolor      => '#ff8800',
        -command          => sub {
            return unless $chart_engine;

            if ($value eq 'pivot') {
                $chart_engine->{vwap_anchor_mode} = 'pivot';

                if ($vars{show_vwap_anchored}) {
                    # El indicador ya estaba activo: pedimos el click ahora.
                    $vwap_status_label->configure(-text => "VWAP: haz click en una vela para anclar")
                        if $vwap_status_label;
                    $chart_engine->activate_vwap_anchor_selection();
                }
            }
            elsif ($vars{show_vwap_anchored}) {
                # El indicador ya estaba activo: recalculamos el ancla de
                # inmediato con el nuevo modo.
                $chart_engine->set_vwap_anchor_mode($value);
            }
            else {
                # El indicador todavía no está activo: sólo guardamos la
                # preferencia, se aplicará al marcar el checkbutton.
                $chart_engine->{vwap_anchor_mode} = $value;
            }
        },
    );
}

$menu2->cascade(
    -label      => "    Ancla (VWAP Anclado)",
    -menu       => $vwap_anchor_mode_submenu,
    -foreground => '#ff8800',
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
# la vela que quiere usar como ancla del histograma de volumen, salvo que
# el modo de ancla elegido sea uno de los automáticos.

# Modo de ancla actualmente seleccionado en el submenú "Ancla (Volume
# Profile Anclado)" (ver más abajo). Por defecto "inicio de sesión".
my $vp_anchor_mode_seleccionada = 'session_start';

$menu2->checkbutton(
    -label            => "    Volume Profile Anclado",
    -variable         => \$vars{show_volume_profile_anchored},
    -foreground       => '#2962ff',
    -activeforeground => '#2962ff',
    -selectcolor      => '#2962ff',
    -command          => sub {
        return unless $chart_engine;

        if ($vars{show_volume_profile_anchored}) {
            if ($vp_anchor_mode_seleccionada eq 'pivot') {
                # Modo "Elegir pivote": entramos en modo de selección y
                # esperamos su click sobre una vela (comportamiento clásico).
                $vwap_status_label->configure(-text => "Volume Profile: haz click en una vela para anclar")
                    if $vwap_status_label;
                $chart_engine->activate_volume_profile_anchor_selection();
            }
            else {
                # Resto de modos: el ancla se calcula sola (inicio de
                # sesión, apertura, BOS o CHoCH confirmados), sin necesidad
                # de click.
                $chart_engine->set_volume_profile_anchor_mode($vp_anchor_mode_seleccionada);
            }
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

# ── Ancla del Volume Profile Anclado (igual que la del VWAP Anclado) ──
my @vp_anchor_modes = (
    { value => 'session_start',   label => 'Inicio de sesion' },
    { value => 'session_open',    label => 'Apertura' },
    { value => 'bos_confirmed',   label => 'BOS confirmado' },
    { value => 'choch_confirmed', label => 'CHoCH confirmado' },
    { value => 'pivot',           label => 'Elegir pivote' },
);

my $vp_anchor_mode_submenu = $menu2->Menu(-tearoff => 0);

for my $opt (@vp_anchor_modes) {
    my $value = $opt->{value};

    $vp_anchor_mode_submenu->radiobutton(
        -label            => "    $opt->{label}",
        -variable         => \$vp_anchor_mode_seleccionada,
        -value            => $value,
        -foreground       => '#2962ff',
        -activeforeground => '#2962ff',
        -selectcolor      => '#2962ff',
        -command          => sub {
            return unless $chart_engine;

            if ($value eq 'pivot') {
                $chart_engine->{volume_profile_anchor_mode} = 'pivot';

                if ($vars{show_volume_profile_anchored}) {
                    # El indicador ya estaba activo: pedimos el click ahora.
                    $vwap_status_label->configure(-text => "Volume Profile: haz click en una vela para anclar")
                        if $vwap_status_label;
                    $chart_engine->activate_volume_profile_anchor_selection();
                }
            }
            elsif ($vars{show_volume_profile_anchored}) {
                # El indicador ya estaba activo: recalculamos el ancla de
                # inmediato con el nuevo modo.
                $chart_engine->set_volume_profile_anchor_mode($value);
            }
            else {
                # El indicador todavía no está activo: sólo guardamos la
                # preferencia, se aplicará al marcar el checkbutton.
                $chart_engine->{volume_profile_anchor_mode} = $value;
            }
        },
    );
}

$menu2->cascade(
    -label      => "    Ancla (Volume Profile Anclado)",
    -menu       => $vp_anchor_mode_submenu,
    -foreground => '#2962ff',
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

# ── Número de barras del histograma (Volume Profile Anclado) ───────
# Tk::Menu no admite widgets arbitrarios (como un Scale) embebidos
# directamente en sus entradas, así que este ítem abre una pequeña
# ventana emergente (Toplevel) con el deslizador. Límites prudentes:
# muy pocas franjas (< 10) hacen el histograma poco informativo, y
# demasiadas (> 150) son costosas de calcular/dibujar y dejan de
# aportar detalle útil sobre el rango de precios visible.
my $vp_num_bins_min = 10;
my $vp_num_bins_max = 150;
my $vp_num_bins_seleccionada = 24;
my $vp_num_bins_dialog;

$menu2->command(
    -label      => "    Numero de Barras (Volume Profile)...",
    -foreground => '#2962ff',
    -command    => sub {
        return unless $chart_engine;

        # Si el diálogo ya está abierto, sólo lo traemos al frente.
        if ($vp_num_bins_dialog && Tk::Exists($vp_num_bins_dialog)) {
            $vp_num_bins_dialog->deiconify;
            $vp_num_bins_dialog->raise;
            return;
        }

        $vp_num_bins_dialog = $mw->Toplevel(-bg => '#fbfcf8');
        $vp_num_bins_dialog->title("Volume Profile: numero de barras");
        $vp_num_bins_dialog->geometry('320x110');
        $vp_num_bins_dialog->resizable(0, 0);

        $vp_num_bins_dialog->Label(
            -text => "Numero de barras del histograma",
            -bg   => '#fbfcf8',
            -fg   => '#131722',
        )->pack(-side => 'top', -pady => [6, 2]);

        $vp_num_bins_dialog->Scale(
            -orient      => 'horizontal',
            -from        => $vp_num_bins_min,
            -to          => $vp_num_bins_max,
            -resolution  => 1,
            -tickinterval=> 0,
            -length      => 280,
            -bg          => '#fbfcf8',
            -fg          => '#2962ff',
            -variable    => \$vp_num_bins_seleccionada,
            -command     => sub {
                my ($val) = @_;
                return unless $chart_engine;
                $chart_engine->set_volume_profile_num_bins($val);
            },
        )->pack(-side => 'top', -padx => 15, -fill => 'x');

        $vp_num_bins_dialog->protocol('WM_DELETE_WINDOW', sub {
            $vp_num_bins_dialog->withdraw;
        });
    },
);

# ── Anchors: Ghost Anchors / Ghost Lines / Ghost VWAP ───────────────
# Los tres overlays comparten un único motor de cálculo incremental
# (Market::Indicators::Anchors), pero cada uno es un simple indicador
# on/off independiente (no requiere seleccionar una vela de ancla con
# click, a diferencia del VWAP/Volume Profile Anclados de arriba).
$menu2->separator;

$menu2->checkbutton(
    -label            => "    Ghost Anchors",
    -variable         => \$vars{show_ghost_anchors},
    -foreground       => '#ef5350',
    -activeforeground => '#ef5350',
    -selectcolor      => '#ef5350',
    -command          => sub {
        return unless $chart_engine;
        $chart_engine->{show_ghost_anchors} = $vars{show_ghost_anchors};
        $chart_engine->request_render();
    },
);

$menu2->checkbutton(
    -label            => "    Ghost Lines",
    -variable         => \$vars{show_ghost_lines},
    -foreground       => '#ef5350',
    -activeforeground => '#ef5350',
    -selectcolor      => '#ef5350',
    -command          => sub {
        return unless $chart_engine;
        $chart_engine->{show_ghost_lines} = $vars{show_ghost_lines};
        $chart_engine->request_render();
    },
);

$menu2->checkbutton(
    -label            => "    Ghost VWAP",
    -variable         => \$vars{show_ghost_vwap},
    -foreground       => '#ab47bc',
    -activeforeground => '#ab47bc',
    -selectcolor      => '#ab47bc',
    -command          => sub {
        return unless $chart_engine;
        $chart_engine->{show_ghost_vwap} = $vars{show_ghost_vwap};
        $chart_engine->request_render();
    },
);

# ── Rango de sigmas del Ghost VWAP (1, 2 o 3) ───────────────────────
my $ghost_vwap_sigma_seleccionada = 1;

my $ghost_vwap_sigma_submenu = $menu2->Menu(-tearoff => 0);

for my $n (1, 2, 3) {
    $ghost_vwap_sigma_submenu->radiobutton(
        -label            => "    $n sigma" . ($n == 1 ? '' : 's'),
        -variable         => \$ghost_vwap_sigma_seleccionada,
        -value            => $n,
        -foreground       => '#ab47bc',
        -activeforeground => '#ab47bc',
        -selectcolor      => '#ab47bc',
        -command          => sub {
            $chart_engine->set_ghost_vwap_sigma_range($n) if $chart_engine;
        },
    );
}

$menu2->cascade(
    -label      => "    Rango de Sigma (Ghost VWAP)",
    -menu       => $ghost_vwap_sigma_submenu,
    -foreground => '#ab47bc',
);

# ── Multi Anchored VWAP ──────────────────────────────────────────────
# VWAP Anclado automáticamente en CADA pivote detectado por el indicador
# "Anchors" (en vez de una sola ancla elegida manualmente con click).

$menu2->checkbutton(
    -label            => "    Multi Anchored VWAP",
    -variable         => \$vars{show_multi_vwap},
    -foreground       => '#2962ff',
    -activeforeground => '#2962ff',
    -selectcolor      => '#2962ff',
    -command          => sub {
        return unless $chart_engine;
        $chart_engine->{show_multi_vwap} = $vars{show_multi_vwap};
        $chart_engine->request_render();
    },
);

# ── Rango de sigmas del Multi Anchored VWAP (1, 2 o 3) ──────────────
my $multi_vwap_sigma_seleccionada = 1;

my $multi_vwap_sigma_submenu = $menu2->Menu(-tearoff => 0);

for my $n (1, 2, 3) {
    $multi_vwap_sigma_submenu->radiobutton(
        -label            => "    $n sigma" . ($n == 1 ? '' : 's'),
        -variable         => \$multi_vwap_sigma_seleccionada,
        -value            => $n,
        -foreground       => '#2962ff',
        -activeforeground => '#2962ff',
        -selectcolor      => '#2962ff',
        -command          => sub {
            $chart_engine->set_multi_vwap_sigma_range($n) if $chart_engine;
        },
    );
}

$menu2->cascade(
    -label      => "    Rango de Sigma (Multi Anchored VWAP)",
    -menu       => $multi_vwap_sigma_submenu,
    -foreground => '#2962ff',
);

# Espaciador estético intermedio
$control_panel->Label(-text => "|", -bg => '#fbfcf8', -fg => '#d1d4dc')->pack(-side => 'left', -padx => 10);

# --- MENÚ REPLAY ---
# Agrupa todos los controles de replay en un menú desplegable:
# - Iniciar REPLAY (entra en modo selección)
# - Controles de navegación: <<<<, <<, >>, >>>>
# - Reproducción automática: PLAY/STOP
# - Control de velocidad (slider en ventana emergente)
# - Salir (EXIT)
# --- MENÚ REPLAY ---
my ($replay_play_btn, $replay_stop_btn);
my $replay_speed_var = 1.0;
my $replay_status_label;
my $replay_playback_active = 0;

# Variables para guardar índices de las entradas del menú
my ($play_index, $stop_index, $speed_index, $exit_index);

my $replay_menu_btn = $control_panel->Menubutton(
    -text             => "REPLAY",
    -bg               => '#ffffff',
    -fg               => '#F23645',
    -activebackground => '#F23645',
    -activeforeground => 'white',
    -relief           => 'raised',
    -cursor           => 'hand2',
    -font             => 'Arial 9 bold',
)->pack(-side => 'left', -padx => 5);

my $replay_menu = $replay_menu_btn->Menu(-tearoff => 0);
$replay_menu_btn->configure(-menu => $replay_menu);

# --- Comando para iniciar REPLAY (modo selección) ---
$replay_menu->command(
    -label            => "    Iniciar Replay",
    -foreground       => '#F23645',
    -activeforeground => '#F23645',
    -command          => sub {
        return unless $chart_engine;
        $replay_status_label->configure(
            -text => "REPLAY: haz click en una vela para iniciar"
        ) if $replay_status_label;
        $chart_engine->activate_replay_selection();
    },
);

$replay_menu->separator;

# --- Submenú de Navegación ---
my $nav_submenu = $replay_menu->Menu(-tearoff => 0);

$nav_submenu->command(
    -label            => "    Retroceder 5 (<<<<)",
    -foreground       => '#131722',
    -activeforeground => '#131722',
    -state            => 'disabled',
    -command          => sub {
        $chart_engine->replay_backward(5) if $chart_engine;
    },
);

$nav_submenu->command(
    -label            => "    Retroceder (<<)",
    -foreground       => '#131722',
    -activeforeground => '#131722',
    -state            => 'disabled',
    -command          => sub {
        $chart_engine->replay_backward() if $chart_engine;
    },
);

$nav_submenu->command(
    -label            => "    Avanzar (>>)",
    -foreground       => '#131722',
    -activeforeground => '#131722',
    -state            => 'disabled',
    -command          => sub {
        $chart_engine->replay_forward() if $chart_engine;
    },
);

$nav_submenu->command(
    -label            => "    Avanzar 5 (>>>>)",
    -foreground       => '#131722',
    -activeforeground => '#131722',
    -state            => 'disabled',
    -command          => sub {
        $chart_engine->replay_forward(5) if $chart_engine;
    },
);

$replay_menu->cascade(
    -label      => "    Navegacion",
    -menu       => $nav_submenu,
    -foreground => '#131722',
);

$replay_menu->separator;

# --- Comando PLAY (reproducción automática) ---
# Guardamos el índice de esta entrada para modificarla después
$play_index = $replay_menu->index('end') + 1;

$replay_menu->command(
    -label            => "    > Play",
    -foreground       => '#26a69a',
    -activeforeground => '#26a69a',
    -state            => 'disabled',
    -command          => sub {
        return unless $chart_engine;
        
        # Si ya está reproduciendo, detener
        if ($replay_playback_active) {
            $chart_engine->replay_stop_playback();
        } else {
            $chart_engine->replay_play();
        }
    },
);

# --- Comando STOP (detener reproducción) ---
$stop_index = $replay_menu->index('end') + 1;

$replay_menu->command(
    -label            => "    o Stop",
    -foreground       => '#F23645',
    -activeforeground => '#F23645',
    -state            => 'disabled',
    -command          => sub {
        $chart_engine->replay_stop_playback() if $chart_engine;
    },
);

$replay_menu->separator;

# --- Comando para control de velocidad (abre diálogo con slider) ---
$speed_index = $replay_menu->index('end') + 1;

my $speed_dialog;

$replay_menu->command(
    -label            => "    Velocidad: 1.0x...",
    -foreground       => '#2962ff',
    -activeforeground => '#2962ff',
    -command          => sub {
        return unless $chart_engine;
        
        # Si el diálogo ya está abierto, sólo lo traemos al frente.
        if ($speed_dialog && Tk::Exists($speed_dialog)) {
            $speed_dialog->deiconify;
            $speed_dialog->raise;
            return;
        }
        
        $speed_dialog = $mw->Toplevel(-bg => '#fbfcf8');
        $speed_dialog->title("Velocidad de Reproduccion");
        $speed_dialog->geometry('320x110');
        $speed_dialog->resizable(0, 0);
        
        $speed_dialog->Label(
            -text => "Velocidad (velas por segundo)",
            -bg   => '#fbfcf8',
            -fg   => '#131722',
        )->pack(-side => 'top', -pady => [6, 2]);
        
        my $speed_value_label = $speed_dialog->Label(
            -text => sprintf("%.1fx", $replay_speed_var),
            -bg   => '#fbfcf8',
            -fg   => '#2962ff',
            -font => 'Arial 10 bold',
        )->pack(-side => 'top', -pady => 2);
        
        $speed_dialog->Scale(
            -orient      => 'horizontal',
            -from        => 0.2,
            -to          => 5.0,
            -resolution  => 0.1,
            -tickinterval=> 0,
            -length      => 280,
            -bg          => '#fbfcf8',
            -fg          => '#2962ff',
            -activebackground => '#75bbfd',
            -variable    => \$replay_speed_var,
            -command     => sub {
                my ($val) = @_;
                $speed_value_label->configure(-text => sprintf("%.1fx", $val));
                $chart_engine->set_replay_speed($val) if $chart_engine;
                
                # Actualizar la etiqueta del menú usando el índice guardado
                $replay_menu->entryconfigure(
                    $speed_index,
                    -label => sprintf("    Velocidad: %.1fx", $val)
                );
            },
        )->pack(-side => 'top', -padx => 15, -fill => 'x');
        
        $speed_dialog->protocol('WM_DELETE_WINDOW', sub {
            $speed_dialog->withdraw;
        });
    },
);

$replay_menu->separator;

# --- Comando EXIT (salir del modo replay) ---
$exit_index = $replay_menu->index('end') + 1;

$replay_menu->command(
    -label            => "    Exit Replay",
    -foreground       => '#787b86',
    -activeforeground => '#787b86',
    -state            => 'disabled',
    -command          => sub {
        $chart_engine->exit_replay() if $chart_engine;
    },
);

# Etiqueta de estado para guiar al usuario mientras selecciona la vela de
# inicio del Replay (queda vacía el resto del tiempo)
$replay_status_label = $control_panel->Label(
    -text => "", -bg => '#fbfcf8', -fg => '#F23645', -font => 'Arial 9 bold'
)->pack(-side => 'left', -padx => 10);

#--Fin SECCION REPLAY --

# Etiqueta de estado para guiar al usuario mientras selecciona la vela de
# ancla del VWAP (queda vacía el resto del tiempo)
$vwap_status_label = $control_panel->Label(
    -text => "", -bg => '#fbfcf8', -fg => '#2962ff', -font => 'Arial 9 bold'
)->pack(-side => 'left', -padx => 10);


# --- ESTRUCTURA MODULAR DE CONTENEDORES PARA EVITAR DEFORMACIÓN ---

# --- PROPORCIÓN VERTICAL 2/3 VELAS - 1/3 ATR ---
# Forzamos a Tk a calcular la geometría real de la barra de control ya
# empaquetada para saber cuánta altura queda disponible debajo de ella.
$mw->update;
my $control_panel_height = $control_panel->reqheight;
my $available_height     = $height - $control_panel_height;
my $atr_frame_height     = int($available_height / 3);
# El panel de precios (price_frame, más abajo) usa -expand => 1, así que
# automáticamente ocupa el resto: available_height - atr_frame_height,
# es decir, los 2/3 restantes.

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
my $atr_frame = $mw->Frame(-bg => '#fbfcf8', -height => $atr_frame_height)->pack(-side => 'top', -fill => 'both', -expand => 0);
$atr_frame->packPropagate(0); # conserva la altura calculada (1/3) aunque los hijos pidan más/menos espacio

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
    widgets           => { main_window => $mw, auto_scale_var => \$auto_scale_var }
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

# Actualizar la sección de callbacks del Modo Replay (alrededor de la línea donde se definen los callbacks)

# --- Callbacks del Modo Replay: sincronizan el estado del menú
# (REPLAY / navegación / PLAY / STOP / EXIT) y el mensaje de estado.
# --- Callbacks del Modo Replay ---
# --- Callbacks del Modo Replay ---
$chart_engine->{on_replay_selection_cancelled} = sub {
    $replay_status_label->configure(-text => "") if $replay_status_label;
};

$chart_engine->{on_replay_started} = sub {
    $replay_status_label->configure(-text => "") if $replay_status_label;
    
    # Cambiar texto del botón principal para indicar que está activo
    $replay_menu_btn->configure(-fg => '#787b86', -text => "REPLAY \x{25CF}");
    
    # Habilitar todos los comandos del menú usando índices
    $nav_submenu->entryconfigure(0, -state => 'normal');  # Retroceder 5
    $nav_submenu->entryconfigure(1, -state => 'normal');  # Retroceder
    $nav_submenu->entryconfigure(2, -state => 'normal');  # Avanzar
    $nav_submenu->entryconfigure(3, -state => 'normal');  # Avanzar 5
    
    $replay_menu->entryconfigure($play_index, -state => 'normal');
    $replay_menu->entryconfigure($stop_index, -state => 'normal');
    $replay_menu->entryconfigure($exit_index, -state => 'normal', -foreground => '#F23645');
};

$chart_engine->{on_replay_playback_started} = sub {
    $replay_playback_active = 1;
    $replay_menu->entryconfigure($play_index, 
        -label => "    ⏸ Pause", 
        -foreground => '#787b86',
        -state => 'normal'
    );
    $replay_menu->entryconfigure($stop_index, 
        -foreground => '#F23645', 
        -state => 'normal'
    );
};

$chart_engine->{on_replay_playback_stopped} = sub {
    $replay_playback_active = 0;
    $replay_menu->entryconfigure($play_index, 
        -label => "    ▶ Play", 
        -foreground => '#26a69a',
        -state => 'normal'
    );
    $replay_menu->entryconfigure($stop_index, 
        -foreground => '#787b86', 
        -state => 'normal'
    );
};

$chart_engine->{on_replay_exited} = sub {
    $replay_playback_active = 0;
    $replay_menu_btn->configure(-fg => '#F23645', -text => "REPLAY");
    
    # Deshabilitar todos los comandos del menú usando índices
    $nav_submenu->entryconfigure(0, -state => 'disabled');
    $nav_submenu->entryconfigure(1, -state => 'disabled');
    $nav_submenu->entryconfigure(2, -state => 'disabled');
    $nav_submenu->entryconfigure(3, -state => 'disabled');
    
    $replay_menu->entryconfigure($play_index, 
        -state => 'disabled', 
        -label => "    ▶ Play", 
        -foreground => '#26a69a'
    );
    $replay_menu->entryconfigure($stop_index, 
        -state => 'disabled', 
        -foreground => '#787b86'
    );
    $replay_menu->entryconfigure($exit_index, 
        -state => 'disabled', 
        -foreground => '#787b86'
    );
    
    $replay_status_label->configure(-text => "") if $replay_status_label;
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
