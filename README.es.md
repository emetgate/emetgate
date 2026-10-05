<p align="center">
  <img src="assets/banner.png" alt="Emetgate" width="640">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-windows-0078D6?style=flat-square" alt="Platform: Windows">
  <img src="https://img.shields.io/badge/languages-typescript%20%7C%20javascript%20%7C%20zig-3178C6?style=flat-square" alt="Languages: TypeScript, JavaScript, Zig">
  <img src="https://img.shields.io/badge/protocol-MCP-1E1B26?style=flat-square" alt="Protocol: MCP">
</p>

<p align="center"><a href="README.md">English</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.ko.md">한국어</a> · <a href="README.zh-CN.md">简体中文</a> · <b>Español</b></p>

# Emetgate

Una puerta entre un modelo que escribe código y tu árbol de fuentes. El modelo propone un cambio, Emetgate lo comprueba y el cambio llega al disco solo si las comprobaciones pasan.

Funciona como servidor MCP para Claude Code, en Windows, para proyectos de TypeScript y JavaScript.

<p align="center">
  <img src="assets/demo.gif" alt="The gate refusing a placeholder and a test-breaking body and committing a correct one; a search against rg; a node edit against Read and Edit" width="900">
</p>

## Qué hace

**Comprueba cada escritura.** Un cambio nombra un símbolo y el hash del código en el que se basó. Emetgate coloca el nuevo cuerpo en su sitio, vuelve a analizar el archivo, ejecuta tus reglas y luego ejecuta tu comprobación de tipos y tus pruebas sobre una copia del repositorio dentro de un sandbox. Si algún paso falla, no se escribe nada. Cada commit deja un recibo que `emetgate verify` puede volver a comprobar más tarde sin confiar en el proceso que lo escribió.

**Lee código para el modelo.** `emetgate_explore` responde a una pregunta sobre la base de código con definiciones enteras y números de línea. `emetgate_evidence` devuelve el código completo de los símbolos que nombras. También hay herramientas para símbolos, archivos, búsqueda y git; la lista está en [REFERENCE.md](REFERENCE.md#mcp-tools).

**Guarda tus reglas.** Añades una regla una vez desde la línea de comandos. El modelo puede leer las reglas y no puede cambiarlas ni eliminarlas.

```
emetgate rule add "no console.log" --check "cmd:npx eslint --rule no-console" --in src/ --enforce
emetgate rule add "no networkidle waits" --check forbid:networkidle --enforce
```

## Instalación

Cada versión publica `emetgate.exe` y su SHA-256 en la [página de versiones](https://github.com/emetgate/emetgate/releases).

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\emetgate" | Out-Null
foreach ($f in "emetgate.exe", "emetgate.exe.sha256") { Invoke-WebRequest "https://github.com/emetgate/emetgate/releases/latest/download/$f" -OutFile "$env:USERPROFILE\emetgate\$f" }
(Get-FileHash "$env:USERPROFILE\emetgate\emetgate.exe" -Algorithm SHA256).Hash -eq (Get-Content "$env:USERPROFILE\emetgate\emetgate.exe.sha256").Split(" ")[0]
claude mcp add emetgate -- "$env:USERPROFILE\emetgate\emetgate.exe" mcp --test "npm test"
```

El binario no está firmado, así que SmartScreen avisa en la primera ejecución. Compara la suma de comprobación en su lugar.

`emetgate lockdown` inicia Claude Code solo con las herramientas de Emetgate, de modo que toda escritura pasa por la puerta.

## Mediciones

Hice 15 preguntas sobre cuatro repositorios a través de Emetgate, Serena, codebase-memory-mcp y las herramientas propias de Claude Code: el mismo modelo (`claude-sonnet-5-5`), una copia nueva del repositorio en cada ejecución, sin prompt adicional, tres ejecuciones por pregunta. La puntuación es la proporción de puntos de la clave de respuestas que la respuesta nombra; escribí las claves antes de ejecutar ninguna herramienta.

| Herramienta | Puntuación | Tokens | Coste |
|---|---:|---:|---:|
| Emetgate | 240/252 | 86.7k | $0.132 |
| Serena | 242/252 | 143.8k | $0.143 |
| Herramientas propias de Claude Code | 234/252 | 171.4k | $0.150 |
| codebase-memory-mcp | 246/252 | 178.5k | $0.204 |

En este conjunto Emetgate usa menos tokens y cuesta menos que las demás. No es la más precisa: dos herramientas puntúan más alto. Una diferencia de dos puntos en 252 queda dentro de la variación entre ejecuciones, así que estas ejecuciones no ordenan las herramientas por puntuación.

También escribí a mano tres preguntas más en las cuatro herramientas, una ejecución cada una. Emetgate volvió a usar menos tokens, y las herramientas propias de Claude Code fueron más baratas y más rápidas:

<p align="center">
  <img src="tests/bench/hand/three-questions.png" alt="Three questions, four tools, one model: tokens, API time and cost of each tool" width="900">
</p>

Lo que las 345 sesiones grabadas mostraron sobre el coste:

- El coste de una sesión lo fijan cuatro recuentos de tokens, y un token escrito en la caché cuesta 20 veces lo que un token leído de ella. Menos tokens no siempre significa una factura menor.
- Una llamada más al modelo cuesta más o menos lo mismo que 8,000 caracteres de salida de herramienta.
- El modelo escribe lo que pidió. Un punto de la clave que nombró en su propia llamada llegó a la respuesta el 98.5% de las veces; uno que solo vio en una respuesta, el 90.5%.

Las sesiones, las preguntas, las claves de respuestas y el script que produce estos números están en [tests/bench/neutral](tests/bench/neutral). La prueba manual con sus respuestas completas está en [tests/bench/hand](tests/bench/hand). Los recuentos de tokens de lecturas, ediciones y búsquedas individuales están en [REFERENCE.md](REFERENCE.md).

## Cómo se prueba la puerta

- **Pruebas de mutación.** Cada guarda se rompe a propósito y al menos una prueba debe fallar. Para el motor hay hoy 64 mutantes: 57 eliminados, 4 demostrados equivalentes, 2 guardas redundantes mantenidas como defensa en profundidad, 1 abierto. La lista está en [VERIFICATION.md](VERIFICATION.md).
- **Verificación de modelos.** El diario de commits está especificado en TLA+ y comprobado con TLC, incluidas las caídas durante la recuperación.
- **Pruebas de caída.** Los lotes se cortan después de cada paso y se recuperan.
- **Suites de red team y de fuzzing** contra la superficie MCP, el sandbox, el diario y los analizadores.

Los hallazgos contra la puerta y sus correcciones se listan en [REFERENCE.md](REFERENCE.md#security-history).

## Límites

- Solo Windows. Solo TypeScript, JavaScript y Zig.
- Pasar la puerta significa que el código se analiza, se mantiene dentro de sus límites y pasa tus pruebas. No significa que el código sea correcto, y la puerta de pruebas es tan fuerte como tus pruebas.
- El sandbox bloquea las escrituras fuera de la copia. No bloquea las lecturas ni el acceso a la red.
- Los cambios hechos fuera de la puerta no están cubiertos. Para eso está lockdown.
- Node.js 24.15.0 y anteriores fallan de forma intermitente en conexiones loopback de Windows; usa 24.16.0 o posterior.

## Compilación

Zig 0.16.0. tree-sitter y las gramáticas están incluidos en el repositorio.

```sh
zig build                  # zig-out/bin/emetgate
zig build test             # all tests
tools/accept.ps1 <ref>     # tests three times, then the mutants on lines changed since <ref>
```

## Licencia

MIT. Las gramáticas incluidas bajo `vendor/` conservan sus propias licencias MIT.

<p align="center"><a href="README.md">English</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.ko.md">한국어</a> · <a href="README.zh-CN.md">简体中文</a> · <b>Español</b></p>
