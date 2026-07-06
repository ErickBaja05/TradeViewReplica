package Market::Overlays::Liquidity;
 
use strict;
use warnings;
use parent 'Market::Overlays::Base';
use List::Util qw(max min);
 
sub new {
    my ($class, %args) = @_;
    my $self = $class->SUPER::new(%args);
 
    # Referencia al indicador inyectado desde el exterior
    $self->{liquidity_indicator} = $args{liquidity_indicator};
    
    # --- Configuración Visual General ---
    $self->{bg_color} = $args{bg_color} || [251, 252, 248]; # Fondo base para transparencias (#fbfcf8)
 
    # --- Colores Base ---
    $self->{bsl_color}  = $args{bsl_color}  || '#ef5350'; # Rojo BSL
    $self->{ssl_color}  = $args{ssl_color}  || '#26a69a'; # Verde SSL
    $self->{grab_color} = $args{grab_color} || '#ffb74d'; # Naranja (Grab)
    $self->{run_color}  = $args{run_color}  || '#2962ff'; # Azul (Run)
    $self->{eqh_color}  = $args{eqh_color}  || '#ef5350'; # Rojo EQH
    $self->{eql_color}  = $args{eql_color}  || '#26a69a'; # Verde EQL
    
    $self->{zz_ext_color} = $args{zz_ext_color} || '#2962ff'; # Azul para ZigZag Estructural
    $self->{zz_int_color} = $args{zz_int_color} || '#787b86'; # Gris neutro para ZigZag Menor
 
    # --- Configuraciones de Grosor y Tamaños ---
    $self->{line_width_ext} = $args{line_width_ext} || 2;
    $self->{line_width_int} = $args{line_width_int} || 1;
    $self->{font_size}      = $args{font_size}      || 7;
    $self->{label_bg_color} = $args{label_bg_color} || '#fbfcf8';
 
    # --- Toggles de Visibilidad (Configuración) ---
    $self->{show_zz_ext}    = exists $args{show_zz_ext}    ? $args{show_zz_ext}    : 1;
    $self->{show_zz_int}    = exists $args{show_zz_int}    ? $args{show_zz_int}    : 1;
    $self->{show_candidates}= exists $args{show_candidates}? $args{show_candidates}: 1;
    $self->{show_eqh}       = exists $args{show_eqh}       ? $args{show_eqh}       : 1;
    $self->{show_eql}       = exists $args{show_eql}       ? $args{show_eql}       : 1;
    $self->{show_bsl}       = exists $args{show_bsl}       ? $args{show_bsl}       : 1;
    $self->{show_ssl}       = exists $args{show_ssl}       ? $args{show_ssl}       : 1;
    $self->{show_sweep}     = exists $args{show_sweep}     ? $args{show_sweep}     : 1;
    $self->{show_grab}      = exists $args{show_grab}      ? $args{show_grab}      : 1;
    $self->{show_run}       = exists $args{show_run}       ? $args{show_run}       : 1;
 
    # --- Transparencias por Estado (LuxAlgo Style) ---
    $self->{opacities} = {
        ACTIVE     => 1.0,
        DETECTED   => 1.0,
        SWEPT      => 0.7,
        ACCEPTANCE => 0.5,
        RESOLVED   => 0.3
    };
 
    # Sistema de Caché para Renderizado Incremental
    $self->{canvas_cache} = {};
 
    return $self;
}
 
# ==========================================================
# Controlador Principal (Orquestador de Render)
# ==========================================================
sub render {
    my ($self, $start_index, $end_index, $scale) = @_;
    my $canvas = $self->{canvas};
    return undef unless $canvas && $scale && ($self->{active} // 1);
 
    my $indicator = $self->_get_liquidity_indicator();
    return undef unless $indicator;
 
    my $tf = $indicator->{active_timeframe} || '1m';
    $self->{canvas_cache}->{$tf} ||= {};
    my %seen_tags;
    my @placed_labels;
 
    # --- SECUENCIA ESTRICTA DE Z-ORDER (Dibujo de fondo a frente) ---
    
    # 1. ZigZag Estructural e Interno (Segmentos)
    $self->_render_zigzag($indicator, $start_index, $end_index, $scale, $tf, \%seen_tags);
 
    # 2. Pivotes Confirmados
    $self->_render_pivots($indicator, $start_index, $end_index, $scale, $tf, \%seen_tags);
 
    # 3. Equal Highs / Equal Lows (Bandas de liquidez)
    $self->_render_equal_levels($indicator, $start_index, $end_index, $scale, $tf, \%seen_tags);
 
    # 4. Niveles BSL / SSL (Líneas horizontales y marcadores básicos)
    $self->_render_liquidity_levels($indicator, $start_index, $end_index, $scale, $tf, \%seen_tags);
 
    # 5. Eventos Resueltos (Sweep, Grab, Run - Etiquetas y marcadores avanzados)
    $self->_render_resolved_events($indicator, $start_index, $end_index, $scale, $tf, \%seen_tags, \@placed_labels);
 
    # 6. Candidatos Activos (Líneas punteadas)
    $self->_render_candidates($indicator, $start_index, $end_index, $scale, $tf, \%seen_tags);
 
    # --- PURGA DE CACHÉ (Render Incremental) ---
    foreach my $cached_tag (keys %{$self->{canvas_cache}->{$tf}}) {
        if (!$seen_tags{$cached_tag}) {
            $canvas->delete($cached_tag);
            delete $self->{canvas_cache}->{$tf}->{$cached_tag};
        }
    }
 
    # --- ENFORCEMENT DE Z-ORDER ---
    $canvas->raise('lq_zz_ext');
    $canvas->raise('lq_zz_int');
    $canvas->raise('lq_eq_level');
    $canvas->raise('lq_bsl_ssl');
    $canvas->raise('lq_cand');
    $canvas->raise('lq_event');
    $canvas->raise('lq_label');
}
 
# ==========================================================
# 1. Renderizado de ZigZag
# ==========================================================
sub _render_zigzag {
    my ($self, $indicator, $start_index, $end_index, $scale, $tf, $seen) = @_;
    
    my $segments = $indicator->get_zigzag_segments();
    return unless $segments && ref($segments) eq 'ARRAY';
 
    foreach my $seg (@$segments) {
        my $idx1 = $seg->{start_index};
        my $idx2 = $seg->{end_index};
        
        # Filtro estricto para Replay: Nunca dibujar el segmento si el final es futuro
        next if $idx2 > $end_index;
        next if $idx2 < $start_index && $idx1 < $start_index;
 
        my $tier   = $seg->{tier} || 'minor';
        next if $tier eq 'structural' && !$self->{show_zz_ext};
        next if $tier eq 'minor'      && !$self->{show_zz_int};
 
        my $is_ext = ($tier eq 'structural');
        my $color  = $is_ext ? $self->{zz_ext_color} : $self->{zz_int_color};
        my $width  = $is_ext ? $self->{line_width_ext} : $self->{line_width_int};
        my $layer  = $is_ext ? 'lq_zz_ext' : 'lq_zz_int';
 
        my $tag = "zz_${tier}_${idx1}_${idx2}";
        $seen->{$tag} = 1;
 
        my $x1 = $scale->index_to_center_x($idx1);
        my $y1 = $scale->value_to_y($seg->{start_price});
        my $x2 = $scale->index_to_center_x($idx2);
        my $y2 = $scale->value_to_y($seg->{end_price});
 
        $self->_draw_cached_line($tag, $x1, $y1, $x2, $y2, $color, $width, undef, $layer);
        $self->{canvas_cache}->{$tf}->{$tag} = 1;
    }
}
 
# ==========================================================
# 2. Renderizado de Pivotes (Estructurales y Menores)
# ==========================================================
sub _render_pivots {
    my ($self, $indicator, $start_index, $end_index, $scale, $tf, $seen) = @_;
    
    my @all_pivots;
    push @all_pivots, @{$indicator->get_structural_pivots() || []} if $self->{show_zz_ext};
    push @all_pivots, @{$indicator->get_minor_pivots() || []}      if $self->{show_zz_int};
 
    foreach my $pivot (@all_pivots) {
        my $idx  = $pivot->{index};
        next unless defined $idx;
        next if $idx > $end_index || $idx < $start_index;
 
        my $tier   = $pivot->{tier} || 'minor';
        my $is_ext = ($tier eq 'structural');
        
        my $radius = $is_ext ? 3 : 1.5;
        my $color  = $is_ext ? $self->{zz_ext_color} : $self->{zz_int_color};
        my $layer  = $is_ext ? 'lq_zz_ext' : 'lq_zz_int';
        my $tag    = "piv_${tier}_${idx}";
        $seen->{$tag} = 1;
 
        my $x = $scale->index_to_center_x($idx);
        my $y = $scale->value_to_y($pivot->{price});
 
        $self->_draw_cached_oval($tag, $x, $y, $radius, $color, $color, 1, $layer);
        $self->{canvas_cache}->{$tf}->{$tag} = 1;
    }
}
 
# ==========================================================
# 3. Renderizado de Candidatos (Repintado activo)
# ==========================================================
sub _render_candidates {
    my ($self, $indicator, $start_index, $end_index, $scale, $tf, $seen) = @_;
    return unless $self->{show_candidates};
 
    # IMPORTANTE: get_candidate_high()/get_candidate_low() requieren el
    # nombre del tier ('structural' o 'minor'). Llamarlos sin argumento
    # hace que $tier_name llegue undef al indicador, que autovivifica
    # $self->{tiers}->{undef} y siempre devuelve undef: la capa de
    # candidatos nunca dibujaba nada. Se piden ambos tiers explícitamente.
    my @candidates = (
        $indicator->get_candidate_high('structural'),
        $indicator->get_candidate_low('structural'),
        $indicator->get_candidate_high('minor'),
        $indicator->get_candidate_low('minor'),
    );
 
    foreach my $cand (@candidates) {
        next unless $cand && ref($cand) eq 'HASH' && defined $cand->{index};
        next if $cand->{index} > $end_index;
        next if $cand->{index} < $start_index;
 
        my $type = $cand->{type} || 'HIGH';
        my $tier = $cand->{tier} || 'structural';
        # El tag incluye el tier para no colisionar en caché cuando
        # structural y minor comparten mismo tipo/índice.
        my $tag  = "cand_${tier}_${type}_$cand->{index}";
        $seen->{$tag} = 1;
 
        my $x = $scale->index_to_center_x($cand->{index});
        my $y = $scale->value_to_y($cand->{price});
        
        # Color neutro semitransparente para indicar incerteza
        my $color = $self->_apply_opacity('#9e9e9e', 0.6);
 
        # Marcador circular en el extremo del candidato
        $self->_draw_cached_oval($tag."_m", $x, $y, 4, $color, $self->{label_bg_color}, 1, 'lq_cand');
        $seen->{$tag."_m"} = 1;
 
        # Si el candidato tiene origin_index, dibujamos la línea punteada de conexión
        if (defined $cand->{origin_index} && $cand->{origin_index} <= $end_index) {
            my $origin_x = $scale->index_to_center_x($cand->{origin_index});
            my $origin_y = $scale->value_to_y($cand->{origin_price} || $cand->{price});
            $self->_draw_cached_line($tag."_l", $origin_x, $origin_y, $x, $y, $color, 1, [3, 3], 'lq_cand');
            $seen->{$tag."_l"} = 1;
            $self->{canvas_cache}->{$tf}->{$tag."_l"} = 1;
        }
 
        $self->{canvas_cache}->{$tf}->{$tag} = 1;
        $self->{canvas_cache}->{$tf}->{$tag."_m"} = 1;
    }
}
 
# ==========================================================
# 4. Renderizado de Equal Levels (EQH / EQL)
# ==========================================================
sub _render_equal_levels {
    my ($self, $indicator, $start_index, $end_index, $scale, $tf, $seen) = @_;
    
    my $eq_levels = $indicator->get_equal_levels();
    return unless $eq_levels && ref($eq_levels) eq 'ARRAY';
 
    foreach my $eq (@$eq_levels) {
        my $type = $eq->{type};
        next if $type eq 'EQH' && !$self->{show_eqh};
        next if $type eq 'EQL' && !$self->{show_eql};
 
        my $idx = $eq->{index}; # Índice de inicio
        next unless defined $idx;
        next if $idx > $end_index;
 
        my $state = $eq->{state} || 'ACTIVE';
        my $resolved_idx = $eq->{resolved_index} // $end_index;
        my $draw_end_idx = min($resolved_idx, $end_index);
        
        next if $draw_end_idx < $start_index;
 
        my $base_color = $type eq 'EQH' ? $self->{eqh_color} : $self->{eql_color};
        my $opacity = $self->{opacities}->{$state} // 1.0;
        
        # En Swept cambia color temporalmente a color neutro resaltado
        $base_color = '#ff9800' if $state eq 'SWEPT';
        my $color = $self->_apply_opacity($base_color, $opacity);
 
        my $tag_band = "eq_band_${idx}_${type}";
        my $tag_lbl  = "eq_lbl_${idx}_${type}";
        $seen->{$tag_band} = $seen->{$tag_lbl} = 1;
 
        my $x1 = $scale->index_to_center_x($idx);
        my $x2 = $scale->index_to_center_x($draw_end_idx);
 
        # Dibujar como rectángulo si la API entrega bounds (upper/lower), sino como línea gruesa
        if (defined $eq->{upper_bound} && defined $eq->{lower_bound}) {
            my $y1 = $scale->value_to_y($eq->{upper_bound});
            my $y2 = $scale->value_to_y($eq->{lower_bound});
            $self->_draw_cached_rect($tag_band, $x1, $y1, $x2, $y2, $color, 'gray25', 'lq_eq_level');
        } else {
            my $y = $scale->value_to_y($eq->{price});
            $self->_draw_cached_line($tag_band, $x1, $y, $x2, $y, $color, 3, undef, 'lq_eq_level');
        }
 
        # Etiqueta
        my $lbl_y = $scale->value_to_y($eq->{price}) + ($type eq 'EQH' ? -10 : 10);
        $self->_draw_cached_text($tag_lbl, $x1 + 4, $lbl_y, $type, $color, 'w', ['Helvetica', 6, 'bold'], 'lq_label');
 
        $self->{canvas_cache}->{$tf}->{$tag_band} = 1;
        $self->{canvas_cache}->{$tf}->{$tag_lbl} = 1;
    }
}
 
# ==========================================================
# 5. Renderizado de Niveles BSL / SSL
# ==========================================================
sub _render_liquidity_levels {
    my ($self, $indicator, $start_index, $end_index, $scale, $tf, $seen) = @_;
    
    my $events = $indicator->get_liquidity_events();
    return unless $events && ref($events) eq 'ARRAY';
 
    foreach my $ev (@$events) {
        my $type = $ev->{type};
        next if $type eq 'BSL' && !$self->{show_bsl};
        next if $type eq 'SSL' && !$self->{show_ssl};
 
        my $idx = $ev->{index};
        next if $idx > $end_index;
 
        my $state = $ev->{state} || 'DETECTED';
        my $resolved_idx = $ev->{resolved_index} // $end_index;
        my $draw_end_idx = min($resolved_idx, $end_index);
 
        next if $draw_end_idx < $start_index && $idx < $start_index;
 
        my $base_color = $type eq 'BSL' ? $self->{bsl_color} : $self->{ssl_color};
        my $opacity = $self->{opacities}->{$state} // 1.0;
        my $color   = $self->_apply_opacity($base_color, $opacity);
 
        my $tag_line = "lq_lvl_${idx}_${type}";
        $seen->{$tag_line} = 1;
 
        my $x1 = $scale->index_to_center_x($idx);
        my $x2 = $scale->index_to_center_x($draw_end_idx);
        my $y  = $scale->value_to_y($ev->{price});
 
        # Estilo sólido para activos, punteado para resueltos
        my $dash = ($state eq 'RESOLVED' || $state eq 'ACCEPTANCE') ? [2, 2] : undef;
        
        $self->_draw_cached_line($tag_line, $x1, $y, $x2, $y, $color, 1, $dash, 'lq_bsl_ssl');
        $self->{canvas_cache}->{$tf}->{$tag_line} = 1;
 
        # Pequeño marcador visual sobre la vela exacta de sweep si está en estado SWEPT
        if ($state eq 'SWEPT' && defined $ev->{swept_index} && $ev->{swept_index} <= $end_index) {
            my $tag_sweep_dot = "lq_swp_dot_${idx}";
            $seen->{$tag_sweep_dot} = 1;
            my $x_swp = $scale->index_to_center_x($ev->{swept_index});
            $self->_draw_cached_oval($tag_sweep_dot, $x_swp, $y, 2, $color, $color, 1, 'lq_event');
            $self->{canvas_cache}->{$tf}->{$tag_sweep_dot} = 1;
        }
    }
}
 
# ==========================================================
# 6. Renderizado de Eventos Resueltos (Sweep / Grab / Run)
# ==========================================================
sub _render_resolved_events {
    my ($self, $indicator, $start_index, $end_index, $scale, $tf, $seen, $placed_labels) = @_;
    
    my $res_events = $indicator->get_resolved_events();
    return unless $res_events && ref($res_events) eq 'ARRAY';
 
    foreach my $ev (@$res_events) {
        my $class = $ev->{classification};
        next unless $class;
 
        next if $class eq 'Sweep' && !$self->{show_sweep};
        next if $class eq 'Grab'  && !$self->{show_grab};
        next if $class eq 'Run'   && !$self->{show_run};
 
        my $idx = $ev->{resolved_index} // $ev->{swept_index};
        next unless defined $idx && $idx <= $end_index && $idx >= $start_index;
 
        my $tag = "res_ev_${idx}_${class}";
        $seen->{$tag} = 1;
 
        my $color = $self->{grab_color};
        $color = $self->{run_color} if $class eq 'Run';
        $color = ($ev->{type} eq 'BSL') ? $self->{bsl_color} : $self->{ssl_color} if $class eq 'Sweep';
 
        my $x = $scale->index_to_center_x($idx);
        my $y = $scale->value_to_y($ev->{price});
        
        my $label_text = $class;
        my $font = ['Helvetica', $self->{font_size}, 'bold'];
        
        # Desplazamiento inicial según tipo
        my $direction = ($ev->{type} eq 'BSL') ? 'UP' : 'DOWN';
        my $y_target  = $y + ($direction eq 'UP' ? -14 : 14);
 
        # Prevención estricta de solapamientos
        $y_target = $self->_resolve_label_collision($x, $y_target, length($label_text)*5, 12, $placed_labels, $direction);
 
        $self->_draw_label_with_bg($tag, $x, $y_target, $label_text, $color, $font, 'center', 'lq_label');
        
        # Línea conectora tenue
        my $tag_line = "${tag}_conn";
        $seen->{$tag_line} = 1;
        $self->_draw_cached_line($tag_line, $x, $y, $x, $y_target + ($direction eq 'UP' ? 6 : -6), $self->_apply_opacity($color, 0.4), 1, [1, 2], 'lq_event');
 
        $self->{canvas_cache}->{$tf}->{$tag} = 1;
        $self->{canvas_cache}->{$tf}->{$tag_line} = 1;
    }
}
 
# ==========================================================
# Utilidades de Dibujo Incremental
# ==========================================================
 
sub _draw_cached_line {
    my ($self, $tag, $x1, $y1, $x2, $y2, $color, $width, $dash, $layer_tag) = @_;
    my $canvas = $self->{canvas};
 
    if ($canvas->find('withtag', $tag)) {
        $canvas->coords($tag, $x1, $y1, $x2, $y2);
        $canvas->itemconfigure($tag, -fill => $color, -width => $width);
        $canvas->itemconfigure($tag, -dash => $dash) if defined $dash;
    } else {
        my @opts = (-fill => $color, -width => $width, -tags => [$layer_tag, $tag]);
        push @opts, (-dash => $dash) if $dash;
        $canvas->createLine($x1, $y1, $x2, $y2, @opts);
    }
}
 
sub _draw_cached_rect {
    my ($self, $tag, $x1, $y1, $x2, $y2, $fill, $stipple, $layer_tag) = @_;
    my $canvas = $self->{canvas};
    if ($canvas->find('withtag', $tag)) {
        $canvas->coords($tag, $x1, $y1, $x2, $y2);
        $canvas->itemconfigure($tag, -fill => $fill, -outline => '');
    } else {
        $canvas->createRectangle($x1, $y1, $x2, $y2, -fill => $fill, -outline => '', -stipple => $stipple, -tags => [$layer_tag, $tag]);
    }
}
 
sub _draw_cached_oval {
    my ($self, $tag, $x, $y, $r, $outline, $fill, $width, $layer_tag) = @_;
    my $canvas = $self->{canvas};
    if ($canvas->find('withtag', $tag)) {
        $canvas->coords($tag, $x - $r, $y - $r, $x + $r, $y + $r);
        $canvas->itemconfigure($tag, -outline => $outline, -fill => $fill);
    } else {
        $canvas->createOval($x - $r, $y - $r, $x + $r, $y + $r, -outline => $outline, -fill => $fill, -width => $width, -tags => [$layer_tag, $tag]);
    }
}
 
sub _draw_cached_text {
    my ($self, $tag, $x, $y, $text, $color, $anchor, $font, $layer_tag) = @_;
    my $canvas = $self->{canvas};
    if ($canvas->find('withtag', $tag)) {
        $canvas->coords($tag, $x, $y);
        $canvas->itemconfigure($tag, -text => $text, -fill => $color);
    } else {
        $canvas->createText($x, $y, -text => $text, -fill => $color, -anchor => $anchor, -font => $font, -tags => [$layer_tag, $tag]);
    }
}
 
sub _draw_label_with_bg {
    my ($self, $tag, $x, $y, $text, $color, $font, $anchor, $layer_tag) = @_;
    
    my $tag_bg = $tag . "_bg";
    my $font_size = $font->[1];
    
    my $w = length($text) * ($font_size * 0.6) + 4;
    my $h = $font_size + 4;
    my $x1 = $x - ($w / 2);
    my $x2 = $x + ($w / 2);
    my $y1 = $y - ($h / 2);
    my $y2 = $y + ($h / 2);
 
    $self->_draw_cached_rect($tag_bg, $x1, $y1, $x2, $y2, $self->{label_bg_color}, undef, $layer_tag);
    $self->_draw_cached_text($tag, $x, $y, $text, $color, $anchor, $font, $layer_tag);
}
 
# ==========================================================
# Algoritmos de Utilidad (Prevención de Solapamiento y Color)
# ==========================================================
sub _resolve_label_collision {
    my ($self, $x, $y, $w, $h, $placed_boxes, $direction) = @_;
 
    my $adjusted_y = $y;
    my $collision  = 1;
    my $loops = 0;
 
    while ($collision && $loops < 10) {
        $collision = 0;
        my $my_x1 = $x - ($w / 2);
        my $my_x2 = $x + ($w / 2);
        my $my_y1 = $adjusted_y - ($h / 2);
        my $my_y2 = $adjusted_y + ($h / 2);
 
        foreach my $box (@$placed_boxes) {
            if (!($my_x2 < $box->{x1} || $my_x1 > $box->{x2} || $my_y2 < $box->{y1} || $my_y1 > $box->{y2})) {
                $collision = 1;
                $adjusted_y += ($direction eq 'UP' ? -($h + 2) : ($h + 2));
                last;
            }
        }
        $loops++;
    }
 
    push @$placed_boxes, { x1 => $x - ($w / 2), x2 => $x + ($w / 2), y1 => $adjusted_y - ($h / 2), y2 => $adjusted_y + ($h / 2) };
    return $adjusted_y;
}
 
sub _apply_opacity {
    my ($self, $hex, $alpha) = @_;
    return $hex if $alpha >= 1.0;
    return $hex unless $hex =~ /^#?([a-fA-F0-9]{2})([a-fA-F0-9]{2})([a-fA-F0-9]{2})$/;
    
    my $r_fg = hex($1); my $g_fg = hex($2); my $b_fg = hex($3);
    my $r_bg = $self->{bg_color}->[0];
    my $g_bg = $self->{bg_color}->[1];
    my $b_bg = $self->{bg_color}->[2];
 
    my $r = int($r_fg * $alpha + $r_bg * (1 - $alpha));
    my $g = int($g_fg * $alpha + $g_bg * (1 - $alpha));
    my $b = int($b_fg * $alpha + $b_bg * (1 - $alpha));
 
    return sprintf("#%02x%02x%02x", $r, $g, $b);
}
 
sub _get_liquidity_indicator {
    my ($self) = @_;
    return $self->{liquidity_indicator} if $self->{liquidity_indicator};
 
    if ($self->{engine} && $self->{engine}->{indicator_manager}) {
        my $manager = $self->{engine}->{indicator_manager};
        return $manager->get_liquidity() if $manager->can('get_liquidity');
    }
    return undef;
}
 
1;


