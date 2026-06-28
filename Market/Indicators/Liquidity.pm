package Market::Indicators::Liquidity;
use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        atr_period       => $args{atr_period} || 14,
        k_depth          => $args{k_depth} || 3,
        swing_highs      => [],
        swing_lows       => [],
        liquidity_events => [],
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{swing_highs}      = [];
    $self->{swing_lows}       = [];
    $self->{liquidity_events} = [];
}

sub update_last {
    my ($self, $market_data) = @_;
    my $size = $market_data->size();
    return if $size <= $self->{k_depth};

    my $candidate_index = $size - 1 - $self->{k_depth};
    return if $candidate_index < 0;

    $self->detect_swing_points($market_data, $candidate_index);
    $self->update_state_machine($market_data);
}

sub detect_swing_points {
    my ($self, $market_data, $current_index) = @_;
    my $k      = $self->{k_depth};
    my $size   = $market_data->size();
    return unless defined $current_index && $current_index >= $k;
    return if $current_index + $k > $size - 1;

    my $candle = $market_data->get_candle($current_index);
    return unless $candle && defined $candle->{high} && defined $candle->{low};

    my $high = $candle->{high};
    my $low  = $candle->{low};

    my $is_swing_high = 1;
    my $is_swing_low  = 1;

    for my $index ($current_index - $k .. $current_index + $k) {
        next if $index == $current_index;
        my $peer = $market_data->get_candle($index);
        next unless $peer;

        $is_swing_high = 0 if $high <= $peer->{high};
        $is_swing_low  = 0 if $low >= $peer->{low};
        last if !$is_swing_high && !$is_swing_low;
    }

    return unless $is_swing_high || $is_swing_low;

    if ($is_swing_high && !$self->_contains_event($current_index, 'BSL')) {
        push @{$self->{liquidity_events}}, {
            index       => $current_index,
            price       => $high,
            type        => 'BSL',
            state       => 'DETECTED',
            detected_at => $market_data->get_timestamp($current_index),
            bar_count   => 0,
        };
    }

    if ($is_swing_low && !$self->_contains_event($current_index, 'SSL')) {
        push @{$self->{liquidity_events}}, {
            index       => $current_index,
            price       => $low,
            type        => 'SSL',
            state       => 'DETECTED',
            detected_at => $market_data->get_timestamp($current_index),
            bar_count   => 0,
        };
    }
}

sub update_state_machine {
    my ($self, $market_data) = @_;
    my $current_candle = $market_data->last_candle();
    return unless $current_candle;

    my $current_index = $market_data->last_index();
    my $atr_value     = $self->compute_atr($market_data);
    my $tolerance     = $self->calculate_eq_tolerance($atr_value);

    foreach my $event (@{$self->{liquidity_events}}) {
        next if $event->{state} =~ /^(SWEEP|GRAB|RUN)$/;

        if ($event->{state} eq 'DETECTED') {
            if ($event->{type} eq 'BSL' && $current_candle->{high} >= $event->{price}) {
                $event->{state}       = 'SWEEP_UP';
                $event->{sweep_index} = $current_index;
                $event->{bar_count}   = 0;
                next;
            }

            if ($event->{type} eq 'SSL' && $current_candle->{low} <= $event->{price}) {
                $event->{state}       = 'SWEEP_DOWN';
                $event->{sweep_index} = $current_index;
                $event->{bar_count}   = 0;
                next;
            }
        }

        if ($event->{state} eq 'SWEEP_UP') {
            $event->{bar_count}++;

            if ($current_candle->{close} > $event->{price} + $tolerance) {
                if ($event->{bar_count} <= 3 && $current_candle->{low} <= $event->{price} + $tolerance) {
                    $self->_resolve_event($event, 'GRAB', $current_index);
                } else {
                    $self->_resolve_event($event, 'RUN', $current_index);
                }
                next;
            }

            if ($current_candle->{low} <= $event->{price} - $tolerance) {
                $self->_resolve_event($event, 'SWEEP', $current_index);
                next;
            }

            if ($event->{bar_count} >= 3) {
                $self->_resolve_event($event, 'RUN', $current_index);
            }
        }

        if ($event->{state} eq 'SWEEP_DOWN') {
            $event->{bar_count}++;

            if ($current_candle->{close} < $event->{price} - $tolerance) {
                if ($event->{bar_count} <= 3 && $current_candle->{high} >= $event->{price} - $tolerance) {
                    $self->_resolve_event($event, 'GRAB', $current_index);
                } else {
                    $self->_resolve_event($event, 'RUN', $current_index);
                }
                next;
            }

            if ($current_candle->{high} >= $event->{price} + $tolerance) {
                $self->_resolve_event($event, 'SWEEP', $current_index);
                next;
            }

            if ($event->{bar_count} >= 3) {
                $self->_resolve_event($event, 'RUN', $current_index);
            }
        }
    }
}

sub calculate_eq_tolerance {
    my ($self, $atr_value) = @_;
    return $atr_value && $atr_value > 0 ? $atr_value * 0.10 : 0.0001;
}

sub compute_atr {
    my ($self, $market_data) = @_;
    my $period = $self->{atr_period} || 14;
    my $size   = $market_data->size();
    return 0 if $size < 2;

    my $start = $size - $period - 1;
    $start = 0 if $start < 0;

    my $sum   = 0;
    my $count = 0;

    for my $idx ($start + 1 .. $size - 1) {
        my $current  = $market_data->get_candle($idx);
        my $previous = $market_data->get_candle($idx - 1);
        next unless $current && $previous;

        my $tr = $current->{high} - $current->{low};
        my $high_close = abs($current->{high} - $previous->{close});
        my $low_close  = abs($current->{low}  - $previous->{close});

        $tr = $high_close if $high_close > $tr;
        $tr = $low_close  if $low_close  > $tr;

        $sum += $tr;
        $count++;
    }

    return $count ? $sum / $count : 0;
}

sub get_values {
    my ($self) = @_;
    return $self->{liquidity_events};
}

sub get_resolved_events {
    my ($self) = @_;
    my @resolved = grep { $_->{state} =~ /^(SWEEP|GRAB|RUN)$/ } @{$self->{liquidity_events}};
    return \@resolved;
}

sub _contains_event {
    my ($self, $index, $type) = @_;
    for my $event (@{$self->{liquidity_events}}) {
        return 1 if $event->{index} == $index && $event->{type} eq $type;
    }
    return 0;
}

sub _resolve_event {
    my ($self, $event, $state, $resolved_index) = @_;
    $event->{state}        = $state;
    $event->{resolved_at}  = $resolved_index;
    $event->{last_updated} = $resolved_index;
}

1;