package Market::Overlays::Liquidity;

use strict;
use warnings;

=head1 NOMBRE

Market::Overlays::Liquidity - Capa visual encargada de dibujar los niveles
de liquidez (BSL / SSL) y los niveles de igualdad (EQH / EQL) calculados por
Market::Indicators::Liquidity, sobre el canvas principal de velas.

Esta clase está adaptada a la arquitectura de escalas de TradeViewReplica
(Market::Panels::Scales), que ya conoce internamente el rango de precios
visible y el mapeo índice->x, por lo que basta con invocar:

    $scale->index_to_center_x($index)
    $scale->value_to_y($price)

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        liq_result => $args{liq_result},
        show_bsl   => $args{show_bsl} // 1,
        show_ssl   => $args{show_ssl} // 1,
        show_eqh   => $args{show_eqh} // 1,
        show_eql   => $args{show_eql} // 1,
    };

    return bless $self, $class;
}

=head2 set_result($liq_result)

Actualiza el resultado calculado por el motor de liquidez.

=cut

sub set_result {
    my ($self, $liq_result) = @_;
    $self->{liq_result} = $liq_result;
}

=head2 draw($canvas, $scale, $start, $end)

Dibuja los niveles de liquidez visibles entre los índices [$start, $end].

=cut

sub draw {
    my ($self, $canvas, $scale, $start, $end) = @_;

    return unless $self->{liq_result} && $canvas && $scale;

    my $right_limit = ($canvas->Width() || 0) - 2;
    $right_limit = 0 if $right_limit < 0;

    $self->_draw_bsl_ssl($canvas, $scale, $start, $end, $right_limit);
    $self->_draw_eqh_eql($canvas, $scale, $start, $end, $right_limit);
}

sub _draw_bsl_ssl {
    my ($self, $canvas, $scale, $start, $end, $right_limit) = @_;

    my $levels = $self->{liq_result}->{liquidity} || [];

    for my $lvl (@$levels) {
        my $created_index  = $lvl->{created_index} // $lvl->{index};
        my $resolved_index = $lvl->{resolved_index};
        my $draw_end_index = defined $resolved_index ? $resolved_index : $end;

        next if $draw_end_index < $start;
        next if $created_index > $end;

        next if $lvl->{type} eq 'BSL' && !$self->{show_bsl};
        next if $lvl->{type} eq 'SSL' && !$self->{show_ssl};

        my $x1 = $scale->index_to_center_x($lvl->{index});
        my $x2 = $scale->index_to_center_x($draw_end_index);
        $x2 = $right_limit if $x2 > $right_limit;

        my $y = $scale->value_to_y($lvl->{price});
        my $color = $lvl->{type} eq 'BSL' ? '#f23645' : '#089981';

        $canvas->createLine(
            $x1, $y,
            $x2, $y,
            -fill  => $color,
            -dash  => [4, 4],
            -width => 1
        );

        $canvas->createText(
            $x2 - 4,
            $y - 8,
            -text   => $lvl->{type},
            -fill   => $color,
            -font   => ['Arial', 8, 'bold'],
            -anchor => 'e'
        );
    }
}

sub _draw_eqh_eql {
    my ($self, $canvas, $scale, $start, $end, $right_limit) = @_;

    my $equals = $self->{liq_result}->{equal_levels} || [];

    for my $eq (@$equals) {
        next if $eq->{index2} < $start;
        next if $eq->{index1} > $end;

        next if $eq->{type} eq 'EQH' && !$self->{show_eqh};
        next if $eq->{type} eq 'EQL' && !$self->{show_eql};

        my $x1 = $scale->index_to_center_x($eq->{index1});
        my $x2 = $scale->index_to_center_x($eq->{index2});
        $x2 = $right_limit if $x2 > $right_limit;

        my $y = $scale->value_to_y($eq->{price});
        my $color = $eq->{type} eq 'EQH' ? '#d32f2f' : '#00796b';

        $canvas->createLine(
            $x1, $y,
            $x2, $y,
            -fill  => $color,
            -dash  => [2, 3],
            -width => 1
        );

        my $label_x = ($x1 + $x2) / 2;

        $canvas->createText(
            $label_x,
            $y + ($eq->{type} eq 'EQH' ? -10 : 10),
            -text   => $eq->{type},
            -fill   => $color,
            -font   => ['Arial', 8, 'bold'],
            -anchor => 'center'
        );
    }
}

1;
