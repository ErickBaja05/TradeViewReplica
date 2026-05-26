package Market::ChartEngine;

use strict;
use warnings;

# Importación de los paneles que el motor debe instanciar según el documento
use Market::Panels::PricePanel;
use Market::Panels::ATRPanel;

=head1 NOMBRE

Market::ChartEngine - Motor gráfico central y orquestador de la interfaz.

=head1 MÉTODOS

=head2 new

Inicializa el motor del gráfico, define el estado interno e instancia los paneles.

Atributos de entrada (recibidos como un hash de argumentos):
  - market_data       : Referencia obligatoria a la instancia de Market::MarketData.
  - indicator_manager : Referencia obligatoria a la instancia de Market::IndicatorManager.
  - price_canvas      : Widget Canvas de Tk asignado para el panel de precios.
  - atr_canvas        : Widget Canvas de Tk asignado para el panel del indicador ATR.
  - widgets           : (Opcional) Hashref para almacenar referencias a otros widgets de Tk (botones, menús, etc.).

Retorna:
  - $self : Instancia bendecida del objeto Market::ChartEngine.

=cut

sub new {
    my ($class, %args) = @_;

    # Construcción del estado interno básico exigido por el documento
    my $self = {
        # Referencias externas recibidas
        market_data       => $args{market_data},
        indicator_manager => $args{indicator_manager},
        price_canvas      => $args{price_canvas},
        atr_canvas        => $args{atr_canvas},
        widgets           => $args{widgets} || {},

        # Estado interno de control visual
        visible_bars      => $args{visible_bars} || 100, # Controla el zoom horizontal (velas visibles)
        offset            => $args{offset} || 0,         # Controla el desplazamiento / scroll horizontal
        crosshair         => { x => -1, y => -1 },       # Coordenadas actuales del cursor en cruz
        render_pending    => 0,                          # Render flag utilizado para optimización diferida

        # Contenedores para las instancias de los paneles independientes
        price_panel       => undef,
        atr_panel         => undef,

        # Estado de Escalas (Día 6)
        auto_scale        => 1,      # 1 = Modo Automático (Default), 0 = Modo Manual
        manual_y_max      => 100,    # Límite superior manual (Dome lo actualizará)
        manual_y_min      => 0,      # Límite inferior manual (Dome lo actualizará)
    };

    bless $self, $class;

    # Instanciación de los paneles correspondientes pasándoles su respectivo canvas
    $self->{price_panel} = Market::Panels::PricePanel->new(
        canvas => $self->{price_canvas},
        engine => $self
    );

    $self->{atr_panel} = Market::Panels::ATRPanel->new(
        canvas => $self->{atr_canvas},
        engine => $self
    );

    return $self;
}

=head2 round

Redondeo numérico auxiliar. Útil para mapeos exactos entre valores continuos y píxeles discretos.

Atributos de entrada:
  - $value : Valor numérico de tipo flotante (float) que se desea redondear.

Retorna:
  - Número entero (integer) correspondiente al redondeo matemático más cercano.

=cut

sub round {
    my ($self, $value) = @_;
    # Implementación matemática estándar en Perl usando el operador spaceship (<=>)
    return int($value + 0.5 * ($value <=> 0));
}


# =========================================================================
#   STUBS DE CONTRATO - FUNCIONES PARA DESARROLLO CONCURRENTE
# =========================================================================
# Los siguientes métodos están declarados vacíos para cumplir con la interfaz
# del documento sin generar errores de llamadas en los módulos de tus compañeros.

=head2 compute_window

Calcula qué porción de datos es visible en la pantalla.
Utiliza las variables de estado visible_bars, zoom y offset para definir
el rango exacto de índices (velas) que se deben renderizar [cite: 490-493].

Retorna:
  - Una lista con dos enteros: ($start_index, $end_index)
=cut

sub compute_window {
    my ($self) = @_;

    my $market_data = $self->{market_data};
    my $total_candles = $market_data->size() || 0;

    # Si aún no hay datos en el mercado, devolvemos un rango nulo (0, 0)
    return (0, 0) if $total_candles == 0;

    # El offset determina cuántas velas nos hemos movido hacia el pasado (izquierda).
    # Si offset es 0, estamos viendo el extremo derecho (lo más reciente).
    my $end_index = $total_candles - 1 - $self->{offset};

    # El índice de inicio depende de la cantidad de barras visibles que permite el zoom actual
    my $start_index = $end_index - $self->{visible_bars} + 1;

    # --- Validaciones de Límites (Boundary Checks) ---
    # Evitar índices negativos si el usuario hace scroll más allá del inicio de los datos
    $start_index = 0 if $start_index < 0;
    
    # Si por el zoom el end_index queda en negativo, se ajusta a 0
    $end_index = 0 if $end_index < 0;

    # Evitar superar el límite derecho si el offset se vuelve negativo 
    # (Tratar de ir al "futuro" donde no hay velas)
    if ($end_index >= $total_candles) {
        $end_index = $total_candles - 1;
        $start_index = $end_index - $self->{visible_bars} + 1;
        $start_index = 0 if $start_index < 0;
    }

    return ($start_index, $end_index);
}

=head2 request_render

Solicita un render diferido. En lugar de dibujar inmediatamente, encola 
la petición para evitar renderizados redundantes. Es la optimización clave
para el rendimiento en Tk .

Retorna:
  - Nada.
=cut

sub request_render {
    my ($self) = @_;

    # Si ya hay una orden de dibujo en la cola, la ignoramos. 
    # Esto garantiza complejidad O(1) en las peticiones.
    return if $self->{render_pending};

    # Levantamos la bandera (flag) indicando que un render está pendiente
    $self->{render_pending} = 1;

    # Obtenemos la referencia a la ventana principal de Tk para encolar el evento
    if (my $mw = $self->{widgets}->{main_window}) {
        # afterIdle ejecuta el bloque de código una vez que Tk termina de 
        # procesar todos los eventos de mouse/teclado actuales.
        $mw->afterIdle(sub {
            # Bajamos la bandera y ejecutamos el render pesado
            $self->{render_pending} = 0;
            $self->render();
        });
    }
}

=head2 render

Orquesta el dibujado principal del gráfico. 
Calcula qué datos se ven, limpia la pantalla y le da la orden de pintar a cada panel.
=cut

sub render {
    my ($self) = @_;

    # 1. Calculamos qué porción del arreglo de velas estamos viendo (Día 2)
    my ($start, $end) = $self->compute_window();

    # 2. Le pedimos a la capa de datos de Josue exactamente ese "pedazo" (slice)
    my $data_slice = $self->{market_data}->get_slice($start, $end);

    # Si por algún motivo no hay datos, detenemos el renderizado
    return unless $data_slice && scalar(@$data_slice) > 0;

    # 3. Limpiamos ambos lienzos de Tk por completo antes de pintar el nuevo "fotograma"
    $self->{price_canvas}->delete('all');
    $self->{atr_canvas}->delete('all');

    # 4. Le enviamos los datos exactos a Domenica para que pinte sus respectivos paneles
    $self->{price_panel}->render($data_slice) if $self->{price_panel};
    $self->{atr_panel}->render($data_slice)   if $self->{atr_panel};
}


=head2 bind_all_canvas

Conecta los eventos físicos del usuario (mouse, redimensionar ventana) 
con las lógicas de este motor gráfico.
=cut

sub bind_all_canvas {
    my ($self) = @_;

    my $price_cv = $self->{price_canvas};
    my $atr_cv   = $self->{atr_canvas};

    # Evento <Configure>: Se dispara cada vez que el usuario cambia el tamaño de la ventana.
    # Al cambiar el tamaño, solicitamos un re-renderizado para ajustar las escalas.
    $price_cv->Tk::bind('<Configure>', sub { $self->request_render(); });
    $atr_cv->Tk::bind('<Configure>', sub { $self->request_render(); });

    # Evento <Motion>: Se dispara al mover el mouse sin presionar botones.
    # Capturamos el evento y se lo pasamos a tu función de Crosshair (línea negra).
    $price_cv->Tk::bind('<Motion>', sub { 
        my $event = $price_cv->XEvent; 
        $self->on_mouse_move($event); 
    });
    $atr_cv->Tk::bind('<Motion>', sub { 
        my $event = $atr_cv->XEvent; 
        $self->on_mouse_move($event); 
    });
}

=head2 bind_events

Conecta los eventos globales de la ventana principal (teclado y rueda del mouse)
con las acciones de control del motor (zoom, scroll y reinicio).

Retorna:
  - Nada.
=cut

sub bind_events {
    my ($self) = @_;

    my $mw = $self->{widgets}->{main_window};
    return unless $mw;

    # --- 1. CONTROL DE ZOOM CON LA RUEDA DEL RATÓN ---
    # En sistemas basados en Linux/X11, la rueda del ratón no se captura siempre
    # con el evento '<MouseWheel>', sino como clics de los botones físicos 4 y 5.
    
   # --- 1. CONTROL DE ZOOM CON LA RUEDA DEL RATÓN ---
    
    # Rueda hacia arriba -> Acercar (Zoom In: reducir barras visibles)
    $mw->Tk::bind('<Button-4>', sub { 
        my $widget = shift; # 1. Capturamos el widget físico que recibió el scroll
        my $e = $widget->XEvent; # 2. Le pedimos su evento
        
        if ($e) { # 3. Si el evento existe, operamos de forma segura
            # El modificador 's' (State) guarda qué teclas adicionales se estaban presionando
            my $has_ctrl = ($e->s & 4) ? 1 : 0; 
            $self->horizontal_zoom(1, $e->x, $has_ctrl); 
        }
    });

    # Rueda hacia abajo -> Alejar (Zoom Out: aumentar barras visibles)
    $mw->Tk::bind('<Button-5>', sub { 
        my $widget = shift;
        my $e = $widget->XEvent;
        
        if ($e) {
            my $has_ctrl = ($e->s & 4) ? 1 : 0;
            $self->horizontal_zoom(-1, $e->x, $has_ctrl); 
        }
    });


    # --- 2. CONTROL DE SCROLL CON LAS FLECHAS DEL TECLADO ---
    # Flecha Izquierda: Desplazarse hacia el pasado (incrementar el offset)
    $mw->Tk::bind('<Left>', sub {
        my $market_data = $self->{market_data};
        my $total_candles = $market_data ? $market_data->size() : 0;

        # Evitamos que el scroll supere la cantidad total de datos disponibles
        if ($self->{offset} < $total_candles - $self->{visible_bars}) {
            $self->{offset}++;
            $self->request_render();
        }
    });

    # Flecha Derecha: Desplazarse hacia el presente (disminuir el offset)
    $mw->Tk::bind('<Right>', sub {
        if ($self->{offset} > 0) {
            $self->{offset}--;
            $self->request_render();
        }
    });


    # --- 3. ATAJOS DE TECLADO ESTILO TRADINGVIEW ---
    # Tecla 'r' o 'R': Invoca el reinicio completo de la vista (escala y offset por defecto)
    $mw->Tk::bind('<Key-r>', sub { $self->reset_view(); });
    $mw->Tk::bind('<Key-R>', sub { $self->reset_view(); });
}


=head2 compute_intraday_labels

Calcula de forma dinámica qué etiquetas de tiempo deben dibujarse para evitar 
el amontonamiento, resaltando los inicios de día (Velas Ancla).
=cut

sub compute_intraday_labels {
    my ($self) = @_;
    
    my ($start, $end) = $self->compute_window();
    my $velas = $self->{market_data}->get_data();
    my @etiquetas_visibles;

    # 1. Calculamos la densidad dinámica: ¿Cada cuántas velas dibujamos?
    my $visibles = $self->{visible_bars};
    my $salto = 1;
    $salto = 5  if $visibles > 30;
    $salto = 10 if $visibles > 100;
    $salto = 50 if $visibles > 500;

    my $ultimo_dia_visto = "";
    my $posicion_relativa = 0;

    for my $i ($start .. $end) {
        my $vela = $velas->[$i];
        last unless $vela;
        my $ts = $vela->{time} || "";

        # Extraer solo la fecha (YYYY-MM-DD) para detectar cambios de día
        my ($dia_actual) = $ts =~ /^(\d{4}-\d{2}-\d{2})/;
        $dia_actual //= "";

        # REGLA DEL PROFESOR: Detectar inicio de un nuevo día (Vela Ancla)
        my $es_cambio_dia = 0;
        if ($dia_actual ne $ultimo_dia_visto && $ultimo_dia_visto ne "") {
            $es_cambio_dia = 1;
        }
        $ultimo_dia_visto = $dia_actual if $dia_actual;

        # Condición para dibujar: O es un cambio de día, o toca por la densidad
        if ($es_cambio_dia || $posicion_relativa % $salto == 0) {
            push @etiquetas_visibles, {
                indice_relativo => $posicion_relativa,
                timestamp       => $ts,
                es_cambio_dia   => $es_cambio_dia
            };
        }
        $posicion_relativa++;
    }

    return \@etiquetas_visibles;
}

=head2 _vertical_drag

Ejecuta el paneo vertical (arrastrar la escala de precios).
Al invocar esto, el gráfico rompe el Auto-Scale y pasa a Modo Manual.
=cut

sub _vertical_drag {
    my ($self, $dy) = @_;
    
    # ¡Rompemos el modo automático!
    $self->{auto_scale} = 0;

    # Calculamos el desplazamiento basado en una altura teórica de pantalla (400px)
    my $rango = $self->{manual_y_max} - $self->{manual_y_min};
    my $desplazamiento = ($dy / 400) * $rango;

    # Movemos los límites de la ventana manual
    $self->{manual_y_max} += $desplazamiento;
    $self->{manual_y_min} += $desplazamiento;

    $self->request_render();
}

=head2 vertical_zoom

Expande o contrae la escala de precios. Cambia a Modo Manual automáticamente.
=cut

sub vertical_zoom {
    my ($self, $factor) = @_;
    
    $self->{auto_scale} = 0;

    # factor = 1 (acercar/estirar), factor = -1 (alejar/comprimir)
    my $rango = $self->{manual_y_max} - $self->{manual_y_min};
    my $cambio = $rango * 0.05 * $factor; # 5% de zoom por click

    # Ajustamos los márgenes (El techo sube, el piso baja)
    $self->{manual_y_max} += $cambio;
    $self->{manual_y_min} -= $cambio;

    $self->request_render();
}

=head2 set_timeframe

Orquesta el cambio de temporalidad en la capa de datos y resetea la vista.
=cut

sub set_timeframe {
    my ($self, $tf) = @_;
    
    # Asumiendo que Josué programará una función para cambiar el arreglo activo
    # $self->{market_data}->set_active_timeframe($tf) if $self->{market_data}->can('set_active_timeframe');
    
    # Volvemos al presente y recuperamos el Auto-Scale
    $self->reset_view(); 
}

=head2 on_mouse_move

Captura el evento de movimiento del ratón desde Tk, extrae las coordenadas físicas
y determina qué panel está recibiendo el foco actualmente.
=cut

sub on_mouse_move {
    my ($self, $event) = @_;

    # Validamos que el evento exista
    return unless $event;

    # Extraemos la posición X del ratón (Esta coordenada es idéntica para todos los paneles)
    my $x = $event->x;
    
    # Extraemos la posición Y (¡Ojo! Esta coordenada es local al canvas que la generó)
    my $y = $event->y;

    # Identificamos qué widget (Canvas) generó el evento físicamente
    my $active_widget = $event->W;

    # Pasamos las coordenadas y el widget activo al orquestador de dibujado
    $self->draw_crosshair_all($x, $y, $active_widget);
}

=head2 draw_crosshair_all

Propaga la orden de dibujar el crosshair (la línea en cruz) a todos los paneles registrados.
Le indica a cada panel si tiene el foco del ratón para que decida si dibuja la línea horizontal.
=cut

sub draw_crosshair_all {
    my ($self, $x, $y, $active_widget) = @_;

    # 1. Enviar coordenadas al Panel de Precios (Domenica)
    if ($self->{price_panel}) {
        # Verificamos si el ratón está físicamente sobre este canvas
        my $is_active = ($active_widget == $self->{price_canvas}) ? 1 : 0;
        $self->{price_panel}->draw_crosshair($x, $y, $is_active);
    }

    # 2. Enviar coordenadas al Panel de Volatilidad ATR (Domenica)
    if ($self->{atr_panel}) {
        my $is_active = ($active_widget == $self->{atr_canvas}) ? 1 : 0;
        $self->{atr_panel}->draw_crosshair($x, $y, $is_active);
    }
}


=head2 horizontal_zoom

Controla el nivel de zoom de la gráfica ajustando la cantidad de barras visibles.
Implementa el requerimiento de "Ancla a la derecha" por defecto, y "Ancla al ratón" si hay Ctrl.
=cut

sub horizontal_zoom {
    my ($self, $delta, $mouse_x, $has_ctrl) = @_;

    my $current_bars = $self->{visible_bars} || 100;
    
    # 1. Calcular la intensidad del zoom (10% de la pantalla actual por cada "click" de rueda)
    my $zoom_factor = 0.10;
    my $bars_change = $current_bars * $zoom_factor;
    $bars_change = 1 if $bars_change < 1; # Mínimo cambiar de 1 en 1
    
    # Si delta es positivo (acercar), reducimos las barras visibles. Si es negativo (alejar), aumentamos.
    my $new_bars = $current_bars + ($delta > 0 ? -$bars_change : $bars_change);
    
    # 2. REGLA DEL PROFESOR: Mínimo número de velas = 2
    $new_bars = 2 if $new_bars < 2;

    # 3. Lógica de Anclaje
    if ($has_ctrl && defined $mouse_x && defined $self->{price_panel}) {
        # MODO CTRL: El zoom ocurre desde el centro del ratón.
        # Calculamos el porcentaje de la pantalla donde está el cursor (ej. 0.5 es la mitad)
        my $canvas_width = $self->{price_canvas}->Width() || 1;
        my $porcentaje_pantalla = $mouse_x / $canvas_width;
        
        # Ajustamos el offset para que la vela bajo el ratón no se desplace visualmente
        my $barras_perdidas = $current_bars - $new_bars;
        
        # Si perdemos 10 barras de visión, y el ratón está en el 80% (0.8) de la pantalla,
        # desplazamos el offset en 8 barras para compensar.
        $self->{offset} += ($barras_perdidas * (1 - $porcentaje_pantalla));
    } else {
        # MODO DEFAULT: Si no hay Ctrl, el offset no cambia.
        # Al no cambiar el offset, nuestra arquitectura por defecto ancla la vista 
        # a la última vela de la derecha, exactamente como pidió el profesor.
    }

    # Actualizamos el estado y solicitamos re-dibujar
    $self->{visible_bars} = $self->round($new_bars);
    $self->request_render();
}

=head2 reset_view

Restaura la vista del gráfico a su estado original "por defecto" (TradingView Auto-Fit).
=cut

sub reset_view {
    my ($self) = @_;
    
    # 1. Restaurar zoom por defecto
    $self->{visible_bars} = 100; 
    
    # 2. Restaurar scroll al presente
    $self->{offset} = 0;   
    
    # 3. Preparación para el Día 6 (Reactivar Auto-Scale)
    $self->{auto_scale} = 1; 

    # 4. Redibujar todo
    $self->request_render();
}


=head2 get_all_timestamps

Devuelve los timestamps únicamente de las velas que son visibles actualmente.
Usado para etiquetar el eje temporal y sincronizar otros elementos.

Retorna:
  - Una referencia a un arreglo (\@timestamps) con las etiquetas de tiempo.
=cut

sub get_all_timestamps {
    my ($self) = @_;

    my ($start, $end) = $self->compute_window();
    my $market_data = $self->{market_data};
    my @timestamps;

    # Recorremos solo la porción visible de datos y extraemos su fecha/hora
    for my $i ($start .. $end) {
        my $ts = $market_data->get_timestamp($i);
        push @timestamps, $ts if defined $ts;
    }

    return \@timestamps;
}

1; # Retorno verdadero obligatorio para módulos en Perl