package Market::Indicators::OrderBlocks;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        swing_length    => $args{swing_length}    // 10,
        history_to_keep => $args{history_to_keep} // 20,
        box_width       => $args{box_width}       // 2.5,
        atr_period      => $args{atr_period}      // 50,
        zones           => [],
        active_supply   => [],
        active_demand   => [],
    };
    return bless $self, $class;
}

sub reset {
    my ($self) = @_;
    $self->{zones}         = [];
    $self->{active_supply} = [];
    $self->{active_demand} = [];
}

sub get_values {
    my ($self) = @_;
    return $self->{zones};
}

sub _overlaps {
    my ($active_zones, $new_poi, $atr_threshold) = @_;
    for my $z (@$active_zones) {
        return 1 if $new_poi >= ($z->{poi} - $atr_threshold) && $new_poi <= ($z->{poi} + $atr_threshold);
    }
    return 0;
}

sub update_last {
    my ($self, $candles, $atr_values, $i) = @_;

    return { zones => $self->{zones} } if !defined $i || $i < 0 || !$candles;

    my $bar_high = $candles->[$i]->{high};
    my $bar_low  = $candles->[$i]->{low};

    for my $z (@{$self->{active_supply}}) {
        if (!$z->{mitigated} && $bar_high >= $z->{bottom}) {
            $z->{mitigated} = 1;
            $z->{right_index} = $i;
        }
    }
    for my $z (@{$self->{active_demand}}) {
        if (!$z->{mitigated} && $bar_low <= $z->{top}) {
            $z->{mitigated} = 1;
            $z->{right_index} = $i;
        }
    }
    
    @{$self->{active_supply}} = grep { !$_->{mitigated} } @{$self->{active_supply}};
    @{$self->{active_demand}} = grep { !$_->{mitigated} } @{$self->{active_demand}};

    my $swing_length = $self->{swing_length};
    return { zones => $self->{zones} } if $i < 2 * $swing_length;

    my $p = $i - $swing_length;
    my $center = $candles->[$p];
    return { zones => $self->{zones} } unless $center;

    my $atr = $atr_values->[$p] // $atr_values->[$i];
    return { zones => $self->{zones} } unless defined $atr;

    my $atr_buffer    = $atr * ($self->{box_width} / 10);
    my $atr_threshold = $atr * 2;

    my $is_pivot_high = 1;
    my $is_pivot_low  = 1;
    for my $j (($p - $swing_length) .. ($p + $swing_length)) {
        next if $j == $p;
        my $cj = $candles->[$j];
        next unless $cj;
        $is_pivot_high = 0 if $cj->{high} >= $center->{high};
        $is_pivot_low  = 0 if $cj->{low}  <= $center->{low};
    }

    if ($is_pivot_high) {
        my $top    = $center->{high};
        my $bottom = $top - $atr_buffer;
        my $poi    = ($top + $bottom) / 2;

        if (!_overlaps($self->{active_supply}, $poi, $atr_threshold)) {
            my $zone = { type => 'SUPPLY', top => $top, bottom => $bottom, poi => $poi, left_index => $p, right_index => undef, mitigated => 0 };
            push @{$self->{zones}}, $zone;
            
            for my $k (($p + 1) .. $i) {
                if ($candles->[$k] && $candles->[$k]->{high} >= $bottom) {
                    $zone->{mitigated} = 1; $zone->{right_index} = $k; last;
                }
            }
            unless ($zone->{mitigated}) {
                push @{$self->{active_supply}}, $zone;
                shift @{$self->{active_supply}} if @{$self->{active_supply}} > $self->{history_to_keep};
            }
        }
    }

    if ($is_pivot_low) {
        my $bottom = $center->{low};
        my $top    = $bottom + $atr_buffer;
        my $poi    = ($top + $bottom) / 2;

        if (!_overlaps($self->{active_demand}, $poi, $atr_threshold)) {
            my $zone = { type => 'DEMAND', top => $top, bottom => $bottom, poi => $poi, left_index => $p, right_index => undef, mitigated => 0 };
            push @{$self->{zones}}, $zone;

            for my $k (($p + 1) .. $i) {
                if ($candles->[$k] && $candles->[$k]->{low} <= $top) {
                    $zone->{mitigated} = 1; $zone->{right_index} = $k; last;
                }
            }
            unless ($zone->{mitigated}) {
                push @{$self->{active_demand}}, $zone;
                shift @{$self->{active_demand}} if @{$self->{active_demand}} > $self->{history_to_keep};
            }
        }
    }

    return { zones => $self->{zones} };
}
1;