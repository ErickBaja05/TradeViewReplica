package Market::Overlays::Liquidity;

use strict;
use warnings;

=head1 NOMBRE

Market::Overlays::Liquidity - Capa visual que dibuja los niveles de liquidez
(BSL/SSL) con líneas punteadas etiquetadas, y los eventos resueltos de
Liquidity Sweep, Grab y Run coloreando las velas correspondientes.

=head1 DESCRIPCIÓN

Elemento visual              Estilo                    Color          Etiqueta
─────────────────────────────────────────────────────────────────────────────
Buy Side Liquidity (BSL)     Línea horiz. punteada     Rojo (#ef5350) BSL
Sell Side Liquidity (SSL)    Línea horiz. punteada     Verde (#26a69a) SSL
Sweep Up (BSL barrido)       Vela pintada + marcador   Rojo Neon (#FF0044) SWEEP ↑
Sweep Down (SSL barrido)     Vela pintada + marcador   Verde Neon (#00FF88) SWEEP ↓
Liquidity Grab               Vela pintada + marcador   Naranja (#FF8C00) LQ GRAB
Liquidity Run                Vela(s) pintadas + marker Azul (#2962FF) LQ RUN

Las líneas BSL/SSL se dibujan únicamente mientras el nivel esté en estado
'Detected' (no resuelto aún); en cuanto es sweepado desaparece la línea.
Los colores de vela se superponen sobre el cuerpo/mecha de la vela del
evento swept_index (y las N velas de Run siguientes).

=cut

# ─── Paleta de colores ────────────────────────────────────────────────────
my %COLOR = (
    BSL_LINE      => '#ef5350',   # rojo
    SSL_LINE      => '#26a69a',   # verde teal
    SWEEP_UP      => '#FF0044',   # rojo neón
    SWEEP_DOWN    => '#00FF88',   # verde neón
    GRAB          => '#FF8C00',   # naranja
    RUN           => '#2962FF',   # azul
    LABEL_BG      => '#1e222d',   # fondo oscuro para etiquetas
);

sub new {
    my ($class, %args) = @_;

    my $self = {
        liq_result  => $args{liq_result},

        # Controles individuales de visibilidad
        show_bsl    => $args{show_bsl}   // 1,
        show_ssl    => $args{show_ssl}   // 1,
        show_sweep  => $args{show_sweep} // 1,
        show_grab   => $args{show_grab}  // 1,
        show_run    => $args{show_run}   // 1,
    };

    return bless $self, $class;
}

=head2 set_result($liq_result)

Actualiza el resultado calculado por Market::Indicators::Liquidity.

=cut

sub set_result {
    my ($self, $liq_result) = @_;
    $self->{liq_result} = $liq_result;
}

=head2 draw($canvas, $scale, $start, $end)

Punto de entrada principal. Dibuja primero las líneas BSL/SSL y después los
eventos de evento (Sweep/Grab/Run) en el canvas de precios.

=cut

sub draw {
    my ($self, $canvas, $scale, $start, $end) = @_;

    return unless $self->{liq_result};
    return unless $canvas && $scale;

    my $right_limit = ($canvas->Width() || 800) - 2;
    $right_limit = 0 if $right_limit < 0;

    $self->_draw_bsl_ssl($canvas, $scale, $start, $end, $right_limit);
    $self->_draw_events($canvas, $scale, $start, $end, $right_limit);
}

# ─── Líneas horizontales punteadas BSL / SSL ─────────────────────────────

sub _draw_bsl_ssl {
    my ($self, $canvas, $scale, $start, $end, $right_limit) = @_;

    my $levels = $self->{liq_result}{liquidity} // [];

    for my $lvl (@$levels) {

        # Solo dibujamos líneas para niveles aún ACTIVOS (no resueltos)
        next if $lvl->{state} eq 'Resolved';

        my $type = $lvl->{type};   # 'BSL' o 'SSL'

        next if $type eq 'BSL' && !$self->{show_bsl};
        next if $type eq 'SSL' && !$self->{show_ssl};

        # El nivel se creó en created_index; si eso está fuera del rango
        # visible por la derecha, aún no existe.
        my $created = $lvl->{created_index} // $lvl->{index};
        next if $created > $end;

        my $price = $lvl->{price};
        my $y     = $scale->value_to_y($price);

        # La línea va desde la vela de creación hasta el borde derecho
        my $x1 = $scale->index_to_center_x($created);
        my $x2 = $right_limit;

        # Si la vela de creación está antes del inicio visible, recortamos
        $x1 = $scale->index_to_center_x($start) if $created < $start;

        next if $x2 <= $x1;

        my $color = $type eq 'BSL' ? $COLOR{BSL_LINE} : $COLOR{SSL_LINE};

        # Línea punteada horizontal
        $canvas->createLine(
            $x1, $y, $x2, $y,
            -fill  => $color,
            -width => 1,
            -dash  => [4, 4],
        );

        # Etiqueta al extremo derecho de la línea
        $canvas->createText(
            $x2 - 2, $y - 7,
            -text   => $type,
            -fill   => $color,
            -font   => ['Arial', 7, 'bold'],
            -anchor => 'e',
        );
    }
}

# ─── Velas de evento: Sweep / Grab / Run ────────────────────────────────

sub _draw_events {
    my ($self, $canvas, $scale, $start, $end, $right_limit) = @_;

    my $levels = $self->{liq_result}{liquidity} // [];

    for my $lvl (@$levels) {

        # Solo niveles ya resueltos tienen clasificación final
        next unless $lvl->{state} eq 'Resolved';

        my $class = $lvl->{classification} // '';
        next unless $class eq 'Sweep' || $class eq 'Grab' || $class eq 'Run';

        my $swept_idx    = $lvl->{swept_index};
        my $resolved_idx = $lvl->{resolved_index};
        my $liq_type     = $lvl->{type};   # BSL o SSL

        next unless defined $swept_idx;

        # ── Determinar color y etiqueta ────────────────────────────────
        my ($color, $label);

        if ($class eq 'Sweep') {
            next unless $self->{show_sweep};
            if ($liq_type eq 'BSL') {
                $color = $COLOR{SWEEP_UP};
                $label = 'SWEEP UP';
            } else {
                $color = $COLOR{SWEEP_DOWN};
                $label = 'SWEEP DOWN';
            }
        }
        elsif ($class eq 'Grab') {
            next unless $self->{show_grab};
            $color = $COLOR{GRAB};
            $label = 'GRAB';
        }
        elsif ($class eq 'Run') {
            next unless $self->{show_run};
            $color = $COLOR{RUN};
            $label = 'RUN';
        }

        # ── Rango de velas a colorear ──────────────────────────────────
        # Para Sweep/Grab: solo la vela del barrido (swept_index)
        # Para Run: desde swept_index hasta resolved_index
        my $hi_from = $swept_idx;
        my $hi_to   = ($class eq 'Run' && defined $resolved_idx)
                        ? $resolved_idx
                        : $swept_idx;

        # ¿Hay al menos una vela visible en el rango [$start,$end]?
        next if $hi_to   < $start;
        next if $hi_from > $end;

        # Recortar al rango visible
        my $draw_from = ($hi_from < $start) ? $start : $hi_from;
        my $draw_to   = ($hi_to   > $end  ) ? $end   : $hi_to;

        # ── Dibujar cuerpo de vela coloreado ──────────────────────────
        my $candles = $self->{liq_result}{candles};   # inyectado si disponible

        for my $ci ($draw_from .. $draw_to) {

            my $cx = $scale->index_to_center_x($ci);
            next if $cx < 0 || $cx > $right_limit;

            # Ancho de la vela: estimamos según barras visibles
            my $bar_w = _bar_width($scale, $start, $end);

            # Si tenemos las velas en el resultado las usamos; sino
            # dibujamos un rectángulo genérico en torno al precio medio.
            if ($candles && $candles->[$ci]) {
                my $c   = $candles->[$ci];
                my $y_h = $scale->value_to_y($c->{high});
                my $y_l = $scale->value_to_y($c->{low});
                my $y_o = $scale->value_to_y($c->{open});
                my $y_c = $scale->value_to_y($c->{close});

                my $body_top = ($y_o < $y_c) ? $y_o : $y_c;
                my $body_bot = ($y_o < $y_c) ? $y_c : $y_o;
                my $half     = int($bar_w / 2);

                # Mecha
                $canvas->createLine(
                    $cx, $y_h, $cx, $y_l,
                    -fill  => $color,
                    -width => 1,
                );

                # Cuerpo con stipple para que se vea sobre las velas normales
                $canvas->createRectangle(
                    $cx - $half, $body_top,
                    $cx + $half, $body_bot,
                    -fill    => $color,
                    -outline => $color,
                    -stipple => 'gray50',
                );
            } else {
                # Marcador simple (diamante)
                _draw_diamond($canvas, $cx,
                    $liq_type eq 'BSL'
                        ? $scale->value_to_y($lvl->{price}) - 8
                        : $scale->value_to_y($lvl->{price}) + 8,
                    $color, 4);
            }
        }

        # ── Etiqueta del evento (se pone sobre la primera vela visible) ─
        my $label_ci = $draw_from;
        my $lx = $scale->index_to_center_x($label_ci);
        my $bar_w = _bar_width($scale, $start, $end);

        # Posición vertical: encima del máximo para BSL, debajo para SSL
        my $ly;
        if ($candles && $candles->[$label_ci]) {
            my $c = $candles->[$label_ci];
            if ($liq_type eq 'BSL') {
                $ly = $scale->value_to_y($c->{high}) - 14;
            } else {
                $ly = $scale->value_to_y($c->{low})  + 14;
            }
        } else {
            $ly = $liq_type eq 'BSL'
                ? $scale->value_to_y($lvl->{price}) - 16
                : $scale->value_to_y($lvl->{price}) + 16;
        }

        $canvas->createText(
            $lx, $ly - 3,
            -text   => $label,
            -fill   => $color,
            -font   => ['Arial', 7, 'bold'],
            -anchor => 'center',
        );
    }
}

# ─── Utilidades internas ──────────────────────────────────────────────────

# Estima el ancho de barra en píxeles dado el rango visible
sub _bar_width {
    my ($scale, $start, $end) = @_;
    my $n = ($end - $start) || 1;
    my $x0 = $scale->index_to_center_x($start);
    my $x1 = $scale->index_to_center_x($end);
    my $total_px = abs($x1 - $x0) || 100;
    my $w = int($total_px / $n * 0.7);
    $w = 2 if $w < 2;
    $w = 20 if $w > 20;
    return $w;
}

# Dibuja un marcador en forma de diamante
sub _draw_diamond {
    my ($canvas, $cx, $cy, $color, $r) = @_;
    $canvas->createPolygon(
        $cx,      $cy - $r,
        $cx + $r, $cy,
        $cx,      $cy + $r,
        $cx - $r, $cy,
        -fill    => $color,
        -outline => $color,
    );
}

1;
