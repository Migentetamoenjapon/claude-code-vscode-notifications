# Línea de estado

*[English](statusline.md)*

`statusline.py` imprime una línea gris y mínima al pie de Claude Code. Muestra lo que casi siempre
quieres saber de un vistazo: qué proyecto, qué modelo, qué tan lleno está el contexto y cuánto has
usado de los límites de tu plan.

Es opcional. La ventanita y la barra de menú funcionan sin ella.

## Línea de ejemplo

```
my-project  Sonnet high │ ctx 52% │ sesión ~1.2% ~$0.28 45k │ 5h 12% ↻3:00pm │ sem 45% $10.38/$23 │ ABC 101.50 +0.42% 3:58pm
```

Todo es gris. Un porcentaje se pone verde, amarillo o rojo solo cuando pasa el umbral de color
(40 % por defecto). Así, una barra sin color significa que nada requiere tu atención.

## Qué significa cada segmento

| Segmento | Significado |
|---|---|
| `my-project` | Nombre de la carpeta del proyecto. |
| `Sonnet high` | Modelo y nivel de esfuerzo. Un `⚡` tras el modelo indica modo rápido. |
| `ctx 52%` | Qué tan lleno está el contexto. |
| `sesión ~1.2% ~$0.28 45k` | Solo esta sesión. Vuelve a cero después de `/clear`. El primer número es la parte estimada de tu límite semanal que usó la sesión. La cifra en dólares es esa parte en dólares del plan (solo aparece si defines `plan_monthly_usd`). El último número son los tokens usados (entrada, escritura de caché y salida). |
| `5h 12% ↻3:00pm` | Cuánto has usado del límite de 5 horas y la hora local en que se reinicia. |
| `sem 45% $10.38/$23` | Cuánto has usado del límite semanal. Con `plan_monthly_usd` definido, muestra también los dólares del plan usados y los dólares del plan por semana. |
| `ABC 101.50 +0.42% 3:58pm` | Cotización opcional: último precio, variación desde el cierre anterior y la hora de ese precio. |

Colores: gris hasta el umbral; luego verde por debajo de 60 %, amarillo por debajo de 80 % y rojo
desde 80 %. La variación de la cotización solo se colorea con el mercado abierto y un movimiento de
al menos `ticker_min_move_pct`.

### Terminales angostas

El script lee `COLUMNS` y recorta la línea para que quepa. Quita cosas en este orden: el modelo; luego
la forma larga de los segmentos semanal, de cotización, de 5 horas y de sesión; luego la cotización,
la sesión y el contexto. El porcentaje semanal nunca se quita.

## Las cifras en dólares del plan son estimaciones

Claude Code no informa el uso por sesión, y una suscripción no tiene un precio real por token. Por eso:

- **Parte de la sesión (`~1.2%`).** El porcentaje semanal se reparte entre las sesiones de la semana
  en proporción a su costo a precio de lista. Una sesión nunca muestra más que la semana completa. Es
  una aproximación y solo conoce las sesiones que corrieron esta línea de estado en este Mac.
- **Dólares del plan (`~$0.28`, `$10.38/$23`).** Son tu porcentaje multiplicado por
  `plan_monthly_usd × 12 ÷ 52` (el precio del plan por semana). Indican «qué parte de lo que pagas
  cada semana es esto», no lo que habría cobrado la API. La `~` marca una estimación.

Si no defines `plan_monthly_usd`, no aparece ninguna cifra en dólares. Solo porcentajes.

## Cómo activarla

Agrega esto a `~/.claude/settings.json` (combínalo con lo que ya tengas):

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/ccnotify/statusline/statusline.py",
    "refreshInterval": 60
  }
}
```

`install.sh` copia el script a esa ruta. Reinicia Claude Code después de cambiar el ajuste.

## Configuración

Los ajustes van en `~/.claude/ccnotify/config.json`, dentro de `"statusline"`. Todas las claves son
opcionales. (Si defines la variable de entorno `CCNOTIFY_HOME`, el archivo es
`$CCNOTIFY_HOME/config.json`.)

```json
{
  "language": "auto",
  "statusline": {
    "plan_monthly_usd": 100,
    "ticker": "",
    "ticker_refresh_open_s": 60,
    "ticker_refresh_closed_s": 1800,
    "ticker_min_move_pct": 0.5,
    "color_threshold_pct": 40
  }
}
```

| Clave | Por defecto | Significado |
|---|---|---|
| `language` (nivel superior) | `"auto"` | `"auto"`, `"en"` o `"es"`. En automático usa el primer idioma preferido de macOS (`defaults read -g AppleLanguages`), o `LANG` si eso falla. Se lee una sola vez y se guarda en `state/statusline/lang.json`. Borra ese archivo para que lo detecte de nuevo. |
| `plan_monthly_usd` | `null` | El precio mensual de tu plan en dólares. Sin definir: no se muestran cifras en dólares. |
| `ticker` | `""` | Un símbolo de Yahoo Finance, como `SPY` o `QQQ`. Vacío: no hay cotización y el script **no accede a la red en absoluto**. |
| `ticker_refresh_open_s` | `60` | Segundos entre actualizaciones con el mercado abierto. |
| `ticker_refresh_closed_s` | `1800` | Segundos entre actualizaciones con el mercado cerrado. |
| `ticker_min_move_pct` | `0.5` | La variación de la cotización toma color a partir de este movimiento. |
| `color_threshold_pct` | `40` | Los porcentajes se quedan en gris hasta este valor. |

### La cotización y tu red

La cotización es lo único de CCNotify que usa la red, y viene apagada. Si defines un símbolo, el script
lee una copia local del precio y, si está vieja, lanza un `curl` en segundo plano a
`query1.finance.yahoo.com`. La barra nunca lo espera: la primera línea tras un arranque en frío no
trae cotización, y el precio aparece en una actualización posterior. Solo se envía el símbolo.

## Seguridad

- Siempre imprime una línea y termina con código 0, incluso con una entrada dañada.
- Tolera campos ausentes. Claude Code puede omitir `rate_limits` o `effort`, y esos segmentos
  simplemente desaparecen.
- Nunca espera a la red.
- Los archivos de caché están en `~/.claude/ccnotify/state/statusline/`. Puedes borrar esa carpeta
  en cualquier momento.

## Pruébala a mano

```bash
echo '{"model":{"display_name":"Sonnet"},"context_window":{"used_percentage":52}}' \
  | ~/.claude/ccnotify/statusline/statusline.py
```
