# Orden de columnas en `output.csv`

Las columnas de `output.csv` están agrupadas por indicador/origen de datos
(no en el orden en que se fueron agregando históricamente). El orden
actual es:

1. **Tiempo**: `minute`, `hour`, `day`, `month`, `year`.
2. **Vela** (OHLCV, ATR y geometría de la vela): `open (pip)`, `high (pip)`,
   `low (pip)`, `close (pip)`, `volume`, `atr (pip)`, `body`, `upper_wick`,
   `lower_wick`, `candle_type`, `momentum`, `lenght`.
3. **Pivotes**: `pivote`, `pivote3`, `pivote5`, `pivote10`, `pivote15`.
4. **Estructura de mercado** (`SMC_Structures`/`Structure`): `trend_ext`,
   `bos_ext`, `bos_int`, `choch_ext`, `choch_int`, `eqh`, `eql`,
   `bars_since_bos`, `bars_since_choch`.
5. **Fair Value Gaps** (`FVG`): `inside_fvg`, `distance_FVG`, `fvg_size`,
   `bars_since_fvg`.
6. **Order Blocks** (`OrderBlocks`): `inside_order_block`, `distance_ob`,
   `ob_type`, `bars_since_ob`.
7. **Último HH/LL confirmado** (`SMC_Structures`): `distance_hh`,
   `distance_ll`.
8. **Fibonacci** (`Fibonacci`): `nearest_fib_level`.
9. **Niveles MTF** (alto/bajo del período anterior): `distance_daily_high`,
   `distance_daily_low`, `distance_weekly_high`, `distance_weekly_low`,
   `distance_monthly_high`, `distance_monthly_low`.
10. **Liquidez y swings menores** (`Liquidity`): `distance_bsl`,
    `distance_ssl`, `lq_event`, `bars_since_lq_event`, `is_sh`, `is_sl`,
    `distance_sh`, `distance_sl`.
11. **Tendencia interna multi-temporalidad** (`ZigzagInternal`
    re-muestreado): `trend_int_15min`, `trend_int_30min`, `trend_int_1hr`,
    `trend_int_2hr`, `trend_int_4hr`.
12. **HalfTrend**: `half_trend`, `distance_high_half_trend`,
    `distance_low_half_trend`.
13. **SuperTrend**: `super_trend`, `distance_high_super_trend`,
    `distance_low_super_trend`.
14. **Range Filter**: `range_filter`, `distance_high_range_filter`,
    `distance_low_range_filter`.
15. **VWAP Anclado** (`VWAPAnchored`): `session_vwap_distance`,
    `open_vwap_distance`, `bos_vwap_distance`, `choch_vwap_distance`,
    `pivot_vwap_distance`.

El resto de este documento describe el significado de cada columna
agrupado por tema; no necesariamente en el mismo orden en que aparecen en
`output.csv`, pero cada sección corresponde a uno de los bloques listados
arriba.

# Lookup — Columna `trend_ext`

Equivalencia entre el estado de tendencia calculado por
`Market::Indicators::SMC_Structures` (campo `trend` del objeto) y el valor
numérico guardado en la columna `trend_ext` de `output.csv`. Se llama
`trend_ext` (tendencia "externa" o estructural) para distinguirla de las
columnas `trend_int_*` (tendencia interna por temporalidad, ver más
abajo), que usan un zigzag más sensible sobre velas re-muestreadas.

| Tendencia (SMC_Structures) | Valor en `trend_ext` | Descripción                                   |
|-----------------------------|:-----------------:|------------------------------------------------|
| `DOWN`                      | `-1`               | Estructura de mercado bajista (tras un CHoCH/BOS a la baja) |
| `UNKNOWN`                   | `0`                | Aún no se ha determinado una tendencia (fase inicial, antes del primer HH/LL) |
| `UP`                        | `1`                | Estructura de mercado alcista (tras un CHoCH/BOS al alza)   |

## Notas de implementación

- `datos.pl` recorre las velas en orden cronológico y, en cada índice marcado
  como pivote (`is_high_pivot` / `is_low_pivot`), llama a
  `Market::Indicators::SMC_Structures->update_last()` con:
  - `type`: `HIGH` o `LOW`.
  - `price`: el `high` o `low` de la vela pivote.
  - `index`: índice de la vela.
  - `atr`: valor de ATR (en precio absoluto, no en pips) de esa vela, usado
    internamente por el módulo para el umbral de ruptura (`choch_atr_mult`).
- El valor de `trend_ext` se propaga (forward-fill) a todas las velas
  intermedias entre pivotes: cada fila guarda la tendencia vigente en ese
  momento, no solo las filas donde ocurre un pivote.
- Si una vela es simultáneamente pivote de `HIGH` y de `LOW`, se procesa
  primero el evento `HIGH` y luego el `LOW`.

## Columnas booleanas (0 / 1)

Las siguientes columnas de `output.csv` son indicadores binarios: `1`
significa que el evento/condición existe en esa vela, `0` que no existe.

| Columna     | Significa `1`                                                                 |
|-------------|--------------------------------------------------------------------------------|
| `pivote`    | La vela es un pivote (máximo o mínimo) detectado por la lógica de pivotes del script. |
| `bos_ext`   | Ocurre un **BOS (Break of Structure)** en la estructura **externa** (swing), detectado por `Market::Indicators::Structure`. |
| `bos_int`   | Ocurre un **BOS** en la estructura **interna**, detectado por `Market::Indicators::Structure`. |
| `choch_ext` | Ocurre un **CHoCH (Change of Character)** en la estructura **externa** (swing), detectado por `Market::Indicators::Structure`. |
| `choch_int` | Ocurre un **CHoCH** en la estructura **interna**, detectado por `Market::Indicators::Structure`. |
| `eqh`       | Se detecta un **Equal High** (dos máximos externos igualados dentro del umbral `eq_threshold * ATR`), detectado por `Market::Indicators::Structure`. |
| `eql`       | Se detecta un **Equal Low** (dos mínimos externos igualados dentro del umbral `eq_threshold * ATR`), detectado por `Market::Indicators::Structure`. |

### Notas sobre `bos_ext`, `bos_int`, `choch_ext`, `choch_int`, `eqh`, `eql`

- `datos.pl` llama a `Market::Indicators::Structure->update_last(\@data, $atr_values, $i)`
  para cada vela `$i`, en orden cronológico. El módulo mantiene su propio
  estado interno (leg externo/interno, pivotes, tendencia) y va acumulando
  eventos en `$structure->{events}`.
- Cada evento trae un `index` que indica en qué vela ocurrió. Para `BOS_*` y
  `CHoCH_*` ese índice es la vela donde el precio cruza el nivel (la vela
  actual del bucle). Para `EQH`/`EQL` el índice corresponde a la vela pivote
  central detectada (`i - eq_len`), que puede ser anterior a la vela donde
  se confirma la igualdad.
- `tier => 'external'` marca eventos de la estructura de swing (mayor
  tamaño, `swing_size`); `tier => 'internal'` marca eventos de la estructura
  interna (menor tamaño, `internal_size`).
- Si una vela nunca produce ninguno de estos eventos, todas estas columnas
  quedan en `0`.

# Lookup — Columnas `inside_fvg`, `distance_FVG`, `fvg_size`

Estas tres columnas describen la relación entre el cierre de cada vela y el
**Fair Value Gap (FVG)** más reciente detectado hasta ese momento por
`Market::Indicators::FVG`.

- `datos.pl` recorre las velas en orden cronológico llamando a
  `Market::Indicators::FVG->update_last(\@data, $atr_values, $i)` para cada
  vela `$i`. Esta llamada actualiza el estado de mitigación de las zonas
  abiertas y, si corresponde, detecta un nuevo FVG usando las velas
  `i-3` e `i-1`.
- En cada índice `$i` se toma el **FVG más reciente creado hasta ese
  momento** (el último elemento de `$result->{zones}`, sin importar su
  estado —`Open`, `Mitigated` o `Filled`—). Si todavía no se ha creado
  ningún FVG (por ejemplo, en las primeras velas de la serie), las tres
  columnas quedan en `0`.
- El "centro" de la zona se calcula como `(top + bottom) / 2`, donde `top`
  y `bottom` son los límites superior e inferior de la zona en precio
  absoluto.

| Columna        | Significado                                                                                     |
|----------------|---------------------------------------------------------------------------------------------------|
| `inside_fvg`   | `1` si el `close` de la vela cae dentro de los límites `[bottom, top]` del FVG más reciente, `0` si está fuera (o si aún no existe ningún FVG). |
| `distance_FVG` | Distancia normalizada por ATR entre el centro del FVG más reciente y el `close` de la vela: `(centro_fvg - close) / ATR`. Se usa el ATR en precio absoluto de esa vela (el mismo que produce `Market::Indicators::ATR`, antes de convertirlo a pips). Si el ATR de esa vela es `0` o no existe ningún FVG todavía, el valor es `0`. Un valor positivo indica que el centro del FVG está por encima del cierre; negativo, que está por debajo. |
| `fvg_size`     | Tamaño de la zona del FVG más reciente, en pips: `(top - bottom) * pip_multiplier`. Es `0` si aún no existe ningún FVG. |

## Notas de implementación

- El objeto `Market::Indicators::FVG` mantiene su propio estado interno
  (`zones`, `open_zones`, `visible_queue`) a lo largo de todo el recorrido;
  por eso basta con instanciarlo una vez fuera del bucle y llamar a
  `update_last()` vela a vela, igual que con `Structure`.
- El "FVG más reciente" se determina por orden de creación
  (`created_index`), no por su estado de mitigación: una zona ya `Filled`
  puede seguir siendo la más reciente si no se ha creado ninguna otra zona
  después de ella.
- `fvg_size` se expresa en pips para mantener la misma escala que el resto
  de columnas de precio del CSV (`open (pip)`, `high (pip)`, etc.).
  `distance_FVG`, en cambio, se deja en unidades de ATR (sin convertir a
  pips), ya que es un ratio y no una magnitud de precio.

# Lookup — Columnas `inside_order_block`, `distance_ob`, `ob_type`

Estas tres columnas describen la relación entre el cierre de cada vela y el
**Order Block** más reciente detectado hasta ese momento por
`Market::Indicators::OrderBlocks`.

- `datos.pl` recorre las velas en orden cronológico llamando a
  `Market::Indicators::OrderBlocks->update_last(\@data, $atr_values, $i)`
  para cada vela `$i`. Esta llamada actualiza primero la mitigación de las
  zonas `SUPPLY`/`DEMAND` activas y, si la vela `$i - swing\_length` resulta
  ser un pivote confirmado (mirando `swing_length` velas hacia atrás y
  hacia adelante), crea una nueva zona `SUPPLY` (en un pivote alto) o
  `DEMAND` (en un pivote bajo).
- En cada índice `$i` se toma el **Order Block más reciente creado hasta
  ese momento** (el último elemento de `$result->{zones}`), sin importar si
  ya fue mitigado o si sigue activo. Si todavía no se ha creado ningún
  Order Block (por ejemplo, mientras `$i < 2 * swing_length`, o al inicio
  de la serie), las tres columnas quedan en `0`.
- El `poi` ("point of interest") de la zona es el que calcula internamente
  `OrderBlocks.pm` como el punto medio entre `top` y `bottom` de la zona.

| Columna              | Significado                                                                                   |
|-----------------------|-------------------------------------------------------------------------------------------------|
| `inside_order_block`  | `1` si el `close` de la vela cae dentro de los límites `[bottom, top]` del Order Block más reciente, `0` si está fuera (o si aún no existe ninguno). |
| `distance_ob`         | Distancia normalizada por ATR entre el `poi` del Order Block más reciente y el `close` de la vela: `(poi - close) / ATR`. Se usa el ATR en precio absoluto de esa vela (antes de convertirlo a pips). Si el ATR de esa vela es `0` o no existe ningún Order Block todavía, el valor es `0`. Un valor positivo indica que el `poi` está por encima del cierre; negativo, que está por debajo. |
| `ob_type`             | Tipo del Order Block más reciente: `1` si es `SUPPLY` (zona de oferta, formada en un pivote alto), `-1` si es `DEMAND` (zona de demanda, formada en un pivote bajo). `0` si todavía no existe ningún Order Block. |

## Notas de implementación

- El objeto `Market::Indicators::OrderBlocks` mantiene su propio estado
  interno (`zones`, `active_supply`, `active_demand`) a lo largo de todo el
  recorrido; por eso basta con instanciarlo una vez fuera del bucle y
  llamar a `update_last()` vela a vela, igual que con `Structure` y `FVG`.
- El "Order Block más reciente" se determina por orden de creación
  (posición en `zones`, que coincide con `left_index` ascendente), no por
  si sigue activo (`mitigated => 0`): una zona ya mitigada puede seguir
  siendo la más reciente si no se ha creado ninguna otra zona después de
  ella.
- A diferencia de `distance_FVG`, `distance_ob` también se deja en
  unidades de ATR (sin convertir a pips), por ser igualmente un ratio y no
  una magnitud de precio.
- `ob_type` no tiene equivalente de "tamaño en pips" como `fvg_size`
  porque no fue solicitado; si se necesitara, podría derivarse de
  `(top - bottom) * pip_multiplier` del Order Block más reciente siguiendo
  el mismo patrón que `fvg_size`.

# Lookup — Columnas `distance_hh`, `distance_ll`

Estas columnas describen la distancia normalizada por ATR entre el cierre
de cada vela y el precio del **HH (Higher High)** y del **LL (Lower Low)**
más recientes, según el etiquetado de pivotes que hace
`Market::Indicators::SMC_Structures`.

- En el mismo recorrido cronológico donde `datos.pl` alimenta
  `Market::Indicators::SMC_Structures->update_last()` con cada pivote
  (`HIGH`/`LOW`, ver sección "Columna `trend_ext`" más arriba), se inspecciona
  el `label` que el módulo asigna a ese pivote (`H`, `HH`, `LH`, `L`, `HL`,
  `LL`).
- Cada vez que un pivote de tipo `HIGH` recibe la etiqueta `HH`, su precio
  (`high` de esa vela) se guarda como el HH más reciente. Cada vez que un
  pivote de tipo `LOW` recibe la etiqueta `LL`, su precio (`low` de esa
  vela) se guarda como el LL más reciente. Las etiquetas `H`, `LH` y `HL`
  no actualizan estos valores.
- Al igual que `trend_ext`, estos valores se propagan (forward-fill) a todas
  las velas intermedias: cada fila usa el HH/LL más reciente conocido
  hasta esa vela, no solo las filas donde ocurre el pivote.
- Mientras todavía no se haya confirmado ningún HH (o ningún LL) en toda
  la serie, la columna correspondiente vale `0` en esas filas.

| Columna       | Fórmula                                   | Descripción                                                                 |
|----------------|--------------------------------------------|-------------------------------------------------------------------------------|
| `distance_hh` | `(HH_mas_reciente - close) / ATR`          | Distancia (en unidades de ATR) entre el precio del HH más reciente y el `close` de la vela. `0` si aún no se ha confirmado ningún HH, o si el ATR de esa vela es `0`. |
| `distance_ll` | `(LL_mas_reciente - close) / ATR`          | Distancia (en unidades de ATR) entre el precio del LL más reciente y el `close` de la vela. `0` si aún no se ha confirmado ningún LL, o si el ATR de esa vela es `0`. |

## Notas de implementación

- Se usa el ATR en precio absoluto de esa vela (el mismo que produce
  `Market::Indicators::ATR`, antes de convertirlo a pips), igual que en
  `distance_FVG` y `distance_ob`.
- Un valor positivo en `distance_hh` indica que el HH más reciente está
  por encima del cierre actual (lo habitual, salvo que el precio ya haya
  superado ese máximo); análogamente, un valor positivo en `distance_ll`
  indica que el LL más reciente está por encima del cierre actual.
- `distance_hh` y `distance_ll` son independientes de la tendencia
  (`trend_ext`): se actualizan por la etiqueta del pivote (`HH`/`LL`) sin
  importar si el mercado está, en ese momento, en tendencia `UP`, `DOWN` o
  `UNKNOWN`.

# Lookup — Columnas `distance_daily_high`, `distance_daily_low`, `distance_weekly_high`, `distance_weekly_low`, `distance_monthly_high`, `distance_monthly_low`

Estas seis columnas describen la distancia normalizada por ATR entre el
cierre de cada vela y los niveles MTF (Multi Time Frame) calculados por
`Market::Indicators::Levels`: el Alto y el Bajo del **día**, la **semana**
y el **mes anteriores** (PDH/PDL, PWH/PWL, PMH/PML).

- `datos.pl` llama a `$levels->calculate_until(\@data, $i)` para cada vela
  `$i`, en orden cronológico. Cada llamada recalcula, con todo el
  histórico de velas desde el inicio hasta `$i`, el Alto y el Bajo del
  período **previo** (día/semana/mes anterior al que contiene la vela
  `$i`) y los proyecta como vigentes hasta esa vela.
- De los niveles devueltos (`mtf_levels`) se toma el precio asociado a cada
  etiqueta (`label`): `PDH`/`PDL` (Previous Day High/Low), `PWH`/`PWL`
  (Previous Week High/Low), `PMH`/`PML` (Previous Month High/Low).
- Si un nivel todavía no existe (por ejemplo, `PDH`/`PDL` en las velas del
  primer día de la serie, antes de que se complete un día anterior; lo
  mismo aplica a la primera semana o el primer mes), la columna
  correspondiente vale `0` en esas filas. También vale `0` si el ATR de esa
  vela es `0` o no está definido.

| Columna                  | Fórmula                              | Nivel usado |
|---------------------------|----------------------------------------|-------------|
| `distance_daily_high`     | `(PDH - close) / ATR`                 | `PDH` (máximo del día anterior) |
| `distance_daily_low`      | `(PDL - close) / ATR`                 | `PDL` (mínimo del día anterior) |
| `distance_weekly_high`    | `(PWH - close) / ATR`                 | `PWH` (máximo de la semana anterior) |
| `distance_weekly_low`     | `(PWL - close) / ATR`                 | `PWL` (mínimo de la semana anterior) |
| `distance_monthly_high`   | `(PMH - close) / ATR`                 | `PMH` (máximo del mes anterior) |
| `distance_monthly_low`    | `(PML - close) / ATR`                 | `PML` (mínimo del mes anterior) |

## Notas de implementación

- `datos.pl` **no** llama a `Market::Indicators::Levels->calculate_until()`
  vela a vela (esa función recalcula toda la historia desde cero en cada
  llamada, con costo O(n) por vela y O(n²) en total). En su lugar,
  replica su misma lógica de detección de cambio de período y de cálculo
  del Alto/Bajo del período anterior, pero de forma **incremental**: cada
  vela se procesa una única vez, en O(1) amortizado (O(n) en total sobre
  toda la serie), manteniendo el mismo criterio de claves que
  `Levels.pm` (día: `YYYY-MM-DD`; semana ISO: `YYYY-WW` vía
  `Time::Piece->strftime("%G-%V")`; mes: `YYYY-MM`) y produciendo
  exactamente los mismos niveles PDH/PDL/PWH/PWL/PMH/PML.
- Se usa el ATR en precio absoluto de esa vela (el mismo que produce
  `Market::Indicators::ATR`, antes de convertirlo a pips), igual que en
  `distance_FVG`, `distance_ob`, `distance_hh` y `distance_ll`.
- Un valor positivo indica que el nivel está por encima del cierre actual;
  uno negativo, que está por debajo (por ejemplo, `distance_daily_low`
  negativo significa que el precio ya cerró por debajo del mínimo del día
  anterior).
- Los niveles diario/semanal/mensual dependen de que el campo `time` de
  cada vela venga en formato `YYYY-MM-DD...` o como timestamp epoch
  numérico; si el formato no es reconocido, esa vela no actualiza el
  estado de niveles de ese período (igual que en `Levels.pm`).

# Lookup — Columnas `distance_bsl`, `distance_ssl`, `lq_event`

Estas columnas se derivan de `Market::Indicators::Liquidity`, que detecta
niveles de liquidez **BSL** (Buy Side Liquidity, sobre un pivote
estructural de tipo `HIGH`) y **SSL** (Sell Side Liquidity, sobre un
pivote estructural de tipo `LOW`), y los clasifica cuando son barridos.

- `datos.pl` llama a `$liquidity->update_last(\@data, $atr_values, $i)`
  para cada vela `$i`, en orden cronológico. El módulo detecta
  internamente sus propios pivotes estructurales (usando `atr_mult`) y, al
  confirmar uno, crea un nivel `BSL` (en un `HIGH`) o `SSL` (en un `LOW`)
  en estado `Detected`. La llamada no hace nada (devuelve `undef`) en
  velas cuyo ATR es `0` o no está definido.
- `distance_bsl` y `distance_ssl` usan, respectivamente, el precio del BSL
  y del SSL **más recientes creados hasta esa vela** (sin importar su
  estado — `Detected`, `Pending` o `Resolved`), igual que `distance_hh` /
  `distance_ll`: se propagan (forward-fill) a todas las velas intermedias
  hasta que se crea un nivel más nuevo del mismo tipo.
- Cada nivel, una vez tocado, pasa a `Pending` y luego se resuelve como
  `Sweep` (rechazo inmediato en la misma vela), `Grab` (revierte antes de
  `confirm_bars` velas: falso breakout) o `Run` (sigue cerrando más allá
  del nivel durante al menos `confirm_bars` velas: continuación). Esa
  resolución queda registrada en el propio nivel, en su vela
  `resolved_index`.

| Columna        | Fórmula / Valor                                    | Descripción |
|-----------------|------------------------------------------------------|-------------|
| `distance_bsl`  | `(BSL_mas_reciente - close) / ATR`                   | Distancia (en unidades de ATR) entre el precio del BSL más reciente y el `close` de la vela. `0` si aún no se ha creado ningún BSL, o si el ATR de esa vela es `0`. |
| `distance_ssl`  | `(SSL_mas_reciente - close) / ATR`                   | Distancia (en unidades de ATR) entre el precio del SSL más reciente y el `close` de la vela. `0` si aún no se ha creado ningún SSL, o si el ATR de esa vela es `0`. |
| `lq_event`      | `0`=Sweep en BSL (sweep al alza) · `1`=Sweep en SSL (sweep a la baja) · `2`=Grab (en BSL o SSL) · `3`=Run (en BSL o SSL) · `-1`=ningún nivel se resolvió en esa vela | Clasificación de la(s) resolución(es) de liquidez que ocurre(n) exactamente en esa vela (`resolved_index == i`). |

## Notas de implementación

- Se usa el ATR en precio absoluto de esa vela, igual que en el resto de
  columnas `distance_*`.
- `lq_event` no es forward-fill: a diferencia de `distance_bsl`/
  `distance_ssl`, marca únicamente la vela exacta en la que un nivel se
  resuelve como `Sweep`, `Grab` o `Run`; en el resto de velas vale `-1`.
  Se eligió `-1` (y no `0`) para "sin evento" porque `0` ya está reservado
  para `Sweep en BSL`.
- El módulo no distingue explícitamente `Grab`/`Run` por tipo (`BSL` vs
  `SSL`) en su clasificación (`classification` solo guarda `Sweep`,
  `Grab` o `Run`), así que `lq_event` tampoco lo distingue para esos dos
  casos — únicamente `Sweep` se separa en "al alza" (`0`, sobre un `BSL`)
  o "a la baja" (`1`, sobre un `SSL`), tal como se solicitó.
- Si dos niveles distintos se resuelven en la misma vela, `lq_event` en
  esa vela refleja la resolución del último nivel procesado en el
  recorrido interno de `$liquidity->{liquidity}` (en la práctica, esto es
  poco frecuente).
- Por optimización, `datos.pl` no vuelve a recorrer toda la lista de
  niveles en cada vela: aprovecha que los niveles nuevos siempre se
  agregan al final de la lista para actualizar `distance_bsl`/
  `distance_ssl` en O(1) amortizado, y hace un único recorrido final sobre
  todos los niveles (O(m), con `m` = cantidad total de niveles creados)
  para volcar las resoluciones (`lq_event`) en la vela correspondiente.

# Lookup — Columnas `is_sh`, `is_sl`, `distance_sh`, `distance_sl`

Estas columnas se derivan de los **pivotes menores** (`minor_pivots`) que
`Market::Indicators::Liquidity` detecta con su propio umbral, más
sensible, `minor_atr_mult` (por defecto `1.5`, frente a `atr_mult => 4.0`
que usa para los pivotes estructurales de BSL/SSL). Estos pivotes menores
son los "swing high" (`SH`) y "swing low" (`SL`) — más frecuentes y de
menor magnitud que los pivotes estructurales usados en `distance_bsl` /
`distance_ssl` / `trend_ext`.

- `datos.pl` reutiliza la misma llamada a
  `$liquidity->update_last(\@data, $atr_values, $i)` que ya hace para
  `distance_bsl`/`distance_ssl`/`lq_event` (mismo objeto `$liquidity`, una
  sola pasada por todas las velas). De cada resultado se toma
  `$result->{minor_pivots}`.
- Al igual que con los niveles de liquidez, los pivotes menores nuevos
  siempre se agregan al final de esa lista, así que `datos.pl` solo
  inspecciona las entradas nuevas comparando el tamaño de la lista
  antes/después de cada llamada (O(1) amortizado por vela, sin volver a
  recorrerla completa).
- **Importante:** un pivote menor se **confirma** varias velas después de
  haber ocurrido (recién cuando el precio se aleja del extremo lo
  suficiente, según `minor_atr_mult * ATR`). Su índice (`->{index}`) es el
  de la vela donde ocurrió el extremo (el `high` o `low` real), no el de
  la vela en la que se confirma. Por eso `is_sh`/`is_sl` se marcan de
  forma retroactiva en `->{index}` en el momento en que el pivote aparece
  en `minor_pivots` — la vela del swing queda marcada como tal recién
  cuando el script "se entera", varias filas más adelante en el CSV.

| Columna        | Significado                                                                                   |
|-----------------|--------------------------------------------------------------------------------------------------|
| `is_sh`         | `1` si esa vela es un swing high (pivote menor de tipo `HIGH`) ya confirmado por `Liquidity.pm`, `0` si no. |
| `is_sl`         | `1` si esa vela es un swing low (pivote menor de tipo `LOW`) ya confirmado por `Liquidity.pm`, `0` si no. |
| `distance_sh`   | `(SH_mas_reciente - close) / ATR`: distancia en unidades de ATR entre el precio del swing high más reciente y el `close` de la vela. `0` si aún no se ha confirmado ningún swing high, o si el ATR de esa vela es `0`. |
| `distance_sl`   | `(SL_mas_reciente - close) / ATR`: distancia en unidades de ATR entre el precio del swing low más reciente y el `close` de la vela. `0` si aún no se ha confirmado ningún swing low, o si el ATR de esa vela es `0`. |

## Notas de implementación

- `distance_sh`/`distance_sl` se propagan (forward-fill) igual que
  `distance_bsl`/`distance_ssl`/`distance_hh`/`distance_ll`: usan el
  precio del swing más reciente confirmado hasta esa vela, y se
  recalculan en cada vela con el `close` y el ATR de esa vela (el swing
  en sí permanece fijo hasta que se confirma uno nuevo).
- `is_sh`/`is_sl` son independientes de `distance_sh`/`distance_sl`: una
  vela puede tener `is_sh = 1` sin que `distance_sh` "salte" todavía a su
  precio en esa misma fila si la confirmación (y por lo tanto la
  actualización de `distance_sh`) ocurre en una vela posterior — ver la
  nota sobre confirmación retroactiva más arriba.
- `is_sh`/`is_sl` y `distance_sh`/`distance_sl` son conceptualmente
  distintos de `pivote`/`pivote3`/`pivote5`/`pivote10`/`pivote15`
  (columnas basadas en el algoritmo de pivotes con `length=50` del inicio
  del script) y también de `distance_bsl`/`distance_ssl` (pivotes
  estructurales de `Liquidity.pm`, con `atr_mult=4.0`): son tres
  detectores de pivote distintos, con sensibilidades distintas.

# Lookup — Columnas `trend_int_15min`, `trend_int_30min`, `trend_int_1hr`, `trend_int_2hr`, `trend_int_4hr`

Estas cinco columnas reflejan la tendencia **interna** vigente en cada
vela, según el ZigZag de `Market::Indicators::ZigzagInternal`, calculado
sobre velas re-muestreadas a 15 minutos, 30 minutos, 1 hora, 2 horas y 4
horas respectivamente. A diferencia de `trend_ext` (basada en HH/HL/LH/LL
y en niveles de ATR vía `SMC_Structures`), esta tendencia es puramente
geométrica: sigue la dirección (`dir`) del último pivote confirmado por
el ZigZag, sin usar ATR ni umbrales de ruptura.

## Cómo se calcula

1. **Re-muestreo:** `datos.pl` agrupa las velas base en barras OHLC de la
   temporalidad correspondiente (15min/30min/1hr/2hr/4hr), usando el
   campo `time` de cada vela (formato ISO `YYYY-MM-DD[ HH:MM:SS]` o
   timestamp epoch numérico) para determinar a qué barra pertenece cada
   vela base. Dentro de cada barra: `open` es el de la primera vela base
   que la abre, `high`/`low` son el máximo/mínimo de todas las velas base
   que caen en ella, y `close` es el de la última vela base recibida
   hasta el momento.
2. **ZigZag:** sobre la serie re-muestreada de cada temporalidad se
   instancia un `Market::Indicators::ZigzagInternal->new(period => 2)`
   (mismo período por defecto que el indicador original) y se llama a
   `update_last()` barra a barra, en orden, sobre el arreglo completo de
   barras re-muestreadas (tal como exige el contrato del módulo).
3. **Tendencia por barra re-muestreada:** después de procesar cada barra,
   se toma directamente el campo interno `dir` del ZigZag (`1` = último
   pivote confirmado fue un máximo/pivote alto, `-1` = fue un mínimo/pivote
   bajo, `0` = todavía no se confirmó ningún pivote).
4. **Mapeo a las velas base:** cada vela base hereda el `dir` vigente de
   la barra re-muestreada a la que pertenece (todas las velas base dentro
   de una misma barra en formación comparten el mismo valor, ya que ese
   valor solo se conoce/actualiza al cerrar cada barra en el bucle de
   re-muestreo).

| Valor | Significado                                                          |
|:-----:|-----------------------------------------------------------------------|
| `-1`  | `DOWN`: el último pivote confirmado por el ZigZag de esa temporalidad fue un pivote bajo. |
| `0`   | `UNKNOWN`: todavía no se ha confirmado ningún pivote del ZigZag en esa temporalidad (inicio de la serie, o muy poca historia para esa temporalidad). |
| `1`   | `UP`: el último pivote confirmado por el ZigZag de esa temporalidad fue un pivote alto. |

## Notas de implementación

- Las cinco columnas son independientes entre sí: cada una corre su
  propia instancia de `ZigzagInternal` sobre su propia serie
  re-muestreada, por lo que es normal (y esperado) que
  `trend_int_15min` cambie de signo con mucha más frecuencia que
  `trend_int_4hr`.
- Si el campo `time` de una vela no tiene un formato reconocible y
  todavía no se abrió ninguna barra re-muestreada para esa temporalidad,
  la columna correspondiente vale `0` en esa fila (equivalente a
  `UNKNOWN`).
- El período del ZigZag (`period => 2`) es el mismo que usa por defecto
  `ZigzagInternal.pm` (y el indicador PineScript original en el que se
  basa); no está atado al parámetro `$length` (50) usado para los
  pivotes de `trend_ext`.
- `trend_int_*` es independiente de `trend_ext`: pueden coincidir o no en
  un momento dado, ya que responden a lógicas y temporalidades distintas
  (una recorre velas re-muestreadas con un zigzag de 2 barras; la otra
  corre sobre las velas base con pivotes de `length=50` velas y
  confirmación por ATR vía `SMC_Structures`).

# Lookup — Columna `nearest_fib_level`

Esta columna indica cuál de los 7 niveles de retroceso de Fibonacci
calculados por `Market::Indicators::Fibonacci` sobre el **último tramo del
zigzag externo** (los pivotes estructurales de
`Market::Indicators::SMC_Structures`, los mismos que alimentan `trend_ext`
/ `distance_hh` / `distance_ll`) está más cerca del `close` de esa vela, en
distancia de precio absoluta (sin normalizar por ATR).

- `datos.pl` llama a `$fib->calculate($smc->{structure})` en cada vela,
  reutilizando la lista de pivotes que ya va acumulando `$smc` (el mismo
  objeto `SMC_Structures` usado para `trend_ext`). Como `calculate()` solo
  mira los últimos dos elementos de esa lista, la llamada es O(1) por vela
  y no agrega costo relevante.
- Según el contrato de `Fibonacci.pm`, el **anchor** (nivel `0`) es el
  penúltimo pivote estructural (`$structure->[-2]`) y el **origin** (nivel
  `1000`) es el antepenúltimo (`$structure->[-3]`) — es decir, el tramo
  entre los dos pivotes estructurales confirmados inmediatamente
  anteriores al más reciente, no el tramo que incluye el pivote más
  reciente. Mientras no haya al menos 3 pivotes estructurales acumulados,
  `calculate()` no devuelve niveles y `nearest_fib_level` vale `0` (mismo
  valor de "sin datos todavía" que usa el resto de columnas del CSV, que
  coincide además con la etiqueta real del nivel `0%`; ver nota más
  abajo).
- Para cada nivel se calcula
  `price(nivel) = anchor_price + nivel * (origin_price - anchor_price)`,
  y se compara `abs(price(nivel) - close)` entre los 7 niveles; el valor
  guardado en `nearest_fib_level` es la etiqueta del nivel con la menor
  distancia absoluta al `close` de esa vela.

| Valor de `nearest_fib_level` | Nivel de Fibonacci |
|:---:|:---:|
| `0`     | `0%` (anchor, pivote más reciente de los dos usados) |
| `236`   | `23.6%` |
| `382`   | `38.2%` |
| `500`   | `50%` |
| `618`   | `61.8%` |
| `786`   | `78.6%` |
| `1000`  | `100%` (origin, pivote más antiguo de los dos usados) |

## Notas de implementación

- Los niveles y su orden son los que trae `Fibonacci.pm` por defecto
  (`[0, 0.236, 0.382, 0.5, 0.618, 0.786, 1]`); `datos.pl` no los
  reconfigura.
- Al igual que en `distance_hh`/`distance_ll`, el nivel más cercano **no**
  se recalcula solo en las velas donde ocurre un pivote: se recalcula en
  cada vela usando el `close` de esa vela, mientras que el anchor/origin
  (el tramo del zigzag externo) permanece fijo hasta que se confirma un
  nuevo pivote estructural.
- La comparación usa distancia de precio absoluta (`abs(price(nivel) -
  close)`), no distancia normalizada por ATR: como todos los niveles
  pertenecen al mismo tramo, el ATR es el mismo para los 7 y no afecta
  cuál resulta más cercano; por eso se omite esa normalización aquí (a
  diferencia de las columnas `distance_*` del resto del CSV).
- Si dos niveles quedan exactamente a la misma distancia del `close`
  (caso borde), `datos.pl` conserva el primero encontrado recorriendo los
  niveles en su orden por defecto (`0, 236, 382, 500, 618, 786, 1000`).
- Esta columna depende de los mismos pivotes estructurales que
  `distance_hh`/`distance_ll`/`trend_ext`, pero mientras esas usan
  directamente el precio del último HH o LL confirmado,
  `nearest_fib_level` usa el tramo completo entre los dos pivotes
  estructurales previos al más reciente (sin importar si son `HH`, `LH`,
  `HL` o `LL`), tal como lo define `Fibonacci.pm`.
- Esta columna reemplaza a las anteriores `distance_fib_0`,
  `distance_fib_236`, `distance_fib_382`, `distance_fib_500`,
  `distance_fib_618`, `distance_fib_786` y `distance_fib_1000` (7 columnas
  de distancia normalizada por ATR), que quedan eliminadas de
  `output.csv`.

# Lookup — Columnas `half_trend`, `distance_high_half_trend`, `distance_low_half_trend`

Estas columnas se derivan de `Market::Indicators::HalfTrend`, una
adaptación del indicador PineScript "Half Trend": una línea de tendencia
suavizada con su propio canal (`atr_high`/`atr_low`), calculada con un ATR
Wilder interno de período fijo (`atr_period => 100`), independiente del
ATR "del gráfico" (`$atr_values`) que usa el resto del script.

- `datos.pl` llama a `$halftrend->update_last(\@data, $atr_values, $i)`
  para cada vela `$i`, en orden cronológico (según el contrato incremental
  del módulo), y toma `$result->{values}[$i]` (el resultado de esa vela
  puntual).
- Mientras el ATR Wilder interno del indicador todavía está en
  calentamiento (menos de `atr_period` = 100 velas de historial), el
  módulo no tiene aún un `trend` confiable; en esas velas `half_trend`
  vale `0` (`UNKNOWN`) y `distance_high_half_trend`/
  `distance_low_half_trend` valen `0`.
- Una vez terminado el calentamiento, el campo `trend` del indicador (`0`
  = alcista, `1` = bajista en el propio módulo) se traduce a la
  convención del resto de columnas de tendencia de este CSV (`-1`/`0`/`1`).
- Para las distancias (`distance_high_half_trend`/
  `distance_low_half_trend`) se usa el ATR "del gráfico"
  (`Market::Indicators::ATR`, el mismo `$atr_values` que usan
  `distance_FVG`, `distance_ob`, `distance_hh`, etc.), **no** el ATR
  Wilder interno del propio `HalfTrend` — esto es intencional, para que
  todas las columnas `distance_*` del CSV compartan la misma escala/ATR de
  referencia. El canal (`atr_high`/`atr_low`) sí se calcula internamente
  con el ATR Wilder propio del indicador, tal como especifica el
  PineScript original; solo la conversión final a "distancia" usa el ATR
  del gráfico.

| Columna                        | Valor / Fórmula                                              | Descripción |
|----------------------------------|-----------------------------------------------------------------|-------------|
| `half_trend`                    | `1`=UP (`trend==0` en el módulo) · `-1`=DOWN (`trend==1`) · `0`=UNKNOWN (calentamiento del ATR Wilder interno) | Dirección vigente de HalfTrend. |
| `distance_high_half_trend`      | `(atr_high - close) / ATR`                                     | Distancia (en unidades del ATR del gráfico) entre la banda superior del canal HalfTrend y el `close`. `0` durante el calentamiento o si el ATR del gráfico es `0`. |
| `distance_low_half_trend`       | `(atr_low - close) / ATR`                                      | Distancia (en unidades del ATR del gráfico) entre la banda inferior del canal HalfTrend y el `close`. `0` durante el calentamiento o si el ATR del gráfico es `0`. |

## Notas de implementación

- `atr_high`/`atr_low` no son un rango fijo alrededor del precio: son
  `up ± dev` o `down ± dev` (según el `trend` vigente), donde `up`/`down`
  son la línea HalfTrend propiamente dicha y `dev` depende del ATR Wilder
  interno del indicador (`channel_deviation * atr2`). Ver `HalfTrend.pm`
  para el detalle completo de la lógica (replicada 1:1 del PineScript
  original).
- Un valor positivo en `distance_high_half_trend` indica que la banda
  superior del canal está por encima del cierre actual; análogamente para
  `distance_low_half_trend` con la banda inferior.
- Como el indicador necesita su propio historial completo de velas (no
  solo hasta la vela `$i`) para las ventanas de `highest`/`lowest`/`SMA`
  de `amplitude` barras, se le pasa siempre `\@data` completo, igual que
  con `ZigzagInternal`, `Structure`, `FVG`, `OrderBlocks` y `Liquidity`.

# Lookup — Columnas `super_trend`, `distance_high_super_trend`, `distance_low_super_trend`

Estas columnas se derivan de `Market::Indicators::Supertrend`, el
indicador clásico "SuperTrend" (bandas `up`/`dn` alrededor del precio,
basadas en ATR, con cambio de tendencia cuando el `close` las cruza).
Igual que `HalfTrend`, calcula su propio ATR interno (Wilder por defecto,
`change_atr => 1`), independiente del ATR "del gráfico" (`$atr_values`)
que usa el resto del script.

- `datos.pl` llama a `$supertrend->update_last(\@data, $atr_values, $i)`
  para cada vela `$i`, en orden cronológico, y toma
  `$result->{values}[$i]`.
- Mientras el ATR Wilder interno del indicador está en calentamiento
  (menos de `period` = 10 velas de historial), `super_trend` vale `0`
  (`UNKNOWN`) y las dos columnas de distancia valen `0`.
- A diferencia de `HalfTrend` (que usa `0`/`1` internamente y hay que
  traducir), el campo `trend` de `Supertrend.pm` ya usa la convención
  `1`=alcista / `-1`=bajista, igual que la columna `super_trend` del CSV;
  no hace falta ninguna conversión más allá del `0` de "UNKNOWN" durante
  el calentamiento.
- Para las distancias se usa el ATR "del gráfico" (el mismo `$atr_values`
  que el resto de columnas `distance_*`), no el ATR interno del propio
  `SuperTrend` — igual criterio que en `distance_high_half_trend` /
  `distance_low_half_trend`.
- `up` es la banda **inferior** (funciona como soporte durante una
  tendencia alcista) y `dn` es la banda **superior** (resistencia durante
  una tendencia bajista). El nombre de las columnas (`_high`/`_low`) se
  refiere a esa posición relativa de cada banda, no a si el mercado está
  en ese momento en tendencia alcista o bajista.

| Columna                          | Valor / Fórmula            | Descripción |
|-------------------------------------|-------------------------------|-------------|
| `super_trend`                       | `1`=UP · `-1`=DOWN · `0`=UNKNOWN (calentamiento del ATR interno) | Dirección vigente de SuperTrend. |
| `distance_high_super_trend`         | `(dn - close) / ATR`          | Distancia (en unidades del ATR del gráfico) entre la banda superior (`dn`) y el `close`. `0` durante el calentamiento o si el ATR del gráfico es `0`. |
| `distance_low_super_trend`          | `(up - close) / ATR`          | Distancia (en unidades del ATR del gráfico) entre la banda inferior (`up`) y el `close`. `0` durante el calentamiento o si el ATR del gráfico es `0`. |

## Notas de implementación

- Un valor positivo en `distance_high_super_trend` indica que la banda
  superior (`dn`) está por encima del cierre actual; análogamente para
  `distance_low_super_trend` con la banda inferior (`up`).
- `Supertrend.pm` es puramente incremental (O(1) por vela, no necesita
  ventanas hacia atrás como `HalfTrend`), pero se le pasa igualmente
  `\@data` completo para respetar el mismo contrato incremental
  (`update_last($candles, $atr_values, $i)`) que el resto de indicadores.

# Lookup — Columnas `range_filter`, `distance_high_range_filter`, `distance_low_range_filter`

Estas columnas se derivan de `Market::Indicators::RangeFilter`, que
replica fielmente la lógica PineScript del indicador "Range Filter"
(`smoothrng`/`rngfilt`, variante "Default"): una línea de filtro
(`filt`) que sigue al `close` con un "rango" de tolerancia (`smrng`)
calculado a partir de dos EMA anidadas sobre `|close - close[1]|`, y
dos contadores (`upward`/`downward`) de barras consecutivas en cada
dirección. A diferencia de `HalfTrend`/`Supertrend`, este indicador
**no** usa ningún ATR interno propio: `smrng` se calcula únicamente a
partir del `close`.

- `datos.pl` llama a `$range_filter->update_last(\@data, $atr_values, $i)`
  para cada vela `$i`, en orden cronológico (según el contrato
  incremental del módulo), y toma `$result->{values}[$i]`.
  `$atr_values` se pasa por uniformidad con el resto de indicadores pero
  el módulo lo ignora para su propio cálculo.
- El campo `trend` del indicador (`1`=`upward > 0`, `-1`=`downward > 0`,
  `0`=neutro, sólo posible en la primera vela antes de que exista un
  `filt[1]`) se usa directamente como valor de `range_filter`, sin
  necesidad de traducción.
- Para las distancias (`distance_high_range_filter`/
  `distance_low_range_filter`) se usa el ATR "del gráfico"
  (`Market::Indicators::ATR`, el mismo `$atr_values` que usan
  `distance_high_half_trend`, `distance_high_super_trend`, etc.), para
  mantener la misma escala/criterio que el resto de columnas
  `distance_*` del CSV. Si el ATR del gráfico es `0` en esa vela, ambas
  distancias quedan en `0`.

| Columna                          | Valor / Fórmula        | Descripción |
|-------------------------------------|-------------------------|-------------|
| `range_filter`                      | `1`=UP (`upward>0`) · `-1`=DOWN (`downward>0`) · `0`=UNKNOWN (sólo la primera vela) | Dirección vigente del Range Filter. |
| `distance_high_range_filter`        | `(hband - close) / ATR` | Distancia (en unidades del ATR del gráfico) entre la banda superior (`filt + smrng`) y el `close`. |
| `distance_low_range_filter`         | `(lband - close) / ATR` | Distancia (en unidades del ATR del gráfico) entre la banda inferior (`filt - smrng`) y el `close`. |

## Notas de implementación

- `hband`/`lband` no son un canal fijo alrededor del precio, sino
  `filt ± smrng`, donde `filt` es la propia línea Range Filter (que
  sigue al `close` con retardo/tolerancia) y `smrng` es el "rango
  suavizado" (EMA anidada de `|close - close[1]|`, escalado por
  `multiplier`). Ver `RangeFilter.pm` para el detalle completo de la
  lógica (replicada 1:1 del PineScript original, sección "Range
  Filter").
- Un valor positivo en `distance_high_range_filter` indica que la banda
  superior está por encima del cierre actual; análogamente para
  `distance_low_range_filter` con la banda inferior.
- `RangeFilter.pm` es puramente incremental (O(1) por vela, no necesita
  ventanas hacia atrás), pero se le pasa igualmente `\@data` completo
  para respetar el mismo contrato incremental
  (`update_last($candles, $atr_values, $i)`) que el resto de
  indicadores.
- El módulo también expone `buy_signal`/`sell_signal` (1 cuando `trend`
  pasa a `1`/`-1` respectivamente en esa barra), pero `datos.pl` no los
  vuelca a columnas propias del CSV; sólo usa `trend`, `hband` y
  `lband`.

# Lookup — Columnas `session_vwap_distance`, `open_vwap_distance`, `bos_vwap_distance`, `choch_vwap_distance`, `pivot_vwap_distance`

Estas cinco columnas se derivan de `Market::Indicators::VWAPAnchored` (VWAP
Anclado con bandas de desviación estándar), calculado con distintos
criterios de "ancla" (la vela desde la que se reinicia la acumulación del
VWAP). En todos los casos la columna guarda la distancia normalizada por
ATR entre el `vwap` de esa ancla y el `close` de la vela: `(vwap - close) /
ATR`, usando siempre el ATR "del gráfico" (`Market::Indicators::ATR`, el
mismo `$atr_values` que el resto de columnas `distance_*`). Un valor
positivo indica que el VWAP está por encima del cierre; negativo, que está
por debajo. Mientras el ancla correspondiente todavía no existe (por
ejemplo, antes del primer BOS/CHoCH/pivote de la serie), la columna vale
`0`.

| Columna                    | Ancla del VWAP                                                                 |
|-----------------------------|--------------------------------------------------------------------------------|
| `session_vwap_distance`     | Vela `0` de todo el histórico (VWAP acumulado desde el inicio de la serie, sin reiniciarse nunca). |
| `open_vwap_distance`        | Apertura de la última sesión de mercado vigente en esa vela, según `Market::MarketData->find_last_session_open_index($i)`. |
| `bos_vwap_distance`         | Vela del último **BOS externo** (`bos_ext`) confirmado hasta esa vela.         |
| `choch_vwap_distance`       | Vela del último **CHoCH externo** (`choch_ext`) confirmado hasta esa vela.     |
| `pivot_vwap_distance`       | Última vela marcada como **pivote** (`pivote`, alta o baja) hasta esa vela.    |

## Notas de implementación

- `datos.pl` calcula, para cada vela, el índice de ancla correspondiente a
  cada una de las 5 variantes:
  - `session_vwap_distance`: ancla fija en `0` para todas las velas.
  - `open_vwap_distance`: se llama a
    `$market_data->find_last_session_open_index($i)` para cada vela `$i`.
    Este método retrocede desde `$i` buscando el hueco de tiempo más
    grande entre dos velas consecutivas (mayor a 3 veces el intervalo
    "normal" de la temporalidad activa) y devuelve el índice de la
    primera vela posterior a ese hueco; si no encuentra ningún hueco
    relevante, devuelve `0` (la primera vela del histórico).
  - `bos_vwap_distance` / `choch_vwap_distance` / `pivot_vwap_distance`:
    se reutilizan las mismas señales que ya produce el script para
    `bos_ext`, `choch_ext` y `pivote` (ver secciones anteriores de este
    documento), guardando el índice de la última vela en la que cada una
    ocurrió (forward-fill).
- En vez de llamar a `VWAPAnchored->calculate_until()` vela a vela (lo cual
  recalcularía el VWAP completo desde el ancla en cada llamada, con costo
  cuadrático), `datos.pl` agrupa las velas consecutivas que comparten la
  misma ancla en un solo "segmento" y llama a `calculate_until()` una única
  vez por segmento (desde el ancla hasta el final del segmento), leyendo
  el `vwap` de cada vela del resultado devuelto. Esto mantiene el costo
  total en O(n) para las 5 columnas combinadas.
- Cada una de las 5 variantes usa su propia secuencia de anclas
  independiente; por ejemplo, `bos_vwap_distance` puede estar anclado en
  una vela distinta de `choch_vwap_distance` en el mismo momento, según
  cuál de los dos eventos (BOS o CHoCH externo) haya ocurrido más
  recientemente.
- `VWAPAnchored.pm` usa `hlc3` (`(high + low + close) / 3`) como precio
  típico para el cálculo del VWAP, tal como el indicador nativo de
  TradingView; no usa el `close` puro.
- Aunque `VWAPAnchored.pm` también calcula bandas de desviación estándar
  (`upper`/`lower`, `upper1..3`/`lower1..3`), `datos.pl` sólo vuelca a
  columnas del CSV la línea central (`vwap`); las bandas no se usan aquí.

# Lookup — Columnas `bars_since_bos`, `bars_since_choch`, `bars_since_fvg`, `bars_since_ob`, `bars_since_lq_event`

Estas cinco columnas indican cuántas velas han pasado desde el último
evento de cada tipo (0 = el evento ocurrió en la vela actual; 1 = ocurrió
en la vela anterior; etc.). Mientras el evento correspondiente todavía no
ha ocurrido ninguna vez en la serie, la columna vale `-1` (mismo criterio
de "sin datos todavía" que ya usa `lq_event`, para no confundirlo con "el
evento ocurrió hace 0 velas").

| Columna                 | Evento que cuenta                                                             |
|---------------------------|--------------------------------------------------------------------------------|
| `bars_since_bos`          | Último **BOS externo** (`bos_ext == 1`).                                      |
| `bars_since_choch`        | Último **CHoCH externo** (`choch_ext == 1`).                                  |
| `bars_since_fvg`          | Creación del último **Fair Value Gap** (según `created_index` de la zona más reciente reportada por `Market::Indicators::FVG`). |
| `bars_since_ob`           | Creación del último **Order Block** (según `created_index` de la zona más reciente reportada por `Market::Indicators::OrderBlocks`). |
| `bars_since_lq_event`     | Última resolución de liquidez (`lq_event != -1`: Sweep, Grab o Run — ver sección de `lq_event`). |

## Notas de implementación

- `bars_since_bos` y `bars_since_choch` reutilizan las mismas señales
  `bos_ext`/`choch_ext` que ya calcula `datos.pl` a partir de los eventos
  de `Market::Indicators::Structure` (ver sección `bos_ext`/`choch_ext`
  más arriba) — **externos**, no internos (`bos_int`/`choch_int` no
  tienen columna `bars_since_*` propia).
- `bars_since_fvg` y `bars_since_ob` usan el campo `created_index` de la
  zona más reciente devuelta por `FVG.pm`/`OrderBlocks.pm` en cada vela
  (el mismo campo que ya se documenta en las secciones de `inside_fvg` /
  `inside_order_block` para determinar "la zona más reciente"), en vez de
  contar simplemente cuándo cambia el tamaño de la lista de zonas — esto
  es intencional, ya que `created_index` es la vela real donde se originó
  la zona (puede no coincidir con la vela `$i` donde `update_last()`
  detecta/reporta esa zona por primera vez).
- `bars_since_lq_event` cuenta desde la última vela con `lq_event != -1`
  (una resolución de Sweep/Grab/Run sobre un nivel de liquidez BSL/SSL),
  no desde la creación del nivel de liquidez en sí.
- Las cinco columnas se calculan en un único recorrido final, O(n), sobre
  los arrays de eventos ya construidos (`bos_ext`, `choch_ext`,
  `fvg_created_index` por vela, `ob_created_index` por vela, `lq_event`),
  llevando el índice de la última ocurrencia de cada tipo a medida que se
  avanza cronológicamente.

# Lookup — Columnas `body`, `upper_wick`, `lower_wick`, `candle_type`, `momentum`, `lenght`

Estas seis columnas describen la geometría de cada vela individual (cuerpo,
mechas, tipo, momentum respecto al cierre anterior y largo total),
calculadas directamente a partir de `open`/`high`/`low`/`close` de esa
misma vela, sin depender de ningún indicador. Igual que `fvg_size` y
`atr (pip)`, se expresan en pips como precio absoluto multiplicado por
`pip_multiplier` (`10000`) — **no** como variación porcentual respecto al
cierre anterior, a diferencia de `open (pip)`/`high (pip)`/`low
(pip)`/`close (pip)`.

| Columna       | Fórmula                                              | Descripción |
|-----------------|---------------------------------------------------------|-------------|
| `body`          | `abs(close - open) * pip_multiplier`                     | Tamaño del cuerpo de la vela (distancia entre apertura y cierre), siempre `>= 0`. |
| `upper_wick`    | `(high - max(open, close)) * pip_multiplier`              | Tamaño de la mecha superior. |
| `lower_wick`    | `(min(open, close) - low) * pip_multiplier`               | Tamaño de la mecha inferior. |
| `candle_type`   | `1` si `close >= open` (vela alcista/bullish) · `-1` si `close < open` (vela bajista/bearish) | Signo del cuerpo de la vela. |
| `momentum`      | `(close[i] - close[i-1]) * pip_multiplier`                | Variación absoluta del cierre respecto a la vela anterior. |
| `lenght`        | `(high - low) * pip_multiplier`                           | Rango total de la vela (de punta a punta, mecha incluida). |

## Notas de implementación

- El nombre de columna `lenght` se mantiene tal cual (en vez de `length`)
  para seguir el nombre solicitado.
- `momentum` reutiliza la misma variable `$prev_close` que ya calcula
  `datos.pl` para `open (pip)`/`high (pip)`/`low (pip)`/`close (pip)`: es
  el `close` de la vela anterior, salvo en la primera vela de la serie
  (`$i == 0`), donde no existe una vela previa y se usa el `open` de la
  propia vela como sustituto (mismo criterio que el resto de columnas
  `*_pip`). Por eso `momentum` vale `0` únicamente si `open == close` en
  la primera vela.
- `candle_type` trata una vela **doji** (`close == open`, cuerpo `0`) como
  alcista (`1`), ya que la condición usada es `close >= open`.
- Estas columnas no dependen del ATR ni de ningún estado incremental entre
  velas (salvo `momentum`, que necesita el cierre de la vela anterior); se
  calculan directamente dentro del bucle final de escritura del CSV, sin
  ningún módulo `Market::Indicators::*` adicional.

# Lookup — Columnas `minute`, `hour`, `day`, `month`, `year`

Estas cinco columnas descomponen el campo `time` de cada vela (tal como
viene en `input.csv`) en sus componentes de calendario, usando el "reloj
de pared" (los componentes Y-M-D H:M:S tal cual aparecen en el CSV,
ignorando cualquier offset de zona horaria) — mismo criterio que usan
`build_tf_candles()` y las columnas `distance_daily_*`/`distance_weekly_*`/
`distance_monthly_*` para agrupar por día/semana/mes.

| Columna   | Valor                                                              |
|-------------|-----------------------------------------------------------------------|
| `minute`    | Minuto de la vela (`0`-`59`).                                         |
| `hour`      | Hora de la vela (`0`-`23`).                                           |
| `day`       | Día del mes de la vela (`1`-`31`).                                    |
| `month`     | Mes de la vela (`1`-`12`).                                            |
| `year`      | Año de la vela (4 dígitos, ej. `2024`).                                |

## Notas de implementación

- `datos.pl` reconoce dos formatos de `time`, igual que el resto del
  script (`_parse_epoch()`, usado para `trend_int_*`):
  - ISO `"YYYY-MM-DD[T ]HH:MM:SS..."` (o sólo `"YYYY-MM-DD"`, en cuyo caso
    `minute`/`hour` quedan en `0`): se extraen los componentes
    directamente por regex, sin pasar por `Time::Piece`/epoch, para no
    perder el reloj de pared (evita que un offset de zona horaria en el
    string, si lo hubiera, desplace la hora).
  - Timestamp epoch numérico (sólo dígitos): se usa `gmtime()` (UTC) para
    descomponerlo, igual que en la sección de `distance_daily_*` cuando
    `time` viene como epoch.
- Si el formato de `time` no es reconocible (o el campo viene vacío), las
  cinco columnas quedan en `0` para esa vela, igual que el resto de
  columnas del CSV que usan `0` como valor por defecto ante datos
  faltantes.
- A diferencia de las columnas `trend_int_*` (que sí usan epoch vía
  `Time::Piece`/`timegm` para agrupar en bloques de N minutos), aquí no se
  necesita aritmética de tiempo: sólo se leen los componentes de la fecha
  tal cual, por lo que el parseo es más simple y no requiere manejar
  segundos/husos horarios.
