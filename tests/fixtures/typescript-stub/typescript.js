'use strict';
const fs = require('fs');
const path = require('path');

function plan() {
  return JSON.parse(fs.readFileSync(path.join(__dirname, 'plan.json'), 'utf8'));
}

function sleep(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function act(p) {
  if (p.hang) sleep(60000);
  if (p.exit) process.exit(3);
  if (p.write) {
    try {
      fs.writeFileSync(p.write, 'written by the language service');
    } catch (error) {
      process.stderr.write(String(error));
    }
  }
}

function location(entry) {
  return {
    fileName: entry.file,
    textSpan: { start: entry.start, length: entry.end - entry.start },
    isDefinition: Boolean(entry.definition),
    prefixText: entry.prefix ? 'name: ' : undefined,
  };
}

const sys = {
  readFile: (file) => {
    try {
      return fs.readFileSync(file, 'utf8');
    } catch (error) {
      return undefined;
    }
  },
  fileExists: (file) => fs.existsSync(file),
  directoryExists: (dir) => fs.existsSync(dir),
  readDirectory: () => [],
  getDirectories: () => [],
};

module.exports = {
  version: '0.0.0-stub',
  sys: sys,
  readConfigFile: (file, read) => ({ config: JSON.parse(read(file)) }),
  parseJsonConfigFileContent: (config) => ({ options: Object.assign({}, config.compilerOptions || {}) }),
  ScriptSnapshot: { fromString: (text) => ({ text: text }) },
  getDefaultLibFilePath: () => path.join(__dirname, 'lib.d.ts'),
  createDocumentRegistry: () => ({}),
  createLanguageService(host) {
    return {
      getProgram() {
        return {
          getSourceFile(file) {
            const snapshot = host.getScriptSnapshot(file);
            return snapshot && { text: snapshot.text };
          },
        };
      },
      getRenameInfo(file, position) {
        if (host.getCompilationSettings().plugins) throw new Error('plugins reached the language service');
        const p = plan();
        act(p);
        if (p.canRename === false) return { canRename: false, localizedErrorMessage: 'cannot rename this element' };
        return { canRename: true };
      },
      findRenameLocations(file, position) {
        const p = plan();
        if (p.echo) return [location({ file: file, start: position, end: position + p.echo })];
        return (p.rename || []).map(location);
      },
      getEditsForFileRename(oldPath, newPath) {
        const p = plan();
        act(p);
        return (p.fileRename || []).map((e) => ({ fileName: e.file, textChanges: [{ span: { start: e.start, length: e.end - e.start }, newText: e.text }] }));
      },
      findReferences(file, position) {
        const p = plan();
        act(p);
        return [{ definition: {}, references: (p.references || []).map(location) }];
      },
    };
  },
};
