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

## Lógica

1. Se detectan pivotes de máximo/mínimo confirmados (`PivotLookback` velas a cada lado).
2. Se traza una línea de resistencia por los 2 últimos pivotes de máximo, y una de soporte por los 2 últimos pivotes de mínimo, proyectadas hacia adelante vela a vela.
3. **Punto verde (compra)**: el cierre de una vela cruza por encima de la línea de resistencia. Si había una posición corta abierta, se cierra e invierte (stop & reverse).
4. **Punto rojo (venta)**: el cierre cruza por debajo de la línea de soporte. Si había una posición larga abierta, se cierra e invierte.
5. Cada entrada lleva **SL = ATR × 1.5** y **TP = distancia del SL × ratio R:R** (por defecto 3) — así la posición también se cierra sola "al llegar al beneficio", no solo cuando aparece el punto contrario, tal como pediste.

## Archivos

- [XAUUSD_TrendlineBreak_EA.mq5](XAUUSD_TrendlineBreak_EA.mq5) — EA para MT5, opera stop & reverse de forma automática y dibuja las líneas de tendencia en el gráfico.
- [XAUUSD_TrendlineBreak.pine](XAUUSD_TrendlineBreak.pine) — Script Pine v5 para TradingView, dibuja las líneas, los puntos verdes/rojos, las etiquetas de entrada con SL/TP, y corre como `strategy()` para backtest.

## Instalación

Mismo procedimiento que el sistema de sesión (sección 1): compilar/adjuntar el `.mq5` en MT5, o pegar el `.pine` en el Pine Editor de TradingView. Mismas advertencias sobre backtest/demo antes de capital real, y mismo filtro de spread máximo en el EA.

## Nota sobre LuxAlgo específicamente

Si de verdad quieres seguir usando el indicador LuxAlgo tal cual (no esta recreación propia) y automatizar sobre él: haz clic derecho sobre el indicador en el gráfico → "Agregar alerta" y revisa qué condiciones aparecen en la lista. Si el script trae `alertcondition()` propias para ruptura alcista/bajista, puedes usarlas para disparar un webhook hacia un puente que ejecute la orden en tu bróker — sin necesidad de ningún script adicional. Esto solo funciona si el autor del indicador incluyó esas alertas; si no aparecen en la lista, esa vía no es posible y el camino queda siendo esta recreación propia.
