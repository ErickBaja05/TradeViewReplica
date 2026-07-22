package Market::Indicators::Levels;

use strict;
use warnings;
use POSIX qw(strftime);
use Time::Piece;

=head1 NOMBRE

Market::Indicators::Levels - Motor de cálculo de niveles MTF (Multi Time Frame)
al estilo SMC Pro.

=head1 DESCRIPCIÓN

Calcula automáticamente el Alto y Bajo del período anterior para todas las
temporalidades (Día, Semana, Mes) y proyecta estos niveles desde el inicio
del período actual hasta la última vela.

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        mtf_levels => [],
    };

    return bless $self, $class;
}

sub reset {
    my ($self) = @_;
    $self->{mtf_levels} = [];
}

=head2 calculate_until($candles, $until_index)

Devuelve C<< { mtf_levels => [...] } >> con todos los niveles H/L (D, W, M).
Cada elemento contiene: type, label, tf, price, start_index, end_index.

=cut

sub calculate_until {
    my ($self, $candles, $until_index) = @_;

    $self->reset();
    return { mtf_levels => [] }
        unless $candles && ref($candles) eq 'ARRAY' && defined $until_index;

    my @out_mtf = ();

    # Trackers de estado para TODAS las temporalidades simultáneamente.
    my %st = (
        D => { key => '', h => -1, l => 9999999, ph => undef, pl => undef, start => 0 },
        W => { key => '', h => -1, l => 9999999, ph => undef, pl => undef, start => 0 },
        M => { key => '', h => -1, l => 9999999, ph => undef, pl => undef, start => 0 },
    );

    for my $i (0 .. $until_index) {
my $c = $candles->[$i];
        next unless $c && $c->{time};

        my ($year, $mon, $mday);

        # Verificamos si la fecha viene en formato ISO o texto con guiones (ej. 2026-07-13...)
        if ($c->{time} =~ /^(\d{4})-(\d{2})-(\d{2})/) {
            ($year, $mon, $mday) = ($1, $2, $3);
        } elsif ($c->{time} =~ /^\d+$/) {
            # Si por el contrario es un timestamp numérico (epoch)
            my @g = gmtime($c->{time});
            ($year, $mon, $mday) = ($g[5] + 1900, sprintf("%02d", $g[4] + 1), sprintf("%02d", $g[3]));
        } else {
            next; # Si el formato no es reconocido, saltamos la vela
        }

        # Construimos las llaves directamente evitando problemas de zona horaria o Time::Piece
        my $d_key = "$year-$mon-$mday";
        
        # Para la semana ISO y mes, podemos apoyarnos en un epoch seguro o cálculo directo
        # Usando un epoch aproximado o Time::Piece de forma segura solo con la fecha base:
        my $tp   = Time::Piece->strptime("$year-$mon-$mday", "%Y-%m-%d");
        my $w_key = $tp->strftime("%G-%V");
        my $m_key = "$year-$mon";

        # --- Lógica Diaria ---
        if ($st{D}{key} ne $d_key) {
            $st{D}{ph} = $st{D}{h} if $st{D}{key}; # Guardar H anterior
            $st{D}{pl} = $st{D}{l} if $st{D}{key}; # Guardar L anterior
            $st{D}{key}   = $d_key;
            $st{D}{h}     = $c->{high};
            $st{D}{l}     = $c->{low};
            $st{D}{start} = $i;
        } else {
            $st{D}{h} = $c->{high} if $c->{high} > $st{D}{h};
            $st{D}{l} = $c->{low}  if $c->{low}  < $st{D}{l};
        }

        # --- Lógica Semanal ---
        if ($st{W}{key} ne $w_key) {
            $st{W}{ph} = $st{W}{h} if $st{W}{key};
            $st{W}{pl} = $st{W}{l} if $st{W}{key};
            $st{W}{key}   = $w_key;
            $st{W}{h}     = $c->{high};
            $st{W}{l}     = $c->{low};
            $st{W}{start} = $i;
        } else {
            $st{W}{h} = $c->{high} if $c->{high} > $st{W}{h};
            $st{W}{l} = $c->{low}  if $c->{low}  < $st{W}{l};
        }

        # --- Lógica Mensual ---
        if ($st{M}{key} ne $m_key) {
            $st{M}{ph} = $st{M}{h} if $st{M}{key};
            $st{M}{pl} = $st{M}{l} if $st{M}{key};
            $st{M}{key}   = $m_key;
            $st{M}{h}     = $c->{high};
            $st{M}{l}     = $c->{low};
            $st{M}{start} = $i;
        } else {
            $st{M}{h} = $c->{high} if $c->{high} > $st{M}{h};
            $st{M}{l} = $c->{low}  if $c->{low}  < $st{M}{l};
        }
    }

    # Compilar los niveles finales proyectados para D, W y M sin restricciones
    if (defined $st{D}{ph}) {
        push @out_mtf, { type => 'MTF_HIGH', label => 'PDH', tf => 'D', price => $st{D}{ph}, start_index => $st{D}{start}, end_index => $until_index };
        push @out_mtf, { type => 'MTF_LOW',  label => 'PDL', tf => 'D', price => $st{D}{pl}, start_index => $st{D}{start}, end_index => $until_index };
    }
    if (defined $st{W}{ph}) {
        push @out_mtf, { type => 'MTF_HIGH', label => 'PWH', tf => 'W', price => $st{W}{ph}, start_index => $st{W}{start}, end_index => $until_index };
        push @out_mtf, { type => 'MTF_LOW',  label => 'PWL', tf => 'W', price => $st{W}{pl}, start_index => $st{W}{start}, end_index => $until_index };
    }
    if (defined $st{M}{ph}) {
        push @out_mtf, { type => 'MTF_HIGH', label => 'PMH', tf => 'M', price => $st{M}{ph}, start_index => $st{M}{start}, end_index => $until_index };
        push @out_mtf, { type => 'MTF_LOW',  label => 'PML', tf => 'M', price => $st{M}{pl}, start_index => $st{M}{start}, end_index => $until_index };
    }

    $self->{mtf_levels} = \@out_mtf;

    return { mtf_levels => \@out_mtf };
}

1;
