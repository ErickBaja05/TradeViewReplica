package Market::ML::HMM;

use strict;
use warnings;
use AI::MXNet qw(mx nd);

# HMM de primer orden con decodificacion Viterbi tensorial.
# Las observaciones son los clusters producidos por GMM: 0..K-1.
#
# IMPORTANTE:
# - fit() aprende los parametros SOLO con TRAIN.
# - predict()/viterbi_tensors() aplican esos mismos parametros a TRAIN o TEST.
# - Para secuencias largas se recomienda log => 1 (por defecto en predict).

sub new {
    my ($class, %args) = @_;

    my $self = {
        num_states        => $args{num_states},
        smoothing         => defined $args{smoothing} ? $args{smoothing} : 1.0,
        emission_accuracy => defined $args{emission_accuracy} ? $args{emission_accuracy} : 0.80,
        transitions       => undef,   # A: [K,K]
        emissions         => undef,   # B: [K,K] (cluster observado por estado oculto)
        start             => undef,   # pi: [K]
        fitted            => 0,
    };

    return bless $self, $class;
}

# ----------------------------------------------------------------------
# Compatibilidad con el ejercicio del profesor
# ----------------------------------------------------------------------
sub set_start {
    my ($self, $start) = @_;
    $self->{start} = $start;
    return $self;
}

sub set_emissions {
    my ($self, $emissions) = @_;
    $self->{emissions} = $emissions;
    return $self;
}

sub set_transitions {
    my ($self, $transitions) = @_;
    $self->{transitions} = $transitions;
    return $self;
}

sub get_start       { return $_[0]->{start}; }
sub get_emissions   { return $_[0]->{emissions}; }
sub get_transitions { return $_[0]->{transitions}; }
sub get_num_states  { return $_[0]->{num_states}; }

# ----------------------------------------------------------------------
# APRENDIZAJE DEL HMM (SOLO TRAIN)
# ----------------------------------------------------------------------
sub fit {
    my ($self, $observations) = @_;

    die "HMM::fit requiere un ARRAY ref con cluster_gmm\n"
        unless ref($observations) eq 'ARRAY';
    die "HMM::fit recibio una secuencia vacia\n"
        unless @$observations;

    # Si K no se especifico, lo inferimos del mayor id de cluster.
    my $K = $self->{num_states};
    if (!defined $K) {
        my $max = $observations->[0];
        for my $obs (@$observations) {
            $max = $obs if $obs > $max;
        }
        $K = $max + 1;
        $self->{num_states} = $K;
    }

    die "num_states debe ser >= 1\n" if $K < 1;

    # Validacion: GMM debe entregar ids enteros 0..K-1.
    for my $obs (@$observations) {
        die "Observacion invalida '$obs': se esperaba entero entre 0 y " . ($K - 1) . "\n"
            unless defined($obs) && $obs =~ /^\d+$/ && $obs >= 0 && $obs < $K;
    }

    my $alpha = $self->{smoothing};

    # ---------------- pi ----------------
    # Prior empirico de estados a partir de TRAIN con Laplace smoothing.
    # Con una sola secuencia larga es mas estable que asignar probabilidad 1
    # unicamente al primer cluster.
    my @pi_counts = map { $alpha } (1 .. $K);
    $pi_counts[$_]++ for @$observations;

    my $pi_total = 0;
    $pi_total += $_ for @pi_counts;
    my @pi = map { $_ / $pi_total } @pi_counts;

    # ---------------- A -----------------
    # A[i][j] = P(S_t=j | S_{t-1}=i)
    # Estimada empiricamente a partir de cambios consecutivos de cluster.
    my @A_counts;
    for my $i (0 .. $K - 1) {
        $A_counts[$i] = [ map { $alpha } (1 .. $K) ];
    }

    for my $t (0 .. $#$observations - 1) {
        my $from = $observations->[$t];
        my $to   = $observations->[$t + 1];
        $A_counts[$from][$to]++;
    }

    my @A;
    for my $i (0 .. $K - 1) {
        my $row_sum = 0;
        $row_sum += $_ for @{ $A_counts[$i] };
        $A[$i] = [ map { $_ / $row_sum } @{ $A_counts[$i] } ];
    }

    # ---------------- B -----------------
    # B[state][observed_cluster].
    # No tenemos etiquetas verdaderas de estados ocultos para estimar B de
    # forma supervisada. Se usa la hipotesis acordada: el cluster observado
    # coincide mayormente con el estado oculto, dejando margen para ruido.
    my $acc = $self->{emission_accuracy};
    die "emission_accuracy debe estar entre 0 y 1\n"
        if $acc < 0 || $acc > 1;

    my @B;
    if ($K == 1) {
        $B[0] = [1.0];
    }
    else {
        my $off_diag = (1.0 - $acc) / ($K - 1);
        for my $i (0 .. $K - 1) {
            $B[$i] = [ map { $_ == $i ? $acc : $off_diag } (0 .. $K - 1) ];
        }
    }

    $self->{start}       = nd->array(\@pi);
    $self->{transitions} = nd->array(\@A);
    $self->{emissions}   = nd->array(\@B);
    $self->{fitted}      = 1;

    return $self;
}

# ----------------------------------------------------------------------
# VITERBI TENSORIAL DE ORDEN 1
# Basado en el ejercicio del profesor: el bucle temporal permanece,
# pero las combinaciones estado-origen x estado-destino se calculan
# mediante broadcasting de MXNet.
# ----------------------------------------------------------------------
sub viterbi_tensors {
    my ($self, $O, %args) = @_;

    my $use_log = exists $args{log} ? $args{log} : 1;
    my $tiny    = 1e-30;

    die "HMM sin matriz de transicion A\n" unless defined $self->{transitions};
    die "HMM sin matriz de emisiones B\n"  unless defined $self->{emissions};
    die "HMM sin vector inicial pi\n"      unless defined $self->{start};

    # Permite pasar ARRAY ref o NDArray.
    $O = nd->array($O) if ref($O) eq 'ARRAY';

    my $A  = $self->{transitions};
    my $B  = $self->{emissions};
    my $pi = $self->{start};

    if ($use_log) {
        $A  = nd->log($A  + $tiny);
        $B  = nd->log($B  + $tiny);
        $pi = nd->log($pi + $tiny);
    }

    my $I = $self->{num_states};
    my $N = $O->len;
    die "Viterbi requiere al menos una observacion\n" if $N < 1;

    my $D = nd->zeros([$I, $N]);
    my $E = $N > 1 ? nd->zeros([$I, $N - 1]) : nd->zeros([$I, 0]);

    # Inicializacion: D[:,0] = pi (*) B[:,O[0]]
    my $obs = int($O->slice(0)->asscalar);
    my $b0  = $B->slice(':', $obs);

    if ($use_log) {
        $D->slice(':', 0)->set(($pi + $b0)->expand_dims(axis => 1));
    }
    else {
        $D->slice(':', 0)->set(($pi * $b0)->expand_dims(axis => 1));
    }

    # Recursion tensorial.
    for my $n (1 .. $N - 1) {
        $obs = int($O->slice($n)->asscalar);

        # [I] -> [I,1]; al combinar con A[I,I], MXNet hace broadcasting.
        my $prev = $D->slice(':', $n - 1)->expand_dims(axis => 1);
        my $temp = $use_log ? ($prev + $A) : ($prev * $A);

        # Para cada estado destino j, elegimos el mejor estado origen i.
        my $max_vals = $temp->max(axis => 0);
        my $argmaxes = $temp->argmax(axis => 0);
        my $emit     = $B->slice(':', $obs);

        if ($use_log) {
            $D->slice(':', $n)->set(($max_vals + $emit)->expand_dims(axis => 1));
        }
        else {
            $D->slice(':', $n)->set(($max_vals * $emit)->expand_dims(axis => 1));
        }

        $E->slice(':', $n - 1)->set($argmaxes->expand_dims(axis => 1));
    }

    # Backtracking.
    my $S_opt = nd->zeros([$N]);
    $S_opt->slice($N - 1)->set(
        $D->slice(':', $N - 1)->argmax->asscalar
    );

    for (my $n = $N - 2; $n >= 0; $n--) {
        my $next_state = int($S_opt->slice($n + 1)->asscalar);
        $S_opt->slice($n)->set(
            $E->slice($next_state, $n)->asscalar
        );
    }

    # Si se trabajo en log, D se devuelve nuevamente en escala probabilistica
    # solo por compatibilidad con el ejercicio. S_opt y E no cambian.
    return $use_log
        ? ($S_opt, nd->exp($D), $E)
        : ($S_opt, $D, $E);
}

# Alias por compatibilidad con codigo que llame simplemente viterbi().
sub viterbi {
    my ($self, @args) = @_;
    return $self->viterbi_tensors(@args);
}

# ----------------------------------------------------------------------
# APLICACION DEL MODELO YA ENTRENADO
# Devuelve NDArray para que el pipeline pueda seguir trabajando con MXNet.
# ----------------------------------------------------------------------
sub predict {
    my ($self, $observations, %args) = @_;

    die "Debe ejecutar fit() con TRAIN antes de predict()\n"
        unless $self->{fitted}
            || (defined $self->{transitions} && defined $self->{emissions} && defined $self->{start});

    my ($S_opt) = $self->viterbi_tensors(
        $observations,
        log => exists $args{log} ? $args{log} : 1,
    );

    return $S_opt;
}

1;