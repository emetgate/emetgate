'use strict';
const fs = require('fs');
const path = require('path');

const [typescriptDir, root, requestPath, outPath] = process.argv.slice(2);
const ts = require(typescriptDir);
const request = JSON.parse(fs.readFileSync(requestPath, 'utf8'));

const slash = (p) => p.replace(/\\/g, '/');
const absolute = (rel) => slash(path.join(root, rel));
const relative = (abs) => slash(path.relative(root, abs));
const files = request.files.map(absolute);
const known = new Set(files.map((f) => f.toLowerCase()));
const modules = request.modules;

const options = {
  allowJs: true,
  noEmit: true,
  target: ts.ScriptTarget.ES2022,
  module: ts.ModuleKind.ESNext,
  moduleResolution: ts.ModuleResolutionKind.Bundler,
  experimentalDecorators: true,
  emitDecoratorMetadata: true,
  jsx: ts.JsxEmit.Preserve,
  skipLibCheck: true,
  strict: false,
};

function extensionOf(file) {
  for (const e of ['.d.ts', '.tsx', '.ts', '.jsx', '.js', '.mjs', '.cjs']) if (file.endsWith(e)) return e;
  return '.ts';
}

let resolved = 0;
let unresolved = 0;
const host = {
  getScriptFileNames: () => files,
  getScriptVersion: () => '1',
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
  fileExists: (file) => known.has(slash(file).toLowerCase()) || ts.sys.fileExists(file),
  readFile: (file, encoding) => ts.sys.readFile(file, encoding),
  useCaseSensitiveFileNames: () => false,
  resolveModuleNameLiterals: (literals, containingFile) => literals.map((literal) => {
    const map = modules[relative(containingFile)];
    const target = map && map[literal.text];
    if (!target || !known.has(absolute(target).toLowerCase())) {
      unresolved += 1;
      return { resolvedModule: undefined };
    }
    resolved += 1;
    const file = absolute(target);
    return { resolvedModule: { resolvedFileName: file, extension: extensionOf(file), isExternalLibraryImport: false } };
  }),
};

const service = ts.createLanguageService(host, ts.createDocumentRegistry(false, root));

function textOf(file) {
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

function nodeAt(source, position) {
  let node = source;
  outer: while (true) {
    for (const child of node.getChildren(source)) {
      if (child.getStart(source) <= position && position < child.getEnd()) {
        node = child;
        continue outer;
      }
    }
    return node;
  }
}

function roleOf(node) {
  let current = node;
  let parent = current.parent;
  if (parent && (ts.isPropertyAccessExpression(parent) || ts.isPropertyAccessChain && ts.isPropertyAccessChain(parent)) && parent.name === current) {
    current = parent;
    parent = current.parent;
  }
  while (parent && (ts.isParenthesizedExpression(parent) || ts.isNonNullExpression(parent))) {
    current = parent;
    parent = current.parent;
  }
  if (!parent) return 'read';
  if (ts.isCallExpression(parent) && parent.expression === current) return 'call';
  if (ts.isNewExpression(parent) && parent.expression === current) return 'new';
  if (ts.isTaggedTemplateExpression(parent) && parent.tag === current) return 'call';
  if ((ts.isJsxOpeningElement(parent) || ts.isJsxSelfClosingElement(parent)) && parent.tagName === current) return 'call';
  return 'read';
}

const results = [];
const started = Date.now();
for (const query of request.queries) {
  const file = absolute(query.path);
  const entry = { id: query.id, refs: [], error: null };
  try {
    const source = textOf(file);
    const position = toUnits(source.text, query.offset);
    for (const group of service.findReferences(file, position) || []) {
      for (const r of group.references) {
        const target = textOf(r.fileName);
        const node = nodeAt(target, r.textSpan.start);
        const start = toBytes(target.text, r.textSpan.start);
        const line = target.getLineAndCharacterOfPosition(r.textSpan.start).line + 1;
        entry.refs.push({ path: relative(r.fileName), start, line, role: roleOf(node), definition: Boolean(r.isDefinition) });
      }
    }
  } catch (error) {
    entry.error = String((error && error.message) || error);
  }
  results.push(entry);
}
const memory = process.memoryUsage();
fs.writeFileSync(outPath, JSON.stringify({ version: ts.version, resolved, unresolved, ms: Date.now() - started, rss: memory.rss, results }));
