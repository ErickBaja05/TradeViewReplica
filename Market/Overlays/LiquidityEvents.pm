package Market::Overlays::LiquidityEvents;

use strict;
use warnings;

=head1 NOMBRE

Market::Overlays::LiquidityEvents - Capa visual que etiqueta los eventos de
liquidez ya clasificados por Market::Indicators::Liquidity una vez que un
nivel BSL/SSL es resuelto ("Resolved"):

  - classification "Run"   => LIQUIDITY RUN   (precio acepta y sigue fuera,
                               etiqueta "LQ RUN").
  - classification "Grab"  => LIQUIDITY GRAB  (barrido con reingreso tras
                               algunas barras, etiqueta "LQ GRAB").
  - classification "Sweep" => LIQUIDITY SWEEP (barrido y reingreso en la
                               misma barra, etiqueta "LQ SWEEP").

Se apoya en el mismo resultado (liq_result) que ya calcula
Market::Indicators::Liquidity y que usa Market::Overlays::Liquidity para
dibujar los niveles BSL/SSL.

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        liq_result  => $args{liq_result},
        show_run    => $args{show_run} // 1,
        show_grab   => $args{show_grab} // 1,
        show_sweep  => $args{show_sweep} // 1,
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

Dibuja las etiquetas de eventos de liquidez resueltos y visibles entre los
índices [$start, $end].

=cut

my %STYLE = (
    Run   => { label => 'LQ RUN',   color => '#06023f' },
    Grab  => { label => 'LQ GRAB',  color => '#06023f' },
    Sweep => { label => 'LQ SWEEP', color => '#06023f' },
);

sub draw {
    my ($self, $canvas, $scale, $start, $end) = @_;

    return unless $self->{liq_result} && $canvas && $scale;

    my $right_limit = ($canvas->Width() || 0) - 2;
    $right_limit = 0 if $right_limit < 0;

    my $levels = $self->{liq_result}->{liquidity} || [];

    for my $lvl (@$levels) {

        my $classification = $lvl->{classification};
        next unless defined $classification;
        next unless exists $STYLE{$classification};

        next if $classification eq 'Run'   && !$self->{show_run};
        next if $classification eq 'Grab'  && !$self->{show_grab};
        next if $classification eq 'Sweep' && !$self->{show_sweep};

        my $resolved_index = $lvl->{resolved_index};
        next unless defined $resolved_index;
        next if $resolved_index < $start || $resolved_index > $end;

        my $x = $scale->index_to_center_x($resolved_index);
        next unless defined $x;
        next if $x > $right_limit;

        my $y = $scale->value_to_y($lvl->{price});
        next unless defined $y;

        my $style = $STYLE{$classification};

        # Marca el punto de resolución del evento con una pequeña cruz.
        my $r = 3;
        $canvas->createLine($x - $r, $y, $x + $r, $y, -fill => $style->{color}, -width => 1);
        $canvas->createLine($x, $y - $r, $x, $y + $r, -fill => $style->{color}, -width => 1);

        my $dy = $lvl->{type} eq 'BSL' ? -18 : 18;

        $canvas->createText(
            $x,
            $y + $dy,
            -text   => $style->{label},
            -fill   => $style->{color},
            -font   => ['Arial', 8, 'bold'],
            -anchor => 'center'
        );
    }
}

1;