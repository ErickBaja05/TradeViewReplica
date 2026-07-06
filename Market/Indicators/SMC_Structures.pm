package Market::Indicators::SMC_Structures;
use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        market_data      => $args{market_data},
        liquidity_engine => $args{liquidity_engine},
        settings         => $args{settings} || {},
        swings           => { highs => [], lows => [], structure => [], internal => [], external => [] },
        bos_list         => [],
        choch_list       => [],
        fvg_list         => [],
        events           => [],
        market_structure => { trend => 'UNKNOWN' },
        latest_anchor_events => [],
        choch_atr_mult   => $args{choch_atr_mult} // 1.25,
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{swings} = { highs => [], lows => [], structure => [], internal => [], external => [] };
    $self->{bos_list} = [];
    $self->{choch_list} = [];
    $self->{fvg_list} = [];
    $self->{events} = [];
    $self->{latest_anchor_events} = [];
    $self->{market_structure} = { trend => 'UNKNOWN' };
}

sub recalculate {
    my ($self, $market_data) = @_;
    $market_data ||= $self->{market_data};
    return unless $market_data;
    $self->{market_data} = $market_data;
    $self->reset();

    my $internal_pivots = [];
    my $external_pivots = [];

    if ($self->{liquidity_engine}) {
        if ($self->{liquidity_engine}->can('get_internal_zigzag')) {
            $internal_pivots = $self->{liquidity_engine}->get_internal_zigzag() || [];
        }
        if ($self->{liquidity_engine}->can('get_external_zigzag')) {
            $external_pivots = $self->{liquidity_engine}->get_external_zigzag() || [];
        }
        if (!@$internal_pivots && $self->{liquidity_engine}->can('get_pivots')) {
            $internal_pivots = $self->{liquidity_engine}->get_pivots() || [];
        }
    }

    $self->_build_structure_from_pivots($internal_pivots);

    # El zigzag externo debe venir del cálculo tipo Volume Profile, no de un
    # filtro posterior sobre las etiquetas pequeñas. Así se parece más a la
    # propuesta del profesor: interno = ZZMTF; externo = línea azul limpia.
    if ($external_pivots && @$external_pivots >= 2) {
        my $external_labeled = $self->_label_external_sequence($external_pivots);
        $self->{swings}{external} = $external_labeled;
        my %external_idx = map { ($_->{index} // -1) => 1 } @$external_labeled;
        for my $pivot (@{$self->{swings}{structure}}) {
            $pivot->{structure_class} = $external_idx{$pivot->{index} // -1} ? 'EXTERNAL' : 'INTERNAL';
        }
        $self->_detect_events_from_external($external_labeled);
    }

    $self->_detect_fvg_full($market_data);
    $self->{latest_anchor_events} = [ @{$self->{bos_list}}, @{$self->{choch_list}}, @{$self->{fvg_list}} ];
}

sub _label_external_sequence {
    my ($self, $pivots) = @_;
    my ($last_high, $last_low);
    my @out;
    for my $pivot (@$pivots) {
        next unless $pivot && ref($pivot) eq 'HASH';
        my %p = %$pivot;
        if (($p{type} || '') eq 'HIGH') {
            $p{label} = !defined $last_high ? 'H' : ($p{price} > $last_high->{price} ? 'HH' : 'LH');
            $last_high = \%p;
        } elsif (($p{type} || '') eq 'LOW') {
            $p{label} = !defined $last_low ? 'L' : ($p{price} > $last_low->{price} ? 'HL' : 'LL');
            $last_low = \%p;
        }
        $p{structure_class} = 'EXTERNAL';
        push @out, \%p;
    }
    return \@out;
}

sub _detect_events_from_external {
    my ($self, $external) = @_;
    return unless $external && @$external >= 3;

    # Recalculamos BOS/CHoCH con la estructura externa limpia. Si se dejan
    # los eventos de la microestructura, el gráfico vuelve a saturarse.
    $self->{bos_list} = [];
    $self->{choch_list} = [];
    $self->{events} = [];

    my ($last_high, $last_low);
    my $trend = 'UNKNOWN';

    for my $p (@$external) {
        my $label = $p->{label} || '';

        if ($trend eq 'UNKNOWN') {
            $trend = 'UP' if $label eq 'HH';
            $trend = 'DOWN' if $label eq 'LL';
        }

        if (($p->{type} || '') eq 'HIGH') {
            if ($trend eq 'DOWN' && $label eq 'HH' && $last_high) {
                $self->_register_structure_event('CHOCH', 'BULLISH', $last_high, $p);
                $trend = 'UP';
            } elsif ($trend eq 'UP' && $label eq 'HH' && $last_high) {
                $self->_register_structure_event('BOS', 'BULLISH', $last_high, $p);
            }
            $last_high = $p;
        }
        elsif (($p->{type} || '') eq 'LOW') {
            if ($trend eq 'UP' && $label eq 'LL' && $last_low) {
                $self->_register_structure_event('CHOCH', 'BEARISH', $last_low, $p);
                $trend = 'DOWN';
            } elsif ($trend eq 'DOWN' && $label eq 'LL' && $last_low) {
                $self->_register_structure_event('BOS', 'BEARISH', $last_low, $p);
            }
            $last_low = $p;
        }
    }

    $self->{market_structure}{trend} = $trend;
}

sub update {
    my ($self, $candle_index) = @_;
    $self->recalculate($self->{market_data});
}

sub update_last {
    my ($self, $market_data) = @_;
    $self->recalculate($market_data);
}

sub _build_structure_from_pivots {
    my ($self, $pivots) = @_;
    return unless $pivots && ref($pivots) eq 'ARRAY';

    my ($last_high, $last_low);
    my ($external_high, $external_low);
    my $trend = 'UNKNOWN';

    for my $pivot (@$pivots) {
        next unless $pivot && ref($pivot) eq 'HASH';
        my $label;

        if (($pivot->{type} || '') eq 'HIGH') {
            $label = !defined $last_high ? 'H' : ($pivot->{price} > $last_high->{price} ? 'HH' : 'LH');
            $last_high = $pivot;
        }
        elsif (($pivot->{type} || '') eq 'LOW') {
            $label = !defined $last_low ? 'L' : ($pivot->{price} > $last_low->{price} ? 'HL' : 'LL');
            $last_low = $pivot;
        }
        else {
            next;
        }

        my $struct_pivot = { %$pivot, label => $label };
        push @{$self->{swings}{structure}}, $struct_pivot;
        push @{$self->{swings}{highs}}, $struct_pivot if $pivot->{type} eq 'HIGH';
        push @{$self->{swings}{lows}},  $struct_pivot if $pivot->{type} eq 'LOW';

        if ($trend eq 'UNKNOWN') {
            if ($label eq 'HH') { $trend = 'UP';   $external_high = $struct_pivot; }
            if ($label eq 'LL') { $trend = 'DOWN'; $external_low  = $struct_pivot; }
            $self->{market_structure}{trend} = $trend;
            next;
        }

        if ($trend eq 'UP') {
            if ($label eq 'HH') {
                $self->_register_structure_event('BOS', 'BULLISH', $external_high || $struct_pivot, $struct_pivot);
                $external_high = $struct_pivot;
            }
            elsif ($label eq 'HL') {
                $external_low = $struct_pivot;
            }
            elsif ($label eq 'LL' && $external_low) {
                $self->_register_structure_event('CHOCH', 'BEARISH', $external_low, $struct_pivot);
                $trend = 'DOWN';
                $external_low = $struct_pivot;
            }
        }
        elsif ($trend eq 'DOWN') {
            if ($label eq 'LL') {
                $self->_register_structure_event('BOS', 'BEARISH', $external_low || $struct_pivot, $struct_pivot);
                $external_low = $struct_pivot;
            }
            elsif ($label eq 'LH') {
                $external_high = $struct_pivot;
            }
            elsif ($label eq 'HH' && $external_high) {
                $self->_register_structure_event('CHOCH', 'BULLISH', $external_high, $struct_pivot);
                $trend = 'UP';
                $external_high = $struct_pivot;
            }
        }

        $self->{market_structure}{trend} = $trend;
    }

    # Al terminar la lectura de pivotes, separamos estructura interna y externa.
    # Interna: todos los pivotes válidos. Externa: swings principales que eliminan ruido.
    $self->{swings}{internal} = [ @{$self->{swings}{structure}} ];
    $self->{swings}{external} = $self->_select_external_swings($self->{swings}{structure});

    my %external_idx = map { ($_->{index} // -1) => 1 } @{$self->{swings}{external}};
    for my $pivot (@{$self->{swings}{structure}}) {
        $pivot->{structure_class} = $external_idx{$pivot->{index} // -1} ? 'EXTERNAL' : 'INTERNAL';
    }
}

sub _select_external_swings {
    my ($self, $swings) = @_;
    return [] unless $swings && ref($swings) eq 'ARRAY';
    return [ @$swings ] if @$swings <= 4;

    my @external;
    my $last;

    for my $s (@$swings) {
        next unless $s && ref($s) eq 'HASH';

        if (!$last) {
            push @external, $s;
            $last = $s;
            next;
        }

        # Si llega un pivot del mismo tipo, conservamos el extremo más fuerte.
        if (($s->{type} || '') eq ($last->{type} || '')) {
            my $replace = 0;
            $replace = 1 if $s->{type} eq 'HIGH' && ($s->{price} // 0) > ($last->{price} // 0);
            $replace = 1 if $s->{type} eq 'LOW'  && ($s->{price} // 0) < ($last->{price} // 0);
            if ($replace) {
                $external[-1] = $s;
                $last = $s;
            }
            next;
        }

        my $atr = (($s->{atr} // 0) + ($last->{atr} // 0)) / 2;
        $atr = 0.0001 if $atr <= 0;
        my $move = abs(($s->{price} // 0) - ($last->{price} // 0));

        # Filtro de ruido: evita unir micro-swings como estructura externa.
        if ($move >= $atr * 1.35) {
            push @external, $s;
            $last = $s;
        }
    }

    # Si el filtro fue demasiado estricto, usamos la estructura completa para no ocultar HH/HL/LH/LL.
    return @external >= 3 ? \@external : [ @$swings ];
}

sub _register_structure_event {
    my ($self, $type, $direction, $swing, $break_pivot) = @_;
    return unless $swing && $break_pivot;

    my $event = {
        type        => $type,
        direction   => $direction,
        swing_index => $swing->{index},
        break_index => $break_pivot->{index},
        break_price => $swing->{price},
        pivot_price => $break_pivot->{price},
        label       => $type eq 'CHOCH' ? 'CHoCH' : 'BOS',
        timestamp   => $break_pivot->{timestamp},
    };

    if ($type eq 'CHOCH') { push @{$self->{choch_list}}, $event; }
    else                  { push @{$self->{bos_list}},   $event; }
    push @{$self->{events}}, $event;
}

sub _detect_fvg_full {
    my ($self, $market_data) = @_;
    my $size = $market_data->size();
    return if $size < 3;

    my @active;
    for my $i (2 .. $size - 1) {
        my $c0 = $market_data->get_candle($i);
        my $c2 = $market_data->get_candle($i - 2);
        next unless $c0 && $c2;

        if (($c0->{low} // 0) > ($c2->{high} // 0)) {
            my $fvg = {
                type          => 'BULLISH',
                top           => $c0->{low},
                bottom        => $c2->{high},
                created_index => $i,
                timestamp     => $market_data->get_timestamp($i),
                state         => 'ACTIVE',
            };
            push @{$self->{fvg_list}}, $fvg;
            push @active, $fvg;
        }
        elsif (($c0->{high} // 0) < ($c2->{low} // 0)) {
            my $fvg = {
                type          => 'BEARISH',
                top           => $c2->{low},
                bottom        => $c0->{high},
                created_index => $i,
                timestamp     => $market_data->get_timestamp($i),
                state         => 'ACTIVE',
            };
            push @{$self->{fvg_list}}, $fvg;
            push @active, $fvg;
        }

        my @remaining;
        for my $gap (@active) {
            next if $gap->{created_index} == $i;
            if ($gap->{type} eq 'BULLISH' && ($c0->{low} // 0) <= ($gap->{bottom} // 0)) {
                $gap->{state} = 'MITIGATED';
                $gap->{mitigated_index} = $i;
            }
            elsif ($gap->{type} eq 'BEARISH' && ($c0->{high} // 0) >= ($gap->{top} // 0)) {
                $gap->{state} = 'MITIGATED';
                $gap->{mitigated_index} = $i;
            }
            else {
                push @remaining, $gap;
            }
        }
        @active = @remaining;
    }
}

sub get_bos                  { return $_[0]->{bos_list}; }
sub get_choch                { return $_[0]->{choch_list}; }
sub get_fvg                  { return $_[0]->{fvg_list}; }
sub get_events               { return $_[0]->{events}; }
sub get_latest_anchor_events { return $_[0]->{latest_anchor_events}; }
sub get_swings               { return $_[0]->{swings}; }
sub get_internal_swings      { return $_[0]->{swings}{internal}; }
sub get_external_swings      { return $_[0]->{swings}{external}; }
sub get_market_structure     { return $_[0]->{market_structure}; }
sub get_values               { return $_[0]->{events}; }

1;
