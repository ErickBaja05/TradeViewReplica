package Market::Indicators::FVG;

use strict;
use warnings;

=head1 NOMBRE

Market::Indicators::FVG - Motor de cálculo de Fair Value Gaps (FVG).

=head1 DESCRIPCIÓN

Un Fair Value Gap (imbalance) ocurre cuando, en una secuencia de 3 velas
consecutivas [i-2, i-1, i], la vela extrema más reciente deja un "hueco" de
precio respecto a la vela extrema más antigua, sin que la vela intermedia lo
haya llegado a cubrir:

  * FVG ALCISTA (BULLISH): low(i) > high(i-2)   -> zona = [high(i-2), low(i)]
  * FVG BAJISTA (BEARISH): high(i) < low(i-2)   -> zona = [high(i), low(i-2)]

La zona queda "abierta" hasta que el precio regresa y la rellena por
completo (mitigación), momento en el cual se marca como 'Filled'.

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        # Filtra huecos insignificantes (ruido) exigiendo que el tamaño del
        # gap sea al menos esta fracción del ATR vigente en la vela i.
        min_gap_atr_mult => $args{min_gap_atr_mult} // 0.05,
        zones            => [],
    };

    return bless $self, $class;
}

sub reset {
    my ($self) = @_;
    $self->{zones} = [];
}

=head2 calculate_until($candles, $atr_values, $until_index)

Recalcula desde cero (barrido único hacia adelante) todas las zonas FVG
visibles hasta el índice indicado.

=cut

sub calculate_until {
    my ($self, $candles, $atr_values, $until_index) = @_;

    $self->reset();
    return { zones => $self->{zones} } if !defined $until_index || $until_index < 2;

    my @open_zones;

    for my $i (0 .. $until_index) {
        my $bar = $candles->[$i];
        next unless $bar;

        # 1. Actualizamos mitigación de zonas abiertas con la vela actual
        for my $z (@open_zones) {
            if ($z->{type} eq 'BULLISH') {
                if ($bar->{low} <= $z->{bottom}) {
                    $z->{state}        = 'Filled';
                    $z->{filled_index} = $i;
                }
            } else {
                if ($bar->{high} >= $z->{top}) {
                    $z->{state}        = 'Filled';
                    $z->{filled_index} = $i;
                }
            }
        }
        @open_zones = grep { $_->{state} eq 'Open' } @open_zones;

        # 2. Detectamos un nuevo FVG usando las velas (i-2, i-1, i)
        next if $i < 2;

        my $c0 = $candles->[$i - 2];
        my $c2 = $candles->[$i];
        next unless $c0 && $c2;

        my $atr      = $atr_values->[$i] // 0;
        my $min_gap  = $atr * $self->{min_gap_atr_mult};

        if ($c2->{low} > $c0->{high} && ($c2->{low} - $c0->{high}) > $min_gap) {
            my $zone = {
                type          => 'BULLISH',
                top           => $c2->{low},
                bottom        => $c0->{high},
                left_index    => $i - 2,
                created_index => $i,
                state         => 'Open',
                filled_index  => undef,
            };
            push @{$self->{zones}}, $zone;
            push @open_zones, $zone;
        }
        elsif ($c2->{high} < $c0->{low} && ($c0->{low} - $c2->{high}) > $min_gap) {
            my $zone = {
                type          => 'BEARISH',
                top           => $c0->{low},
                bottom        => $c2->{high},
                left_index    => $i - 2,
                created_index => $i,
                state         => 'Open',
                filled_index  => undef,
            };
            push @{$self->{zones}}, $zone;
            push @open_zones, $zone;
        }
    }

    return { zones => $self->{zones} };
}

1;
