# Lector EPUB/PDF multidispositivo — Brief de arranque para Claude Code

## Objetivo real del proyecto

No es un "tracker de lectura". El problema concreto a resolver es la **discontinuidad de posición entre dispositivos Apple** (Mac, iPad, iPhone) sobre un fondo propio de EPUB/PDF sin DRM. Apple Books sincroniza un único punto de lectura, de forma opaca, sin historial ni datos exportables. Esta app sustituye eso por un log de posiciones propio, transparente y multidispositivo, del que la analítica de lectura es un subproducto, no el fin.

Prioridad de valor, en orden:
1. Continuidad de posición fluida entre Mac/iPad/iPhone.
2. Historial de posiciones (deshacer saltos accidentales de sync).
3. Analítica: cuánto leo, ritmo, sesiones, por libro/autor.

La 2 y la 3 **son la misma tabla** (log de `posición + timestamp`); no diseñar como features separadas.

## Restricciones y decisiones ya tomadas (no re-discutir)

- **Plataformas**: macOS, iPadOS, iOS. Una sola base de código SwiftUI compartida.
- **EPUB**: usar **Readium Swift Toolkit** vía SPM. No escribir motor propio de paginación. Apple no expone API de EPUB.
- **PDF**: usar **PDFKit** nativo (render, búsqueda, anotaciones, extracción de texto). Casi resuelto de fábrica.
- **Sincronización**: **CloudKit** (base de datos privada del usuario). Cero servidor, gratis dentro de la cuenta de desarrollador, privado. Aceptado el lock-in a Apple porque los tres dispositivos son Apple.
- **Cuenta de desarrollador Apple de pago (99 €/año) desde el inicio**, no opcional. El sideload gratuito caduca cada 7 días y es incompatible con lectura diaria en iOS.
- **Fuera de alcance**: DRM (Kindle/Amazon). La app solo lee EPUB/PDF sin DRM. El usuario ya cura su fondo.
- **Fondo de entrada homogéneo**: el usuario procesa/recodifica todo en Calibre (EPUB 3 limpios). Asumir EPUBs bien formados; no invertir esfuerzo en la cola larga de archivos rotos.

## Decisión de modelo de datos crítica

**Identificar cada libro por un ID estable asignado por la app, NO por hash de fichero ni por ruta.** Razón: el usuario recodifica libros en Calibre (el fichero cambia) y mueve archivos entre carpetas (mergerfs). El log de posiciones debe sobrevivir a un reprocesado o a un movimiento de archivo. Vincular posición al contenido lógico del libro, no al binario.

Al importar un libro: intentar casar con un libro ya conocido por metadatos (título + autor + identificador interno del OPF si existe) antes de crear una entrada nueva, para no duplicar tras una recodificación.

### Esquema mínimo

```
Book
  id: UUID (estable, asignado por la app — la clave de todo)
  title, author
  format: epub | pdf
  opfIdentifier: String?   // identificador interno del EPUB si lo trae, ayuda a recasar
  fileBookmark: Data       // security-scoped bookmark al archivo local
  addedAt: Date

ReadingPosition            // el log; una fila por evento, NO se pisa
  id: UUID
  bookId: UUID -> Book.id
  locator: String          // CFI/locator de Readium (EPUB) | "page+scrollOffset" (PDF)
  timestamp: Date
  deviceId: String         // qué dispositivo lo registró
  progressFraction: Double // 0..1, derivado, para analítica y barra de progreso

// La "última posición" = la fila más reciente por bookId.
// El historial = todas las filas ordenadas por timestamp.
// La analítica = derivada de la serie (Δprogress / Δtime, huecos = sesiones).
```

Sincronizar `Book` y `ReadingPosition` por CloudKit. Resolución de conflictos: last-write-wins por timestamp es suficiente para uso personal; el log append-only minimiza conflictos reales.

## Plan por fases (cada fase valida algo antes de seguir)

**Fase 0 — Andamiaje**
Proyecto SwiftUI multiplataforma. Integrar Readium por SPM. Confirmar que compila y corre en macOS y simulador iOS con `xcodebuild`.

**Fase 1 — MVP que valida el núcleo (el bucle de dos dispositivos)**
- Importar y abrir un EPUB con Readium en Mac e iPad.
- Guardar `ReadingPosition` al cerrar/cambiar de posición.
- Sincronizar por CloudKit.
- Criterio de éxito: abrir un EPUB en el iPad, cerrarlo, abrirlo en el Mac y aparecer donde se dejó, de forma fluida. **Si esto no convence, el proyecto no merece seguir.**

**Fase 2 — PDF**
Añadir PDFKit como segundo tipo de documento, misma capa de posiciones (locator = página + offset). Barato porque PDFKit da casi todo.

**Fase 3 — iPhone + historial**
Tercer dispositivo. UI para ver/restaurar posiciones anteriores de un libro (deshacer saltos de sync).

**Fase 4 — Analítica**
Vistas derivadas del log: páginas/palabras por día, ritmo, sesiones, desglose por libro y autor. Exportable (el dato es del usuario).

## Decisiones que quedan abiertas para Jorge

- ¿Conteo por **palabras** o por **fracción de progreso/páginas**? Palabras es más significativo para "cuánto leo" pero requiere extraer y contar el texto del EPUB al importar. Recomendación: contar palabras una vez al importar y guardar el total en `Book`; la analítica se vuelve trivial después.
- ¿Anotaciones/subrayados en alcance? No están en las fases; añadir solo si se quiere y se diseña sobre la misma idea de locator.

## Notas para Claude Code

- Ejecución local en MacBook Pro M1 Max: el bucle compilar → simulador/dispositivo → corregir funciona de verdad. Usar `xcodebuild` y el simulador para iterar.
- No introducir dependencias más allá de Readium (SPM) salvo justificación; PDFKit, CloudKit y SwiftUI son nativos.
- Empezar por Fase 0 y 1. No adelantar analítica ni PDF hasta que la sincronización de posición esté demostrada.
