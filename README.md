# Sistemas XAUUSD — EA (MT5) + Indicador (TradingView)

Dos sistemas independientes, sobre **oro (XAUUSD)** únicamente:

1. **Session Opening Range Breakout** — ruptura del rango de apertura de sesión (Asia → Londres, pre-NY → NY).
2. **Trendline Break (Stop & Reverse)** — ruptura de líneas de tendencia dinámicas basadas en pivotes, con puntos verdes/rojos en el gráfico, igual al concepto de osciladores tipo "Trendlines with Breaks" pero con código propio para poder automatizarlo sin depender de indicadores de terceros.

---

# 1. Session Opening Range Breakout

## Lógica (idéntica en ambas versiones)

1. **Sesión A** (por defecto: rango asiático 00:00–07:00, ventana de operación 07:00–11:00 — apertura de Londres).
2. **Sesión B** (por defecto: rango pre-NY 11:00–13:30, ventana de operación 13:30–17:00 — apertura de Nueva York / COMEX, incluye la hora típica de datos macro de EE.UU. 13:30 UTC).
3. Se marca el máximo/mínimo de cada rango. En la ventana de operación, si el **cierre de una vela** rompe el rango (+ buffer de confirmación), se evalúan las confluencias:
   - **Filtro de tendencia**: EMA rápida vs EMA lenta en timeframe superior (H1 por defecto) — solo se opera a favor de la tendencia.
   - **Filtro de volatilidad ATR**: el tamaño del rango debe estar entre 0.5×ATR y 3×ATR (evita rangos muertos o gaps extremos).
   - **Filtro de máximo/mínimo del día anterior**: no se persigue una ruptura ya muy extendida más allá del rango del día previo.
4. Si pasa todos los filtros habilitados → entrada.
   - **SL** = ATR × 1.5 (configurable).
   - **TP** = distancia del SL × ratio riesgo:beneficio (3, 4 o 5 — configurable, por defecto 4).
   - **Tamaño de posición** = % de riesgo de la cuenta (MT5) / 100% del equity para backtest limpio (TradingView).
   - **Breakeven + trailing por ATR** una vez alcanzado 1R (solo EA de MT5).
5. Máximo una operación por sesión por día.

## Archivos entregados

- [XAUUSD_SessionBreakout_EA.mq5](XAUUSD_SessionBreakout_EA.mq5) — Expert Advisor para MetaTrader 5, opera automáticamente.
- [XAUUSD_SessionBreakout.pine](XAUUSD_SessionBreakout.pine) — Script Pine v5 para TradingView (`strategy()`), dibuja el rango, las entradas, SL y TP en el gráfico, y corre backtest con curva de equity.
- Este README.

## Instalación — MT5

1. Abre MetaEditor (F4 desde MT5), `Archivo → Abrir`, selecciona `XAUUSD_SessionBreakout_EA.mq5` (o cópialo a `MQL5/Experts/`).
2. Compila (F7). No debería haber errores.
3. Arrástralo a un gráfico de XAUUSD (o el símbolo de oro de tu bróker, ej. `XAUUSD`, `GOLD`, `XAUUSD.m`).
4. **Importante**: revisa el desfase horario del servidor de tu bróker respecto a UTC/GMT y ajusta las horas de `Session A` / `Session B` en los inputs para que realmente coincidan con la sesión asiática / pre-NY reales.
5. Prueba primero en **Strategy Tester** (modo "Every tick based on real ticks") y luego en cuenta demo antes de considerar real.

## Instalación — TradingView

1. Abre el gráfico de XAUUSD (o `OANDA:XAUUSD`, `COMEX:GC1!`, etc.) en Pine Editor.
2. Pega el contenido de `XAUUSD_SessionBreakout.pine`, guarda y agrégalo al gráfico.
3. Ajusta el input `tz` y las horas de sesión para que coincidan con la sesión que quieras operar.
4. Usa la pestaña **Strategy Tester** de TradingView para ver estadísticas del backtest.
5. **Sobre automatización real desde TradingView**: TradingView no ejecuta órdenes en un bróker por sí solo. El script incluye `alertcondition()` para long/short — si quieres automatizar, necesitas configurar una alerta que envíe un webhook a un puente/bot que ejecute la orden en tu bróker (por ejemplo, un servicio en VPS conectado a MT5/tu bróker). El EA de MT5 sí opera de forma nativa y automática sin necesidad de ningún puente.

## Notas importantes

- **Ningún parámetro aquí es una garantía de rentabilidad.** Los valores por defecto (EMA 50/200 en H1, ATR 14, SL=1.5×ATR, RR=4, riesgo 1%) son puntos de partida razonables para oro en temporalidad baja, pero **debes optimizar y validar con backtest + forward test en demo** antes de arriesgar capital real.
- El requisito de "todas las confluencias posibles" hace la estrategia más selectiva (menos señales, mayor calidad esperada) — si ves muy pocas operaciones en el backtest, es el comportamiento esperado; puedes relajar un filtro a la vez para evaluar el impacto.
- El spread y el slippage en oro pueden ser altos en momentos de noticias — el EA incluye un filtro de spread máximo (`MaxSpreadPoints`) para evitar entrar en esos momentos.
- Ajusta `ConfirmationBufferPoints` (MT5, en puntos) y `buffer` (Pine, en dólares) según la volatilidad típica de tu bróker para oro.

---

# 2. Trendline Break (Stop & Reverse)

Nace de la pregunta: "¿cómo automatizo entradas cuando aparece un punto verde/rojo en un oscilador de ruptura de líneas de tendencia (tipo LuxAlgo)?". Respuesta corta: **no se puede "escuchar" directamente los puntos de un indicador de terceros** desde otro script — en Pine, `input.source()` solo puede leer valores dibujados con `plot()`, y esos puntos casi siempre se dibujan con `plotshape()`/`plotchar()`, que no son enlazables. Por eso se construyó una versión propia, con la misma idea visual y de trading, pero de código 100% nuestro y totalmente automatizable.

**Multi-instrumento**: aunque nació para XAUUSD, el EA (`TrendlineBreak_EA.mq5`) ya no exige un símbolo específico — se ha validado también en índices como US30. Ajusta los parámetros (buffer, ATR, tolerancia de toque) por instrumento, ya que el comportamiento de precio no es igual en oro que en índices.

## Lógica (v2 — "reacción en la línea")

1. Se detectan pivotes de máximo/mínimo confirmados (`PivotLookback` velas a cada lado).
2. Se traza una línea de resistencia por los 2 últimos pivotes de máximo, y una de soporte por los 2 últimos pivotes de mínimo, proyectadas hacia adelante vela a vela.
3. Cada vez que el precio reacciona contra una de estas líneas, hay exactamente dos desenlaces posibles, y el sistema opera el que realmente ocurra:
   - **Ruptura (continuación)**: el cierre de una vela supera la línea (+ buffer de confirmación) → entrada a favor de la ruptura. Es el "punto verde/rojo" original.
   - **Rebote (reversión)**: el precio toca la línea (dentro de una tolerancia basada en ATR) pero **no** la supera, y se confirma con un **patrón de vela de reversión** (envolvente alcista/bajista, martillo o estrella fugaz) → entrada en sentido contrario a la línea.
   - Ejemplo en resistencia: o rompe hacia arriba (compra por continuación) o la respeta con un patrón bajista (venta por reversión). Simétrico en soporte.
   - La línea que reacciona primero queda "usada" (no vuelve a disparar señal) hasta que un nuevo pivote la reproyecte.
4. Si había una posición contraria abierta, se cierra e invierte (stop & reverse) al aparecer una señal confirmada en el sentido opuesto.
5. Cada entrada lleva **SL = ATR × 1.5** y **TP = distancia del SL × ratio R:R** (por defecto 3, configurable a 4 o 5 según el objetivo) — así la posición también se cierra sola "al llegar al beneficio", no solo cuando aparece la señal contraria.
6. **Panel visual automático de R-múltiplos**: en cada entrada se dibujan automáticamente los niveles 0 (entrada), SL y 1R…NR (por defecto hasta 5), con zonas sombreadas de ganancia/pérdida — el equivalente automatizado de medir la operación a mano con Fibonacci/regla de medición.
7. Modo de entrada configurable (`EntryMode` / `entryMode`): *Breakout Only* (solo continuación, comportamiento del v1), *Bounce Only* (solo reversión confirmada por patrón de vela) o *Both* (el sistema opera lo que realmente suceda en la línea — recomendado).

## Archivos

- [TrendlineBreak_EA.mq5](TrendlineBreak_EA.mq5) — EA para MT5: detecta ruptura y rebote, opera stop & reverse de forma automática, dibuja las líneas de tendencia/señales/panel de R-múltiplos, y trae gestión de riesgo para cuenta real (ver abajo).
- [XAUUSD_TrendlineBreak.pine](XAUUSD_TrendlineBreak.pine) — Script Pine v5 para TradingView: misma lógica de ruptura/rebote, etiquetas de entrada compactas, panel de escaneo en vivo, filtro opcional de horario, y corre como `strategy()` para backtest.

## Parámetros nuevos de la v2

- `touchATRMult` / `TouchATRMultiplier`: qué tan cerca (en múltiplos de ATR) debe llegar el precio a la línea para contar como "toque" válido para un rebote.
- `useEngulfing` / `UseEngulfingPattern` y `usePinBar` / `UsePinBarPattern`: qué patrones de vela confirman el rebote.
- `showRPanel` / `ShowRPanel`, `maxRLevels` / `MaxRLevels`, `panelBarsRight` / `PanelBars`: controlan el panel visual de R-múltiplos.
- Si ves demasiadas señales de rebote de baja calidad, sube `touchATRMult` (toque más exigente) o desactiva uno de los dos patrones de vela para hacerlo más selectivo — el mismo principio de "todas las confluencias" del sistema de sesión aplica aquí.
- Pine: `useTimeFilter` (apagado por defecto) restringe las entradas a una ventana horaria configurable (`sessionWindow`, `sessionTZ`) — útil para cortar horarios muertos por instrumento. La detección de líneas sigue corriendo fuera de la ventana; solo se bloquea la ejecución de la orden.
- Pine: `closeBeforeWeekend` (activado por defecto) + `fridayCloseHour`: mismo cierre de protección de gap de fin de semana que el EA (ver sección de gestión de riesgo del EA abajo para el porqué). Usa la misma zona horaria `sessionTZ`.
- Pine: la tabla de rendimiento por hora usaba `syminfo.timezone` (zona del exchange del símbolo), que en algunos símbolos/brókers queda ~1 hora desfasada de la zona horaria que el gráfico realmente muestra — ahora usa `sessionTZ` (igual que el filtro de horario) para que las horas de la tabla coincidan con las del gráfico. Si calibraste algo contra la tabla antes de este fix, vuelve a verificarlo.

## Gestión de riesgo del EA (v3, cuenta real)

- **Riesgo fijo en dólares**: `UseFixedRiskUSD` (activado por defecto) + `FixedRiskUSD` (por defecto **$30**) — el tamaño de posición se calcula para que, si se toca el SL, la pérdida sea ese monto exacto, sin importar el balance de la cuenta. Si prefieres volver a riesgo por porcentaje de balance, apaga `UseFixedRiskUSD` y ajusta `RiskPercent`.
- **Tope de lotaje**: `MaxLotSize` — límite duro de lotes por operación, se aplica siempre, sin importar lo que calcule el riesgo en dólares. Ajústalo al tamaño de tu cuenta FTUK.
- **Freno de pérdidas consecutivas**: `MaxConsecutiveLosses` (por defecto 2) — tras esa cantidad de SL seguidos (detectados vía `OnTradeTransaction`), se pausan nuevas entradas hasta el inicio del siguiente día calendario. El estado se ve en el `Comment()` del gráfico ("activo" / "PAUSADO").
- **Protección de cuenta (límites reales de FTUK, confirmados desde el dashboard de la cuenta)**: tu cuenta es **Flex Funded** de $10,000, no One-Step — los límites reales son **Max Daily Loss $500 (5%)** y **Max Loss $600 (6%, trailing desde el watermark/peak de equity)**. `DailyLossLimitPercent` (2.5% por defecto) y `MaxDrawdownPercent` (**4.5%** por defecto) calculan la pérdida real acumulada del día y el drawdown desde el equity más alto visto (mismo mecanismo de "trailing" que usa FTUK), aunque las pérdidas no hayan sido consecutivas. Si se alcanza cualquiera de los dos, cierra la posición abierta al instante (`CloseOnProtectionTrigger`) y bloquea nuevas entradas. La pérdida diaria se resetea al día siguiente; el drawdown máximo queda bloqueado permanentemente hasta que reinicies el EA manualmente (hazlo solo después de confirmar el estado real de tu cuenta con FTUK).
  - **Importante**: `MaxDrawdownPercent` debe quedar siempre por debajo del 6% real — si se pone en o por encima de ese número, FTUK cerraría la cuenta antes de que esta protección reaccione. Verifica los límites vigentes de tu cuenta en `app.ftuk.com` si el tipo/tamaño de cuenta cambia.
  - FTUK también muestra una regla de **consistencia** (máx. 20% de la ganancia total en un solo día) que afecta la elegibilidad de retiro — no la gestiona el EA automáticamente, es algo a vigilar manualmente con el tiempo.
- **Tope de ganancia por operación**: `MaxProfitPerTradeUSD` (por defecto $200) — cierra la posición de inmediato si su ganancia flotante alcanza este monto, sin esperar al TP. Con el riesgo fijo de $30 y R:R 3, una operación que llega a su TP completo gana ~$90 (bajo el límite), así que este tope es principalmente una red de seguridad ante gaps/slippage — cumple la regla de la prop firm de no exceder una ganancia máxima por operación individual cerrada.
- **Breakeven + trailing por ATR**: `UseBreakevenTrail` (activado por defecto) — una vez la operación alcanza `BreakevenAtR` (1R por defecto), el SL se mueve a breakeven y luego se va arrastrando por `TrailATRMultiplier` × ATR. No cambia qué señales se toman, solo reduce el tamaño promedio de las pérdidas en operaciones que llegaron a ir ganando y se revirtieron.
- **Protección de gap de fin de semana**: `CloseBeforeWeekend` (activado por defecto) + `FridayCloseHour` (**20**, hora del **servidor de MT5**, no la del gráfico de TradingView) — calculado para caer a las 3pm hora de Nueva York: el dueño de la cuenta está en Montreal (misma zona horaria que Nueva York, Eastern Time), y el reloj del servidor se observó 5 horas adelante del reloj local → servidor = NY + 5h. **Vuelve a verificar esto después de que termine el horario de verano en EE.UU./Canadá** (~primer domingo de noviembre): si el servidor del bróker no cambia de horario junto con Montreal/NY, esta diferencia de 5h podría cambiar. Cierra cualquier posición abierta y bloquea nuevas entradas desde esa hora el viernes hasta que el mercado reabre. Se agregó después de que un análisis de backtest encontrara una sola operación viernes→domingo que perdió 7.3× el riesgo normal por el gap del fin de semana (3.7% de una cuenta de $10,000 — con un stop más corto habría sido 5.5%, superando el límite diario real de FTUK).
- **Notificaciones push**: `EnablePushNotifications` (activado por defecto) — manda un push a tu celular al abrir cada operación (símbolo, dirección, lotes, SL/TP, motivo) y al cerrarla (motivo: SL/TP/manual, P/L, conteo de SL seguidos). Requiere vincular tu MetaQuotes ID: en MT5 ve a `Herramientas → Opciones → Notificaciones`, marca "Habilitar notificaciones push" e ingresa el ID que te muestra la app de MetaTrader en tu celular (pestaña "Mensajes" → ícono de engranaje).
- Los ratios de riesgo:beneficio (`RR_Multiplier`) y el SL base en ATR (`SL_ATR_Multiplier`) no cambiaron — la gestión de riesgo nueva solo controla el tamaño de la posición, cuándo se permite operar, y cómo se gestiona una posición ya abierta, no la distancia del SL/TP en sí. Reducir `SL_ATR_Multiplier` (stop más corto) es una hipótesis de estrategia distinta, pendiente de validar con backtest antes de aplicarla aquí.

## Panel en vivo del EA (v3.1)

Al adjuntar el EA aparece un panel real en la esquina superior derecha del gráfico (fondo + texto, no un simple `Comment()`), con: estado (escaneando / tocando línea / en posición / pausado por qué motivo), precio, resistencia y soporte con distancia en ATR, posición abierta (lotes, SL/TP, R actual), última señal y pérdida diaria / drawdown vs. sus límites. Se actualiza en cada tick.

Las líneas de resistencia/soporte y el panel ya no dependen de que el EA "observe" pivotes formarse desde que lo adjuntas — al iniciar, escanea el historial ya cargado en el gráfico para encontrar los 2 pivotes más recientes de cada tipo, así que se ven datos reales desde el primer segundo (en vez de esperar horas en temporalidades altas).

## Instalación

Mismo procedimiento que el sistema de sesión (sección 1): compilar/adjuntar el `.mq5` en MT5, o pegar el `.pine` en el Pine Editor de TradingView. Mismas advertencias sobre backtest/demo antes de capital real, y mismo filtro de spread máximo en el EA.

## Análisis de desempeño (línea base)

[`analysis/2026-09-06_a_2026-10-01_US30_TLBreak.xlsx`](analysis/2026-09-06_a_2026-10-01_US30_TLBreak.xlsx) — análisis completo de las 231 operaciones del backtest de Trendline Break en US30 (5 min, 6 sept–1 oct 2026): desglose por hora, por día de la semana, prueba de una regla de "cooldown tras ganar" (no se sostiene fuera de muestra, no activada), y rachas de pérdidas. Conclusión: con 25 días de datos no hay señal suficiente para calibrar filtro de horario ni cooldown — las únicas hipótesis a vigilar con más historial son el lunes (pierde en ambas mitades del mes) y las horas 2/8/13/22h. No se aplicó ningún cambio al código a partir de este análisis.

Este archivo es la línea base para repetir el mismo análisis con 3-6 meses de historial antes de considerar cambios al EA.

## Nota sobre LuxAlgo específicamente

Si de verdad quieres seguir usando el indicador LuxAlgo tal cual (no esta recreación propia) y automatizar sobre él: haz clic derecho sobre el indicador en el gráfico → "Agregar alerta" y revisa qué condiciones aparecen en la lista. Si el script trae `alertcondition()` propias para ruptura alcista/bajista, puedes usarlas para disparar un webhook hacia un puente que ejecute la orden en tu bróker — sin necesidad de ningún script adicional. Esto solo funciona si el autor del indicador incluyó esas alertas; si no aparecen en la lista, esa vía no es posible y el camino queda siendo esta recreación propia.
