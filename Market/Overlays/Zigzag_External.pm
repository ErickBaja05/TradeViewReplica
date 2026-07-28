package Market::Overlays::Zigzag_External;

use strict;
use warnings;

=head1 NOMBRE

Market::Overlays::SMC_Structures - Capa visual que dibuja el zigzag de
estructura de mercado (HH / HL / LH / LL) generado por
Market::Indicators::SMC_Structures sobre el canvas principal de velas.

Adaptada a Market::Panels::Scales de TradeViewReplica.

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        smc_result  => $args{smc_result},
        show_zigzag => $args{show_zigzag} // 1,
        show_labels => $args{show_labels} // 1,
    };

    return bless $self, $class;
}

=head2 set_result($smc_result)

Actualiza el resultado calculado por el motor de estructura SMC.

=cut

sub set_result {
    my ($self, $smc_result) = @_;
    $self->{smc_result} = $smc_result;
}

=head2 draw($canvas, $scale, $start, $end)

Dibuja el zigzag de estructura visible entre los índices [$start, $end].

=cut

sub draw {
    my ($self, $canvas, $scale, $start, $end) = @_;

    return if !$self->{show_zigzag};
    return unless $self->{smc_result} && $self->{smc_result}->{structure};
    return unless $canvas && $scale;

    my $structure = $self->{smc_result}->{structure};

    my $right_limit = ($canvas->Width() || 0) - 2;
    $right_limit = 0 if $right_limit < 0;

    my @pivots_to_draw;
    my $prev_pivot;
    my $next_pivot;

    for my $p (@$structure) {
        if ($p->{index} < $start) {
            $prev_pivot = $p;
            next;
        }

        if ($p->{index} > $end) {
            $next_pivot = $p;
            last;
        }

        push @pivots_to_draw, $p;
    }

    unshift @pivots_to_draw, $prev_pivot if defined $prev_pivot;
    push @pivots_to_draw, $next_pivot if defined $next_pivot;

    my @visible_points;

    for my $p (@pivots_to_draw) {
        my $x = $scale->index_to_center_x($p->{index});
        my $y = $scale->value_to_y($p->{price});

        next unless defined $x && defined $y;

        push @visible_points, {
            x     => $x,
            y     => $y,
            label => $p->{label},
            type  => $p->{type},
            price => $p->{price},
            index => $p->{index},
        };
    }

    return if @visible_points < 2;

    for my $i (1 .. $#visible_points) {
        my $a = $visible_points[$i - 1];
        my $b = $visible_points[$i];

        my ($x1, $y1) = ($a->{x}, $a->{y});
        my ($x2, $y2) = ($b->{x}, $b->{y});

        next if $x1 > $right_limit && $x2 > $right_limit;

        if ($x2 > $right_limit && $x2 != $x1) {
            my $t = ($right_limit - $x1) / ($x2 - $x1);
            $x2 = $right_limit;
            $y2 = $y1 + $t * ($y2 - $y1);
        }

        if ($x1 > $right_limit && $x1 != $x2) {
            my $t = ($right_limit - $x2) / ($x1 - $x2);
            $x1 = $right_limit;
            $y1 = $y2 + $t * ($y1 - $y2);
        }

        my $is_last_segment = ($i == $#visible_points);
        my @dash_opt = $is_last_segment ? (-dash => [4, 2]) : ();

        $canvas->createLine(
            $x1, $y1,
            $x2, $y2,
            -fill  => '#2962ff',
            -width => 2,
            @dash_opt
        );
    }

    for my $p (@visible_points) {
        next if $p->{x} > $right_limit;

        my $r = 3;

        $canvas->createOval(
            $p->{x} - $r, $p->{y} - $r,
            $p->{x} + $r, $p->{y} + $r,
            -fill    => '#2962ff',
            -outline => '#2962ff'
        );

        next if !$self->{show_labels};
        next if !defined $p->{label};
        next if $p->{label} eq 'H';
        next if $p->{label} eq 'L';

        my $dy = $p->{type} eq 'HIGH' ? -14 : 14;

        $canvas->createText(
            $p->{x},
            $p->{y} + $dy,
            -text   => $p->{label},
            -fill   => '#111111',
            -font   => ['Arial', 8, 'bold'],
            -anchor => 'center'
        );
    }
}

1;
