package Market::Indicators::VolumeProfileAnchored;

use strict;
use warnings;

=head1 NOMBRE

Market::Indicators::VolumeProfileAnchored - Motor de cálculo del Volume
Profile Anclado (Anchored Volume Profile), replicando la lógica del
indicador nativo de TradingView:

  * Se divide el rango de precios [min(low), max(high)] entre la vela de
    ancla y la vela actual en $num_bins franjas horizontales.
  * El volumen de cada vela se reparte proporcionalmente entre las franjas
    que cubre su rango [low, high] (distribución uniforme intravela, ya que
    no disponemos de datos tick-by-tick).
  * POC (Point of Control): franja con mayor volumen acumulado.
  * Value Area de 1 sigma: en vez del clásico 70% "value area" de
    TradingView, aquí la zona de valor se calcula como
    [media - 1*sigma, media + 1*sigma], usando la media y la desviación
    estándar del precio ponderadas por volumen (igual criterio que las
    bandas del VWAP Anclado, pero aplicado a la distribución de volumen por
    precio en lugar de a la serie temporal).

El cálculo se reinicia ("ancla") en la vela seleccionada por el usuario
($anchor_index) y considera todas las velas hasta $until_index.

=head1 PARÁMETROS

  num_bins => cantidad de franjas de precio del histograma (def: 24)

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        num_bins     => $args{num_bins} // 24,
        bins         => [],   # [{ price_low, price_high, volume }, ...]
        anchor_index => undef,
        until_index  => undef,
        poc_price    => undef,
        vah          => undef,   # límite superior de la zona de valor (media + 1 sigma)
        val          => undef,   # límite inferior de la zona de valor (media - 1 sigma)
        max_volume   => 0,
        total_volume => 0,
    };

    return bless $self, $class;
}

sub reset {
    my ($self) = @_;
    $self->{bins}         = [];
    $self->{poc_price}    = undef;
    $self->{vah}          = undef;
    $self->{val}          = undef;
    $self->{max_volume}   = 0;
    $self->{total_volume} = 0;
}

sub get_values {
    my ($self) = @_;
    return $self->{bins};
}

sub set_anchor {
    my ($self, $anchor_index) = @_;
    $self->{anchor_index} = $anchor_index;
}

sub get_anchor {
    my ($self) = @_;
    return $self->{anchor_index};
}

=head2 calculate_until($candles, $anchor_index, $until_index)

Recalcula el histograma de Volume Profile desde $anchor_index hasta
$until_index (ambos inclusive). $candles es un arrayref completo de velas
{open,high,low,close,volume}.

Devuelve un hashref:
  anchor_index => ...
  until_index  => ...
  bins         => [{ price_low, price_high, volume }, ...]  (de abajo a arriba)
  poc_price    => precio central de la franja con más volumen
  vah          => media + 1 sigma (ponderada por volumen)
  val          => media - 1 sigma (ponderada por volumen)
  max_volume   => volumen de la franja más operada (para escalar las barras)

=cut

sub calculate_until {
    my ($self, $candles, $anchor_index, $until_index) = @_;

    $self->reset();
    $self->{anchor_index} = $anchor_index;
    $self->{until_index}  = $until_index;

    return {
        anchor_index => $anchor_index,
        until_index  => $until_index,
        bins         => $self->{bins},
        poc_price    => undef,
        vah          => undef,
        val          => undef,
        max_volume   => 0,
    } if !defined $anchor_index || !defined $until_index
      || $anchor_index < 0 || $until_index < $anchor_index
      || !$candles;

    my $num_bins = $self->{num_bins};
    $num_bins = 1 if $num_bins < 1;

    # --- 1. Rango de precios cubierto por el tramo anclado ---
    my ($price_min, $price_max);

    for my $i ($anchor_index .. $until_index) {
        my $c = $candles->[$i];
        next unless $c;
        $price_min = $c->{low}  if !defined $price_min || $c->{low}  < $price_min;
        $price_max = $c->{high} if !defined $price_max || $c->{high} > $price_max;
    }

    return {
        anchor_index => $anchor_index,
        until_index  => $until_index,
        bins         => $self->{bins},
        poc_price    => undef,
        vah          => undef,
        val          => undef,
        max_volume   => 0,
    } unless defined $price_min && defined $price_max && $price_max > $price_min;

    my $bin_size = ($price_max - $price_min) / $num_bins;
    $bin_size = 1e-9 if $bin_size <= 0;

    # --- 2. Inicializamos las franjas vacías ---
    my @bins;
    for my $b (0 .. $num_bins - 1) {
        push @bins, {
            price_low  => $price_min + $b * $bin_size,
            price_high => $price_min + ($b + 1) * $bin_size,
            volume     => 0,
        };
    }

    # --- 3. Repartimos el volumen de cada vela entre las franjas que
    #        solapa su rango [low, high], de forma proporcional al ancho
    #        de solapamiento (distribución uniforme intravela). ---
    for my $i ($anchor_index .. $until_index) {
        my $c = $candles->[$i];
        next unless $c;

        my $vol = $c->{volume} // 0;
        $vol = 0 if $vol eq '';
        next if $vol <= 0;

        my $low  = $c->{low};
        my $high = $c->{high};

        if ($high <= $low) {
            # Vela sin rango (low == high): todo el volumen va a la franja
            # que contiene ese precio único.
            my $idx = int(($low - $price_min) / $bin_size);
            $idx = 0 if $idx < 0;
            $idx = $num_bins - 1 if $idx > $num_bins - 1;
            $bins[$idx]{volume} += $vol;
            next;
        }

        my $candle_range = $high - $low;

        my $first_bin = int(($low - $price_min) / $bin_size);
        my $last_bin  = int(($high - $price_min) / $bin_size);
        $first_bin = 0 if $first_bin < 0;
        $last_bin  = $num_bins - 1 if $last_bin > $num_bins - 1;

        for my $b ($first_bin .. $last_bin) {
            my $bin_low  = $bins[$b]{price_low};
            my $bin_high = $bins[$b]{price_high};

            my $overlap_low  = $low  > $bin_low  ? $low  : $bin_low;
            my $overlap_high = $high < $bin_high ? $high : $bin_high;
            my $overlap = $overlap_high - $overlap_low;
            next if $overlap <= 0;

            $bins[$b]{volume} += $vol * ($overlap / $candle_range);
        }
    }

    $self->{bins} = \@bins;

    # --- 4. POC: franja con mayor volumen ---
    my ($poc_bin, $max_volume) = (undef, 0);
    my $total_volume = 0;

    for my $bin (@bins) {
        $total_volume += $bin->{volume};
        if ($bin->{volume} > $max_volume) {
            $max_volume = $bin->{volume};
            $poc_bin    = $bin;
        }
    }

    my $poc_price = $poc_bin
        ? ($poc_bin->{price_low} + $poc_bin->{price_high}) / 2
        : undef;

    # --- 5. Zona de valor de 1 sigma: media y desviación estándar del
    #        precio, ponderadas por el volumen de cada franja. ---
    my ($vah, $val);

    if ($total_volume > 0) {
        my $sum_pv  = 0;
        my $sum_pv2 = 0;

        for my $bin (@bins) {
            my $mid = ($bin->{price_low} + $bin->{price_high}) / 2;
            $sum_pv  += $mid * $bin->{volume};
            $sum_pv2 += $mid * $mid * $bin->{volume};
        }

        my $mean     = $sum_pv / $total_volume;
        my $variance = ($sum_pv2 / $total_volume) - ($mean * $mean);
        $variance = 0 if $variance < 0;
        my $sigma = sqrt($variance);

        $vah = $mean + $sigma;
        $val = $mean - $sigma;
    }

    $self->{poc_price}    = $poc_price;
    $self->{vah}          = $vah;
    $self->{val}          = $val;
    $self->{max_volume}   = $max_volume;
    $self->{total_volume} = $total_volume;

    return {
        anchor_index => $anchor_index,
        until_index  => $until_index,
        bins         => \@bins,
        poc_price    => $poc_price,
        vah          => $vah,
        val          => $val,
        max_volume   => $max_volume,
    };
}

1;
