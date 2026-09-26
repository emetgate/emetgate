'use strict';
const fs = require('fs');
const path = require('path');
const root = process.argv[1];
console.log = console.error;
console.info = console.error;
console.warn = console.error;
let ts = null;
let service = null;
let options = null;
let files = [];

function reply(message) {
  process.stdout.write(JSON.stringify(message) + '\n');
}

function version(file) {
  try {
    const stat = fs.statSync(file);
    return stat.mtimeMs + ':' + stat.size;
  } catch (error) {
    return 'missing';
  }
}

function load() {
  if (service) return;
  ts = require(path.join(root, 'node_modules', 'typescript'));
  options = { allowJs: true, noEmit: true };
  const config = path.join(root, 'tsconfig.json');
  if (fs.existsSync(config)) {
    const read = ts.readConfigFile(config, ts.sys.readFile);
    if (!read.error) {
      const parsed = ts.parseJsonConfigFileContent(read.config, ts.sys, root);
      options = Object.assign({}, parsed.options, { allowJs: true, noEmit: true });
    }
  }
  delete options.plugins;
  const host = {
    getScriptFileNames: () => files,
    getScriptVersion: version,
    getScriptSnapshot: (file) => {
      try {
        return ts.ScriptSnapshot.fromString(fs.readFileSync(file, 'utf8'));
      } catch (error) {
        return undefined;
      }
    },
    getCurrentDirectory: () => root,
    getCompilationSettings: () => options,
    getDefaultLibFileName: (settings) => ts.getDefaultLibFilePath(settings),
    fileExists: (file) => ts.sys.fileExists(file),
    readFile: (file, encoding) => ts.sys.readFile(file, encoding),
    readDirectory: (...args) => ts.sys.readDirectory(...args),
    directoryExists: (dir) => ts.sys.directoryExists(dir),
    getDirectories: (dir) => ts.sys.getDirectories(dir),
    useCaseSensitiveFileNames: () => false,
  };
  service = ts.createLanguageService(host, ts.createDocumentRegistry(false, root));
}

function sourceOf(file) {
  const program = service.getProgram();
  const source = program && program.getSourceFile(file);
  if (!source) throw new Error('not in the program: ' + file);
  return source;
}

function toUnits(text, bytes) {
  return Buffer.from(text, 'utf8').subarray(0, bytes).toString('utf8').length;
}

function toBytes(text, units) {
  return Buffer.byteLength(text.slice(0, units), 'utf8');
}

function span(file, textSpan) {
  const text = sourceOf(file).text;
  return { file: file, start: toBytes(text, textSpan.start), end: toBytes(text, textSpan.start + textSpan.length) };
}

function handle(request) {
  load();
  if (request.op === 'ping') return { version: String(ts.version) };
  if (Array.isArray(request.files)) files = request.files;
  if (request.op === 'fileRename') {
    const changes = [];
    for (const f of service.getEditsForFileRename(request.file, request.target, {}, {}) || []) {
      const text = sourceOf(f.fileName).text;
      for (const c of f.textChanges) {
        changes.push({ file: f.fileName, start: toBytes(text, c.span.start), end: toBytes(text, c.span.start + c.span.length), text: c.newText });
      }
    }
    return { changes: changes };
  }
  const position = toUnits(sourceOf(request.file).text, request.offset);
  if (request.op === 'rename') {
    const info = service.getRenameInfo(request.file, position, { allowRenameOfImportPath: false });
    if (!info.canRename) return { can_rename: false, reason: String(info.localizedErrorMessage || '') };
    const found = service.findRenameLocations(request.file, position, false, false, { providePrefixAndSuffixTextForRename: true }) || [];
    const locations = found.map((l) => Object.assign(span(l.fileName, l.textSpan), { prefix: Boolean(l.prefixText || l.suffixText) }));
    return { can_rename: true, locations: locations };
  }
  if (request.op === 'references') {
    const references = [];
    for (const group of service.findReferences(request.file, position) || []) {
      for (const r of group.references) references.push(Object.assign(span(r.fileName, r.textSpan), { definition: Boolean(r.isDefinition) }));
    }
    return { references: references };
  }
  throw new Error('unknown op: ' + request.op);
}

let pending = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  pending += chunk;
  let at;
  while ((at = pending.indexOf('\n')) >= 0) {
    const line = pending.slice(0, at);
    pending = pending.slice(at + 1);
    let request = { id: 0 };
    try {
      request = JSON.parse(line);
      reply(Object.assign({ id: request.id, ok: true }, handle(request)));
    } catch (error) {
      reply({ id: request.id || 0, ok: false, error: String((error && error.message) || error) });
    }
  }
});
process.stdin.on('end', () => process.exit(0));
