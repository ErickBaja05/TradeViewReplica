package Market::ReplayController;
use strict;
use warnings;

# Market::ReplayController — control del índice-tope de Replay (spec 0002).
#
# Mantiene un replay_idx que ninguna capa (render, indicadores, overlays) puede
# superar. Cuando está activo, compute_window y todo el pipeline ven el dataset
# como si terminara en replay_idx. Sin UI aquí (task 0004).

# Tabla de velocidades TradingView (task 0041): etiqueta → ms por tick de autoplay.
my @SPEED_OPTIONS = (
    { label => '10x',  ms => 100 },
    { label => '7x',   ms => 143 },
    { label => '5x',   ms => 200 },
    { label => '3x',   ms => 333 },
    { label => '1x',   ms => 1000 },
    { label => '0.5x', ms => 2000 },
    { label => '0.3x', ms => 3000 },
    { label => '0.2x', ms => 5000 },
    { label => '0.1x', ms => 10000 },
);

my %SPEED_MS = map { $_->{label} => $_->{ms} } @SPEED_OPTIONS;

sub new {
    my ($class, %args) = @_;
    my $self = {
        market_data     => $args{market_data},
        active          => 0,
        replay_idx      => undef,
        playing         => 0,
        speed           => $args{speed} || 1,
        speed_label     => '1x',
        replay_interval => 1,
        auto_replay_interval => 1,
        interval_label  => '1 hour',
        _timer_id       => undef,
        _timer_cb       => undef,
    };
    bless $self, $class;
    return $self;
}

# start($idx) — activa Replay con tope en $idx (clamp a [0, last_index]).
sub start {
    my ($self, $idx) = @_;
    my $last = $self->_last_index();
    $idx = 0 if !defined $idx || $idx < 0;
    $idx = $last if defined $last && $idx > $last;
    $self->{active} = 1;
    $self->{replay_idx} = $idx;
    $self->{playing} = 0;
    return $self;
}

# play — inicia reproducción automática via after($ms, $cb).
# $cb es una subrutina que se llama en cada tick; típicamente hace step_forward
# + request_render. El temporizador se guarda para poder cancelarlo con pause.
sub play {
    my ($self, $cb) = @_;
    return unless $self->{active};
    $self->{playing} = 1;
    $self->{_timer_cb} = $cb if defined $cb;
    $self->_schedule_timer();
    return $self;
}

# pause — detiene la reproducción automática.
sub pause {
    my ($self) = @_;
    $self->{playing} = 0;
    $self->_cancel_timer();
    return $self;
}

# step_forward — avanza replay_idx exactamente 1 (clamp al último).
sub step_forward {
    my ($self) = @_;
    return unless $self->{active};
    my $last = $self->_last_index();
    $self->{replay_idx}++ if defined $self->{replay_idx};
    $self->{replay_idx} = $last if defined $last && $self->{replay_idx} > $last;
    # Si Play llega al último índice, detener el loop automático. Sin esto,
    # step_forward queda clampado en el último frame pero `playing` sigue true,
    # y la UI reprograma after() indefinidamente mostrando un frame congelado.
    $self->pause() if defined $self->{replay_idx} && defined $last && $self->{replay_idx} >= $last;
    return $self->{replay_idx};
}

# step_backward — retrocede replay_idx exactamente 1 (clamp a 0).
sub step_backward {
    my ($self) = @_;
    return unless $self->{active};
    $self->{replay_idx}-- if defined $self->{replay_idx};
    $self->{replay_idx} = 0 if !defined $self->{replay_idx} || $self->{replay_idx} < 0;
    return $self->{replay_idx};
}

# fast_forward — avanza N velas (default: 10 * speed), clamp al último.
sub fast_forward {
    my ($self, $n) = @_;
    return unless $self->{active};
    $n //= 10 * ($self->{speed} || 1);
    my $last = $self->_last_index();
    $self->{replay_idx} += $n;
    $self->{replay_idx} = $last if defined $last && $self->{replay_idx} > $last;
    $self->pause() if defined $self->{replay_idx} && defined $last && $self->{replay_idx} >= $last;
    return $self->{replay_idx};
}

# jump_to_end — revela hasta la ultima vela (replay_idx = last) y pausa autoplay.
sub jump_to_end {
    my ($self) = @_;
    return unless $self->{active};
    $self->pause();
    my $last = $self->_last_index();
    $self->{replay_idx} = $last if defined $last;
    return $self->{replay_idx};
}

# exit — desactiva Replay y restaura tope = last_index.
sub exit {
    my ($self) = @_;
    $self->pause();
    $self->{active} = 0;
    $self->{replay_idx} = undef;
    return $self;
}

# current_index — retorna replay_idx o undef si no activo.
sub current_index {
    my ($self) = @_;
    return $self->{active} ? $self->{replay_idx} : undef;
}

# is_active — bool.
sub is_active {
    my ($self) = @_;
    return $self->{active} ? 1 : 0;
}

# effective_end($last_index) — retorna el índice efectivo superior para
# compute_window: min(replay_idx, last_index) si activo, o last_index si no.
sub effective_end {
    my ($self, $last_index) = @_;
    return $last_index unless $self->{active} && defined $self->{replay_idx};
    my $end = $self->{replay_idx};
    $end = $last_index if defined $last_index && $end > $last_index;
    return $end;
}

# set_speed($n) — cambia la velocidad de fast_forward (retrocompat; no afecta tick_ms).
sub set_speed {
    my ($self, $n) = @_;
    $self->{speed} = $n if defined $n && $n > 0;
    return $self;
}

# speed_options — lista ordenada {label, ms} para los 9 multiplicadores TV.
sub speed_options {
    return map { +{ label => $_->{label}, ms => $_->{ms} } } @SPEED_OPTIONS;
}

# set_speed_label($label) — selecciona velocidad de autoplay por etiqueta (p.ej. '5x').
sub set_speed_label {
    my ($self, $label) = @_;
    if (defined $label && exists $SPEED_MS{$label}) {
        $self->{speed_label} = $label;
    }
    return $self;
}

# tick_ms — periodo del tick de autoplay según la velocidad seleccionada.
sub tick_ms {
    my ($self) = @_;
    my $label = $self->{speed_label} // '1x';
    return $SPEED_MS{$label} // 1000;
}

# replay_interval — nº de velas avanzadas por tick de autoplay.
sub replay_interval {
    my ($self) = @_;
    return $self->{replay_interval} // 1;
}

# set_replay_interval($n) — cuántas velas añade cada tick (default 1).
sub set_replay_interval {
    my ($self, $n) = @_;
    $self->{replay_interval} = $n if defined $n && $n > 0;
    return $self;
}

# auto_replay_interval — 1 = intervalo sigue al TF; 0 = manual (task 0045).
sub auto_replay_interval {
    my ($self) = @_;
    return $self->{auto_replay_interval} // 1;
}

sub set_auto_replay_interval {
    my ($self, $on) = @_;
    $self->{auto_replay_interval} = $on ? 1 : 0;
    return $self;
}

sub interval_label {
    my ($self) = @_;
    return $self->{interval_label};
}

sub set_interval_label {
    my ($self, $label) = @_;
    $self->{interval_label} = $label if defined $label;
    return $self;
}

# advance_one_tick — avanza replay_interval pasos de step_forward (clamp + pause al final).
sub advance_one_tick {
    my ($self) = @_;
    return unless $self->{active};
    my $interval = $self->replay_interval();
    my $last = $self->_last_index();
    my $idx;
    for (my $i = 0; $i < $interval; $i++) {
        $idx = $self->step_forward();
        last if defined $last && defined $idx && $idx >= $last;
    }
    return $idx;
}

# --- internals ---

sub _last_index {
    my ($self) = @_;
    return undef unless $self->{market_data};
    my $size = $self->{market_data}->size();
    return $size > 0 ? $size - 1 : 0;
}

sub _schedule_timer {
    my ($self) = @_;
    return unless $self->{playing} && $self->{_timer_cb};
    my $canvas = $self->{market_data};  # placeholder; el timer real se cablea en 0004
    # El temporizador Tk se cablea en task 0004 con after().
    # Aquí dejamos la infraestructura; el callback se invoca manualmente en tests.
}

sub _cancel_timer {
    my ($self) = @_;
    $self->{_timer_id} = undef;
}

1;
