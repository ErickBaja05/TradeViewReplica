# Orden de columnas en `output.csv`

Las columnas de `output.csv` están agrupadas por indicador/origen de datos. El orden actual es:

1. **Tiempo**: `minute`, `hour`, `day`, `month`, `year`.
2. **Vela** (OHLCV en pips relativos, geometría normalizada por ATR): `open (pip)`, `high (pip)`, `low (pip)`, `close (pip)`, `volume_ratio`, `atr (pct)`, `body`, `upper_wick`, `lower_wick`, `candle_type`, `momentum`, `lenght`.
3. **Pivotes**: `pivote`, `pivote3`, `pivote5`, `pivote10`, `pivote15`.
4. **Estructura de mercado** (`SMC_Structures`/`Structure`): `trend_ext`, `bos_ext`, `bos_int`, `choch_ext`, `choch_int`, `eqh`, `eql`, `bars_since_eqh`, `bars_since_eql`, `distance_eqh`, `distance_eql`, `bars_since_bos`, `distance_bos`, `bars_since_choch`, `distance_choch`.
5. **Fair Value Gaps** (`FVG`): `inside_fvg`, `distance_FVG`, `fvg_size`, `bars_since_fvg`.
6. **Order Blocks** (`OrderBlocks`): `inside_order_block`, `distance_ob`, `ob_type`, `bars_since_ob`.
7. **Último HH/LL confirmado** (`SMC_Structures`): `distance_hh`, `distance_ll`.
8. **Fibonacci** (`Fibonacci`): `nearest_fib_level`.
9. **Niveles MTF** (alto/bajo del período anterior): `distance_daily_high`, `distance_daily_low`, `distance_weekly_high`, `distance_weekly_low`, `distance_monthly_high`, `distance_monthly_low`.
10. **Liquidez y swings menores** (`Liquidity`): `distance_bsl`, `distance_ssl`, `lq_sweep_bsl`, `lq_sweep_ssl`, `lq_grab`, `lq_run`, `bars_since_lq_event`, `is_sh`, `is_sl`, `distance_sh`, `distance_sl`.
11. **Tendencia interna multi-temporalidad** (`ZigzagInternal` re-muestreado): `trend_int_15min`, `trend_int_30min`, `trend_int_1hr`, `trend_int_2hr`, `trend_int_4hr`.
12. **HalfTrend**: `half_trend`, `distance_high_half_trend`, `distance_low_half_trend`.
13. **SuperTrend**: `super_trend`, `distance_high_super_trend`, `distance_low_super_trend`.
14. **Range Filter**: `range_filter`, `distance_high_range_filter`, `distance_low_range_filter`.
15. **VWAP Anclado** (`VWAPAnchored`): `session_vwap_distance`, `open_vwap_distance`, `bos_vwap_distance`, `choch_vwap_distance`, `pivot_vwap_distance`.
16. **Volume Profile Anclado** (`VolumeProfileAnchored`): `poc`, `vah`, `val`.

El resto de este documento describe el significado de cada columna agrupado por tema; no necesariamente en el mismo orden en que aparecen en `output.csv`, pero cada sección corresponde a uno de los bloques listados arriba.

---

# Lookup — Columna `trend_ext`

Equivalencia entre el estado de tendencia calculado por `Market::Indicators::SMC_Structures` (campo `trend` del objeto) y el valor numérico guardado en la columna `trend_ext` de `output.csv`. Se llama `trend_ext` (tendencia "externa" o estructural) para distinguirla de las columnas `trend_int_*` (tendencia interna por temporalidad, ver más abajo), que usan un zigzag más sensible sobre velas re-muestreadas.

| Tendencia (SMC_Structures) | Valor en `trend_ext` | Descripción |
|-----------------------------|:-------------------:|-------------|
| `DOWN` | `-1` | Estructura de mercado bajista (tras un CHoCH/BOS a la baja) |
| `UNKNOWN` | `0` | Aún no se ha determinado una tendencia (fase inicial, antes del primer HH/LL) |
| `UP` | `1` | Estructura de mercado alcista (tras un CHoCH/BOS al alza) |

## Notas de implementación

- `datos.pl` recorre las velas en orden cronológico y, en cada índice marcado como pivote (`is_high_pivot` / `is_low_pivot`), llama a `Market::Indicators::SMC_Structures->update_last()` con:
  - `type`: `HIGH` o `LOW`.
  - `price`: el `high` o `low` de la vela pivote.
  - `index`: índice de la vela.
  - `atr`: valor de ATR (en precio absoluto, no en pips) de esa vela, usado internamente por el módulo para el umbral de ruptura (`choch_atr_mult`).
- El valor de `trend_ext` se propaga (forward-fill) a todas las velas intermedias entre pivotes: cada fila guarda la tendencia vigente en ese momento, no solo las filas donde ocurre un pivote.
- Si una vela es simultáneamente pivote de `HIGH` y de `LOW`, se procesa primero el evento `HIGH` y luego el `LOW`.

---

# Lookup — Columnas `pivote3`, `pivote5`, `pivote10`, `pivote15`

Estas columnas indican la proporción de pivotes (`is_pivot`, alta o baja) que aparecen en las próximas velas, mirando hacia adelante desde la vela actual. **Están normalizadas en el rango `[0, 1]`**.

| Columna | Ventana | Fórmula | Rango |
|---------|---------|---------|-------|
| `pivote3` | Próximas 3 velas (`i+1` a `i+3`) | `conteo_de_pivotes / 3` | `0` – `1` |
| `pivote5` | Próximas 5 velas (`i+1` a `i+5`) | `conteo_de_pivotes / 5` | `0` – `1` |
| `pivote10` | Próximas 10 velas (`i+1` a `i+10`) | `conteo_de_pivotes / 10` | `0` – `1` |
| `pivote15` | Próximas 15 velas (`i+1` a `i+15`) | `conteo_de_pivotes / 15` | `0` – `1` |

## Notas de implementación

- `datos.pl` recorre `$j` de `1` a `15` y, por cada `j` en el que `is_pivot[$i + $j]` es `1`, incrementa el contador correspondiente a cada ventana. Al final, cada contador se divide por el tamaño de su ventana.
- Si la vela `i` está a menos de 15 velas del final de la serie (`$i + $j >= $total_rows`), el bucle se corta antes (`last`), por lo que las últimas filas del CSV reflejan un conteo parcial (menos velas futuras disponibles para contar).
- `pivote` (sin sufijo numérico) sigue siendo la columna binaria original: vale `1` si la vela `i` misma es un pivote confirmado, `0` si no.

---

# Lookup — Columnas `volume_ratio`

Esta columna contiene el volumen relativo de cada vela comparado con el promedio de las últimas `VOLUME_SMA_PERIOD` velas (20 por defecto).

| Columna | Fórmula | Descripción |
|---------|---------|-------------|
| `volume_ratio` | `volumen_vela / promedio_móvil_volumen(20)` | `1` = volumen igual al promedio, `> 1` = por encima del promedio, `< 1` = por debajo del promedio. |

## Notas de implementación

- Se usa una suma prefijo para que el costo total sea O(n) en vez de O(n * VOLUME_SMA_PERIOD).
- El promedio se calcula incluyendo la vela actual, sin mirar al futuro.

---

# Lookup — Columna `atr (pct)`

Esta columna contiene el ATR (Average True Range) expresado como porcentaje del precio de cierre de la vela.

| Columna | Fórmula | Descripción |
|---------|---------|-------------|
| `atr (pct)` | `ATR / close` | ATR en unidades de precio absoluto dividido por el precio de cierre. Durante el periodo de calentamiento del ATR (menos de `atr_period` = 14 velas), el valor es `0`. |

## Notas de implementación

- El ATR se calcula con `Market::Indicators::ATR` sobre precios absolutos.
- Se guarda como porcentaje para que sea comparable entre activos con precios distintos.
- A diferencia de versiones anteriores, **no** se expresa en pips.

---

# Lookup — Columnas `body`, `upper_wick`, `lower_wick`, `candle_type`, `momentum`, `lenght`

Estas seis columnas describen la geometría de cada vela individual, **normalizadas por el ATR** de esa vela (a diferencia de versiones anteriores, que usaban pips absolutos). Esto las hace comparables entre distintos regímenes de volatilidad.

| Columna | Fórmula | Descripción |
|---------|---------|-------------|
| `body` | `abs(close - open) / ATR` | Tamaño del cuerpo de la vela (distancia entre apertura y cierre), en unidades de ATR. `0` si ATR = 0. |
| `upper_wick` | `(high - max(open, close)) / ATR` | Tamaño de la mecha superior, en unidades de ATR. `0` si ATR = 0. |
| `lower_wick` | `(min(open, close) - low) / ATR` | Tamaño de la mecha inferior, en unidades de ATR. `0` si ATR = 0. |
| `candle_type` | `1` si `close >= open` (vela alcista/bullish) · `-1` si `close < open` (vela bajista/bearish) | Signo del cuerpo de la vela. |
| `momentum` | `(close - close_anterior) / ATR` | Variación del cierre respecto a la vela anterior, en unidades de ATR. `0` si ATR = 0. |
| `lenght` | `(high - low) / ATR` | Rango total de la vela (de punta a punta), en unidades de ATR. `0` si ATR = 0. |

## Notas de implementación

- El nombre de columna `lenght` se mantiene tal cual (en vez de `length`) para seguir el nombre solicitado.
- `momentum` reutiliza la misma variable `$prev_close` que ya calcula `datos.pl` para `open (pip)`/`high (pip)`/`low (pip)`/`close (pip)`: es el `close` de la vela anterior, salvo en la primera vela de la serie (`$i == 0`), donde no existe una vela previa y se usa el `open` de la propia vela como sustituto.
- `candle_type` trata una vela **doji** (`close == open`, cuerpo `0`) como alcista (`1`).

---

# Lookup — Columnas `open (pip)`, `high (pip)`, `low (pip)`, `close (pip)`

Estas columnas contienen los precios OHLC expresados como variación porcentual (pips) respecto al cierre de la vela anterior.

| Columna | Fórmula | Descripción |
|---------|---------|-------------|
| `open (pip)` | `(open - close_anterior) / close_anterior * 10000` | Apertura de la vela en pips relativos. |
| `high (pip)` | `(high - close_anterior) / close_anterior * 10000` | Máximo de la vela en pips relativos. |
| `low (pip)` | `(low - close_anterior) / close_anterior * 10000` | Mínimo de la vela en pips relativos. |
| `close (pip)` | `(close - close_anterior) / close_anterior * 10000` | Cierre de la vela en pips relativos. |

## Notas de implementación

- `pip_multiplier = 10000`.
- En la primera vela de la serie (`$i == 0`), se usa el `open` de la propia vela como referencia en lugar de `close_anterior`.
- Estos pips son **relativos** (variación porcentual), no pips absolutos de precio.

---

# Lookup — Columnas booleanas de estructura de mercado (0 / 1)

Las siguientes columnas son indicadores binarios: `1` significa que el evento/condición existe en esa vela, `0` que no existe.

| Columna | Significa `1` |
|---------|---------------|
| `pivote` | La vela es un pivote (máximo o mínimo) detectado por la lógica de pivotes del script. |
| `bos_ext` | Ocurre un **BOS (Break of Structure)** en la estructura **externa** (swing), detectado por `Market::Indicators::Structure`. |
| `bos_int` | Ocurre un **BOS** en la estructura **interna**, detectado por `Market::Indicators::Structure`. |
| `choch_ext` | Ocurre un **CHoCH (Change of Character)** en la estructura **externa** (swing), detectado por `Market::Indicators::Structure`. |
| `choch_int` | Ocurre un **CHoCH** en la estructura **interna**, detectado por `Market::Indicators::Structure`. |
| `eqh` | Se detecta un **Equal High** (dos máximos externos igualados dentro del umbral `eq_threshold * ATR`), detectado por `Market::Indicators::Structure`. |
| `eql` | Se detecta un **Equal Low** (dos mínimos externos igualados dentro del umbral `eq_threshold * ATR`), detectado por `Market::Indicators::Structure`. |

### Notas sobre `bos_ext`, `bos_int`, `choch_ext`, `choch_int`, `eqh`, `eql`

- `datos.pl` llama a `Market::Indicators::Structure->update_last(\@data, $atr_values, $i)` para cada vela `$i`, en orden cronológico. El módulo mantiene su propio estado interno (leg externo/interno, pivotes, tendencia) y va acumulando eventos en `$structure->{events}`.
- Cada evento trae un `index` que indica en qué vela ocurrió. Para `BOS_*` y `CHoCH_*` ese índice es la vela donde el precio cruza el nivel (la vela actual del bucle). Para `EQH`/`EQL` el índice corresponde a la vela pivote central detectada (`i - eq_len`), que puede ser anterior a la vela donde se confirma la igualdad.
- `tier => 'external'` marca eventos de la estructura de swing (mayor tamaño, `swing_size`); `tier => 'internal'` marca eventos de la estructura interna (menor tamaño, `internal_size`).

---

# Lookup — Columnas `bars_since_eqh`, `bars_since_eql`

Estas columnas cuentan las velas transcurridas desde el último `eqh` o `eql`, **normalizadas en el rango `[0, 1]`**.

| Columna | Fórmula | Descripción |
|---------|---------|-------------|
| `bars_since_eqh` | `min(velas_desde_ultimo_EQH, 100) / 100` | `0` = EQH ocurrió en la vela actual, `1` = EQH ocurrió hace 100 velas o más, o aún no ha ocurrido. |
| `bars_since_eql` | `min(velas_desde_ultimo_EQL, 100) / 100` | `0` = EQL ocurrió en la vela actual, `1` = EQL ocurrió hace 100 velas o más, o aún no ha ocurrido. |

## Notas de implementación

- El tope de normalización es `BARS_SINCE_CAP = 100`.
- Mientras el evento correspondiente no haya ocurrido todavía en la serie, el valor es `1` (el valor más alto posible).

---

# Lookup — Columnas `distance_eqh`, `distance_eql`

Estas columnas son la distancia normalizada por ATR entre el nivel del Equal High/Equal Low y el `close` de la vela actual.

| Columna | Fórmula | Descripción |
|---------|---------|-------------|
| `distance_eqh` | `(high_del_EQH - close) / ATR` | Distancia en unidades de ATR. Mientras no haya EQH confirmado o ATR = 0, el valor es `0`. |
| `distance_eql` | `(low_del_EQL - close) / ATR` | Distancia en unidades de ATR. Mientras no haya EQL confirmado o ATR = 0, el valor es `0`. |

---

# Lookup — Columnas `bars_since_bos`, `bars_since_choch`

Estas columnas cuentan las velas transcurridas desde el último `bos_ext` o `choch_ext`, **normalizadas en el rango `[0, 1]`**.

| Columna | Fórmula | Descripción |
|---------|---------|-------------|
| `bars_since_bos` | `min(velas_desde_ultimo_BOS, 100) / 100` | `0` = BOS ocurrió en la vela actual, `1` = BOS ocurrió hace 100 velas o más, o aún no ha ocurrido. |
| `bars_since_choch` | `min(velas_desde_ultimo_CHoCH, 100) / 100` | `0` = CHoCH ocurrió en la vela actual, `1` = CHoCH ocurrió hace 100 velas o más, o aún no ha ocurrido. |

## Notas de implementación

- Reutilizan las mismas señales `bos_ext`/`choch_ext` que ya calcula `datos.pl` a partir de los eventos de `Market::Indicators::Structure`.
- El tope de normalización es `BARS_SINCE_CAP = 100`.

---

# Lookup — Columnas `distance_bos`, `distance_choch`

Estas columnas son la distancia normalizada por ATR entre el `close` de la vela donde ocurrió el último BOS/CHoCH externo y el `close` de la vela actual.

| Columna | Fórmula | Descripción |
|---------|---------|-------------|
| `distance_bos` | `(close_del_BOS - close) / ATR` | Distancia en unidades de ATR. Mientras no haya BOS confirmado o ATR = 0, el valor es `0`. |
| `distance_choch` | `(close_del_CHoCH - close) / ATR` | Distancia en unidades de ATR. Mientras no haya CHoCH confirmado o ATR = 0, el valor es `0`. |

## Notas de implementación

- Se usa el `close` de la vela ancla (y no su `high`/`low`) porque el índice del evento BOS/CHoCH corresponde a la vela donde el precio **cruza** el nivel roto, no a la vela del nivel en sí.

---

# Lookup — Columnas `inside_fvg`, `distance_FVG`, `fvg_size`

Estas tres columnas describen la relación entre el cierre de cada vela y el **Fair Value Gap (FVG)** más reciente detectado hasta ese momento por `Market::Indicators::FVG`.

| Columna | Significado |
|---------|-------------|
| `inside_fvg` | `1` si el `close` de la vela cae dentro de los límites `[bottom, top]` del FVG más reciente, `0` si está fuera (o si aún no existe ningún FVG). |
| `distance_FVG` | Distancia normalizada por ATR entre el centro del FVG más reciente y el `close`: `(centro_fvg - close) / ATR`. `0` si ATR = 0 o no existe FVG. |
| `fvg_size` | Tamaño de la zona del FVG más reciente, en unidades de ATR: `(top - bottom) / ATR`. `0` si ATR = 0 o no existe FVG. |

## Notas de implementación

- El "FVG más reciente" se determina por orden de creación (`created_index`), no por su estado de mitigación.
- `fvg_size` se expresa en unidades de ATR (no en pips) para mantener la consistencia con las demás columnas normalizadas.

---

# Lookup — Columnas `inside_order_block`, `distance_ob`, `ob_type`

Estas columnas describen la relación entre el cierre de cada vela y el **Order Block** más reciente detectado hasta ese momento por `Market::Indicators::OrderBlocks`.

| Columna | Significado |
|---------|-------------|
| `inside_order_block` | `1` si el `close` de la vela cae dentro de los límites `[bottom, top]` del Order Block más reciente, `0` si está fuera (o si aún no existe ninguno). |
| `distance_ob` | Distancia normalizada por ATR entre el `poi` del Order Block más reciente y el `close`: `(poi - close) / ATR`. `0` si ATR = 0 o no existe Order Block. |
| `ob_type` | Tipo del Order Block más reciente: `1` si es `SUPPLY`, `-1` si es `DEMAND`, `0` si no existe ninguno. |

---

# Lookup — Columnas `bars_since_fvg`, `bars_since_ob`

Estas columnas cuentan las velas transcurridas desde la creación del último FVG u Order Block, **normalizadas en el rango `[0, 1]`**.

| Columna | Fórmula | Descripción |
|---------|---------|-------------|
| `bars_since_fvg` | `min(velas_desde_creacion_FVG, 100) / 100` | `0` = FVG creado en la vela actual, `1` = creado hace 100 velas o más, o aún no existe. |
| `bars_since_ob` | `min(velas_desde_creacion_OB, 100) / 100` | `0` = Order Block creado en la vela actual, `1` = creado hace 100 velas o más, o aún no existe. |

## Notas de implementación

- Usan el campo `created_index` de la zona más reciente (la vela real donde se originó la zona).
- El tope de normalización es `BARS_SINCE_CAP = 100`.

---

# Lookup — Columnas `distance_hh`, `distance_ll`

Estas columnas describen la distancia normalizada por ATR entre el cierre de cada vela y el precio del **HH (Higher High)** y del **LL (Lower Low)** más recientes.

| Columna | Fórmula | Descripción |
|---------|---------|-------------|
| `distance_hh` | `(HH_mas_reciente - close) / ATR` | Distancia en unidades de ATR. `0` si aún no se ha confirmado ningún HH, o ATR = 0. |
| `distance_ll` | `(LL_mas_reciente - close) / ATR` | Distancia en unidades de ATR. `0` si aún no se ha confirmado ningún LL, o ATR = 0. |

---

# Lookup — Columna `nearest_fib_level`

Esta columna indica cuál de los 7 niveles de retroceso de Fibonacci está más cerca del `close` de esa vela.

| Valor de `nearest_fib_level` | Nivel de Fibonacci |
|:---:|:---:|
| `0` | `0%` (anchor) |
| `236` | `23.6%` |
| `382` | `38.2%` |
| `500` | `50%` |
| `618` | `61.8%` |
| `786` | `78.6%` |
| `1000` | `100%` (origin) |

---

# Lookup — Columnas MTF (Multi Time Frame)

Estas seis columnas describen la distancia normalizada por ATR entre el cierre de cada vela y los niveles del período anterior.

| Columna | Nivel usado |
|---------|-------------|
| `distance_daily_high` | `PDH` (máximo del día anterior) |
| `distance_daily_low` | `PDL` (mínimo del día anterior) |
| `distance_weekly_high` | `PWH` (máximo de la semana anterior) |
| `distance_weekly_low` | `PWL` (mínimo de la semana anterior) |
| `distance_monthly_high` | `PMH` (máximo del mes anterior) |
| `distance_monthly_low` | `PML` (mínimo del mes anterior) |

## Notas de implementación

- `datos.pl` replica la lógica de `Market::Indicators::Levels` de forma incremental (O(n) en total).
- Se usa el ATR "del gráfico" para la normalización.

---

# Lookup — Columnas de Liquidez

## `distance_bsl`, `distance_ssl`

| Columna | Fórmula | Descripción |
|---------|---------|-------------|
| `distance_bsl` | `(BSL_mas_reciente - close) / ATR` | Distancia en unidades de ATR. `0` si aún no se ha creado ningún BSL, o ATR = 0. |
| `distance_ssl` | `(SSL_mas_reciente - close) / ATR` | Distancia en unidades de ATR. `0` si aún no se ha creado ningún SSL, o ATR = 0. |

## `lq_sweep_bsl`, `lq_sweep_ssl`, `lq_grab`, `lq_run`

Estas cuatro columnas son indicadores binarios (0/1) que marcan la vela exacta donde ocurre cada tipo de resolución de liquidez.

| Columna | Significa `1` |
|---------|---------------|
| `lq_sweep_bsl` | Sweep sobre un nivel BSL (barrido al alza) en esa vela. |
| `lq_sweep_ssl` | Sweep sobre un nivel SSL (barrido a la baja) en esa vela. |
| `lq_grab` | Grab (falso breakout, reversión antes de `confirm_bars`) en esa vela. |
| `lq_run` | Run (continuación, cierra más allá del nivel durante `confirm_bars`) en esa vela. |

## `bars_since_lq_event`

Esta columna cuenta las velas transcurridas desde la última resolución de liquidez (cualquier tipo), **normalizada en el rango `[0, 1]`**.

| Columna | Fórmula | Descripción |
|---------|---------|-------------|
| `bars_since_lq_event` | `min(velas_desde_ultimo_evento_liquidez, 100) / 100` | `0` = evento en la vela actual, `1` = evento hace 100 velas o más, o aún no ha ocurrido. |

## `is_sh`, `is_sl`, `distance_sh`, `distance_sl`

Estas columnas se derivan de los **pivotes menores** (`minor_pivots`) de `Market::Indicators::Liquidity`.

| Columna | Descripción |
|---------|-------------|
| `is_sh` | `1` si esa vela es un swing high (pivote menor de tipo `HIGH`) ya confirmado, `0` si no. |
| `is_sl` | `1` si esa vela es un swing low (pivote menor de tipo `LOW`) ya confirmado, `0` si no. |
| `distance_sh` | `(SH_mas_reciente - close) / ATR` en unidades de ATR. `0` si no hay SH o ATR = 0. |
| `distance_sl` | `(SL_mas_reciente - close) / ATR` en unidades de ATR. `0` si no hay SL o ATR = 0. |

---

# Lookup — Columnas `trend_int_*` (tendencia interna multi-temporalidad)

| Columna | Temporalidad |
|---------|--------------|
| `trend_int_15min` | 15 minutos |
| `trend_int_30min` | 30 minutos |
| `trend_int_1hr` | 1 hora |
| `trend_int_2hr` | 2 horas |
| `trend_int_4hr` | 4 horas |

| Valor | Significado |
|:-----:|-------------|
| `-1` | `DOWN`: el último pivote del ZigZag fue un pivote bajo. |
| `0` | `UNKNOWN`: todavía no se ha confirmado ningún pivote. |
| `1` | `UP`: el último pivote del ZigZag fue un pivote alto. |

---

# Lookup — Columnas de HalfTrend, SuperTrend y Range Filter

## HalfTrend

| Columna | Descripción |
|---------|-------------|
| `half_trend` | `1`=UP · `-1`=DOWN · `0`=UNKNOWN (calentamiento del ATR Wilder interno) |
| `distance_high_half_trend` | `(atr_high - close) / ATR` (en unidades de ATR del gráfico) |
| `distance_low_half_trend` | `(atr_low - close) / ATR` (en unidades de ATR del gráfico) |

## SuperTrend

| Columna | Descripción |
|---------|-------------|
| `super_trend` | `1`=UP · `-1`=DOWN · `0`=UNKNOWN (calentamiento del ATR interno) |
| `distance_high_super_trend` | `(dn - close) / ATR` (en unidades de ATR del gráfico) |
| `distance_low_super_trend` | `(up - close) / ATR` (en unidades de ATR del gráfico) |

## Range Filter

| Columna | Descripción |
|---------|-------------|
| `range_filter` | `1`=UP (`upward>0`) · `-1`=DOWN (`downward>0`) · `0`=UNKNOWN (sólo la primera vela) |
| `distance_high_range_filter` | `(hband - close) / ATR` (en unidades de ATR del gráfico) |
| `distance_low_range_filter` | `(lband - close) / ATR` (en unidades de ATR del gráfico) |

---

# Lookup — Columnas de VWAP Anclado

| Columna | Ancla del VWAP |
|---------|----------------|
| `session_vwap_distance` | Vela `0` de todo el histórico (VWAP desde el inicio). |
| `open_vwap_distance` | Apertura de la última sesión de mercado vigente en esa vela. |
| `bos_vwap_distance` | Vela del último **BOS externo** (`bos_ext`) confirmado. |
| `choch_vwap_distance` | Vela del último **CHoCH externo** (`choch_ext`) confirmado. |
| `pivot_vwap_distance` | Última vela marcada como **pivote** (`pivote`) hasta esa vela. |

Todas usan la fórmula: `distance = (vwap - close) / ATR`.

---

# Lookup — Columnas de Volume Profile Anclado

| Columna | Nivel |
|---------|-------|
| `poc` | **POC** (Point of Control): precio central de la franja con mayor volumen acumulado del tramo anclado. |
| `vah` | Límite superior de la zona de valor de 1 sigma: media + 1 desviación estándar. |
| `val` | Límite inferior de la zona de valor de 1 sigma: media - 1 desviación estándar. |

Todas usan la fórmula: `(nivel - close) / ATR`.

## Notas de implementación

- El ancla es la última vela de cambio de tendencia (`trend_ext` cambia de valor respecto a la vela anterior).
- Se llama a `calculate_until()` una vez por cada vela (ventana expansiva desde el ancla hasta la vela actual), por lo que el costo es O(largo²) en el peor caso.

---

# Lookup — Columnas `minute`, `hour`, `day`, `month`, `year`

Estas cinco columnas descomponen el campo `time` de cada vela en sus componentes de calendario.

| Columna | Valor |
|---------|-------|
| `minute` | Minuto de la vela (`0`-`59`). |
| `hour` | Hora de la vela (`0`-`23`). |
| `day` | Día del mes de la vela (`1`-`31`). |
| `month` | Mes de la vela (`1`-`12`). |
| `year` | Año de la vela (4 dígitos). |

## Notas de implementación

- `datos.pl` reconoce dos formatos de `time`: ISO `"YYYY-MM-DD[T ]HH:MM:SS..."` o timestamp epoch numérico.
- Si el formato no es reconocible, las cinco columnas quedan en `0`.
