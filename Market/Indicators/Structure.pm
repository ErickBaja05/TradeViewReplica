package Market::Indicators::Structure;

use strict;
use warnings;

use constant BULLISH_LEG => 1;
use constant BEARISH_LEG => 0;
use constant BULLISH     => 1;
use constant BEARISH     => -1;
use constant UNKNOWN     => 0;

sub new {
    my ($class, %args) = @_;
    my $self = {
        swing_size      => $args{swing_size}    // 50,
        internal_size   => $args{internal_size} // 5,
        eq_len          => $args{eq_len}        // 3,
        eq_threshold    => $args{eq_threshold}  // 0.1,
        events          => [],
        
        swing_leg       => BEARISH_LEG,
        swing_pivot_h   => undef,
        swing_pivot_l   => undef,
        swing_trend     => UNKNOWN,
        swing_h_crossed => 0,
        swing_l_crossed => 0,

        int_leg         => BEARISH_LEG,
        int_pivot_h     => undef,
        int_pivot_l     => undef,
        int_trend       => UNKNOWN,
        int_h_crossed   => 0,
        int_l_crossed   => 0,

        eq_pivot_h      => undef,
        eq_pivot_l      => undef,
    };
    return bless $self, $class;
}

sub update_last {
    my ($self, $candles, $atr_values, $i) = @_;

    return { events => $self->{events} } if !defined $i || $i < 2;

    my $bar = $candles->[$i];
    return { events => $self->{events} } unless $bar;

    my $high  = $bar->{high};
    my $low   = $bar->{low};
    my $close = $bar->{close};

    my $sw = $self->{swing_size};
    my $is = $self->{internal_size};

    # Calcular leg swing
    my $sw_leg_new;
    {
        my $win_start = ($i >= $sw) ? $i - $sw + 1 : 0;
        my ($win_high, $win_low) = _window_high_low($candles, $win_start, $i - 1);
        my $pivot_bar = ($i >= $sw) ? $candles->[$i - $sw] : undef;
        
        if (defined $pivot_bar) {
            $sw_leg_new = ($pivot_bar->{high} > ($win_high // 0)) ? BEARISH_LEG :
                          ($pivot_bar->{low} < ($win_low // 999999)) ? BULLISH_LEG : $self->{swing_leg};
        } else {
            $sw_leg_new = $self->{swing_leg};
        }
    }

    # Calcular leg internal
    my $is_leg_new;
    {
        my $win_start = ($i >= $is) ? $i - $is + 1 : 0;
        my ($win_high, $win_low) = _window_high_low($candles, $win_start, $i - 1);
        my $pivot_bar = ($i >= $is) ? $candles->[$i - $is] : undef;
        
        if (defined $pivot_bar) {
            $is_leg_new = ($pivot_bar->{high} > ($win_high // 0)) ? BEARISH_LEG :
                          ($pivot_bar->{low} < ($win_low // 999999)) ? BULLISH_LEG : $self->{int_leg};
        } else {
            $is_leg_new = $self->{int_leg};
        }
    }

    # Pivot changes
    if ($sw_leg_new != $self->{swing_leg}) {
        if ($self->{swing_leg} == BULLISH_LEG && $sw_leg_new == BEARISH_LEG) {
            my $pb = $candles->[$i - $sw];
            $self->{swing_pivot_h} = { price => $pb->{high}, index => $i - $sw } if $pb;
            $self->{swing_h_crossed} = 0;
        } elsif ($self->{swing_leg} == BEARISH_LEG && $sw_leg_new == BULLISH_LEG) {
            my $pb = $candles->[$i - $sw];
            $self->{swing_pivot_l} = { price => $pb->{low}, index => $i - $sw } if $pb;
            $self->{swing_l_crossed} = 0;
        }
        $self->{swing_leg} = $sw_leg_new;
    }

    if ($is_leg_new != $self->{int_leg}) {
        if ($self->{int_leg} == BULLISH_LEG && $is_leg_new == BEARISH_LEG) {
            my $pb = $candles->[$i - $is];
            $self->{int_pivot_h} = { price => $pb->{high}, index => $i - $is } if $pb;
            $self->{int_h_crossed} = 0;
        } elsif ($self->{int_leg} == BEARISH_LEG && $is_leg_new == BULLISH_LEG) {
            my $pb = $candles->[$i - $is];
            $self->{int_pivot_l} = { price => $pb->{low}, index => $i - $is } if $pb;
            $self->{int_l_crossed} = 0;
        }
        $self->{int_leg} = $is_leg_new;
    }

    # EQH / EQL
    my $eq_len = $self->{eq_len};
    if ($i >= 2 * $eq_len) {
        my $p = $i - $eq_len;
        my $center = $candles->[$p];
        if ($center) {
            my ($is_ph, $is_pl) = (1, 1);
            for my $j (($p - $eq_len) .. ($p + $eq_len)) {
                next if $j == $p || !$candles->[$j];
                $is_ph = 0 if $candles->[$j]->{high} >= $center->{high};
                $is_pl = 0 if $candles->[$j]->{low}  <= $center->{low};
            }
            my $atr = $atr_values->[$p] // $atr_values->[$i];
            if ($is_ph) {
                if (defined $self->{eq_pivot_h} && defined $atr && abs($center->{high} - $self->{eq_pivot_h}->{price}) <= $self->{eq_threshold} * $atr) {
                    push @{$self->{events}}, { type => 'EQH', tier => 'external', index => $p, level_index => $self->{eq_pivot_h}->{index}, level_price => $self->{eq_pivot_h}->{price}, price1 => $self->{eq_pivot_h}->{price}, price2 => $center->{high} };
                }
                $self->{eq_pivot_h} = { price => $center->{high}, index => $p };
            }
            if ($is_pl) {
                if (defined $self->{eq_pivot_l} && defined $atr && abs($center->{low} - $self->{eq_pivot_l}->{price}) <= $self->{eq_threshold} * $atr) {
                    push @{$self->{events}}, { type => 'EQL', tier => 'external', index => $p, level_index => $self->{eq_pivot_l}->{index}, level_price => $self->{eq_pivot_l}->{price}, price1 => $self->{eq_pivot_l}->{price}, price2 => $center->{low} };
                }
                $self->{eq_pivot_l} = { price => $center->{low}, index => $p };
            }
        }
    }

    # Crossovers
    my $prev_close = ($i > 0 && $candles->[$i-1]) ? $candles->[$i-1]->{close} : $close;

    if (defined $self->{swing_pivot_h} && !$self->{swing_h_crossed}) {
        if ($prev_close <= $self->{swing_pivot_h}->{price} && $close > $self->{swing_pivot_h}->{price}) {
            push @{$self->{events}}, { type => ($self->{swing_trend} == BEARISH) ? 'CHoCH_UP' : 'BOS_UP', tier => 'external', index => $i, level_index => $self->{swing_pivot_h}->{index}, level_price => $self->{swing_pivot_h}->{price} };
            $self->{swing_trend} = BULLISH; $self->{swing_h_crossed} = 1;
        }
    }
    if (defined $self->{swing_pivot_l} && !$self->{swing_l_crossed}) {
        if ($prev_close >= $self->{swing_pivot_l}->{price} && $close < $self->{swing_pivot_l}->{price}) {
            push @{$self->{events}}, { type => ($self->{swing_trend} == BULLISH) ? 'CHoCH_DOWN' : 'BOS_DOWN', tier => 'external', index => $i, level_index => $self->{swing_pivot_l}->{index}, level_price => $self->{swing_pivot_l}->{price} };
            $self->{swing_trend} = BEARISH; $self->{swing_l_crossed} = 1;
        }
    }
    if (defined $self->{int_pivot_h} && !$self->{int_h_crossed} && (!defined $self->{swing_pivot_h} || $self->{int_pivot_h}->{price} != $self->{swing_pivot_h}->{price})) {
        if ($prev_close <= $self->{int_pivot_h}->{price} && $close > $self->{int_pivot_h}->{price}) {
            push @{$self->{events}}, { type => ($self->{int_trend} == BEARISH) ? 'CHoCH_UP' : 'BOS_UP', tier => 'internal', index => $i, level_index => $self->{int_pivot_h}->{index}, level_price => $self->{int_pivot_h}->{price} };
            $self->{int_trend} = BULLISH; $self->{int_h_crossed} = 1;
        }
    }
    if (defined $self->{int_pivot_l} && !$self->{int_l_crossed} && (!defined $self->{swing_pivot_l} || $self->{int_pivot_l}->{price} != $self->{swing_pivot_l}->{price})) {
        if ($prev_close >= $self->{int_pivot_l}->{price} && $close < $self->{int_pivot_l}->{price}) {
            push @{$self->{events}}, { type => ($self->{int_trend} == BULLISH) ? 'CHoCH_DOWN' : 'BOS_DOWN', tier => 'internal', index => $i, level_index => $self->{int_pivot_l}->{index}, level_price => $self->{int_pivot_l}->{price} };
            $self->{int_trend} = BEARISH; $self->{int_l_crossed} = 1;
        }
    }

    return { events => $self->{events} };
}

sub _window_high_low {
    my ($candles, $start_i, $end_i) = @_;
    return (undef, undef) if $start_i > $end_i || $start_i < 0;
    my ($max_h, $min_l);
    for my $j ($start_i .. $end_i) {
        my $c = $candles->[$j];
        next unless $c;
        $max_h = $c->{high} if !defined $max_h || $c->{high} > $max_h;
        $min_l = $c->{low}  if !defined $min_l || $c->{low}  < $min_l;
    }
    return ($max_h, $min_l);
}

sub reset {
    my ($self) = @_;
    
    $self->{events}          = [];
    
    $self->{swing_leg}       = BEARISH_LEG;
    $self->{swing_pivot_h}   = undef;
    $self->{swing_pivot_l}   = undef;
    $self->{swing_trend}     = UNKNOWN;
    $self->{swing_h_crossed} = 0;
    $self->{swing_l_crossed} = 0;

    $self->{int_leg}         = BEARISH_LEG;
    $self->{int_pivot_h}     = undef;
    $self->{int_pivot_l}     = undef;
    $self->{int_trend}       = UNKNOWN;
    $self->{int_h_crossed}   = 0;
    $self->{int_l_crossed}   = 0;

    $self->{eq_pivot_h}      = undef;
    $self->{eq_pivot_l}      = undef;
}

1;