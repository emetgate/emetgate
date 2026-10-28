<p align="center">
  <img src="../assets/aleph.svg" alt="Emetgate" width="190">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-windows-0078D6?style=flat-square" alt="Platform: Windows">
  <img src="https://img.shields.io/badge/languages-typescript%20%7C%20javascript%20%7C%20python%20%7C%20c%23%20%7C%20zig-3178C6?style=flat-square" alt="Languages: TypeScript, JavaScript, Python, C#, Zig">
  <img src="https://img.shields.io/badge/protocol-MCP-1E1B26?style=flat-square" alt="Protocol: MCP">
  <a href="https://github.com/emetgate/emetgate/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/emetgate/emetgate/ci.yml?branch=main&style=flat-square&label=tests" alt="Tests"></a>
  <a href="https://github.com/emetgate/emetgate/releases/latest"><img src="https://img.shields.io/github/v/release/emetgate/emetgate?style=flat-square" alt="Latest release"></a>
</p>

<p align="center"><a href="../README.md">English</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.ko.md">한국어</a> · <a href="README.zh-CN.md">简体中文</a> · <b>Español</b></p>

# Emetgate

Los LLM son rápidos y capaces: horas de trabajo en minutos. Pero si siguen tus reglas o no, depende de ellos: un modelo puede leer "nunca uses esto" y usarlo de todos modos.

La respuesta habitual es un mejor prompt, un `AGENTS.md` más largo: reglas que al modelo se le *pide* obedecer. Emetgate toma el otro camino: una capa entre el modelo y tu árbol de fuentes. No una instrucción que pueda saltarse, sino una puerta que tiene que pasar. El modelo propone un cambio; el núcleo lo verifica; nada llega al disco salvo que pase.

Funciona como servidor MCP, en Windows, para TypeScript, JavaScript, Python, C# y Zig. Abajo, cada capacidad se descompone en sus partes: qué es cada parte y qué hace aquí. Ninguna afirmación sin el código y la salida real debajo.

## La puerta

Un cambio nombra un símbolo y el hash del código en el que se basó. Emetgate coloca el nuevo cuerpo en su sitio, vuelve a analizar el archivo, ejecuta tus reglas y luego ejecuta tu comprobación de tipos y tus pruebas sobre una copia del repositorio dentro de un sandbox. Si cada paso pasa, se escribe y se vincula a un recibo; si algún paso falla, no se escribe nada.

```
proposal ─▶ reparse ─▶ rules ─▶ typecheck ─▶ tests ─▶ write + receipt  (אמת)
                  └── any step fails ─▶ nothing is written (מת)
```

| parte | qué es | qué hace aquí |
| --- | --- | --- |
| espacio de trabajo en sombra | una copia aislada del repositorio | la escritura propuesta se aplica primero aquí, de modo que las pruebas y la comprobación de tipos corren sin tocar el árbol real; al fallar, el disco nunca cambió |
| tree-sitter | un analizador incremental | vuelve a analizar el archivo para mostrar que el cambio sí se analiza y no rompió el árbol |
| recibo in-toto | un formato de procedencia de cadena de suministro | vincula cada escritura que pasa a un registro firmado de qué se construyó a partir de qué, y con qué pruebas: comprobable más tarde |

## Búsqueda

Dos motores: un índice literal para la velocidad y un motor certificado para la prueba.

### `emetgate_find` — búsqueda literal

Búsqueda de texto plano y de patrones indexables, sin volver al disco. En caliente, por debajo del milisegundo.

| parte | qué es | qué hace aquí |
| --- | --- | --- |
| arreglo de sufijos (SA-IS) | el arreglo ordenado de cada sufijo del texto, construido en tiempo lineal | encuentra un literal en una sola búsqueda binaria `O(m·log n)`, con todas sus coincidencias a la vez |
| dos árboles wavelet | mapas posición→archivo y de cadena de repeticiones sobre el arreglo | dice qué coincidencia está en qué archivo, sin releer el archivo desde el disco |
| índice `.emet` con mmap | un único archivo de índice mapeado en memoria | los archivos no se reabren durante una búsqueda; en caliente `~0.7–1 ms` |

### `emetgate_search` — búsqueda certificada

Una búsqueda que lleva, junto con el resultado, una prueba de que no se perdió nada.

| parte | qué es | qué hace aquí |
| --- | --- | --- |
| postings de trigramas | un índice invertido comprimido (Elias-Fano / mapa de bits) | acota rápido los archivos candidatos, sin escanear todo el repositorio |
| árbol de Merkle RFC 9162 | una raíz sobre el SHA-256 de cada archivo leído | la respuesta lleva la raíz, así una respuesta completa o parcial es demostrable, no afirmada |
| fallo-cerrado (fail-closed) | el certificado se rechaza como `InconsistentCertificate` si los números no cuadran | nunca se muestra un "completo" erróneo; en caso de duda, calla |
| barrera de cambios NTFS | aviso de cambio de archivo vía `ReadDirectoryChangesW` | solo se relee un archivo que cambió (frescura); cero fallos en el benchmark |
| delegación a ripgrep | una regex que el índice no puede servir (`\b`, lookaround…) | se entrega a ripgrep; la respuesta dice `delegated: rg`: sin pérdida de capacidad |

La respuesta lleva una prueba, no una afirmación — salida real:

```
$ search "InconsistentCertificate"
✓ 6 matches in 429 files            # complete, with the Merkle root
$ search "Allocator"
partial: matches 1-46 of 1617; next offset:46
$ search "zzzNeverOccurs"
✓ no match in 569 files              # even zero is proven
```

> caliente ~1.5–3.5 ms · frío (construcción del índice) 661 ms · paridad línea por línea con ripgrep

## Reglas

Una política que fijas una vez se sostiene en cada escritura. El modelo lee las reglas y no puede cambiarlas.

| parte | qué es | qué hace aquí |
| --- | --- | --- |
| consultas tree-sitter | coincidencias estructurales sobre el árbol de sintaxis | comprobaciones de span/símbolo/comentario: `no_comment`, `require_comment`, `max_function_lines`, `forbid_import`… |
| motor de regex (con presupuesto) | un emparejador con límite de pasos | `forbid_regex` / `no_todo`: búsqueda de un patrón o marcador en el span cambiado |
| `ledger.ndjson` | un libro de reglas de solo anexado (`.emetgate/`) | las reglas viven aquí; el modelo las lee pero no las escribe: la política sigue siendo humana |
| comprobación del mensaje de commit | una regla sobre la superficie del mensaje | `message:conventional`: conventional commits sostenidos en el momento del commit |

```
emetgate rule add "ban lodash"        --check forbid_import:lodash --enforce
emetgate rule add "document exports"  --check require_comment --in src/ --enforce
```

## Git verificado

`emetgate verify --branch base..head` reproduce toda la historia de una rama y devuelve un veredicto que delata manipulaciones.

| parte | qué es | qué hace aquí |
| --- | --- | --- |
| cadena de hashes blake3 | cada cert = blake3(parent ‖ oid ‖ verdict ‖ receipt) | reproduce un commit y la punta de la cadena se desplaza: delata manipulaciones |
| refs CAS + índice privado | write-tree / commit-tree sin tocar el árbol de trabajo | un commit con puerta y recibo, sin perturbar tu editor |
| verificación de modelos TLA⁺ | un modelo formal del diario de commits | un commit que un fallo dejó a medias vuelve a un estado consistente: demostrado |
| recibos in-toto | procedencia vinculada al commit (`refs/notes/emetgate`) | sin recibo → `partial` (fallo-cerrado); sin un "verified" fabricado |
| reproducción con git rev-list | recorre el rango `base..head` | reejecuta la verificación de un solo commit para cada uno, tejiendo la cadena |

```
$ emetgate verify --branch main..HEAD
branch partial: 48 commit(s)          # no receipt → fail-closed
  a179a7f unverified (no receipt)  cert 84c2…

# tamper with one receipt:
branch broken: 1 commit(s)
  3ff23a0 MISMATCH  cert ec79…         # the chain tip shifted → caught
```

## Cómo se prueba

| parte | qué es | qué hace aquí |
| --- | --- | --- |
| pruebas de mutación | rompe el código a propósito y comprueba que la suite lo note | prueba que las pruebas *atrapan* un fallo, no solo que pasan |
| TLA⁺ | una verificación de modelo del diario de commits | la corrección de la recuperación tras un fallo, argumentada aparte del código |
| fuzz y red-team | mutación aleatoria más corpus de ataque | sin caída ni escape ante entrada inesperada u hostil |
| puerta de paridad con ripgrep | compara el conjunto de aciertos contra rg en cada ejecución | la búsqueda no puede ser "rápida pero errónea"; se verifica línea por línea |

Para el motor: 68 mutantes hoy: 59 eliminados, 6 demostrados equivalentes, 2 guardas redundantes conservadas como defensa en profundidad, 1 abierto. La lista está en [VERIFICATION.md](../VERIFICATION.md).

## Medido

| superficie | medida | resultado |
| --- | --- | --- |
| suite de pruebas completa | pasa / falla / fugas | 2386 / 0 / 0 |
| paridad de búsqueda | líneas rg = emetgate | 1617=1617 · 6=6 · 2=2 |
| búsqueda en caliente | mediana | 1.5–3.5 ms |
| find en caliente | mediana | 0.7–1.0 ms |
| verify (recibo manipulado) | veredicto | broken (atrapado) |

```
python tests/bench/n8n_search.py   ·   zig build test
```

## Instalación

¿Primera vez? Sigue [docs/QUICKSTART.md](../docs/QUICKSTART.md): instala, ejecuta `emetgate doctor` y después `emetgate lockdown`.

Descarga el binario de Windows de la [última versión](https://github.com/emetgate/emetgate/releases/latest) y añade su carpeta al `PATH` (PowerShell; abre una terminal nueva después):

```
New-Item -ItemType Directory -Force "$env:USERPROFILE\emetgate" | Out-Null
Invoke-WebRequest "https://github.com/emetgate/emetgate/releases/latest/download/emetgate.exe" -OutFile "$env:USERPROFILE\emetgate\emetgate.exe"
[Environment]::SetEnvironmentVariable("Path", [Environment]::GetEnvironmentVariable("Path", "User") + ";$env:USERPROFILE\emetgate", "User")
```

Después, en la carpeta del proyecto:

```
emetgate lockdown --test "npm test"
```

Windows · TypeScript / JavaScript / Python / C# / Zig. `emetgate lockdown` arranca el agente solo con las herramientas de emetgate, en fallo-cerrado. Si omites `--test`, el comando de pruebas se detecta en cada escritura (`package.json` `scripts.test`, `build.zig`, `Cargo.toml`, `go.mod`, `pyproject.toml`, un `.sln` o un `.csproj`). En una carpeta vacía lockdown ejecuta `git init`, y las escrituras quedan como `unverified_no_tests` hasta que el proyecto tenga un comando de pruebas.

Lockdown lee solo el `.mcp.json` del propio proyecto, nunca un servidor registrado a nivel de usuario. Para usar emetgate como servidor junto a las demás herramientas, o para dar a lockdown tus propios argumentos de servidor, regístralo para el proyecto:

```
claude mcp add --scope project emetgate -- emetgate mcp --test "npm test"
```

Con ese `.mcp.json` en su sitio, lockdown toma de él el comando de pruebas, y `emetgate lockdown --test` se rechaza.

## Profundiza

- [REFERENCE.md](../REFERENCE.md) — cada herramienta
- [VERIFICATION.md](../VERIFICATION.md) — recibos y prueba
- [docs/experiments/tla](../docs/experiments/tla) — los modelos TLA⁺
- [tests/bench](../tests/bench) — los benchmarks

## Límites

Solo Windows; TypeScript, JavaScript, Python, C# y Zig. El sandbox bloquea las escrituras, no las lecturas ni la red. Pasar la puerta prueba que un cambio se analiza y pasa *tus* pruebas: es solo tan fuerte como esas pruebas. Los benchmarks son nuestros, de una sola máquina, y reproducibles.

## De dónde viene el nombre

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../assets/golem-ales-dark.jpg">
  <img src="../assets/golem-ales-light.jpg" alt="Un dibujo a pluma de 1899: el rabino Loew alza la mano y el rostro del golem se forma en el humo, con letras hebreas en la frente" width="220" align="left">
</picture>

En la leyenda de Praga, el golem cobra vida por la palabra **אמת** (*emet*, "verdad") en su frente. Borra la primera letra y **אמת** se convierte en **מת** (*met*, "muerto"): el golem queda inmóvil. La puerta escribe la primera letra cuando un cambio se sostiene; una prueba que falla la borra.

<br clear="left">

## Licencia

MIT. Ver [LICENSE](../LICENSE).
