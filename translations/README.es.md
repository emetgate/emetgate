<p align="center">
  <img src="../assets/readme/hero-once-en.svg" alt="emetgate: say it once" width="100%">
</p>

<p align="center"><a href="../docs/QUICKSTART.md"><b>Inicio rápido</b></a> · <a href="../REFERENCE.md"><b>Referencia</b></a> · <a href="../VERIFICATION.md"><b>Verificación</b></a> · <a href="../examples/discount"><b>Una sesión real</b></a></p>

<p align="center"><sub><a href="../README.md">English</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.ko.md">한국어</a> · <a href="README.zh-CN.md">简体中文</a> · <b>Español</b></sub></p>

> [!NOTE]
> Por ahora solo en Windows. Hecho para Claude Code; funciona en proyectos TypeScript, JavaScript, Python, C# y Zig.

Le dices a tu agente "sin comentarios". Te hace caso un rato. Luego la sesión se alarga, el contexto se compacta, al día siguiente empieza una sesión nueva y el mismo comentario vuelve. Lo pones en CLAUDE.md; ahí también se queda en una petición.

En emetgate una regla no vive en la conversación. Vive en un libro de reglas aparte y se aplica a cada escritura del agente. Si el agente rompe una regla, la escritura nunca llega al disco; el agente ve por qué y lo corrige en el mismo turno.

No es una impresión. La propia documentación de Claude Code dice lo mismo:

> *"CLAUDE.md instructions shape Claude's behavior but are not a hard enforcement layer."* Las instrucciones de CLAUDE.md moldean el comportamiento de Claude, pero no son una capa que las haga cumplir. ([code.claude.com/docs/en/memory](https://code.claude.com/docs/en/memory))

<p align="center">
  <a href="../assets/video/emetgate-ad-en.mp4"><img src="../assets/readme/emetgate-ad-en-cover.png" alt="Vídeo: una regla en un archivo Markdown es una petición, en emetgate es una puerta" width="100%"></a>
  <br><sub>Mira el vídeo: le pedimos al agente que rompa la regla a propósito y la puerta igual no lo escribe.</sub>
</p>

## Cómo funciona

<p align="center">
  <img src="../assets/readme/pillars-once-en.svg" alt="Dilo una vez; la regla se queda; corregido antes de que lo veas" width="100%">
</p>

### Dilo una vez

Cuando das una instrucción duradera en el chat ("de ahora en adelante", "nunca"), emetgate le pide al agente que proponga la línea `/rule` que la convierte en regla. La confirmas y se convierte en regla. También puedes escribir tu propia regla en una línea:

```
emetgate rule add "no lint suppression" --check forbid_regex:eslint-disable --enforce
```

O eliges del catálogo incluido, donde están las habituales: sin `console.log`, sin comentarios nuevos, sin `Co-authored-by`:

<img src="../assets/readme/term-rules-en.svg" alt="emetgate rule pick y emetgate rule add en una terminal" width="100%">

### La sesión termina, la regla se queda

La regla vive en un registro bajo `.emetgate/`. Por larga que sea la sesión, después de compactar, en la sesión nueva de mañana, la misma regla se aplica a cada escritura.

Una regla que quieres en todos los proyectos va en tu registro global: añade `--global` a `emetgate rule add` o `emetgate rule pick`. Vive en `%LOCALAPPDATA%\emetgate\rules`, fuera de cualquier repositorio, y se aplica junto con las reglas propias de cada repositorio; un repositorio no puede cambiarla ni quitarla.

Con `emetgate lockdown`, las herramientas propias de edición y escritura de Claude Code están apagadas; el agente cambia archivos con las herramientas de emetgate y cada cambio pasa por las mismas reglas. El agente no tiene herramienta para añadir, cambiar o borrar una regla; un comando que lo intente te pregunta primero.

Añadir una regla a un repositorio antiguo no rompe nada: solo se rechazan las infracciones nuevas.

### Corregido antes de que lo veas

El rechazo vuelve al agente con su línea y columna; el agente lo corrige en el mismo turno. Tú ves el resultado que cumple la regla.

```
rejected: rule mf97c482341f15e82 (forbid:console.log) at src\pricing.js:3:3: console.log
rejected: rule me2014a06b646515d (added:no_comment) at src\pricing.js:2:3: // clamp the percent
```

## Por qué un hook o ESLint no bastan

Con los hooks de Claude Code y ESLint puedes montar parte de esto tú mismo. La diferencia:

- **La puerta es la misma para cada herramienta de escritura.** Lockdown apaga las herramientas de edición propias de Claude Code; ediciones, renombrados, movimientos y borrados pasan por las mismas reglas. Si el agente cambia un archivo con un comando de shell, queda registrado, las rutas congeladas se restauran y un cambio que no pasó la puerta no se puede hacer commit con emetgate.
- **El agente puede apagar ESLint.** Una línea `eslint-disable` y `.eslintrc` están en archivos que el agente puede editar. Las reglas de emetgate están en un registro que el agente no tiene herramienta para cambiar; añadir `eslint-disable` puede chocar con una regla.
- **El cambio se revisa entero.** Un cambio que toca varios archivos se revisa junto sobre una copia del repositorio; si pasa se escribe todo, si no, nada.
- **Del chat a la regla.** Una instrucción duradera que das se propone como regla; no escribes un script por regla.

## Además

**La búsqueda dice qué leyó.** Cuando el agente dice "encontré todos los usos", la respuesta muestra cuántos archivos revisó y si los leyó todos. Si los números no cuadran, no se muestra resultado.

<img src="../assets/readme/term-search-en.svg" alt="Salida de búsqueda de emetgate con recuento de archivos" width="100%">

**Los commits llevan un registro.** Cada commit hecho a través de la puerta guarda en `refs/notes/emetgate` qué archivos se escribieron y qué comprobaciones corrieron. Es un registro, no una firma: muestra después cómo se escribió algo.

<img src="../assets/readme/term-verify-en.svg" alt="Salida de emetgate verify" width="100%">

Comprueba un commit con el comando de pruebas en el que confías; el comando que registra un recibo nunca se vuelve a ejecutar, así que sin `--test` el commit queda `unverified`:

```
emetgate verify HEAD --test "npm test"
```

**Mira cuánto costó una sesión.** `emetgate report` resume la última sesión del proyecto que llamó a las herramientas de emetgate: duración, turnos del modelo, tokens de input, output y caché, un coste estimado en USD, llamadas a herramientas por nombre y lo que hizo la puerta (escrituras aplicadas y rechazadas, violaciones de reglas, ejecuciones de pruebas, recibos, commits). `--session <id>` elige una sesión, `--all` lista todas en una tabla y `--json` imprime los mismos números en JSON. Los tokens salen del propio registro de Claude Code (`projects/` bajo `CLAUDE_CONFIG_DIR`, o `~/.claude`); el coste usa precios de lista integrados por modelo, así que es una estimación, no tu factura.

**Mira lo que toca el agente.** Con `emetgate lockdown`, las llamadas de emetgate aparecen en la transcripción como las herramientas propias de Claude Code, también cuando las llamadas se agrupan: `Read(archivo)` con las líneas que leyó, `Search("…")` con los primeros resultados, `Update(archivo)` con las líneas cambiadas y su contexto, `Write(archivo)`, `Bash(comando)` con su salida. Junto a una lectura o una edición, una franja fina muestra qué partes del archivo ha visto el agente hasta ahora, y una edición de una parte que nunca leyó se marca como `edited without reading`. Mientras corre una lectura, una franja recorre el archivo; al terminar el turno, una línea resume el turno y lista cada archivo tocado con cuánto se leyó de cada uno. Solo dibuja: el modelo recibe las mismas respuestas. Un archivo secreto (`.env`, claves, credenciales) muestra su nombre, nunca su contenido. `emetgate lockdown --no-marks` lo desactiva.

## Bases de datos

El agente puede leer la base de datos del proyecto sin ver lo que guardas en privado. Se configura una vez en una terminal:

```
emetgate db add main data/app.db
emetgate db hide main users.password_hash
emetgate db mask main users.email --mode email
emetgate db block main api_keys
emetgate db protect main
```

El agente lee con `emetgate_db`: lista tablas, las describe, toma filas de muestra y ejecuta un `SELECT` por llamada, en JSON, CSV o Markdown, con límites de filas, tamaño de celda, tamaño de respuesta y tiempo. El archivo se abre en solo lectura y cada sentencia pasa por el autorizador de SQLite antes de ejecutarse. Una columna oculta se lee como NULL dondequiera que aparezca (`SELECT *`, una vista, una subconsulta, un `WHERE`); una tabla bloqueada se rechaza incluso a través de una vista; una columna enmascarada vuelve enmascarada con cualquier alias, y una consulta que la mete dentro de una expresión se rechaza. Las reglas siguen la columna de la que viene un valor, no el nombre que se le da.

**MongoDB** funciona igual. `db add` inicia sesión una vez para comprobar la URI y luego la sella, contraseña incluida, con DPAPI de Windows:

```
emetgate db add shop "mongodb://app:secret@db.local:27017/shop?authSource=admin&tls=true"
emetgate db hide shop users.ssn
emetgate db mask shop users.email --mode email
emetgate db block shop audit_log
```

Las colecciones hacen de tablas y una regla nombra un campo de primer nivel. En lugar de SQL, el agente envía un comando JSON: `find` (filter, projection, sort, limit, skip), `aggregate` (pipeline), `distinct` o `countDocuments`. emetgate analiza cada comando y lo recorre entero antes de enviar nada. Rechaza un campo oculto o enmascarado nombrado en cualquier sitio (un filtro, un orden, `$expr`, una ruta con puntos, `$getField`), las referencias al documento entero como `$$ROOT`, el JavaScript del lado del servidor, `$out` y `$merge`, y los joins (`$lookup`, `$unionWith`, `$graphLookup`) hacia una colección que tiene reglas. El pipeline que se ejecuta quita los campos ocultos al principio y al final, y la respuesta los vuelve a quitar y enmascara los enmascarados por nombre. Una vista se comprueba como el pipeline al que sustituye.

**Escribir requiere tu permiso.** El agente solo lee. Para dejar que cambie datos, escribe `/db write` como prompt: el hook lo responde y el modelo nunca lo ve. Solo durante el turno de tu siguiente prompt puede `emetgate_db_write` ejecutar `INSERT`, `UPDATE`, `DELETE` o DDL (en MongoDB: `insertOne`, `insertMany`, `updateOne`, `updateMany`, `deleteOne`, `deleteMany`, `drop`), y cada sentencia queda registrada con su número de filas. Borrar una tabla, vaciarla o cambiar todas sus filas sigue rechazado salvo que hayas escrito `/db write --destructive`; `/db read` termina el modo de escritura al instante.

**PostgreSQL** funciona igual. Se añade por URL. La contraseña se sella con DPAPI en `%LOCALAPPDATA%\emetgate\db\credentials` y nunca se escribe en el repositorio; puedes dejarla fuera de la URL y poner `PGPASSWORD` para el comando `db add`:

```
emetgate db add prod "postgres://reader@db.example.com:5432/shop?sslmode=verify-full"
emetgate db hide prod users.password_hash
emetgate db mask prod users.email --mode email
emetgate doctor
```

emetgate habla el protocolo de PostgreSQL por sí mismo: inicio de sesión SCRAM-SHA-256 y TLS verificado contra el almacén raíz de Windows o `sslrootcert` con `sslmode=verify-full`. Cada lectura corre en una transacción `READ ONLY` con un tiempo límite por sentencia y se revierte. Antes de ejecutar una consulta, emetgate pide al servidor su plan (`EXPLAIN (VERBOSE)`) y revisa cada tabla que el plan toca, también a través de vistas y subconsultas, y cada columna y función que usa. Una columna oculta o enmascarada solo puede seleccionarse directamente, y entonces vuelve como NULL o enmascarada; en cualquier otro lugar (`WHERE`, `ORDER BY`, `GROUP BY`, una función, `row_to_json(t)`, la fila entera `t`, `UNION`, una subconsulta escalar) la consulta se rechaza. También se rechazan los catálogos del sistema como `pg_stats`, `COPY` y toda función fuera de una lista integrada (`pg_read_file`, `lo_get`, `dblink`, `query_to_xml`, `set_config`, funciones definidas en la base de datos). Conéctate con un rol que solo tenga `SELECT`: `emetgate doctor` avisa si el rol es superusuario o puede escribir.

## Empieza en 2 minutos

En PowerShell, y luego abre una terminal nueva:

```
irm https://github.com/emetgate/emetgate/releases/latest/download/install.ps1 | iex
```

En la carpeta de tu proyecto:

```
emetgate doctor
emetgate rule pick 1 19 26
emetgate lockdown
```

`emetgate doctor` es una comprobación de instalación en una pantalla, una línea `ok`, `warn` o `FAIL` cada una con su solución: qué emetgate ejecuta el PATH y las copias ocultas, si hay una versión nueva, claude y la carpeta de configuración que lee (`CLAUDE_CONFIG_DIR` o `~/.claude`), dónde está registrado emetgate como servidor MCP, otros procesos de emetgate en ejecución, el tamaño de la carpeta de datos y si esta carpeta es un repositorio git. `--json` imprime lo mismo en JSON.

`emetgate lockdown` inicia Claude Code solo con las herramientas de emetgate. Ejecútalo dentro de la carpeta de tu proyecto (un repositorio git), no desde tu carpeta personal ni desde la raíz de una unidad. Paso a paso: [docs/QUICKSTART.md](../docs/QUICKSTART.md).

## Desinstalar

```
emetgate uninstall
emetgate uninstall --yes
```

El primer comando no borra nada: lista la carpeta del programa (`%LOCALAPPDATA%\Programs\emetgate`), su entrada en tu PATH de usuario y la carpeta de datos (`%LOCALAPPDATA%\emetgate`, cachés que pueden llegar a varios GB) con su tamaño. `--yes` los borra; añade `--keep-cache` para conservar la carpeta de datos. La carpeta del programa desaparece unos segundos después de que el comando termina, porque un emetgate.exe en ejecución no puede borrarse a sí mismo. Si hay otros procesos de emetgate en ejecución, lista sus PID y no borra nada hasta que los cierres. La carpeta `.emetgate` y la entrada de `.mcp.json` de cada proyecto se quedan; bórralas a mano.

### Uso de disco

emetgate guarda cachés por proyecto (índice de búsqueda, hechos, la copia sobre la que corren las pruebas) en `%LOCALAPPDATA%\emetgate`. El servidor borra una vez al día las cachés sin usar durante 30 días. Para verlas y recortarlas tú mismo:

```
emetgate cache size                  # total, per folder and per project (--json for scripts)
emetgate cache prune --dry-run       # what would go, nothing deleted
emetgate cache prune                 # remove caches unused for 14 days (--older-than <days>)
emetgate cache prune --all           # remove every cache no running emetgate is using
```

Una caché que un emetgate en ejecución tiene arrendada nunca se borra. Las carpetas compartidas `cache` y `run-tmp` (cachés de paquetes y TEMP de los comandos aislados) solo se vacían con `--all`, y solo mientras no corra ningún otro proceso de emetgate.

## Límites

- Por ahora solo en Windows.
- Bases de datos: SQLite, PostgreSQL y MongoDB; MySQL llegará después. Guarda una base de datos SQLite con columnas ocultas o enmascaradas fuera del repositorio y ejecuta `emetgate db protect`, para que ninguna herramienta de archivos ni ningún comando lea el archivo en sí. En PostgreSQL, una consulta que la revisión del plan no puede rastrear se rechaza en vez de ejecutarse, así que algunas consultas válidas sobre tablas con columnas ocultas o enmascaradas se rechazan (una vista, un `UNION` o una subconsulta escalar que devuelve esa columna). Las conversiones implícitas y las funciones de tipo que definen las extensiones corren sin revisión; un rol con el mínimo de permisos es el respaldo. Un servidor MongoDB debe pedir contraseña; si no, cualquier programa de la máquina puede leerlo directamente. emetgate solo inicia sesión con SCRAM, no resuelve `mongodb+srv://` (escribe los hosts uno a uno) y no puede conectarse a un servidor que pide un certificado TLS de cliente.
- Las reglas se aplican a los cambios hechos con las herramientas de escritura de emetgate. Un comando que ejecuta el agente no pasa por la puerta: los archivos que cambia se informan y las rutas congeladas se restauran, pero las demás reglas no se aplican a comandos. Con lockdown se rechaza un comando que borra archivos del repositorio sin recursión; el agente los borra con `emetgate_delete`, que pasa por la puerta. `git rm` por `emetgate_git_write` se rechaza igual, incluso con `force:true`; `git rm --cached`, que deja el archivo en el disco, sigue funcionando.
- El registro de reglas es un archivo bajo `.emetgate/`. El agente no tiene herramienta para escribirlo, pero una edición hecha con un comando no la detecta el hook que vigila los comandos de reglas.
- `emetgate_git_write` no cambia archivos por fuera de la puerta: `git clean`, `git mv`, `git apply` y `git am` se rechazan incluso con `force:true`, y la corrección indica `emetgate_delete`, `emetgate_move_file` o `emetgate_change`; `clean -n`, `mv -n`, `apply --check`, `--stat` y `--cached` siguen funcionando. Un `reset --hard`, `restore` o `checkout` de rutas forzado restaura después las rutas congeladas, como hace un comando.
- Fuera de lockdown, en una sesión abierta con las herramientas propias del agente, no hay puerta. En otros agentes que hablan MCP, la puerta funciona mientras el agente use las herramientas de emetgate.
- Cada escritura tarda unos 0.2–0.4 s en la puerta. No prometemos menos tokens.
- Los recibos no están firmados: detectan un recibo editado fuera de sincronía con su commit, no un historial reescrito.
- La comprobación de comandos destructivos mira palabras; no es un sandbox.

## Por dentro

<details>
<summary>La puerta: reanálisis, reglas, comprobación de tipos y tests sobre una copia, y luego una sola escritura</summary>

Un cambio nombra un símbolo y el hash del código en el que se basó. emetgate coloca el cuerpo nuevo, vuelve a analizar el archivo, ejecuta las reglas y después la comprobación de tipos y los tests sobre una copia del repositorio dentro de un sandbox de baja integridad. Si todos los pasos pasan, se escribe; si uno falla, no se escribe nada. La escritura pasa por un journal; si se corta, `emetgate recover` la repara.

</details>

<details>
<summary>Reglas: consultas sobre el árbol sintáctico, patrones, comandos, rutas congeladas, mensajes de commit</summary>

Las comprobaciones de reglas son consultas sobre el árbol sintáctico (`no_comment`, `require_comment`, `max_function_lines`, `forbid_import`), regex con límite de pasos en la zona cambiada (`forbid_regex`, `no_todo`), comandos, rutas congeladas y comprobaciones del mensaje de commit (`message:conventional`, sin Co-authored-by). El registro `ledger.ndjson` solo admite añadir; el modelo lo lee y no tiene herramienta para escribirlo. El hook de chat de lockdown procesa una línea `/rule` antes de que llegue al modelo y propone convertir una instrucción duradera en regla.

</details>

<details>
<summary>Búsqueda y verificación: las técnicas</summary>

La búsqueda usa un índice de suffix array y listas de trigramas; muestra si una respuesta es completa o parcial con una raíz Merkle RFC 9162 sobre el SHA-256 de cada archivo leído, y se compara línea por línea con ripgrep. Los registros de commit son declaraciones in-toto, y `emetgate verify --branch main..HEAD --test "<cmd>"` revisa un rango entero; un commit sin recibo cuenta como `partial`. Detalles: [REFERENCE.md](../REFERENCE.md), [VERIFICATION.md](../VERIFICATION.md).

</details>

## De dónde viene el nombre

En la leyenda de Praga, el gólem cobra vida con la palabra **אמת** (*emet*, "verdad") en la frente; si se borra la primera letra queda **מת** (*met*, "muerto") y se detiene. En emetgate, un cambio que rompe una regla no se escribe.

MIT. Ver [LICENSE](../LICENSE).
