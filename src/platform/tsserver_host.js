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

function nodeAt(source, position) {
  let node = source;
  for (;;) {
    const inner = ts.forEachChild(node, (child) => (child.getStart(source) <= position && position < child.end ? child : undefined));
    if (!inner) return node;
    node = inner;
  }
}

function keepsObjectKey(location) {
  const source = sourceOf(location.fileName);
  const shorthand = nodeAt(source, location.textSpan.start).parent;
  if (!shorthand || !ts.isShorthandPropertyAssignment(shorthand)) return false;
  const owner = shorthand.parent.parent;
  if (!owner || !ts.isBinaryExpression(owner)) return true;
  return !/^(module\.)?exports\b/.test(owner.left.getText(source));
}

function reachableByName(checker, node) {
  let symbol = checker.getSymbolAtLocation(node);
  if (!symbol) return false;
  if (symbol.flags & ts.SymbolFlags.Alias) symbol = checker.getAliasedSymbol(symbol);
  if (symbol.flags & (ts.SymbolFlags.Property | ts.SymbolFlags.Method | ts.SymbolFlags.Accessor)) return true;
  return Boolean(checker.getExportSymbolOfSymbol(symbol).parent);
}

function untypedBinding(checker, pattern, name) {
  const type = checker.getTypeAtLocation(pattern);
  if (type.flags & ts.TypeFlags.Any) return true;
  const property = type.getProperty(name);
  return !property || !property.declarations || property.declarations.every((d) => ts.isBindingElement(d));
}

function untypedUses(file, position, found) {
  const program = service.getProgram();
  const checker = program.getTypeChecker();
  const at = nodeAt(sourceOf(file), position);
  if (!ts.isIdentifier(at) || !reachableByName(checker, at)) return [];
  const name = at.text;
  const covered = new Set(found.map((l) => l.fileName + ':' + l.textSpan.start));
  const out = [];
  for (const source of program.getSourceFiles()) {
    if (source.isDeclarationFile || program.isSourceFileFromExternalLibrary(source) || !source.text.includes(name)) continue;
    const visit = (node) => {
      let id = null;
      let untyped = false;
      if (ts.isPropertyAccessExpression(node) && node.name.text === name) {
        id = node.name;
        untyped = Boolean(checker.getTypeAtLocation(node.expression).flags & ts.TypeFlags.Any);
      } else if (ts.isBindingElement(node) && ts.isObjectBindingPattern(node.parent)) {
        const key = node.propertyName || node.name;
        if (ts.isIdentifier(key) && key.text === name) {
          id = key;
          untyped = untypedBinding(checker, node.parent, name);
        }
      }
      if (id && untyped && !covered.has(source.fileName + ':' + id.getStart(source))) {
        const start = id.getStart(source);
        out.push({ file: source.fileName, start: toBytes(source.text, start), end: toBytes(source.text, id.end) });
      }
      ts.forEachChild(node, visit);
    };
    visit(source);
  }
  return out;
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
    const keep = request.keep_keys !== false;
    const found = service.findRenameLocations(request.file, position, false, false, { providePrefixAndSuffixTextForRename: keep }) || [];
    const kept = new Map();
    if (!keep) {
      for (const l of service.findRenameLocations(request.file, position, false, false, { providePrefixAndSuffixTextForRename: true }) || []) {
        if (l.prefixText || l.suffixText) kept.set(l.fileName + ':' + l.textSpan.start, l);
      }
    }
    const locations = found.map((l) => {
      const held = kept.get(l.fileName + ':' + l.textSpan.start);
      const text = held && keepsObjectKey(l) ? held : l;
      return Object.assign(span(l.fileName, l.textSpan), { prefix: String(text.prefixText || ''), suffix: String(text.suffixText || '') });
    });
    return { can_rename: true, locations: locations, unresolved: untypedUses(request.file, position, found) };
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
