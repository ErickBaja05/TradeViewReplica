package Market::Indicators::Anchors;

use strict;
use warnings;

=head1 NOMBRE

Market::Indicators::Anchors - Motor de cálculo de "Pivot Points High Low &
Missed Reversal Levels", réplica de la lógica PineScript de pivots.txt
(LuxAlgo).

=head1 DESCRIPCIÓN

El indicador original detecta, con una ventana de C<length> barras a cada
lado (equivalente a C<ta.pivothigh(length,length)> / C<ta.pivotlow(length,
length)>):

  - Pivotes REGULARES: el máximo/mínimo local confirmado C<length> barras
    después de haber ocurrido.
  - Pivotes PERDIDOS ("missed"/"ghost"): extremos intermedios que quedaron
    ocultos entre dos pivotes regulares del mismo lado (p.ej. dos máximos
    seguidos sin un mínimo confirmado entre medio) y que el indicador
    original resalta con una etiqueta fantasma para no perder esa
    referencia de reversión.

A diferencia del PineScript original, este motor NO calcula las líneas de
zigzag que conectan los pivotes (ni los "ghost levels" punteados): sólo
produce la lista de marcadores (pivotes regulares y perdidos) para que la
capa visual (Market::Overlays::Anchors) dibuje únicamente los puntos.

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        length => $args{length} // 50,
    };

    return bless $self, $class;
}

sub reset {
    my ($self) = @_;
    return;
}

# Determina si el precio candles->[$c]{high} es un pivote alto estricto
# dentro de la ventana [$c-$length, $c+$length].
sub _is_pivot_high {
    my ($candles, $c, $length) = @_;

    return 0 if $c - $length < 0;
    return 0 if $c + $length > $#$candles;

    my $hi = $candles->[$c]{high};

    for my $i ($c - $length .. $c + $length) {
        next if $i == $c;
        return 0 if $candles->[$i]{high} >= $hi;
    }

    return 1;
}

# Determina si el precio candles->[$c]{low} es un pivote bajo estricto
# dentro de la ventana [$c-$length, $c+$length].
sub _is_pivot_low {
    my ($candles, $c, $length) = @_;

    return 0 if $c - $length < 0;
    return 0 if $c + $length > $#$candles;

    my $lo = $candles->[$c]{low};

    for my $i ($c - $length .. $c + $length) {
        next if $i == $c;
        return 0 if $candles->[$i]{low} <= $lo;
    }

    return 1;
}

=head2 calculate_until($candles, $until_index)

Recalcula desde cero, sobre C<$candles> (arrayref de velas 0..$until_index),
la lista completa de marcadores. Devuelve un hashref:

  { markers => [ { index, price, type }, ... ] }

donde C<type> es uno de: C<reg_high>, C<reg_low>, C<missed_high>,
C<missed_low>.

=cut

sub calculate_until {
    my ($self, $candles, $until_index) = @_;

    my $length = $self->{length};
    my @markers;

    return { markers => \@markers } unless $candles && @$candles;
    $until_index = $#$candles if !defined $until_index || $until_index > $#$candles;

    # Estado persistente (equivalente a las "var" del PineScript original)
    my $max = 0.0;
    my $min = 0.0;
    my $max_x1 = 0;
    my $min_x1 = 0;

    my $follow_max = 0.0;
    my $follow_max_x1 = 0;
    my $follow_min = 0.0;
    my $follow_min_x1 = 0;

    my $os = 0; # 1 = último pivote confirmado fue HIGH, 0 = fue LOW

    for my $n (0 .. $until_index) {

        next if $n - $length < 0;

        my $c  = $n - $length;
        my $h  = $candles->[$c]{high};
        my $l  = $candles->[$c]{low};

        my $prev_max = $max;
        my $prev_min = $min;

        $max = $h if $h > $max;
        $min = $l if $l < $min;

        my $prev_follow_max = $follow_max;
        my $prev_follow_min = $follow_min;

        $follow_max = $h if $h > $follow_max;
        $follow_min = $l if $l < $follow_min;

        if ($max > $prev_max) {
            $max_x1 = $c;
            $follow_min = $l;
        }
        if ($min < $prev_min) {
            $min_x1 = $c;
            $follow_max = $h;
        }

        if ($follow_min < $prev_follow_min) {
            $follow_min_x1 = $c;
        }
        if ($follow_max > $prev_follow_max) {
            $follow_max_x1 = $c;
        }

        my $is_ph = _is_pivot_high($candles, $c, $length);
        my $is_pl = _is_pivot_low($candles, $c, $length);

        my $os_prev = $os; # os[1]

        if ($is_ph) {
            my $ph = $h;

            if ($os_prev == 1) {
                push @markers, { index => $min_x1, price => $min, type => 'missed_low' };
            }
            elsif ($ph < $max) {
                push @markers, { index => $max_x1,       price => $max,       type => 'missed_high' };
                push @markers, { index => $follow_min_x1, price => $follow_min, type => 'missed_low' };
            }

            push @markers, { index => $c, price => $ph, type => 'reg_high' };

            $os  = 1;
            $max = $ph;
            $min = $ph;
        }

        if ($is_pl) {
            my $pl = $l;

            if ($os_prev == 0) {
                push @markers, { index => $max_x1, price => $max, type => 'missed_high' };
            }
            elsif ($pl > $min) {
                push @markers, { index => $follow_max_x1, price => $follow_max, type => 'missed_high' };
                push @markers, { index => $min_x1,        price => $min,        type => 'missed_low' };
            }

            push @markers, { index => $c, price => $pl, type => 'reg_low' };

            $os  = 0;
            $max = $pl;
            $min = $pl;
        }
    }

    return { markers => \@markers };
}

1;
