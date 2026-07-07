package Market::UI::Callbacks;
use strict;
use warnings;

# =============================================================================
# Market::UI::Callbacks — factorías de callbacks para la barra de controles de
# Fase 2 (spec 0010 / task 0004).
# =============================================================================
#
# Capa de ACCIONES de UI desacoplada de la construcción de widgets Tk. Cada
# factoría recibe las dependencias ($chart, refs de estado, opcionalmente $mw
# para `after`) y devuelve una subrutina lista para enchufar en el `-command`
# / `-onchange` de un widget Tk (Button, Optionmenu, Checkbutton).
#
# Por qué existe este módulo: los callbacks antes estaban inline en market.pl
# como `-command => sub { ... }` dentro de la construcción de widgets. Como
# `use Tk; MainWindow->new` no es ejecutable headless, ese cableado era
# imposible de testear. Extraer las acciones puras (sin Tk) permite que
# t/17-ui-wiring.t verifique con mocks que:
#   - cada callback de TF invoca $chart->set_timeframe($tf) con el valor correcto
#     para las 8 temporalidades (1m,5m,15m,1h,2h,4h,D,W);
#   - cada botón de Replay invoca el método correcto del ReplayController
#     (start/play/pause/step_forward/step_backward/fast_forward/exit) y
#     dispara re-render;
#   - cada toggle de overlay invoca overlay_manager->set_visible / liq->set_element_visible;
#   - el toggle HTF alterna su estado.
#
# REGLA (task 0004 / CONSTITUTION): aquí NO se reimplementa la lógica de
# Replay (el truncado por replay_idx ya lo hace ChartEngine.sync_overlay_indicators
# vía task 0015). Solo se cablea UI → controlador/motor y se pide re-render.
# Tampoco se toca zoom/drag/crosshair de Fase 1.
#
# DEPENDENCIAS INYECTADAS:
#   $chart  : instancia de Market::ChartEngine. Expone:
#               set_timeframe($tf), request_render(), reset_view(),
#               {replay_controller}, {overlay_manager}, {smc_overlay},
#               {liq_overlay}, {market_data}.
#   $mw     : MainWindow Tk (para `after`). En tests se pasa un mock cuyo
#             `after($ms,$cb)` ejecuta $cb inmediatamente (o lo registra).
#   $vars   : hashref con referencias a variables de estado compartidas:
#               active_tf   => \$active_tf,
#               htf_enabled => \$htf_enabled,
#               replay_on   => \$replay_on   (bool pintado en la UI).
# =============================================================================

# Lista de temporalidades válidas (spec 0001). Orden de visualización en el
# menú desplegable: del más fino al más grueso. Es la fuente de verdad del
# Optionmenu de market.pl, así ni un TF se queda fuera por error.
my @TIMEFRAMES = qw(1m 5m 15m 1h 2h 4h D W);

# Etiquetas legibles para el menú desplegable (TF => texto humano).
my %TF_LABEL = (
    '1m'  => '1m',
    '5m'  => '5m',
    '15m' => '15m',
    '1h'  => '1h',
    '2h'  => '2h',
    '4h'  => '4h',
    'D'   => 'D',
    'W'   => 'W',
);

# timeframes() — retorna la lista de TF válidos (orden de visualización).
# Público para que market.pl construya el Optionmenu y el test verifique las 8.
sub timeframes { return @TIMEFRAMES; }

# tf_label($tf) — etiqueta legible de un TF.
sub tf_label {
    my ($class_or_self, $tf) = @_;
    return $TF_LABEL{$tf};
}

# ----------------------------------------------------------------------------
# Timeframe
# ----------------------------------------------------------------------------

# make_tf_callback($chart, $tf, $vars) — callback para seleccionar un TF.
#   1. Llama a $chart->set_timeframe($tf) (recalcula ATR + overlays, reset vista).
#   2. Sincroniza $vars->{active_tf} con el TF seleccionado (estado del menú).
#   3. set_timeframe ya dispara reset_view → request_render; no duplicamos.
sub make_tf_callback {
    my ($class, $chart, $tf, $vars) = @_;
    die "make_tf_callback: requiere \$chart" unless $chart;
    die "make_tf_callback: requiere \$tf"   unless defined $tf;
    my $ref = ref($vars) eq 'HASH' ? $vars->{active_tf} : undef;
    return sub {
        _sync_replay_ui_cleanup($chart, $vars);
        $chart->set_timeframe($tf);
        ${$ref} = $tf if $ref;
    };
}

# ----------------------------------------------------------------------------
# Replay (spec 0002). 7 controles del PDF.
# IMPORTANTE: NO reimplementamos el truncado; el ReplayController +
# ChartEngine.sync_overlay_indicators (task 0015) ya respetan replay_idx.
# Cada callback mueve el índice y pide re-render.
# ----------------------------------------------------------------------------

# _replay($chart) — acceso al ReplayController a través del ChartEngine.
# Desacopla el callback del nombre interno del atributo.
sub _replay {
    my ($chart) = @_;
    return $chart->{replay_controller};
}

# _ui_mw($vars) — MainWindow Tk inyectado en ui_vars (task 0045 reschedule).
sub _ui_mw {
    my ($vars) = @_;
    return unless ref($vars) eq 'HASH';
    my $mw = $vars->{mw};
    return $mw if $mw && (!ref($mw) || eval { $mw->can('after') });
    return;
}

# _show_default_tab — vuelve a pestaña principal (Capas) al salir de Replay.
sub _show_default_tab {
    my ($vars) = @_;
    return unless ref($vars) eq 'HASH' && ref($vars->{show_default_tab}) eq 'CODE';
    $vars->{show_default_tab}->();
    return;
}

# _show_replay_tab / _hide_replay_menus — toolbar inline (task 0045 UX).
sub _show_replay_tab {
    my ($vars) = @_;
    if (ref($vars) eq 'HASH' && ref($vars->{show_replay_tab}) eq 'CODE') {
        $vars->{show_replay_tab}->();
        return;
    }
    _show_replay_panel($vars);
    return;
}

sub _hide_replay_menus {
    my ($vars) = @_;
    return unless ref($vars) eq 'HASH' && $vars->{replay_panel};
    my $panel = ${ $vars->{replay_panel} };
    $panel->hide_menus() if $panel && ref($panel) && $panel->can('hide_menus');
    return;
}

# _show_replay_panel — legacy flotante; inline usa show_replay_tab.
sub _show_replay_panel {
    my ($vars) = @_;
    return unless ref($vars) eq 'HASH' && $vars->{replay_panel};
    my $panel = ${ $vars->{replay_panel} };
    if ($panel && ref($panel) && $panel->can('is_inline') && $panel->is_inline()) {
        _show_replay_tab($vars);
        return;
    }
    $panel->show() if $panel && ref($panel) && $panel->can('show');
    return;
}

sub _hide_replay_panel {
    my ($vars) = @_;
    return unless ref($vars) eq 'HASH' && $vars->{replay_panel};
    my $panel = ${ $vars->{replay_panel} };
    if ($panel && ref($panel) && $panel->can('is_inline') && $panel->is_inline()) {
        _hide_replay_menus($vars);
        return;
    }
    $panel->hide() if $panel && ref($panel) && $panel->can('hide');
    return;
}

# _sync_replay_ui_cleanup($chart, $vars) — task 0040: detiene Play, sale de Replay
# y limpia selección; sincroniza vars UI (replay_on, replay_select_mode).
sub _sync_replay_ui_cleanup {
    my ($chart, $vars) = @_;
    return unless $chart;
    _stop_play_schedule($chart, $vars);
    my $rc = _replay($chart);
    $rc->exit() if $rc;
    $chart->restore_after_replay_exit() if $chart->can('restore_after_replay_exit');
    if ($chart->can('clear_replay_select_state')) {
        $chart->clear_replay_select_state();
    }
    $chart->sync_overlay_indicators() if $chart->can('sync_overlay_indicators');
    if (ref($vars) eq 'HASH') {
        ${ $vars->{replay_on} } = 0 if $vars->{replay_on};
        ${ $vars->{replay_select_mode} } = 0 if $vars->{replay_select_mode};
        _hide_replay_panel($vars);
        _show_default_tab($vars);
    }
    _sync_replay_play_icon($chart, $vars) if ref($vars) eq 'HASH';
    return;
}

# _sync_replay_play_icon — task 0046: triangulo vs barras pause en el boton play.
sub _sync_replay_play_icon {
    my ($chart, $vars) = @_;
    return unless ref($vars) eq 'HASH' && $vars->{replay_panel};
    my $panel = ${ $vars->{replay_panel} };
    return unless $panel && ref($panel) && $panel->can('sync_play_button_icon');
    my $rc = $chart ? _replay($chart) : undef;
    my $playing = ($rc && $rc->{playing}) ? 1 : 0;
    $panel->sync_play_button_icon($playing);
    return;
}

# _sync_replay_mark_button — task 0051: texto Mark: on/off tras toggle (boton o tecla M).
sub _sync_replay_mark_button {
    my ($chart, $vars) = @_;
    return unless ref($vars) eq 'HASH' && $vars->{replay_panel};
    my $panel = ${ $vars->{replay_panel} };
    return unless $panel && ref($panel) && $panel->can('sync_mark_button');
    my $ref = $vars->{replay_watermark_on};
    my $on = ($ref && ${ $ref }) ? 1 : 0;
    $panel->sync_mark_button($on);
    return;
}

# _replay_begin($chart, $start_idx, $opts) — task 0040-B: encuadra vista y arranca replay.
# $opts->{anchor} => 1: ultima vela ~80% del plot (Select Bar estilo TradingView).
sub _replay_begin {
    my ($chart, $start_idx, $opts) = @_;
    return unless $chart;
    $chart->frame_replay_view_at($start_idx, $opts) if $chart->can('frame_replay_view_at');
    my $rc = _replay($chart);
    $rc->start($start_idx) if $rc && defined $start_idx;
    $chart->clear_replay_select_mode() if $chart->can('clear_replay_select_mode');
    $chart->focus_price_canvas_for_replay() if $chart->can('focus_price_canvas_for_replay');
    # Tras confirmar Select Bar, el crosshair del cursor no debe pisar la linea de replay.
    delete $chart->{last_mouse_x};
    delete $chart->{last_mouse_y};
    return $rc;
}

# _replay_start_index($chart) — índice inicial para Replay (task 0030).
# Si hay vela seleccionada: selected-1 (la seleccionada no cuenta).
# Si no: last - visible_bars (comportamiento automático previo).
sub _replay_start_index {
    my ($chart) = @_;
    if ($chart->can('replay_start_index')) {
        return $chart->replay_start_index();
    }
    my $md = $chart->{market_data};
    my $last = (defined $md && $md->can('size')) ? ($md->size() - 1) : 0;
    my $vis = $chart->{visible_bars} || 60;
    my $start_idx = $last - $vis;
    return $start_idx < 0 ? 0 : $start_idx;
}

# make_replay_start($chart, $vars) — Inicio Replay.
# Arranca el replay en el índice elegido (Select Bar) o automático y pide re-render.
sub make_replay_start {
    my ($class, $chart, $vars) = @_;
    die "make_replay_start: requiere \$chart" unless $chart;
    my $ref = ref($vars) eq 'HASH' ? $vars->{replay_on} : undef;
    return sub {
        my $start_idx = _replay_start_index($chart);
        _replay_begin($chart, $start_idx);
        ${$ref} = 1 if $ref;
        $chart->request_render();
    };
}

# make_replay_activate($chart, $vars) — task 0043/0045: pestaña Replay = modo tijeras.
# Si el replay ya está activo (vela elegida), solo muestra la barra de controles.
# Si no, entra en Select Bar; la línea azul aparece al mover el cursor sobre el chart.
sub make_replay_activate {
    my ($class, $chart, $vars) = @_;
    die "make_replay_activate: requiere \$chart" unless $chart;
    my $ref_on   = ref($vars) eq 'HASH' ? $vars->{replay_on} : undef;
    my $mode_ref = ref($vars) eq 'HASH' ? $vars->{replay_select_mode} : undef;
    return sub {
        _show_replay_tab($vars);
        my $rc = _replay($chart);
        if ($rc && $rc->is_active()) {
            ${$ref_on} = 1 if $ref_on;
            $chart->request_render();
            return;
        }
        ${$ref_on} = 1 if $ref_on;
        ${$mode_ref} = 1 if $mode_ref;
        $chart->set_replay_select_mode(1) if $chart->can('set_replay_select_mode');
        $chart->request_render();
    };
}

# replay_confirm_bar_selection($chart, $vars) — task UX: al clic en una vela en modo
# tijeras, arranca replay en selected-1 (trunca futuro) y encuadra; espera Play.
sub replay_confirm_bar_selection {
    my ($class, $chart, $vars) = @_;
    die "replay_confirm_bar_selection: requiere \$chart" unless $chart;
    my $start_idx = _replay_start_index($chart);
    _replay_begin($chart, $start_idx, { anchor => 1 });
    if (ref($vars) eq 'HASH') {
        ${ $vars->{replay_on} } = 1 if $vars->{replay_on};
        ${ $vars->{replay_select_mode} } = 0 if $vars->{replay_select_mode};
    }
    $chart->request_render();
    return;
}

# _replay_goto_begin — arranca replay en $start_idx y sincroniza UI (task 0044).
sub _replay_goto_begin {
    my ($chart, $vars, $start_idx) = @_;
    return unless $chart && defined $start_idx;
    _replay_begin($chart, $start_idx);
    if (ref($vars) eq 'HASH') {
        ${ $vars->{replay_on} } = 1 if $vars->{replay_on};
        ${ $vars->{replay_select_mode} } = 0 if $vars->{replay_select_mode};
    }
    $chart->clear_replay_select_mode() if $chart->can('clear_replay_select_mode');
    $chart->request_render();
    return;
}

# make_replay_goto_menu_stub — noop legacy (tests 0043); el toggle real vive en ReplayGotoMenu.
sub make_replay_goto_menu_stub {
    my ($class, $chart, $vars) = @_;
    die "make_replay_goto_menu_stub: requiere \$chart" unless $chart;
    return sub { };
}

# make_replay_goto_bar — modo selección manual (task 0044).
sub make_replay_goto_bar {
    my ($class, $chart, $vars) = @_;
    die "make_replay_goto_bar: requiere \$chart" unless $chart;
    my $mode_ref = ref($vars) eq 'HASH' ? $vars->{replay_select_mode} : undef;
    my $on_ref   = ref($vars) eq 'HASH' ? $vars->{replay_on} : undef;
    return sub {
        ${$on_ref} = 1 if $on_ref;
        ${$mode_ref} = 1 if $mode_ref;
        $chart->set_replay_select_mode(1) if $chart->can('set_replay_select_mode');
        _show_replay_panel($vars);
        $chart->request_render();
    };
}

# make_replay_goto_first — primera vela disponible (índice 0; task 0044).
sub make_replay_goto_first {
    my ($class, $chart, $vars) = @_;
    die "make_replay_goto_first: requiere \$chart" unless $chart;
    return sub {
        _replay_goto_begin($chart, $vars, 0);
    };
}

# make_replay_goto_random — vela aleatoria en [MIN_VISIBLE_BARS, last-1] (task 0044).
sub make_replay_goto_random {
    my ($class, $chart, $vars) = @_;
    die "make_replay_goto_random: requiere \$chart" unless $chart;
    return sub {
        my $idx = $chart->can('replay_random_start_index')
            ? $chart->replay_random_start_index()
            : 0;
        _replay_goto_begin($chart, $vars, $idx);
    };
}

# _replay_date_prompt($mw) — Entry simple para Go-to Date (task 0044).
sub _replay_date_prompt {
    my ($mw) = @_;
    return undef unless $mw && eval { $mw->exists };

    my $result;
    my $top = $mw->Toplevel(-title => 'Go to date');
    $top->transient($mw);
    $top->Label(
        -text => 'Enter date (YYYY-MM-DD or YYYY-MM-DDTHH:MM):',
    )->pack(-padx => 10, -pady => [8, 4]);
    my $entry_var = '';
    $top->Entry(-textvariable => \$entry_var, -width => 28)->pack(-padx => 10, -pady => 4);
    my $finish = sub {
        my ($ok) = @_;
        $result = $ok ? $entry_var : undef;
        $top->destroy();
    };
    my $btn_row = $top->Frame()->pack(-pady => 8);
    $btn_row->Button(-text => 'Ok', -command => sub { $finish->(1) })->pack(-side => 'left', -padx => 4);
    $btn_row->Button(-text => 'Cancel', -command => sub { $finish->(0) })->pack(-side => 'left', -padx => 4);
    eval { $top->grab() };
    $top->waitWindow();
    $result = undef if defined $result && $result !~ /\S/;
    return $result;
}

# make_replay_goto_date — salta a la vela más cercana a la fecha (task 0044).
# $prompt_fn opcional para tests headless (devuelve string de fecha o undef).
sub make_replay_goto_date {
    my ($class, $chart, $mw, $vars, $prompt_fn) = @_;
    die "make_replay_goto_date: requiere \$chart" unless $chart;
    return sub {
        my $input = ref($prompt_fn) eq 'CODE' ? $prompt_fn->() : _replay_date_prompt($mw);
        return unless defined $input && $input =~ /\S/;
        my $idx = $chart->can('index_for_timestamp') ? $chart->index_for_timestamp($input) : undef;
        return unless defined $idx;
        _replay_goto_begin($chart, $vars, $idx);
    };
}

# make_replay_speed_menu_stub — noop legacy (tests 0043); toggle real en ReplayPanel.
sub make_replay_speed_menu_stub {
    my ($class, $chart, $vars) = @_;
    die "make_replay_speed_menu_stub: requiere \$chart" unless $chart;
    return sub { };
}

# make_replay_interval_menu_stub — noop legacy (tests 0043).
sub make_replay_interval_menu_stub {
    my ($class, $chart, $vars) = @_;
    die "make_replay_interval_menu_stub: requiere \$chart" unless $chart;
    return sub { };
}

# --- Intervalo de replay (task 0045) ---

sub chart_tf_minutes {
    my ($chart) = @_;
    return 1 unless $chart;
    if ($chart->can('_timeframe_minutes')) {
        return $chart->_timeframe_minutes();
    }
    my $tf = eval { $chart->{market_data}{active_tf} } || '1m';
    return 5 if $tf eq '5m';
    return 15 if $tf eq '15m';
    return 60 if $tf eq '1h';
    return 120 if $tf eq '2h';
    return 240 if $tf eq '4h';
    return 1440 if $tf eq 'D';
    return 10080 if $tf eq 'W';
    return 1;
}

sub interval_minutes_for_label {
    my ($class, $label) = @_;
    my %m = (
        '1 hour'  => 60,
        '2 hours' => 120,
        '3 hours' => 180,
        '4 hours' => 240,
        '1 day'   => 1440,
    );
    return $m{$label} // 60;
}

sub interval_minutes_to_bars {
    my ($class, $tf_minutes, $interval_minutes) = @_;
    return 1 unless $tf_minutes > 0 && $interval_minutes > 0;
    my $bars = int($interval_minutes / $tf_minutes);
    return $bars > 0 ? $bars : 1;
}

sub interval_label_to_short {
    my ($class, $label) = @_;
    return 'D' if !defined $label || $label eq '';
    return '1h' if $label eq '1 hour';
    return '2h' if $label eq '2 hours';
    return '3h' if $label eq '3 hours';
    return '4h' if $label eq '4 hours';
    return '1d' if $label eq '1 day';
    return 'D';
}

sub replay_interval_button_text {
    my ($class, $rc) = @_;
    return 'D' unless $rc;
    return 'D' if $rc->can('auto_replay_interval') && $rc->auto_replay_interval();
    my $lbl = $rc->can('interval_label') ? $rc->interval_label() : undef;
    return interval_label_to_short($class, $lbl // '1 hour');
}

sub apply_replay_interval_selection {
    my ($class, $chart) = @_;
    my $rc = _replay($chart);
    return unless $rc;
    if ($rc->can('auto_replay_interval') && $rc->auto_replay_interval()) {
        $rc->set_replay_interval(1);
        return $rc;
    }
    my $tfm  = chart_tf_minutes($chart);
    my $mins = interval_minutes_for_label($rc->interval_label() // '1 hour');
    $rc->set_replay_interval(interval_minutes_to_bars($class, $tfm, $mins));
    return $rc;
}

# make_replay_select_bar($chart, $vars) — activa/desactiva modo Select Bar (task 0030).
sub make_replay_select_bar {
    my ($class, $chart, $vars) = @_;
    die "make_replay_select_bar: requiere \$chart" unless $chart;
    my $mode_ref = ref($vars) eq 'HASH' ? $vars->{replay_select_mode} : undef;
    return sub {
        my $on = $chart->can('is_replay_select_mode') && $chart->is_replay_select_mode() ? 0 : 1;
        ${$mode_ref} = $on if $mode_ref;
        $chart->set_replay_select_mode($on) if $chart->can('set_replay_select_mode');
        $chart->request_render();
    };
}

# make_replay_play($chart, $mw, $vars) — Play (interno; usar toggle en UI).
# Autoplay con tick_ms() del ReplayController y advance_one_tick() (task 0041/0045).
sub make_replay_play {
    my ($class, $chart, $mw, $vars) = @_;
    die "make_replay_play: requiere \$chart" unless $chart;
    $mw //= _ui_mw($vars);
    return sub {
        my $rc = _replay($chart);
        return unless $rc;
        if (!$rc->is_active()) {
            _replay_begin($chart, _replay_start_index($chart));
        }
        my $tick = sub {
            return unless $rc->{playing};
            $rc->advance_one_tick();
            $chart->request_render();
            _sync_replay_play_icon($chart, $vars);
        };
        $rc->play($tick);
        _schedule_play($chart, $mw, $tick, $rc);
        _sync_replay_play_icon($chart, $vars);
    };
}

# make_replay_toggle_play — task 0046: un boton alterna Play <-> Pause.
sub make_replay_toggle_play {
    my ($class, $chart, $mw, $vars) = @_;
    die "make_replay_toggle_play: requiere \$chart" unless $chart;
    $mw //= _ui_mw($vars);
    my $play_cb  = $class->make_replay_play($chart, $mw, $vars);
    my $pause_cb = $class->make_replay_pause($chart, $vars);
    return sub {
        my $rc = _replay($chart);
        return unless $rc;
        if ($rc->{playing}) {
            $pause_cb->();
        }
        else {
            $play_cb->();
        }
        _sync_replay_play_icon($chart, $vars);
    };
}

# _schedule_play — after($rc->tick_ms()) sobre $mw; reschedule al cambiar velocidad.
{
    my %_play_active;
    my %_play_after_id;
    my %_play_tick;
    my %_play_mw;

    sub _schedule_play {
        my ($chart, $mw, $tick, $rc) = @_;
        return unless $mw;
        my $key = "$chart";
        $_play_active{$key} = 1;
        $_play_tick{$key} = $tick;
        $_play_mw{$key}   = $mw;
        my $interval = $rc->tick_ms();
        my $aid = $mw->after($interval, sub {
            return unless $_play_active{$key};
            return unless $rc->is_active();
            return unless $rc->{playing};
            $tick->();
            return unless $_play_active{$key} && $rc->{playing};
            _schedule_play($chart, $mw, $tick, $rc);
        });
        $_play_after_id{$key} = $aid if defined $aid;
        return;
    }

    sub _cancel_play_after {
        my ($chart, $mw) = @_;
        my $key = "$chart";
        $mw //= $_play_mw{$key};
        if ($mw && defined $_play_after_id{$key}) {
            eval { $mw->afterCancel($_play_after_id{$key}) };
            delete $_play_after_id{$key};
        }
        return;
    }

    sub reschedule_replay_play {
        my ($chart, $vars) = @_;
        my $rc = _replay($chart);
        return unless $rc && $rc->{playing};
        my $key = "$chart";
        return unless $_play_active{$key};
        my $mw   = _ui_mw($vars) || $_play_mw{$key};
        my $tick = $_play_tick{$key};
        return unless $mw && $tick;
        _cancel_play_after($chart, $mw);
        _schedule_play($chart, $mw, $tick, $rc);
        return;
    }

    sub _stop_play_schedule {
        my ($chart, $vars) = @_;
        my $key = "$chart";
        $_play_active{$key} = 0;
        _cancel_play_after($chart, _ui_mw($vars));
        delete $_play_tick{$key};
        delete $_play_mw{$key};
        return;
    }
}

# make_replay_pause($chart, $vars) — Pause.
sub make_replay_pause {
    my ($class, $chart, $vars) = @_;
    die "make_replay_pause: requiere \$chart" unless $chart;
    return sub {
        my $rc = _replay($chart);
        return unless $rc;
        $rc->pause();
        _stop_play_schedule($chart, $vars);
        $chart->request_render();
        _sync_replay_play_icon($chart, $vars);
    };
}

# make_replay_jump_real — task 0046/UX TV: >> muestra chart vivo y re-entra Select Bar.
# TradingView: al pulsar Jump to real-time se ven todas las velas y el modo tijeras
# vuelve a activarse (como recien entrar en replay), sin salir de la pestaña Replay.
sub make_replay_jump_real {
    my ($class, $chart, $vars) = @_;
    die "make_replay_jump_real: requiere \$chart" unless $chart;
    my $ref_on   = ref($vars) eq 'HASH' ? $vars->{replay_on} : undef;
    my $mode_ref = ref($vars) eq 'HASH' ? $vars->{replay_select_mode} : undef;
    return sub {
        my $rc = _replay($chart);
        _stop_play_schedule($chart, $vars);
        if ($rc && $rc->is_active()) {
            $rc->jump_to_end() if $rc->can('jump_to_end');
            $chart->request_render();
        }
        $rc->exit() if $rc;
        $chart->restore_after_replay_exit() if $chart->can('restore_after_replay_exit');
        if ($chart->can('clear_replay_select_state')) {
            $chart->clear_replay_select_state();
        }
        $chart->sync_overlay_indicators() if $chart->can('sync_overlay_indicators');

        if (ref($vars) eq 'HASH') {
            ${ $ref_on } = 1 if $ref_on;
            ${ $mode_ref } = 1 if $mode_ref;
            _show_replay_tab($vars);
        }
        $chart->set_replay_select_mode(1) if $chart->can('set_replay_select_mode');
        _sync_replay_play_icon($chart, $vars);
        $chart->request_render();
    };
}

# make_replay_step_fwd($chart) — Step Forward (avanza 1 vela).
sub make_replay_step_fwd {
    my ($class, $chart) = @_;
    die "make_replay_step_fwd: requiere \$chart" unless $chart;
    return sub {
        my $rc = _replay($chart);
        return unless $rc;
        # Si no hay replay activo, arrancamos en el índice visible actual
        # (mismo criterio que play/start) para que step funcione desde la UI.
        if (!$rc->is_active()) {
            _replay_begin($chart, _replay_start_index($chart));
        }
        $rc->step_forward();
        $chart->request_render();
    };
}

# make_replay_step_back($chart) — Step Back (retrocede 1 vela).
sub make_replay_step_back {
    my ($class, $chart) = @_;
    die "make_replay_step_back: requiere \$chart" unless $chart;
    return sub {
        my $rc = _replay($chart);
        return unless $rc;
        if (!$rc->is_active()) {
            _replay_begin($chart, _replay_start_index($chart));
        }
        $rc->step_backward();
        $chart->request_render();
    };
}

# make_replay_fast_fwd($chart, $mw, $vars) — Fast Forward.
# Avanza N velas por tick (default 10) y re-render. Usa after() igual que play
# pero con step mayor. $n opcional para tests/velocidades.
sub make_replay_fast_fwd {
    my ($class, $chart, $mw, $vars, $n) = @_;
    die "make_replay_fast_fwd: requiere \$chart" unless $chart;
    $n //= 10;
    return sub {
        my $rc = _replay($chart);
        return unless $rc;
        if (!$rc->is_active()) {
            _replay_begin($chart, _replay_start_index($chart));
        }
        $rc->fast_forward($n);
        $chart->request_render();
    };
}

# make_replay_exit($chart, $vars) — Exit Replay.
# Desactiva replay (tope vuelve a last_index) y re-render. Sincroniza estado.
sub make_replay_exit {
    my ($class, $chart, $vars) = @_;
    die "make_replay_exit: requiere \$chart" unless $chart;
    my $ref = ref($vars) eq 'HASH' ? $vars->{replay_on} : undef;
    return sub {
        _sync_replay_ui_cleanup($chart, $vars);
        ${$ref} = 0 if $ref;
        $chart->request_render();
    };
}

# make_replay_toggle_watermark — task 0051: flip marca "Replay" (boton Mark y tecla M).
sub make_replay_toggle_watermark {
    my ($class, $chart, $vars) = @_;
    die "make_replay_toggle_watermark: requiere \$chart" unless $chart;
    my $ref = (ref($vars) eq 'HASH' && $vars->{replay_watermark_on})
        ? $vars->{replay_watermark_on}
        : $chart->{replay_watermark_on_ref};
    return sub {
        return unless $ref;
        ${ $ref } = ${ $ref } ? 0 : 1;
        _sync_replay_mark_button($chart, $vars);
        $chart->request_render();
    };
}

# ----------------------------------------------------------------------------
# Overlays / Capas (spec 0003 / task 0003).
# Cada toggle llama al OverlayManager o al overlay de liquidez. NO toca la
# lógica del overlay; solo cambia visibilidad y pide re-render.
# ----------------------------------------------------------------------------

# make_overlay_toggle($chart, $name) — toggle de un overlay completo por nombre
# de registro ('smc' o 'liq'). Recibe un bool ($on) desde el Checkbutton Tk
# (vinculado a su -variable). El overlay ya filtra el dibujo por index <= end,
# así que el replay_idx se respeta sin acción extra aquí.
sub make_overlay_toggle {
    my ($class, $chart, $name) = @_;
    die "make_overlay_toggle: requiere \$chart" unless $chart;
    die "make_overlay_toggle: requiere \$name"  unless defined $name;
    return sub {
        my ($on) = @_;
        my $mgr = $chart->{overlay_manager};
        return unless $mgr;
        $mgr->set_visible($name, $on ? 1 : 0);
        $chart->request_render();
    };
}

# make_liq_element_toggle($chart, $element) — toggle de una familia concreta de
# liquidez (BSL/SSL/EQH/EQL/SWEEP/GRAB/RUN) vía set_element_visible del overlay.
# La visibilidad general del overlay ov_liq se controla aparte (make_overlay_toggle).
sub make_liq_element_toggle {
    my ($class, $chart, $element) = @_;
    die "make_liq_element_toggle: requiere \$chart"   unless $chart;
    die "make_liq_element_toggle: requiere \$element" unless defined $element;
    return sub {
        my ($on) = @_;
        my $liq = $chart->{liq_overlay};
        return unless $liq && $liq->can('set_element_visible');
        $liq->set_element_visible($element, $on ? 1 : 0);
        $chart->request_render();
    };
}

# make_mxwll_element_toggle($chart, $element) — toggle de un elemento de la capa
# Mxwll (STRUCTURE/SWINGS/OB/FVG/AOE/FIBS) via set_element_visible del overlay.
# La visibilidad general de la capa Mxwll se controla aparte (make_overlay_toggle).
# ORDEN 9 (task 0021 I): permite encender/apagar cada elemento por separado, igual
# que ya se hace con los sub-elementos de Liquidez.
sub make_mxwll_element_toggle {
    my ($class, $chart, $element) = @_;
    die "make_mxwll_element_toggle: requiere \$chart"   unless $chart;
    die "make_mxwll_element_toggle: requiere \$element" unless defined $element;
    return sub {
        my ($on) = @_;
        my $ov = $chart->{mxwll_overlay};
        return unless $ov && $ov->can('set_element_visible');
        $ov->set_element_visible($element, $on ? 1 : 0);
        $chart->request_render();
    };
}

sub make_zigzag_element_toggle {
    my ($class, $chart, $element) = @_;
    die "make_zigzag_element_toggle: requiere \$chart"   unless $chart;
    die "make_zigzag_element_toggle: requiere \$element" unless defined $element;
    return sub {
        my ($on) = @_;
        my $ov = $chart->{zigzag_overlay};
        return unless $ov && $ov->can('set_element_visible');
        $ov->set_element_visible($element, $on ? 1 : 0);
        $chart->request_render();
    };
}

sub make_zigzag_resolution_callback {
    my ($class, $chart, $minutes) = @_;
    die "make_zigzag_resolution_callback: requiere \$chart" unless $chart;
    die "make_zigzag_resolution_callback: requiere \$minutes" unless defined $minutes;
    return sub {
        $chart->set_zigzag_internal_resolution($minutes);
    };
}

# ----------------------------------------------------------------------------
# HTF sobre LTF (spec 0010 §4). Toggle preparado: alterna una bandera de estado
# ($vars->{htf_enabled}). La proyección de niveles de mayor temporalidad aún no
# está implementada (tarea futura); aquí dejamos el cableado de UI listo para
# que cuando exista solo haya que leer ese estado.
# ----------------------------------------------------------------------------

sub make_htf_toggle {
    my ($class, $chart, $vars) = @_;
    die "make_htf_toggle: requiere \$chart" unless $chart;
    my $ref = ref($vars) eq 'HASH' ? $vars->{htf_enabled} : undef;
    return sub {
        my ($on) = @_;
        ${$ref} = $on ? 1 : 0 if $ref;
        # No hay proyección HTF todavía; cuando exista, aquí se pedirá
        # recálculo. Por ahora solo re-render para reflejar el cambio de
        # estado en cualquier overlay futuro que lo consuma.
        $chart->request_render();
    };
}

1;
