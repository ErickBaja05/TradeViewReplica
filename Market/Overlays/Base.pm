package Market::Overlays::Base;

use strict;
use warnings;

=head1 NOMBRE
Market::Overlays::Base - Clase base abstracta para todos los Overlays gráficos.
=cut

sub new {
    my ($class, %args) = @_;
    my $self = {
        engine => $args{engine}, # Referencia al ChartEngine
        canvas => $args{canvas}, # Referencia al PriceCanvas
        data   => [],            # Datos internos del overlay
    };
    bless $self, $class;
    return $self;
}

# Método que debe ser llamado en cada paso del Replay para recalcular
sub update {
    my ($self, $current_index) = @_;
    die "El método update() debe ser implementado por la subclase.";
}

# Método de dibujado que consumirá Doménica
sub render {
    my ($self, $start_index, $end_index, $scale) = @_;
    die "El método render() debe ser implementado por la subclase.";
}

# Limpieza de elementos del canvas
sub clear {
    my ($self, $tag) = @_;
    $self->{canvas}->delete($tag) if $self->{canvas} && $tag;
}

1;