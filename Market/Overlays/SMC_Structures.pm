# package Market::Overlays::SMC_Structures;
# use strict;
# use warnings;
# use parent 'Market::Overlays::Base';

# sub new {
#     my ($class, %args) = @_;

#     my $self = $class->SUPER::new(%args);

#     # Referencia al indicador (opcional si se inyecta directamente)
#     $self->{smc_indicator} = $args{smc_indicator};

#     # Propiedades visuales específicas
#     $self->{fvg_max_lifetime} = $args{fvg_max_lifetime} || 50;

#     $self->{bg_color}   = [251, 252, 248]; # Fondo del Canvas: #fbfcf8
#     $self->{bull_color} = [38, 166, 154];  # Verde institucional
#     $self->{bear_color} = [239, 83, 80];   # Rojo institucional

#     $self->{bull_text_color} = '#00897b';
#     $self->{bear_text_color} = '#d32f2f';
#     $self->{label_bg_color}  = '#fbfcf8';

#     # Toggles de visibilidad
#     $self->{show_fvg}          = exists $args{show_fvg}          ? $args{show_fvg}          : 1;
#     $self->{show_ext_structure}= exists $args{show_ext_structure}? $args{show_ext_structure}: 1;
#     $self->{show_int_structure}= exists $args{show_int_structure}? $args{show_int_structure}: 1;
#     $self->{show_swings}       = exists $args{show_swings}       ? $args{show_swings}       : 1;

#     # Límite para no saturar el gráfico
#     $self->{max_swing_labels} = $args{max_swing_labels} || 50;

#     return $self;
# }

# sub render {
#     my ($self, $start_index, $end_index, $scale) = @_;

#     my $canvas = $self->{canvas};
#     return unless $canvas && $scale;

#     $canvas->delete('smc_layer');
#     return unless $self->{active} // 1;

#     my $indicator = $self->_get_smc_indicator();
#     return unless $indicator;

#     # 1. Dibujar Zonas FVG (Fondo)
#     $self->_render_fvg($indicator, $start_index, $end_index, $scale)
#         if $self->{show_fvg};

#     # 2. Dibujar Eventos de Ruptura (BOS, CHOCH, MSS)
#     $self->_render_structure_events($indicator, $start_index, $end_index, $scale)
#         if $self->{show_ext_structure} || $self->{show_int_structure};

#     # 3. Dibujar Etiquetas de Swings (HH, HL, LH, LL)
#     $self->_render_swing_labels($indicator, $start_index, $end_index, $scale)
#         if $self->{show_swings};
# }

# # ==========================================================
# # Integración con el IndicatorManager unificado
# # ==========================================================
# sub _get_smc_indicator {
#     my ($self) = @_;

#     return $self->{smc_indicator} if $self->{smc_indicator};

#     if ($self->{engine} && $self->{engine}->{indicator_manager}) {
#         my $manager = $self->{engine}->{indicator_manager};
#         return $manager->get_smc_structures() if $manager->can('get_smc_structures');
#     }

#     return undef;
# }

# # ==========================================================
# # 1. Fair Value Gaps (Con desvanecimiento en el tiempo y mitigación)
# # ==========================================================
# sub _render_fvg {
#     my ($self, $indicator, $start_index, $end_index, $scale) = @_;

#     my $fvgs = $indicator->get_fvg();
#     return unless $fvgs && ref($fvgs) eq 'ARRAY';

#     my $canvas = $self->{canvas};

#     foreach my $fvg (@$fvgs) {
#         my $created_index = $fvg->{index};
#         my $top           = $fvg->{top};
#         my $bottom        = $fvg->{bottom};
#         my $type          = $fvg->{type} || '';
#         my $state         = $fvg->{state} || 'ACTIVE';

#         # Replay: Omitir FVGs futuros
#         next if $created_index > $end_index;

#         # Edad del FVG para el "desvanecimiento progresivo en el tiempo" (Spec)
#         my $age = $end_index - $created_index;
#         next if $age >= $self->{fvg_max_lifetime} && $state ne 'FULLY_MITIGATED';

#         # Límite de dibujado a la derecha
#         my $end_fvg_index = $end_index;
#         if ($state eq 'FULLY_MITIGATED' || $state eq 'INVALIDATED') {
#             $end_fvg_index = $fvg->{last_touch_index} // $created_index;
#         }

#         # No dibujar si ya quedó atrás de la ventana visible
#         next if $end_fvg_index < $start_index;

#         my $x1 = $scale->index_to_center_x($created_index);
#         my $x2 = $scale->index_to_center_x($end_fvg_index);
#         my $y1 = $scale->value_to_y($top);
#         my $y2 = $scale->value_to_y($bottom);

#         # Seleccionar color base
#         my $base_rgb = $type eq 'FVG_UP' ? $self->{bull_color} : $self->{bear_color};

#         # Factor de desvanecimiento basado en el tiempo y en la mitigación SMC
#         my $ratio = $age / $self->{fvg_max_lifetime};
#         $ratio += ($fvg->{mitigation_percentage} // 0) / 100;
#         $ratio = 1 if $ratio > 1;

#         # Interpolación hacia el color de fondo para crear el efecto fade
#         my $r = int($base_rgb->[0] + ($self->{bg_color}->[0] - $base_rgb->[0]) * $ratio);
#         my $g = int($base_rgb->[1] + ($self->{bg_color}->[1] - $base_rgb->[1]) * $ratio);
#         my $b = int($base_rgb->[2] + ($self->{bg_color}->[2] - $base_rgb->[2]) * $ratio);
#         my $fade_color = sprintf("#%02x%02x%02x", $r, $g, $b);

#         $canvas->createRectangle(
#             $x1, $y1, $x2, $y2,
#             -fill    => $fade_color,
#             -outline => $fade_color,
#             -stipple => 'gray25',
#             -tags    => ['smc_layer', 'smc_fvg']
#         );

#         # Etiqueta
#         my $label = $type eq 'FVG_UP' ? 'FVG+' : 'FVG-';
#         $canvas->createText(
#             $x1 + 4, $y1 + (($y2 - $y1) / 2),
#             -text   => $label,
#             -fill   => $type eq 'FVG_UP' ? $self->{bull_text_color} : $self->{bear_text_color},
#             -font   => ['Helvetica', 6, 'bold'],
#             -anchor => 'w',
#             -tags   => ['smc_layer', 'smc_fvg_label']
#         );
#     }
# }

# # ==========================================================
# # 2. Rupturas Estructurales (BOS, CHOCH, MSS)
# # ==========================================================
# sub _render_structure_events {
#     my ($self, $indicator, $start_index, $end_index, $scale) = @_;

#     my $events = $indicator->get_events();
#     return unless $events && ref($events) eq 'ARRAY';

#     my $canvas = $self->{canvas};

#     foreach my $ev (@$events) {
#         my $idx        = $ev->{index};
#         my $origin_idx = $ev->{broken_pivot_index};
#         my $price      = $ev->{price};
#         my $dir        = $ev->{direction};
#         my $type       = $ev->{type};
#         my $tier       = $ev->{tier} || 'external';

#         # Filtro de visibilidad por tier
#         next if $tier eq 'external' && !$self->{show_ext_structure};
#         next if $tier eq 'internal' && !$self->{show_int_structure};

#         # Replay y visibilidad
#         next if $idx > $end_index;
#         next if $idx < $start_index && $origin_idx < $start_index;

#         my $x_start = $scale->index_to_center_x($origin_idx);
#         my $x_end   = $scale->index_to_center_x($idx);
#         my $y       = $scale->value_to_y($price);

#         # Determinar color basado en la dirección del rompimiento
#         my $color = $dir eq 'UP' ? '#26a69a' : '#ef5350';

#         # Diferenciar visualmente la estructura interna de la externa
#         my $is_internal = ($type =~ /^INTERNAL_/ || $type eq 'MSS');
#         my $dash_style  = $is_internal ? [2, 2] : [5, 5];
#         my $line_width  = $is_internal ? 1 : 2;

#         $canvas->createLine(
#             $x_start, $y, $x_end, $y,
#             -fill  => $color,
#             -width => $line_width,
#             -dash  => $dash_style,
#             -tags  => ['smc_layer', 'smc_structure']
#         );

#         # Limpiar prefijo para la etiqueta visual
#         my $label = $type;
#         $label =~ s/^INTERNAL_//;
        
#         # Etiqueta de minúscula para distinguir eventos internos visualmente (ej. iBOS, iCHoCH)
#         $label = "i" . $label if $is_internal && $label ne 'MSS';

#         my $x_center = $x_start + (($x_end - $x_start) / 2);
#         my $label_y  = $dir eq 'DOWN' ? $y + 9 : $y - 9;

#         $canvas->createText(
#             $x_center, $label_y,
#             -text   => $label,
#             -fill   => $color,
#             -font   => ['Helvetica', 7, 'bold'],
#             -anchor => 'center',
#             -tags   => ['smc_layer', 'smc_structure_label']
#         );
#     }
# }

# # ==========================================================
# # 3. Etiquetas de Swings Estructurales (HH, HL, LH, LL)
# # ==========================================================
# sub _render_swing_labels {
#     my ($self, $indicator, $start_index, $end_index, $scale) = @_;

#     # Combinamos pivotes externos e internos
#     my @all_pivots;
#     my $ext = $indicator->get_external_structure();
#     push @all_pivots, @$ext if $ext && ref($ext) eq 'ARRAY';
    
#     my $int = $indicator->get_internal_structure();
#     push @all_pivots, @$int if $int && ref($int) eq 'ARRAY';

#     my $drawn = 0;

#     foreach my $pivot (@all_pivots) {
#         my $idx   = $pivot->{index};
#         my $price = $pivot->{price};
#         my $label = $pivot->{label};
#         my $type  = $pivot->{type};
#         my $tier  = $pivot->{tier} || 'external';

#         next unless $label;
#         next if $idx < $start_index || $idx > $end_index;

#         # Omitimos etiquetas internas si el usuario las apagó
#         next if $tier eq 'internal' && !$self->{show_int_structure};

#         # Minúscula para etiquetas de estructura interna
#         $label = lc($label) if $tier eq 'internal';

#         my $x = $scale->index_to_center_x($idx);
#         my $y = $scale->value_to_y($price);

#         my $color;
#         if ($type eq 'HIGH') {
#             $y -= 12;
#             $color = $self->{bear_text_color};
#         } else {
#             $y += 12;
#             $color = $self->{bull_text_color};
#         }

#         $self->_draw_label(
#             x         => $x,
#             y         => $y,
#             text      => $label,
#             color     => $color,
#             anchor    => 'center',
#             font_size => $tier eq 'external' ? 8 : 6
#         );

#         $drawn++;
#         last if $drawn >= $self->{max_swing_labels};
#     }
# }

# # ==========================================================
# # Utilidad para etiquetas con fondo (Evita cruces con el precio)
# # ==========================================================
# sub _draw_label {
#     my ($self, %args) = @_;

#     my $canvas = $self->{canvas};

#     my $x         = $args{x};
#     my $y         = $args{y};
#     my $text      = $args{text} || '';
#     my $color     = $args{color} || '#131722';
#     my $anchor    = $args{anchor} || 'center';
#     my $font_size = $args{font_size} || 8;

#     my $text_width  = length($text) * ($font_size * 0.65);
#     my $text_height = $font_size + 6;

#     my ($x1, $x2);
#     if ($anchor eq 'center') {
#         $x1 = $x - ($text_width / 2) - 4;
#         $x2 = $x + ($text_width / 2) + 4;
#     } elsif ($anchor eq 'w') {
#         $x1 = $x - 4;
#         $x2 = $x + $text_width + 4;
#     } else {
#         $x1 = $x - $text_width - 4;
#         $x2 = $x + 4;
#     }

#     my $y1 = $y - ($text_height / 2);
#     my $y2 = $y + ($text_height / 2);

#     $canvas->createRectangle(
#         $x1, $y1,
#         $x2, $y2,
#         -fill    => $self->{label_bg_color},
#         -outline => '',
#         -stipple => 'gray50',
#         -tags    => ['smc_layer', 'smc_fvg']
#     );

#     $canvas->createText(
#         $x, $y,
#         -text   => $text,
#         -fill   => $color,
#         -font   => ['Helvetica', $font_size, 'bold'],
#         -anchor => $anchor,
#         -tags   => ['smc_layer', 'smc_label']
#     );
# }

# 1;

package Market::Overlays::SMC_Structures;

use strict;
use warnings;
use parent 'Market::Overlays::Base';
use List::Util qw(max min);

sub new {
    my ($class, %args) = @_;
    my $self = $class->SUPER::new(%args);

    # Referencia e inyección del indicador
    $self->{smc_indicator} = $args{smc_indicator};

    # ---- Configuración de Estilos Visuales (LuxAlgo Style) ----
    $self->{bg_color}       = $args{bg_color}       || [251, 252, 248]; # Fondo base (#fbfcf8)
    
    # Estructura Externa (Premium Colors)
    $self->{color_ext_bull} = $args{color_ext_bull} || '#00b0ff';       # Cyan brillante
    $self->{color_ext_bear} = $args{color_ext_bear} || '#ff3d00';       # Deep Orange
    $self->{line_width_ext} = $args{line_width_ext} || 2;
    $self->{font_size_ext}  = $args{font_size_ext}  || 9;

    # Estructura Interna (Menor intensidad)
    $self->{color_int_bull} = $args{color_int_bull} || '#26a69a';       # Verde institucional
    $self->{color_int_bear} = $args{color_int_bear} || '#ef5350';       # Rojo atenuado
    $self->{line_width_int} = $args{line_width_int} || 1;
    $self->{font_size_int}  = $args{font_size_int}  || 7;

    # Swings (HH, HL, LH, LL)
    $self->{text_color_high}= $args{text_color_high}|| '#e53935';
    $self->{text_color_low} = $args{text_color_low} || '#00897b';
    $self->{font_size_swing}= $args{font_size_swing}|| 8;
    $self->{label_bg_color} = $args{label_bg_color} || '#fbfcf8';

    # ---- Parámetros de Control y Filtros de Memoria ----
    $self->{max_fvg_extend}       = $args{max_fvg_extend}       || 150; # Máxima extensión hacia la derecha
    $self->{fvg_initial_opacity}  = $args{fvg_initial_opacity}  // 0.25;
    $self->{show_mitigated_fvg}   = exists $args{show_mitigated_fvg}   ? $args{show_mitigated_fvg}   : 1;
    $self->{show_invalidated_fvg} = exists $args{show_invalidated_fvg} ? $args{show_invalidated_fvg} : 0;
    
    # Toggles de visibilidad generales
    $self->{show_fvg}           = exists $args{show_fvg}           ? $args{show_fvg}           : 1;
    $self->{show_ext_structure} = exists $args{show_ext_structure} ? $args{show_ext_structure} : 1;
    $self->{show_int_structure} = exists $args{show_int_structure} ? $args{show_int_structure} : 1;
    $self->{show_swings}        = exists $args{show_swings}        ? $args{show_swings}        : 1;
    $self->{max_swing_labels}   = $args{max_swing_labels}   || 100;

    # ---- Sistema de Caché Incremental ----
    # Estructura: $self->{canvas_cache}->{$timeframe}->{$unique_tag} = 1
    $self->{canvas_cache} = {};

    return $self;
}

# ==========================================================
# Controlador de Renderizado Principal
# ==========================================================
sub render {
    my ($self, $start_index, $end_index, $scale) = @_;

    my $canvas = $self->{canvas};
    return undef unless $canvas && $scale && ($self->{active} // 1);

    my $indicator = $self->_get_smc_indicator();
    return undef unless $indicator;

    # Obtener el timeframe activo para segmentar la caché incremental de objetos
    my $tf = $indicator->{active_timeframe} || '1m';
    $self->{canvas_cache}->{$tf} ||= {};
    
    # Estructura de rastreo para la purga selectiva del Render Incremental
    my %elements_seen_this_pass;

    # Contenedores para evitar colisiones/solapamientos de texto en esta ventana visible
    my @placed_event_labels;
    my @placed_swing_labels;

    # ---- PASO 1: Renderizado Geométrico por Capas (Z-Order Natural) ----
    
    if ($self->{show_fvg}) {
        $self->_render_fvgs($indicator, $start_index, $end_index, $scale, $tf, \%elements_seen_this_pass);
    }

    if ($self->{show_ext_structure} || $self->{show_int_structure}) {
        $self->_render_structure_events($indicator, $start_index, $end_index, $scale, $tf, \%elements_seen_this_pass, \@placed_event_labels);
    }

    if ($self->{show_swings}) {
        $self->_render_swing_labels($indicator, $start_index, $end_index, $scale, $tf, \%elements_seen_this_pass, \@placed_swing_labels);
    }

    # ---- PASO 2: Purga Incremental de Memoria del Canvas ----
    # Elimina únicamente los objetos que salieron del rango visible o fueron descartados por el indicador
    foreach my $cached_tag (keys %{$self->{canvas_cache}->{$tf}}) {
        if (!$elements_seen_this_pass{$cached_tag}) {
            $canvas->delete($cached_tag);
            delete $self->{canvas_cache}->{$tf}->{$cached_tag};
        }
    }

    # ---- PASO 3: Consistencia Estricta de Capas (Z-Order Enforcement) ----
    $canvas->raise('smc_line');
    $canvas->raise('smc_swing_lbl');
    $canvas->raise('smc_event_lbl');
}

# ==========================================================
# 1. Renderizado de Fair Value Gaps (FVG)
# ==========================================================
sub _render_fvgs {
    my ($self, $indicator, $start_index, $end_index, $scale, $tf, $seen) = @_;
    
    my $fvgs = $indicator->get_fvg();
    return undef unless $fvgs && ref($fvgs) eq 'ARRAY';

    foreach my $fvg (@$fvgs) {
        my $created_idx = $fvg->{index};
        my $state       = $fvg->{state} || 'ACTIVE';
        
        # Filtrado rápido por horizonte temporal (Safe Replay)
        next if $created_idx > $end_index;

        # Determinar punto de corte/extensión dinámica hacia la derecha
        my $end_fvg_idx = $end_index;
        if ($state eq 'FULLY_MITIGATED' || $state eq 'INVALIDATED') {
            $end_fvg_idx = $fvg->{last_touch_index} // $fvg->{first_touch_index} // $created_idx;
        } else {
            # Limitar extensión máxima por configuración para preservar rendimiento
            if (($end_fvg_idx - $created_idx) > $self->{max_fvg_extend}) {
                $end_fvg_idx = $created_idx + $self->{max_fvg_extend};
            }
        }

        # Saltar si el bloque FVG completo está fuera de la ventana visual izquierda
        next if $end_fvg_idx < $start_index;

        # Toggles de configuración visual para estados cerrados
        next if $state eq 'FULLY_MITIGATED' && !$self->{show_mitigated_fvg};
        next if $state eq 'INVALIDATED'     && !$self->{show_invalidated_fvg};

        # Identificadores únicos para el motor incremental
        my $tag_box  = "smc_fvg_box_$created_idx\_$fvg->{type}";
        my $tag_mit  = "smc_fvg_mit_$created_idx\_$fvg->{type}";
        my $tag_text = "smc_fvg_txt_$created_idx\_$fvg->{type}";
        
        $seen->{$tag_box} = $seen->{$tag_mit} = $seen->{$tag_text} = 1;

        # Cálculo de proyecciones en pantalla
        my $x1 = $scale->index_to_center_x($created_idx);
        my $x2 = $scale->index_to_center_x($end_fvg_idx);
        my $y_top = $scale->value_to_y($fvg->{top});
        my $y_bot = $scale->value_to_y($fvg->{bottom});

        # Mezclar color base y simular opacidad de acuerdo al estado exacto de mitigación
        my $color_hex = $self->_calculate_fvg_appearance($fvg->{type}, $state);
        
        # Representación de mitigación visual (LuxAlgo Style): Reducción del área activa
        my $pct = $fvg->{mitigation_percentage} // 0;
        my $y_mit_split = $y_top;
        if ($pct > 0 && $pct < 100 && $state ne 'INVALIDATED') {
            # En FVG_UP la mitigación entra desde arriba (velas bajando), en FVG_DOWN desde abajo
            my $height = abs($y_bot - $y_top);
            if ($fvg->{type} eq 'FVG_UP') {
                $y_mit_split = $y_top + ($height * ($pct / 100));
            } else {
                $y_mit_split = $y_bot - ($height * ($pct / 100));
            }
        }

        # Dibujar o actualizar zona activa restante
        if ($fvg->{type} eq 'FVG_UP') {
            $self->_draw_cached_rect($tag_box, $x1, $y_mit_split, $x2, $y_bot, $color_hex, 'gray25', 'smc_fvg');
            if ($pct > 0 && $state ne 'INVALIDATED') {
                my $mit_color = $self->_blend_with_bg($color_hex, 0.15);
                $self->_draw_cached_rect($tag_mit, $x1, $y_top, $x2, $y_mit_split, $mit_color, 'gray12', 'smc_fvg');
            }
        } else {
            $self->_draw_cached_rect($tag_box, $x1, $y_top, $x2, $y_mit_split, $color_hex, 'gray25', 'smc_fvg');
            if ($pct > 0 && $state ne 'INVALIDATED') {
                my $mit_color = $self->_blend_with_bg($color_hex, 0.15);
                $self->_draw_cached_rect($tag_mit, $x1, $y_mit_split, $x2, $y_bot, $mit_color, 'gray12', 'smc_fvg');
            }
        }

        # Inyección de texto informativo discreto
        my $label_text = ($fvg->{type} eq 'FVG_UP' ? 'FVG+' : 'FVG-') . ($pct > 0 ? " (".int($pct)."%)" : "");
        $self->_draw_cached_text($tag_text, $x1 + 6, $y_top + (($y_bot - $y_top) / 2), $label_text, 
                                 ($fvg->{type} eq 'FVG_UP' ? $self->{color_int_bull} : $self->{color_int_bear}), 
                                 'w', ['Helvetica', 6, 'bold'], 'smc_fvg_lbl');
        
        # Registrar en la caché global del objeto
        $self->{canvas_cache}->{$tf}->{$tag_box} = 1;
        $self->{canvas_cache}->{$tf}->{$tag_mit} = 1 if $pct > 0;
        $self->{canvas_cache}->{$tf}->{$tag_text} = 1;
    }
}

# ==========================================================
# 2. Renderizado de Rupturas Estructurales (BOS, CHOCH, MSS)
# ==========================================================
sub _render_structure_events {
    my ($self, $indicator, $start_index, $end_index, $scale, $tf, $seen, $placed_labels) = @_;

    my $events = $indicator->get_events();
    return undef unless $events && ref($events) eq 'ARRAY';

    foreach my $ev (@$events) {
        my $idx        = $ev->{index};
        my $origin_idx = $ev->{broken_pivot_index};
        my $tier       = $ev->{tier} || 'external';

        # Filtros de configuración por jerarquía estructural
        next if $tier eq 'external' && !$self->{show_ext_structure};
        next if $tier eq 'internal' && !$self->{show_int_structure};

        # Protección Replay e indexación
        next if $idx > $end_index;
        next if $idx < $start_index && $origin_idx < $start_index;

        my $type = $ev->{type};
        my $dir  = $ev->{direction};

        # Configuración jerárquica de la línea (Grosor, Color y Fuentes Independientes)
        my ($color, $width, $font_size, $is_internal);
        if ($tier eq 'external') {
            $color     = $dir eq 'UP' ? $self->{color_ext_bull} : $self->{color_ext_bear};
            $width     = $self->{line_width_ext};
            $font_size = $self->{font_size_ext};
            $is_internal = 0;
        } else {
            $color     = $dir eq 'UP' ? $self->{color_int_bull} : $self->{color_int_bear};
            $width     = $self->{line_width_int};
            $font_size = $self->{font_size_int};
            $is_internal = 1;
        }

        my $tag_line = "smc_line_$idx\_$type\_$origin_idx";
        my $tag_lbl  = "smc_lbl_$idx\_$type\_$origin_idx";
        $seen->{$tag_line} = $seen->{$tag_lbl} = 1;

        # Coordenadas exactas sobre el nivel de precio roto
        my $x_start = $scale->index_to_center_x($origin_idx);
        my $x_end   = $scale->index_to_center_x($idx);
        my $y       = $scale->value_to_y($ev->{price});

        # Dibujar o desplazar línea de quiebre estructural horizontal
        my $dash_style = $is_internal ? [2, 3] : undef;
        $self->_draw_cached_line($tag_line, $x_start, $y, $x_end, $y, $color, $width, $dash_style, 'smc_line');

        # Formatear el texto de la etiqueta según nomenclatura oficial requerida
        my $label_text = $type;
        $label_text =~ s/^INTERNAL_//;
        $label_text = "i" . $label_text if $is_internal && $label_text ne 'MSS';

        # Cálculo de colisiones y prevención de solapamiento para etiquetas de eventos
        my $x_center = $x_start + (($x_end - $x_start) / 2);
        my $label_y  = $dir eq 'DOWN' ? $y + 8 : $y - 8;
        
        $label_y = $self->_resolve_label_collision($x_center, $label_y, length($label_text)*6, 12, $placed_labels, $dir);

        # Dibujar etiqueta con fondo opaco
        $self->_draw_label_with_buffer($tag_lbl, $x_center, $label_y, $label_text, $color, $font_size, 'center', 'smc_event_lbl');

        $self->{canvas_cache}->{$tf}->{$tag_line} = 1;
        $self->{canvas_cache}->{$tf}->{$tag_lbl}  = 1;
    }
}

# ==========================================================
# 3. Renderizado de Etiquetas Swing (HH, HL, LH, LL)
# ==========================================================
sub _render_swing_labels {
    my ($self, $indicator, $start_index, $end_index, $scale, $tf, $seen, $placed_swings) = @_;

    # Consolidación ordenada de pivots confirmados por la API
    my @all_pivots;
    my $ext = $indicator->get_external_structure();
    push @all_pivots, @$ext if $ext && ref($ext) eq 'ARRAY';
    my $int = $indicator->get_internal_structure();
    push @all_pivots, @$int if $int && ref($int) eq 'ARRAY';

    my $drawn = 0;
    foreach my $pivot (@all_pivots) {
        my $idx  = $pivot->{index};
        next if $idx < $start_index || $idx > $end_index;

        my $tier = $pivot->{tier} || 'external';
        next if $tier eq 'internal' && !$self->{show_int_structure};

        my $label = $pivot->{label};
        next unless $label;

        # Transformar a minúsculas para distinguir visualmente la estructura menor
        $label = lc($label) if $tier eq 'internal';

        my $tag_swing = "smc_swg_$idx\_$pivot->{type}\_$tier\_$label";
        $seen->{$tag_swing} = 1;

        my $x = $scale->index_to_center_x($idx);
        my $y = $scale->value_to_y($pivot->{price});

        # Desplazamiento inicial por diseño: HIGH arriba, LOW abajo
        my $direction_bias = $pivot->{type} eq 'HIGH' ? 'UP' : 'DOWN';
        my $font_size      = $tier eq 'external' ? $self->{font_size_swing} : $self->{font_size_swing} - 1;
        my $color          = $pivot->{type} eq 'HIGH' ? $self->{text_color_high} : $self->{text_color_low};

        my $offset_y = $direction_bias eq 'UP' ? -12 : 12;
        my $target_y = $y + $offset_y;

        # Algoritmo de prevención de solapamientos entre Swings cercanos
        $target_y = $self->_resolve_label_collision($x, $target_y, length($label)*7, 14, $placed_swings, $direction_bias);

        $self->_draw_label_with_buffer($tag_swing, $x, $target_y, $label, $color, $font_size, 'center', 'smc_swing_lbl');

        $self->{canvas_cache}->{$tf}->{$tag_swing} = 1;
        
        $drawn++;
        last if $drawn >= $self->{max_swing_labels};
    }
}

# ==========================================================
# Utilidades Gráficas Nativas y Control de Estado de Canvas
# ==========================================================

sub _draw_cached_rect {
    my ($self, $tag, $x1, $y1, $x2, $y2, $fill, $stipple, $layer_tag) = @_;
    my $canvas = $self->{canvas};
    
    if ($canvas->find('withtag', $tag)) {
        $canvas->coords($tag, $x1, $y1, $x2, $y2);
        $canvas->itemconfigure($tag, -fill => $fill, -outline => $fill);
    } else {
        $canvas->createRectangle($x1, $y1, $x2, $y2,
            -fill    => $fill,
            -outline => $fill,
            -stipple => $stipple,
            -tags    => ['smc_layer', $layer_tag, $tag]
        );
    }
}

sub _draw_cached_line {
    my ($self, $tag, $x1, $y1, $x2, $y2, $color, $width, $dash, $layer_tag) = @_;
    my $canvas = $self->{canvas};

    if ($canvas->find('withtag', $tag)) {
        $canvas->coords($tag, $x1, $y1, $x2, $y2);
        $canvas->itemconfigure($tag, -fill => $color, -width => $width);
    } else {
        my @opts = (-fill => $color, -width => $width, -tags => ['smc_layer', $layer_tag, $tag]);
        push @opts, (-dash => $dash) if $dash;
        $canvas->createLine($x1, $y1, $x2, $y2, @opts);
    }
}

sub _draw_cached_text {
    my ($self, $tag, $x, $y, $text, $color, $anchor, $font, $layer_tag) = @_;
    my $canvas = $self->{canvas};

    if ($canvas->find('withtag', $tag)) {
        $canvas->coords($tag, $x, $y);
        $canvas->itemconfigure($tag, -text => $text, -fill => $color);
    } else {
        $canvas->createText($x, $y,
            -text   => $text,
            -fill   => $color,
            -font   => $font,
            -anchor => $anchor,
            -tags   => ['smc_layer', $layer_tag, $tag]
        );
    }
}

sub _draw_label_with_buffer {
    my ($self, $tag, $x, $y, $text, $color, $font_size, $anchor, $layer_tag) = @_;
    my $canvas = $self->{canvas};
    
    my $tag_bg = $tag . "_bg";
    
    my $w = length($text) * ($font_size * 0.65) + 6;
    my $h = $font_size + 5;
    
    my $x1 = $x - ($w / 2);
    my $x2 = $x + ($w / 2);
    my $y1 = $y - ($h / 2);
    my $y2 = $y + ($h / 2);

    # Rectángulo de fondo opaco (Evita cruces ruidosos con las velas)
    if ($canvas->find('withtag', $tag_bg)) {
        $canvas->coords($tag_bg, $x1, $y1, $x2, $y2);
    } else {
        $canvas->createRectangle($x1, $y1, $x2, $y2,
            -fill    => $self->{label_bg_color},
            -outline => '',
            -tags    => ['smc_layer', $layer_tag, $tag_bg]
        );
    }

    # Texto
    $self->_draw_cached_text($tag, $x, $y, $text, $color, $anchor, ['Helvetica', $font_size, 'bold'], $layer_tag);
}

# ==========================================================
# Algoritmia de Posicionamiento y Prevención de Solapamientos
# ==========================================================
sub _resolve_label_collision {
    my ($self, $x, $y, $w, $h, $placed_boxes, $direction) = @_;

    my $padding_x = 12; 
    my $padding_y = 4;

    my $inflated_w = $w + $padding_x;
    my $inflated_h = $h + $padding_y;

    my $adjusted_y = $y;
    my $collision  = 1;
    my $safety_loop = 0;

    while ($collision && $safety_loop < 10) {
        $collision = 0;
        my $my_x1 = $x - ($inflated_w / 2);
        my $my_x2 = $x + ($inflated_w / 2);
        my $my_y1 = $adjusted_y - ($inflated_h / 2);
        my $my_y2 = $adjusted_y + ($inflated_h / 2);

        foreach my $box (@$placed_boxes) {
            # Verificar intersección AABB estándar
            if (!($my_x2 < $box->{x1} || $my_x1 > $box->{x2} || $my_y2 < $box->{y1} || $my_y1 > $box->{y2})) {
                $collision = 1;
                # Desplazar verticalmente en la dirección del sesgo para no romper el nivel
                if ($direction eq 'UP') {
                    $adjusted_y -= ($h + 2);
                } else {
                    $adjusted_y += ($h + 2);
                }
                last;
            }
        }
        $safety_loop++;
    }

    # Registrar caja ocupada
    push @$placed_boxes, {
        x1 => $x - ($inflated_w / 2),
        x2 => $x + ($inflated_w / 2),
        y1 => $adjusted_y - ($inflated_h / 2),
        y2 => $adjusted_y + ($inflated_h / 2)
    };

    return $adjusted_y;
}

sub _calculate_fvg_appearance {
    my ($self, $type, $state) = @_;
    
    my $base_hex = $type eq 'FVG_UP' ? $self->{color_int_bull} : $self->{color_int_bear};
    
    if ($state eq 'ACTIVE') {
        return $self->_blend_with_bg($base_hex, $self->{fvg_initial_opacity});
    } elsif ($state eq 'TOUCHED') {
        return $self->_blend_with_bg($base_hex, $self->{fvg_initial_opacity} * 0.7);
    } elsif ($state eq 'PARTIALLY_MITIGATED') {
        return $self->_blend_with_bg($base_hex, $self->{fvg_initial_opacity} * 0.4);
    } elsif ($state eq 'FULLY_MITIGATED') {
        return $self->_blend_with_bg($base_hex, 0.06);
    } elsif ($state eq 'INVALIDATED') {
        return '#d1d4dc'; # Gris claro institucional de desactivación
    }
    return $base_hex;
}

sub _blend_with_bg {
    my ($self, $hex, $alpha) = @_;
    return $hex unless $hex =~ /^#?([a-fA-F0-9]{2})([a-fA-F0-9]{2})([a-fA-F0-9]{2})$/;
    
    my $r_b = hex($1); my $g_b = hex($2); my $b_b = hex($3);
    my $r_bg = $self->{bg_color}->[0];
    my $g_bg = $self->{bg_color}->[1];
    my $b_bg = $self->{bg_color}->[2];

    my $r = int($r_b * $alpha + $r_bg * (1 - $alpha));
    my $g = int($g_b * $alpha + $g_bg * (1 - $alpha));
    my $b = int($b_b * $alpha + $b_bg * (1 - $alpha));

    return sprintf("#%02x%02x%02x", $r, $g, $b);
}

sub _get_smc_indicator {
    my ($self) = @_;
    return $self->{smc_indicator} if $self->{smc_indicator};

    if ($self->{engine} && $self->{engine}->{indicator_manager}) {
        my $manager = $self->{engine}->{indicator_manager};
        return $manager->get_smc_structures() if $manager->can('get_smc_structures');
    }
    return undef;
}

1;