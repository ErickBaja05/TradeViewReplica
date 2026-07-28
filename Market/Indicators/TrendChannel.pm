package Market::Indicators::TrendChannel;

use strict;
use warnings;

=head1 NOMBRE

Market::Indicators::TrendChannel - Motor de cálculo del indicador
"Trend Channel", puerto de la lógica PineScript de trendchannel.txt
("Linear Regression Channel" de LonesomeTheBlue).

Para cada barra se ajusta una regresión lineal (mínimos cuadrados) sobre
las últimas "length" velas, obteniendo la línea central (mid) y una banda
paralela de ancho "deviation" desviaciones estándar (upper/lower), igual
que get_channel() del script original (mid/slope/dev).

A diferencia del script original NO se replica la lógica de "canal roto"
(outofchannel / showbroken), ya que este puerto está pensado para no
mostrar canales rotos en ningún caso: sólo se calcula y dibuja el canal
vigente en cada barra.

Se calcula un canal por cada barra (una regresión distinta por cada
ventana deslizante), pero Market::Overlays::TrendChannel sólo dibuja el
canal vigente en la última barra visible, como una recta extendida hacia
la derecha (igual que "Extend Lines" del script original) — así el canal
se ve como una línea recta, no como una curva.

=head1 PARÁMETROS

  length     => nº de velas usadas para la regresión (def: 100)
  deviation  => multiplicador de la desviación estándar (def: 2)
  source     => precio usado como fuente ('close', 'open', 'high', 'low') (def: 'close')

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        length    => $args{length}    // 100,
        deviation => $args{deviation} // 2,
        source    => $args{source}    // 'close',
        values    => [],   # serie completa: [{ mid_y1, mid_y2, upper_y1, upper_y2, lower_y1, lower_y2, slope }, ...]
    };

    return bless $self, $class;
}

sub reset {
    my ($self) = @_;
    $self->{values} = [];
}

sub get_values {
    my ($self) = @_;
    return $self->{values};
}

=head2 calculate_until($candles, $until_index)

Recalcula desde cero la serie completa de canales de tendencia hasta
$until_index (inclusive). $candles es un arrayref de velas
{open,high,low,close}.

Devuelve un hashref { values => [...] } donde cada elemento (uno por
barra, undef si no hay suficiente historial) contiene:

  start, end   => índices de barra (inicio/fin de la ventana de regresión)
  mid_y1/y2    => valores de precio de la línea central en start/end
  upper_y1/y2  => línea central + deviation * desviación estándar
  lower_y1/y2  => línea central - deviation * desviación estándar
  slope        => pendiente de la regresión (>0 alcista, <0 bajista, 0 plano)

=cut

sub calculate_until {
    my ($self, $candles, $until_index) = @_;

    $self->reset();
    return { values => $self->{values} }
        if !defined $until_index || $until_index < 0 || !$candles;

    my $length = $self->{length};
    my $devlen = $self->{deviation};
    my $source = $self->{source};

    return { values => $self->{values} } if $length < 2;

    for my $i (0 .. $until_index) {

        if ($i < $length - 1) {
            push @{$self->{values}}, undef;
            next;
        }

        my $win_start = $i - $length + 1;

        # --- Regresión lineal (mínimos cuadrados) sobre la ventana ---
        # t = 0 en la vela más antigua de la ventana, t = length-1 en la
        # más reciente (barra $i).
        my ($sum_t, $sum_t2, $sum_y, $sum_ty) = (0, 0, 0, 0);

        for my $t (0 .. $length - 1) {
            my $c = $candles->[$win_start + $t];
            my $y = $c->{$source};
            $sum_t  += $t;
            $sum_t2 += $t * $t;
            $sum_y  += $y;
            $sum_ty += $t * $y;
        }

        my $n           = $length;
        my $denominator = $n * $sum_t2 - $sum_t * $sum_t;

        my ($slope, $intercept);
        if ($denominator == 0) {
            $slope     = 0;
            $intercept = $sum_y / $n;
        }
        else {
            $slope     = ($n * $sum_ty - $sum_t * $sum_y) / $denominator;
            $intercept = ($sum_y - $slope * $sum_t) / $n;
        }

        # --- Desviación estándar de los residuos respecto a la recta ---
        my $dev_sum = 0;
        for my $t (0 .. $length - 1) {
            my $c = $candles->[$win_start + $t];
            my $y = $c->{$source};
            my $predicted = $intercept + $slope * $t;
            $dev_sum += ($y - $predicted) ** 2;
        }
        my $dev = sqrt($dev_sum / $n);

        my $mid_y1 = $intercept;
        my $mid_y2 = $intercept + $slope * ($length - 1);

        push @{$self->{values}}, {
            start     => $win_start,
            end       => $i,
            mid_y1    => $mid_y1,
            mid_y2    => $mid_y2,
            upper_y1  => $mid_y1 + $dev * $devlen,
            upper_y2  => $mid_y2 + $dev * $devlen,
            lower_y1  => $mid_y1 - $dev * $devlen,
            lower_y2  => $mid_y2 - $dev * $devlen,
            slope     => $slope,
        };
    }

    return { values => $self->{values} };
}

1;
