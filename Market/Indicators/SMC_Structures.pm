package Market::Indicators::SMC_Structures;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;

    my $self = {
        pivots         => [],
        structure      => [],
        events         => [],
        choch_atr_mult => $args{choch_atr_mult} // 2.0,
    };

    return bless $self, $class;
}

sub calculate {
    my ($self, $pivots) = @_;

    $self->{pivots}    = $pivots;
    $self->{structure} = [];
    $self->{events}    = [];

    my $last_high;
    my $last_low;

    my $trend = 'UNKNOWN';

    my $external_high;
    my $external_low;

    my $pending_choch = undef;

    for my $pivot (@$pivots) {

        my $label;

        if ($pivot->{type} eq 'HIGH') {
            $label = !defined $last_high
                ? 'H'
                : ($pivot->{price} > $last_high->{price} ? 'HH' : 'LH');

            $last_high = $pivot;
        }
        elsif ($pivot->{type} eq 'LOW') {
            $label = !defined $last_low
                ? 'L'
                : ($pivot->{price} > $last_low->{price} ? 'HL' : 'LL');

            $last_low = $pivot;
        }

        my $event;
        my $break_size = 0;
        my ($choch_level, $bos_level); # nivel (pivot previo) roto por un CHoCH, si aplica

        my $atr = $pivot->{atr} // 0;
        my $min_break = $atr * $self->{choch_atr_mult};

        if ($trend eq 'UNKNOWN') {
            if ($label eq 'HH') {
                $trend = 'UP';
                $external_high = $pivot;
            }
            elsif ($label eq 'LL') {
                $trend = 'DOWN';
                $external_low = $pivot;
            }
        }

        elsif ($trend eq 'UP') {

            if ($label eq 'HH') {
                $event = defined $pending_choch && $pending_choch->{direction} eq 'UP'
                    ? 'BOS_UP_CONFIRM'
                    : 'BOS_UP';

                $pending_choch = undef;
                $bos_level = $external_high;

                $event = defined $pending_choch && $pending_choch->{direction} eq 'UP'
                ? 'BOS_UP_CONFIRM'
                : 'BOS_UP';

                $external_high = $pivot;
            }

            elsif ($label eq 'HL') {
                $external_low = $pivot;
            }

            elsif ($label eq 'LL' && defined $external_low) {
                $break_size = $external_low->{price} - $pivot->{price};

                if ($break_size >= $min_break && !defined $pending_choch) {
                    $event = 'CHoCH_DOWN';
                    $choch_level = $external_low;
                    $pending_choch = {
                        direction => 'DOWN',
                        pivot     => $pivot,
                    };

                    $trend = 'DOWN';
                    $external_low = $pivot;
                }
            }
        }

        elsif ($trend eq 'DOWN') {

            if ($label eq 'LL') {
                $event = defined $pending_choch && $pending_choch->{direction} eq 'DOWN'
                    ? 'BOS_DOWN_CONFIRM'
                    : 'BOS_DOWN';

                $pending_choch = undef;
                $bos_level = $external_low;

                $event = defined $pending_choch && $pending_choch->{direction} eq 'DOWN'
                ? 'BOS_DOWN_CONFIRM'
                : 'BOS_DOWN';

                $external_low = $pivot;
            }

            elsif ($label eq 'LH') {
                $external_high = $pivot;
            }

            elsif ($label eq 'HH' && defined $external_high) {
                $break_size = $pivot->{price} - $external_high->{price};

                if ($break_size >= $min_break && !defined $pending_choch) {
                    $event = 'CHoCH_UP';
                    $choch_level = $external_high;
                    $pending_choch = {
                        direction => 'UP',
                        pivot     => $pivot,
                    };

                    $trend = 'UP';
                    $external_high = $pivot;
                }
            }
        }

        if (defined $event) {
            my %evento = (
                type        => $event,
                index       => $pivot->{index},
                price       => $pivot->{price},
                pivot       => $label,
                trend_after => $trend,
                break_size  => $break_size,
            );

            # Para CHoCH guardamos también el nivel (pivote previo) que fue
            # roto, de modo que la capa visual pueda trazar la línea desde
            # ese nivel hasta el punto de ruptura, al estilo TradingView.
            if (defined $choch_level) {
                $evento{level_index} = $choch_level->{index};
                $evento{level_price} = $choch_level->{price};
            }

            if (defined $bos_level) {
                $evento{level_index} = $bos_level->{index};
                $evento{level_price} = $bos_level->{price};
            }

            push @{$self->{events}}, \%evento;
        }

        push @{$self->{structure}}, {
            %$pivot,
            label => $label,
            event => $event,
        };
    }

    return {
        structure => $self->{structure},
        events    => $self->{events},
    };
}

1;