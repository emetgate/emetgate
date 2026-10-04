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

**Nada de lo que escribe el modelo llega al disco sin verificar.**

Una puerta de verificación entre un modelo que escribe código y tu árbol de fuentes. El modelo propone un cambio; Emetgate lo comprueba y lo escribe solo si las comprobaciones pasan.

<p align="center">
  <img src="assets/demo.gif" alt="The gate refusing a placeholder and a test-breaking body and committing a correct one; a search against rg; a node edit against Read and Edit" width="900">
</p>

Funciona como servidor MCP. `emetgate lockdown` inicia Claude Code solo con las herramientas de Emetgate, de modo que toda escritura pasa por la puerta.

## Cómo se comprueba una escritura

1. **Dirección.** Un cambio nombra un símbolo y el hash del contenido en el que se basó. Si el archivo cambió desde entonces, el hash no coincide y el cambio se rechaza. Un cambio también puede nombrar un único nodo sintáctico dentro de un cuerpo, como un bloque `if` o una sentencia, por el hash de su contenido, y enviar solo el nuevo texto de ese nodo.
2. **Empalme y reanálisis.** El nuevo cuerpo sustituye exactamente al anterior por rango de bytes. El archivo se vuelve a analizar con tree-sitter. Se rechazan los errores de sintaxis, un cuerpo que se sale de sus llaves, los cuerpos de relleno y cualquier cambio fuera del tramo.
3. **Prueba, donde la hay.** Los renombrados se comprueban con un hash abstraído de los nombres (alfa) y un resolutor de ámbitos que se contrasta con el servicio de lenguaje de TypeScript. Los traslados conservan el hash del código trasladado y derivan cada import. Los símbolos nuevos y los eliminados no deben tener referencias.
4. **Reglas.** Aquí se ejecutan las reglas que añades desde la CLI: comprobaciones integradas, consultas de tree-sitter (`q:`) o tu propio linter (`cmd:`).
5. **Pruebas en un sandbox.** El cambio se aplica a una copia sombra fuera del repositorio. Tus comandos de comprobación de tipos y de pruebas se ejecutan allí bajo un token de integridad baja, en un Job Object con límites de tiempo, memoria y salida.
6. **Commit atómico.** Un diario de escritura anticipada por lote, reemplazo atómico, vaciados de directorio. Tras una caída, `emetgate recover` deja un lote todo antiguo o todo nuevo.
7. **Recibo.** Cada commit recibe un recibo: hashes de antes y después, la evidencia usada, las pruebas ejecutadas, las reglas aplicadas.

Si una comprobación no puede terminar, el cambio se rechaza. El modelo no puede cambiar el comando de pruebas, las reglas ni la configuración del sandbox.

## Herramientas

| Herramienta | Qué hace |
|---|---|
| `emetgate_explore` | Para una pregunta y nombres opcionales: todas las definiciones de cada símbolo nombrado, luego las funciones y constantes de nivel superior ordenadas por estadísticas de términos sobre nombres, rutas y cuerpos, cada una entera y con un número en cada línea; las demás se listan por dirección |
| `emetgate_evidence` | El código completo de hasta 6 nombres; un nombre definido en varios archivos devuelve todas las definiciones, y un nombre que no es un símbolo se informa junto con los símbolos más cercanos |
| `emetgate_symbols`, `emetgate_skeleton` | Símbolos y firmas con hashes de contenido |
| `emetgate_read_symbol` | Uno o varios cuerpos de símbolos, o un rango de líneas ampliado a símbolos enteros; un cuerpo que supera el presupuesto de lectura (8,192 caracteres) vuelve plegado, con cada rango de líneas omitido nombrado en su lugar; `nodes:true` añade un hash a cada línea que inicia un nodo sintáctico |
| `emetgate_read_file` | Árbol de claves JSON o un solo puntero, encabezados de Markdown o una sola sección, rango de líneas de texto (también de un archivo fuente con `raw:true`) |
| `emetgate_list`, `emetgate_search` | Archivos y búsqueda de texto dentro del repositorio |
| `emetgate_git` | `status`, `diff`, `log`, `show` de solo lectura |
| `emetgate_mutate` | Comprueba un cuerpo propuesto sin escribirlo |
| `emetgate_try`, `emetgate_try_batch` | Reemplaza, crea o elimina símbolos, nodos sintácticos individuales y archivos; un cambio o un lote atómico |
| `emetgate_write_doc` | Escritura en un puntero JSON, una sección de Markdown o un rango de texto, sola o en un lote con código |
| `emetgate_rename` | Renombra una función, clase, variable, tipo o enum en todos los lugares donde se usa |
| `emetgate_move` | Traslada una declaración a otro archivo; el núcleo deriva los imports |
| `emetgate_move_file` | Traslada o renombra un archivo y reescribe cada import hacia él y desde él |
| `emetgate_run` | Ejecuta en la copia sombra un comando que permitiste con `--allow-run` |
| `emetgate_scan` | Mide una regla contra el repositorio |

Con `--mirror` activado, las lecturas no repiten nada dentro de una sesión: un símbolo sin cambios vuelve como una sola línea con su hash.

`emetgate lockdown` inicia Claude Code sin ninguna herramienta integrada, solo con los servidores de `.mcp.json` y con la búsqueda de herramientas desactivada. Pasa a `--allowedTools` las once herramientas que ni cambian el repositorio ni ejecutan un comando, de modo que `emetgate_explore`, `emetgate_evidence`, `emetgate_symbols`, `emetgate_skeleton`, `emetgate_read_symbol`, `emetgate_read_file`, `emetgate_list`, `emetgate_search`, `emetgate_scan`, `emetgate_git` y `emetgate_mutate` se ejecutan sin comprobación de permisos; las herramientas que escriben o ejecutan un comando conservan el modo de permisos que elegiste, que lockdown rechaza solo cuando es `bypassPermissions`. En n8n, una pregunta corta de lectura pasó de 3 turnos a 2 y una llamada de búsqueda en caliente de unos 640 ms a unos 60 ms. El motivo de cada herramienta y la medición están en [REFERENCE.md](REFERENCE.md#lockdown).

## Reglas

```
emetgate rule add "no console.log" --check "cmd:npx eslint --rule no-console" --in src/ --enforce
emetgate rule add "no networkidle waits" --check forbid:networkidle --enforce
emetgate rule list
```

Una regla con `--enforce` rechaza un cambio que la incumple antes de que se ejecuten las pruebas. Las reglas solo se escriben desde la CLI. El modelo puede leerlas y no puede cambiarlas ni eliminarlas.

## Recibos

```
emetgate receipts attach            # attach pending receipts to your last commit as git notes
emetgate verify HEAD --test "npm test"
```

Un recibo es una declaración in-toto en JSON canónico (RFC 8785). `emetgate verify` comprueba un commit sin confiar en el proceso que lo escribió: recalcula los hashes y los hashes alfa y vuelve a ejecutar las pruebas en el sandbox. Un cambio sin recibo, o un archivo editado después de la puerta, se informa como `unverified`, nunca en verde.

El verificador no importa ningún código que escriba. Confía en 2,731 líneas no vacías de Zig en 24 archivos, 727 de ellas en los 3 archivos de `src/verify/`, además de tree-sitter y la biblioteca estándar de Zig. Un segundo verificador en Python, escrito solo a partir del formato del recibo (383 líneas no vacías de Python, más 298 en el BLAKE3 incluido en el repositorio), se ejecuta en cada prueba de verify y debe coincidir con el primero.

## Mediciones

Preguntas sobre una base de código, frente a Serena, codebase-memory-mcp y las herramientas propias de Claude Code (`python tests/bench/neutral/laws.py`, 2026-10-04, `claude-sonnet-5-5`, una copia nueva del repositorio en cada ejecución, sin prompt adicional, tres ejecuciones por pregunta). La puntuación es la proporción de elementos de la clave de respuestas que aparecen en la respuesta; las claves se escribieron antes de ejecutar ninguna herramienta.

| Repositorios | Herramienta | Puntuación | Tokens | Tiempo de API | Coste |
|---|---|---:|---:|---:|---:|
| nest, typeorm, actual (10 preguntas) | Emetgate | 0.944 | 133k | 30.0 s | $0.147 |
| | Serena | 0.963 | 165k | 36.4 s | $0.158 |
| | Herramientas propias de Claude Code | 0.926 | 193k | 35.7 s | $0.168 |
| | codebase-memory-mcp | 0.975 | 199k | 42.0 s | $0.230 |
| OpenBot (5 preguntas) | Emetgate | 0.956 | 97k | 22.7 s | $0.108 |
| | Serena | 0.956 | 102k | 24.5 s | $0.114 |
| | Herramientas propias de Claude Code | 0.933 | 129k | 24.3 s | $0.114 |
| | codebase-memory-mcp | 0.978 | 137k | 35.1 s | $0.152 |

Emetgate puntúa por debajo de codebase-memory-mcp en ambos conjuntos y por debajo de Serena en el primero. La configuración, las 300 sesiones grabadas y los límites de esta comparación están en [tests/bench/neutral](tests/bench/neutral).

Tokens para lecturas habituales, frente a `Read` de Claude Code (o200k_base, `python tests/bench/reader.py`, 2026-09-26):

| Tarea | Read | Emetgate |
|---|---:|---:|
| Encontrar y leer una función en un archivo de 1.6k líneas | 13,313 | 2,819 |
| Leer una clave en un `package-lock.json` de 50 KB | 19,859 | 319 |
| Leer una sección de un README | 15,432 | 1,541 |
| Volver a leer el mismo símbolo en una sesión | 13,313 | 84 |
| Releer un símbolo de 3 líneas después de que cambió | 18 | 74 |

La última fila es peor: la respuesta lleva el hash que necesita la siguiente edición.

Tokens para ediciones completas, frente a `Read` y luego `Edit` de Claude Code (o200k_base, ambos lados contados como los bloques `tool_use` y `tool_result` que guarda el contexto del modelo, `python tests/bench/write_flow.py`, 2026-09-27, el mismo archivo de 1.6k líneas):

| Tarea | Read + Edit | Emetgate |
|---|---:|---:|
| Cambiar una línea en una función grande | 24,646 | 2,145 |
| Reemplazar un bloque `if` | 24,703 | 2,191 |
| Reemplazar entera una función pequeña | 24,734 | 502 |
| Eliminar una función y su único punto de llamada | 24,934 | 810 |
| Dos ediciones en un archivo | 24,813 | 2,213 |
| Cambiar una línea en un archivo ya leído | 139 | 191 |

La última fila es peor. Con el archivo ya en el contexto, `Edit` envía la línea cambiada y recibe una línea; la respuesta predeterminada de emetgate en caso de éxito es el estado y los nuevos hashes (la nota de la copia sombra, los identificadores de recibo y el hash anterior requieren `detail:"full"`), y solo sus argumentos permitirían como mucho 1.9x. Emetgate además ejecuta las pruebas en cada edición, lo que supone la mayor parte de sus 200 a 420 ms por edición. Las mediciones de reglas, consultas y escritura completa están en [REFERENCE.md](REFERENCE.md).

Búsqueda frente a `rg` y `git grep` (`python tests/bench/search.py`, ReleaseFast): la primera búsqueda de una sesión nueva tarda de 5.5 a 22.7 ms y las posteriores de 1.9 a 10.1 ms, frente a rg de 27.2 a 80.9 ms y git grep de 29.1 a 65.7 ms; construir el índice por primera vez, una vez por repositorio, tardó de 91 a 1,335 ms (2026-09-27, ancho de banda de escaneo 3.13 GB/s). Cada búsqueda espera primero a una barrera de vigilancia de cambios, de modo que una escritura cerrada o vaciada antes de la llamada está en el resultado, y una sesión nueva carga el índice guardado y vuelve a leer solo los archivos cuyas marcas cambiaron; la tabla completa y el único caso que esa barrera no cubre (un escritor que mantiene su archivo abierto) están en [REFERENCE.md](REFERENCE.md#search).

| Búsqueda | rg | git grep | Emetgate, primera de la sesión | Emetgate, posteriores |
|---|---:|---:|---:|---:|
| una cadena de mensaje de error | 28.1 ms | 34.8 ms | 6.2 ms | 3.1 ms |
| un término que solo aparece en comentarios | 80.9 ms | 65.7 ms | 22.7 ms | 9.9 ms |
| un valor de clave JSON | 27.2 ms | 29.1 ms | 8.1 ms | 4.8 ms |
| una palabra corta y común | 33.3 ms | 35.9 ms | 11.4 ms | 6.5 ms |
| un patrón regex | 31.3 ms | 47.2 ms | 10.1 ms | 5.9 ms |
| usos de tryRender | 36.8 ms | 36.6 ms | 5.9 ms | 1.9 ms |
| usos de logerror | 28.4 ms | 37.9 ms | 5.5 ms | 2.1 ms |
| búsqueda justo después de una escritura confirmada y un commit de git | 32.0 ms | 29.2 ms | 13.6 ms | 10.1 ms |

rg y git grep se miden como el proceso que inicia una llamada de herramienta, ya que el Grep de Claude Code inicia rg en cada llamada; Emetgate se mide como una llamada a su servidor en ejecución. Iniciar el servidor una vez por sesión y construir el índice una vez por repositorio no están en la tabla; ambos están en REFERENCE.md.

## Cómo se prueba la propia puerta

- **Pruebas de mutación.** Las guardas se mutan y al menos una prueba debe fallar para cada una. Para el motor hay hoy 64 mutantes: 57 eliminados, 4 demostrados equivalentes, 2 guardas redundantes mantenidas como defensa en profundidad, 1 abierto. Cada mutante registrado y la prueba que lo elimina: [VERIFICATION.md](VERIFICATION.md).
- **Verificación de modelos.** El diario de commits está especificado en TLA+ y comprobado con TLC para dos y tres archivos, incluidas las caídas durante la recuperación y las entradas de directorio perdidas.
- **Pruebas de caída.** Los lotes se cortan después de cada paso y se recuperan.
- **Suites de red team y de fuzzing** contra la superficie MCP, el sandbox, el diario y los analizadores.

Los números de los bloques generados del README en inglés se producen a partir del código fuente y se comprueban en CI; en CI también se comprueba que los números de esta página sean los mismos.

## Instalación

Cada versión publica `emetgate.exe` y su SHA-256 en la [página de versiones](https://github.com/emetgate/emetgate/releases).

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\emetgate" | Out-Null
foreach ($f in "emetgate.exe", "emetgate.exe.sha256") { Invoke-WebRequest "https://github.com/emetgate/emetgate/releases/latest/download/$f" -OutFile "$env:USERPROFILE\emetgate\$f" }
(Get-FileHash "$env:USERPROFILE\emetgate\emetgate.exe" -Algorithm SHA256).Hash -eq (Get-Content "$env:USERPROFILE\emetgate\emetgate.exe.sha256").Split(" ")[0]
claude mcp add emetgate -- "$env:USERPROFILE\emetgate\emetgate.exe" mcp --test "npm test"
```

El binario no está firmado, así que SmartScreen avisa en la primera ejecución. Compara la suma de comprobación en su lugar.

## Compilación

Zig 0.16.0. tree-sitter y las gramáticas están incluidos en el repositorio.

```sh
zig build                  # zig-out/bin/emetgate
zig build test             # all tests
tools/accept.ps1 <ref>     # tests three times, then the mutants on lines changed since <ref>
```

## Historial de seguridad

Hallazgos contra la puerta. Detalles en [REFERENCE.md](REFERENCE.md#security-history).

**F1: las herramientas de escritura no estaban confinadas al repositorio servido.** Corregido en v0.1.2.

**F2: `.git` dentro de un worktree de git se rechazaba por el motivo equivocado.** Gravedad baja; corregido.

**F3: una propuesta rechazada podía escribir en el repositorio real mientras se ejecutaban sus pruebas.** Corregido con el token de integridad baja en v0.1.2.

**Registro de reglas del repositorio: las reglas `cmd:` de un registro incluido en un commit se ejecutaban sin consentimiento.** Corregido en el PR #31.

**F4: una caída durante un lote podía dejarlo aplicado a medias.** Encontrado con TLA+; corregido con un registro de commit del lote.

**F5: el comando de pruebas no podía ver `node_modules` a través de una junction.** Fallo funcional; corregido con árboles de hardlinks.

**F6: una caída al reemplazar un archivo podía dejar su ruta vacía.** Encontrado con TLA+; corregido copiando y luego reemplazando.

**F7: un corte de energía podía dejar un lote aplicado a medias.** Encontrado con TLA+; corregido vaciando cuatro cambios de directorio.

## Límites

- Solo Windows; el sandbox usa Job Objects y niveles de integridad. Solo TypeScript, JavaScript y Zig.
- Pasar la puerta significa que el código se analiza, se mantiene dentro de sus límites y pasa tus pruebas. No significa que el código sea correcto.
- La puerta de pruebas es tan fuerte como tus pruebas.
- El sandbox bloquea las escrituras fuera de la copia sombra. No bloquea las lecturas ni el acceso a la red. Existe un backend de AppContainer pero no se usa, porque los proyectos reales todavía no funcionan bajo él.
- Los cambios hechos fuera de la puerta no están cubiertos. Para eso está lockdown.
- Node.js 24.15.0 y anteriores fallan de forma intermitente en conexiones loopback de Windows; usa 24.16.0 o posterior.

## Licencia

MIT. Las gramáticas incluidas bajo `vendor/` conservan sus propias licencias MIT.

<p align="center"><a href="README.md">English</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.ko.md">한국어</a> · <a href="README.zh-CN.md">简体中文</a> · <b>Español</b></p>
