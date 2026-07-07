package Market::Indicators::OrderBlock;

use strict;
use warnings;

=head1 NOMBRE

Market::Indicators::OrderBlock - Motor de cálculo de Order Blocks (OB).

=head1 DESCRIPCIÓN

Un Order Block se identifica como la última vela de color opuesto a un
movimiento impulsivo (cuerpo >= ATR * impulse_atr_mult) que precede a dicho
movimiento:

  * OB ALCISTA (BULLISH): última vela bajista antes de un impulso alcista
    fuerte. La zona = [low, high] de esa vela bajista.
  * OB BAJISTA (BEARISH): última vela alcista antes de un impulso bajista
    fuerte. La zona = [low, high] de esa vela alcista.

La zona queda "abierta" y se extiende hacia adelante hasta que el precio
cierra más allá de ella (mitigación/invalidación).

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        impulse_atr_mult => $args{impulse_atr_mult} // 1.5,
        max_lookback      => $args{max_lookback}      // 15,
        zones             => [],
    };

    return bless $self, $class;
}

sub reset {
    my ($self) = @_;
    $self->{zones} = [];
}

=head2 calculate_until($candles, $atr_values, $until_index)

Recalcula desde cero (barrido único hacia adelante) todos los Order Blocks
visibles hasta el índice indicado.

=cut

sub calculate_until {
    my ($self, $candles, $atr_values, $until_index) = @_;

    $self->reset();
    return { zones => $self->{zones} } if !defined $until_index || $until_index < 1;

    my %anchored; # índices de velas ya usadas como ancla de un OB
    my @open_zones;

    for my $i (0 .. $until_index) {
        my $bar = $candles->[$i];
        next unless $bar;

        # 1. Actualizamos mitigación/invalidación de zonas abiertas
        for my $z (@open_zones) {
            if ($z->{type} eq 'BULLISH') {
                if ($bar->{close} < $z->{bottom}) {
                    $z->{state}        = 'Filled';
                    $z->{filled_index} = $i;
                }
            } else {
                if ($bar->{close} > $z->{top}) {
                    $z->{state}        = 'Filled';
                    $z->{filled_index} = $i;
                }
            }
        }
        @open_zones = grep { $_->{state} eq 'Open' } @open_zones;

        next if $i < 1;

        my $atr = $atr_values->[$i] // 0;
        next if $atr <= 0;

        my $body      = $bar->{close} - $bar->{open};
        my $threshold = $atr * $self->{impulse_atr_mult};
        next if abs($body) < $threshold;

        # Movimiento impulsivo detectado: buscamos hacia atrás la vela ancla
        # de color opuesto más cercana (sin reutilizar anclas ya usadas)
        my $busca_bajista = $body > 0; # impulso alcista -> ancla bajista
        my $limite        = $i - $self->{max_lookback};
        $limite = 0 if $limite < 0;

        my $anchor_idx;
        for (my $j = $i - 1; $j >= $limite; $j--) {
            next if $anchored{$j};
            my $c = $candles->[$j];
            next unless $c;

            my $es_bajista = $c->{close} < $c->{open};
            my $es_alcista = $c->{close} > $c->{open};

            if ($busca_bajista && $es_bajista) { $anchor_idx = $j; last; }
            if (!$busca_bajista && $es_alcista) { $anchor_idx = $j; last; }
        }

        next unless defined $anchor_idx;

        my $anchor = $candles->[$anchor_idx];
        $anchored{$anchor_idx} = 1;

        my $zone = {
            type          => $busca_bajista ? 'BULLISH' : 'BEARISH',
            top           => $anchor->{high},
            bottom        => $anchor->{low},
            left_index    => $anchor_idx,
            created_index => $i,
            state         => 'Open',
            filled_index  => undef,
        };

        push @{$self->{zones}}, $zone;
        push @open_zones, $zone;
    }

    return { zones => $self->{zones} };
}

1;
