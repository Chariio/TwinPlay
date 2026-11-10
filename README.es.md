# TwinPlay — emulador para iPhone y iPad

App SwiftUI (iOS 16+, iPhone y iPad). Los núcleos de DS, GBA, GB y GBC son C++
original. NES y Super NES usan ares (licencia ISC). N64 y 3DS son GPL (Mupen64Plus
y Azahar, sin JIT): ver `THIRD_PARTY_NOTICES.md`. **Sin ROMs, BIOS ni firmware de
Nintendo**. Este árbol se publica bajo **GPL-3.0-or-later** (ver `LICENSE` y
`NOTICE.md`). El copyright del código original de TwinPlay es de Charlie Rodriguez Garcia.

*English version: [README.md](README.md). La interfaz de la app está en inglés.*

> Estado: la app funciona de punta a punta en **modo de prueba** (patrón de colores,
> controles, toque, mando y sonido). El núcleo DS ya tiene las dos CPU, memoria, VRAM,
> motores 2D, **motor 3D**, pantalla táctil, sonido, guardado de partidas, reloj (RTC) y
> estados guardados. Carga y arranca ROMs, pero **todavía no se ha probado con juegos
> comerciales**: es normal que muchos fallen o tengan errores gráficos (ver "Hoja de ruta").

---

## 1. Lo que necesitas (todo gratis)

- Una Mac con macOS 14 o superior.
- **Xcode** (gratis en la Mac App Store), versión 15 o más nueva.
- Tu **Apple ID normal** (no hace falta pagar el programa de desarrollador).
- Para probar en el iPhone: un cable USB/USB‑C.

## 2. Instalar Xcode

1. Abre la **App Store** en la Mac, busca **Xcode** y pulsa **Obtener**. Tarda un rato (pesa >7 GB).
2. Ábrelo una vez y acepta la licencia. Si pide instalar "componentes adicionales", acepta.
3. Cuando pregunte qué plataformas, marca **iOS** (incluye el Simulador).
   Si no lo preguntó: Xcode ▸ Settings ▸ **Components** ▸ descarga **iOS**.

## 3. Abrir el proyecto

1. Descomprime `ds-emu.zip` (doble clic). Quedará una carpeta `ds-emu`.
2. Abre **Terminal** (Aplicaciones ▸ Utilidades ▸ Terminal) y escribe:
   ```bash
   cd ~/Downloads/ds-emu          # o donde hayas dejado la carpeta
   ./scripts/generate-project.sh
   ```
   Esto descarga XcodeGen (herramienta gratuita, solo la primera vez) y crea `DSEmu.xcodeproj`.
   Si macOS dice "permiso denegado", ejecuta antes `chmod +x scripts/*.sh`.
3. Abre el proyecto: `open DSEmu.xcodeproj` (o doble clic en el archivo).
   El proyecto y el target se siguen llamando **DSEmu**; la app instalada se llama **TwinPlay**.

## 4. Poner tu Apple ID para firmar

1. Xcode ▸ **Settings** ▸ **Accounts** ▸ botón **+** ▸ **Apple ID** ▸ inicia sesión.
2. En el panel izquierdo haz clic en el proyecto **DSEmu** (icono azul) ▸ target **DSEmu** ▸
   pestaña **Signing & Capabilities**.
3. Deja marcado **Automatically manage signing** y en **Team** elige
   **"Tu Nombre (Personal Team)"**.
4. Si aparece un error de "Bundle Identifier" no disponible, cambia
   `com.charlie.dsemu` por algo único, por ejemplo `com.charlierodriguez.dsemu2026`.

## 5. Ejecutar en el Simulador

1. Arriba, junto al botón ▶︎, elige un simulador (p. ej. **iPhone 16 Pro** o un **iPad**).
2. Pulsa **▶︎ (Cmd+R)**. La primera compilación tarda un poco.
3. En la app toca **"Test mode"**: verás barras de colores arriba y un degradado abajo.
   - Pulsa botones: se encienden cuadritos rojos en la pantalla de arriba.
   - Toca la pantalla de abajo: aparece una cruz donde tocas.
   - Mantén **A**: suena un tono de 440 Hz.
   - Gira el simulador (Cmd+←/→) para ver el diseño horizontal; en el menú (⋯) puedes elegir
     "Stacked" (una sobre otra) o "Side by side" (lado a lado).

## 6. Ejecutar en tu iPhone (gratis)

1. Conecta el iPhone con el cable y desbloquéalo. Si pregunta "¿Confiar en esta computadora?", toca **Confiar**.
2. En el iPhone activa el **Modo de desarrollador**: Ajustes ▸ Privacidad y seguridad ▸
   **Modo de desarrollador** ▸ activar ▸ reiniciar ▸ confirmar. (Aparece después de conectarlo a Xcode una vez.)
3. En Xcode elige tu iPhone en la lista de dispositivos y pulsa **▶︎**.
4. La primera vez el iPhone dirá que el desarrollador no es de confianza. Ve a
   Ajustes ▸ General ▸ **VPN y gestión de dispositivos** ▸ tu Apple ID ▸ **Confiar**.
5. Vuelve a pulsar ▶︎ en Xcode (o abre la app en el iPhone).

### Límite de 7 días (cuenta gratis)
Con un Apple ID gratis la app **caduca a los 7 días** y deja de abrir. Para renovarla basta
conectar el iPhone y pulsar ▶︎ otra vez en Xcode (tus juegos, partidas y estados se conservan).
Además, una cuenta gratis permite como máximo 3 apps instaladas así a la vez.

## 7. Importar tus juegos

- En la app pulsa **+** y elige tus archivos `.nds`, `.gba`, `.gb`, `.gbc`, `.nes`, `.sfc` o `.smc` (de iCloud Drive, "En mi iPhone", etc.).
  Se copian a la carpeta de la app (`Documentos/ROMs`), visible también en la app Archivos ▸ TwinPlay.
- Usa solo copias de juegos que te pertenezcan. La app no incluye ni descarga juegos ni BIOS.
- Las partidas del cartucho se guardan en `Documentos/Saves/<juego>.sav`; los estados en `Documentos/States`.
- **Opcional:** algunos volcados de ROM tienen la *zona segura cifrada*. Para descifrarla hace falta una
  tabla de claves que solo está en la BIOS ARM7 de la consola. Si has volcado la BIOS de **tu propia**
  consola, impórtala en **Ajustes ▸ Usar mi propia BIOS/firmware ▸ Import BIOS / firmware files…** (TwinPlay Pro). Puedes elegir varios archivos a la vez; cada uno se reconoce por tamaño y CRC32, sea cual sea su nombre o extensión (p. ej. `biosnds7.rom`). La ruta antigua `Documentos/BIOS/biosnds7.bin` (Archivos ▸ TwinPlay ▸ BIOS) se sigue leyendo. Nunca es obligatoria,
  nunca se incluye ni se descarga; la mayoría de volcados ya vienen descifrados.

## 8. Mandos

Funciona con mandos compatibles con iPhone (Xbox, PlayStation, Switch Pro, MFi) vía Bluetooth.
Distribución por posición: botón derecho = A, inferior = B, superior = X, izquierdo = Y;
gatillos/bumpers = L/R; Menú = Start; Opciones = Select; cruceta o stick = dirección.

---

## Funciones

- **Biblioteca**: una cuadrícula de tus juegos que muestra el icono y el título guardados en el banner de cada ROM. Puedes ordenarla (nombre, añadidos recientemente, jugados recientemente) y buscar en ella. Mantén pulsado un juego para Renombrarlo o Eliminarlo, o para cambiar su Portada:
  - Elegir de Fotos, Elegir de Archivos o Pegar imagen.
  - Buscar en Google Imágenes abre un navegador dentro de la app. Guarda la imagen que te guste y luego elígela desde Fotos o Archivos.
  - Restablecer el icono original.
  - En iPad también puedes arrastrar una imagen sobre un juego.
  - Las portadas se guardan en `Documents/Covers/<rom>.png`. La app nunca incluye ni descarga portadas por su cuenta.
- **Estados guardados**: una ranura automática (se escribe al salir del juego o cuando la app pasa a segundo plano) y 5 ranuras manuales, cada una con miniatura y fecha. Ábrelas desde el menú ⋯ → Save states…; el guardado y la carga rápidos usan la ranura 1.
- **Avance rápido**: toca el botón » (arriba a la derecha) o mantén pulsado el stick derecho del mando. Velocidades x2, x3 o ilimitada. Durante el avance rápido el sonido se silencia (por defecto) o suena más agudo. Se ajusta en ⋯ → Fast-forward.
- **Vídeo**: resolución interna 3D de 1x a 4x (por defecto 2x), antialiasing 3D (Apagado / Suavizado de bordes (por defecto) / Supersampling 2x), Texturas 3D suaves y 3D panorámico (experimental, por juego, estira la pantalla superior a 16:9). Filtros de pantalla: Nítido, Suavizado, Scanlines, Bilineal nítido y Escalado por bordes. Color: brillo, contraste, saturación, gamma y corrección de color LCD. Todo en ⋯ → Video.
- **Partidas**: el chip de guardado se detecta solo observando los comandos del juego; se puede forzar por juego en ⋯ → Game save. Compatible con los cartuchos Pokémon con infrarrojos.
- **Controles en pantalla**: automático (se ocultan mientras hay un mando conectado), mostrar siempre u ocultar siempre. Con los controles ocultos, las pantallas se agrandan.
- **Mandos**: ⋯ → Controller buttons…, o el menú de la biblioteca → Controllers. Toca una acción y luego pulsa un botón. Se guarda un perfil por cada modelo de mando.

## Estructura del proyecto

```
ds-emu/
├── project.yml                 # Definición del proyecto (XcodeGen) → DSEmu.xcodeproj
├── scripts/
│   ├── generate-project.sh     # Genera el .xcodeproj (descarga XcodeGen si falta)
│   └── run-core-tests.sh       # Compila y ejecuta las pruebas del núcleo en la Mac
├── DSEmu/                      # App iOS (SwiftUI)
│   ├── App/DSEmuApp.swift
│   ├── Views/                  # Biblioteca, pantalla del emulador, layout, controles, toque
│   ├── Emulation/              # Sesión/hilo de emulación, audio, mandos, biblioteca de ROMs
│   └── Bridge/                 # Puente Objective-C++ hacia el núcleo C++
├── Core/                       # Núcleo C++20. DS/GBA/GB propio; NES/SNES son ares (ISC)
│   ├── include/dscore/         # EmulatorCore (interfaz), ARMCPU, Bus, tipos, AudioRing, StateIO
│   ├── src/                    # Intérprete ARM/Thumb, sistema DS, 2D/3D, sonido, partidas, RTC, KEY1
│   └── tests/core_tests.cpp    # Pruebas unitarias
├── docs/APP_STORE_COMPLIANCE.md
├── LICENSE  (propietaria, todos los derechos reservados)
├── README.md                   # Versión en inglés
└── NOTICE.md
```

### Qué hace ya el núcleo DS
- Cabecera del cartucho y arranque directo HLE: **no necesita BIOS ni firmware**.
- CPU ARM9 (ARMv5TE) y ARM7 (ARMv4T), ARM y Thumb.
- Memoria, WRAM, ITCM/DTCM, **VRAM con mapeo real de bancos A–I**, incluidos los slots de **texturas y paletas 3D**.
- **Motores 2D A y B** (fondos de texto, afines, extendidos, bitmap, sprites, ventanas, mezclas, brillo).
- **Motor 3D** (nuevo):
  - Motor de geometría: todas las órdenes de matrices (proyección, posición, vector y textura, con pilas),
    FIFO empaquetado y puertos directos, DMA e IRQ del GXFIFO, todos los formatos de vértice,
    triángulos/cuadriláteros/tiras, recorte, plano lejano, *culling*, viewport, transformación de coordenadas
    de textura, **iluminación** (4 luces, difusa/ambiente/especular/emisión, tabla de brillo), pruebas de
    posición/vector, RAM_COUNT, lectura de matrices y SWAP_BUFFERS en el VBlank.
  - Rasterizador por software: color y textura con corrección de perspectiva, Z-buffer y W-buffer,
    **los 7 formatos de textura**, repetir/espejo, transparencia del color 0, modulate/decal/toon/highlight,
    translucidez con mezcla, prueba alfa, *wireframe*, orden opacos→translúcidos, **niebla** y **marcado de bordes**.
  - Salida como **BG0 del motor A**, con desplazamiento y mezcla alfa por píxel.
- **Reloj en tiempo real (RTC)** con la hora del dispositivo.
- **Funciones de BIOS (HLE)**: BitUnPack, LZ77, Huffman, RLE, Diff8/Diff16 (también las variantes con
  *callback*, que llaman a las funciones del propio juego), GetSineTable, GetPitchTable y las anteriores.
- **Cartucho y cifrado**: modos raw, KEY1 y de datos. KEY2 es transparente para el software (lo aplican
  consola y cartucho por igual). **KEY1** implementado desde GBATEK: la zona segura cifrada se descifra
  automáticamente si el usuario aporta su propia BIOS ARM7 (opcional).
- **Estados guardados** del núcleo DS (todo el estado de la máquina), con comprobación del juego y rechazo
  de estados dañados sin alterar la partida en curso.
- **Guardado de partidas** (EEPROM/FRAM/Flash con detección automática) y **sonido** de 16 canales a 48 kHz.
- **Rendimiento (sin JIT)**: ~7,7 ms/frame en el peor caso 2D + sonido y ~11,7 ms/frame con
  **1.500 polígonos texturizados con niebla y bordes por frame**.

Pruebas: 21 grupos de pruebas unitarias (nuevas: geometría 3D, profundidad y matrices; texturas, translucidez
y niebla; RTC; descompresión de BIOS; KEY1 de ida y vuelta; estados guardados y rechazo de estados dañados).
Probar en la Mac: `./scripts/run-core-tests.sh` (también pasan en Linux con ASan/UBSan).

---

## Hoja de ruta del núcleo

**Próximo hito sugerido — compatibilidad:**
1. Probar con homebrew libre y juegos propios; corregir lo que falle (tiempos de memoria, prioridades de
   sprites, mosaico, captura de pantalla, FIFO de memoria principal, captura de sonido).
2. Precisión 3D: *box test*, polígonos de sombra, antialiasing, polígonos de 1 punto, bitmap de fondo,
   detalles de toon/bordes, tiempos del GXFIFO (hoy las órdenes se ejecutan al instante).
3. Funciones de BIOS restantes (p. ej. GetVolumeTable), escritura de firmware, micrófono, Wi‑Fi simulado.

Después: salida por Metal, ajustes de controles, portadas en la biblioteca, 3D en varios hilos.

Regla del proyecto: implementar siempre desde documentación pública del hardware (GBATEK, manuales ARM);
nunca copiar código de otros emuladores.

## Problemas frecuentes
- **"No account for team" / "Signing requires a development team"**: repite el paso 4.
- **"Failed to register bundle identifier"**: cambia el Bundle Identifier (paso 4.4).
- **"Untrusted Developer"** en el iPhone: paso 6.4.
- **La app dejó de abrir tras una semana**: es el límite de 7 días; vuelve a pulsar ▶︎ en Xcode.
- **`generate-project.sh` no descarga**: instala XcodeGen con Homebrew (`brew install xcodegen`) y repite.
- **Mensaje "Encrypted secure area"**: el ROM necesita tu propia BIOS ARM7: impórtala en Ajustes (sección 7).

## Ejecutor sin interfaz (depuración)
`Core/tools/headless.cpp` ejecuta una ROM de DS. Se compila con los mismos objetos que `make test` (C++20, más los objetos de ares). `./headless juego.nds -frames 600 -every 60 -out frames/` genera fotogramas PNG y `trace.log`.
Opciones: `-press F:MASK` (mantiene botones 6 fotogramas desde F), `-bench` (ms/fotograma cada 100 fotogramas, sin traza), `-threads N` (hilos de rasterizado 3D), `-skip N` (salto de fotogramas).

## Rendimiento
- El hilo de emulación se sincroniza con el display link y se corrige según la cola de audio (~50 ms), para que el sonido no se corte ni se desfase.
- Los fotogramas usan doble búfer en el puente; ambas pantallas salen siempre del mismo fotograma y se dibujan con Metal desde una textura (Core Graphics como alternativa en el menú).
- El 3D se rasteriza en la línea 215 (final del VBlank, como el hardware) en franjas horizontales con hilos auxiliares; el resultado es idéntico al de un solo hilo.
- El salto de fotogramas (Auto/No/1/2) solo omite imágenes; la emulación siempre va a velocidad completa.
