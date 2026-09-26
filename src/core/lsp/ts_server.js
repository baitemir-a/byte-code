// A small language server for JavaScript and TypeScript, run by the editor
// with node: `node -e <this> <path to typescript.js>`. It speaks the
// Language Server Protocol on stdin/stdout over TypeScript's own language
// service, using the project's TypeScript — nothing to install besides
// what the project already has. What it answers: hover, completion,
// rename, quick fixes (code fixes: missing imports and the like), and the
// file's syntax and type errors.
const ts = require(process.argv[1]);
const fs = require('fs'), path = require('path');
// Missing modules and their types are reported by the editor itself.
const skip = new Set([2307, 2792, 7016, 2875, 7026]);
const projects = new Map();
const norm = f => f.replace(/\\/g, '/');

function parse(config) {
  const read = ts.readConfigFile(config, ts.sys.readFile);
  if (read.error) return null;
  return ts.parseJsonConfigFileContent(read.config, ts.sys, path.dirname(config), undefined, config);
}

function configFor(file) {
  const dir = path.dirname(file);
  const found = ts.findConfigFile(dir, ts.sys.fileExists, 'tsconfig.json') || ts.findConfigFile(dir, ts.sys.fileExists, 'jsconfig.json');
  if (!found) return null;
  const parsed = parse(found);
  if (!parsed) return null;
  if (parsed.fileNames.map(norm).includes(file)) return { config: found, parsed };
  // A solution config (Vite's): the referenced one that has the file, or
  // for a file not saved yet, the first one that has any.
  let fallback = null;
  for (const ref of parsed.projectReferences || []) {
    let p = ref.path;
    if (!p.endsWith('.json')) p = path.join(p, 'tsconfig.json');
    const sub = ts.sys.fileExists(p) && parse(p);
    if (!sub) continue;
    if (sub.fileNames.map(norm).includes(file)) return { config: p, parsed: sub };
    if (!fallback && sub.fileNames.length > 0) fallback = { config: p, parsed: sub };
  }
  return fallback || { config: found, parsed };
}

function projectFor(file) {
  const found = configFor(file);
  const key = found ? found.config : '';
  let p = projects.get(key);
  if (p) return p;
  const options = found ? { ...found.parsed.options } : {
    target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.ESNext,
    moduleResolution: ts.ModuleResolutionKind.Bundler ?? ts.ModuleResolutionKind.NodeJs,
    jsx: ts.JsxEmit.ReactJSX, allowJs: true, esModuleInterop: true, allowSyntheticDefaultImports: true,
    resolveJsonModule: true, allowImportingTsExtensions: true,
  };
  Object.assign(options, { noEmit: true, skipLibCheck: true });
  if (found && path.basename(found.config) === 'jsconfig.json') options.allowJs = true;
  const roots = found ? found.parsed.fileNames.map(norm) : [];
  const open = new Map();
  const host = {
    getScriptFileNames: () => [...new Set([...roots, ...open.keys()])],
    getScriptVersion: f => {
      const o = open.get(f);
      if (o) return 'open' + o.version;
      try { return String(fs.statSync(f).mtimeMs); } catch { return '0'; }
    },
    getScriptSnapshot: f => {
      const o = open.get(f);
      if (o) return ts.ScriptSnapshot.fromString(o.text);
      const text = ts.sys.readFile(f);
      return text === undefined ? undefined : ts.ScriptSnapshot.fromString(text);
    },
    getCurrentDirectory: () => found ? path.dirname(found.config) : process.cwd(),
    getCompilationSettings: () => options,
    getDefaultLibFileName: o => ts.getDefaultLibFilePath(o),
    fileExists: f => open.has(f) || ts.sys.fileExists(f),
    readFile: f => open.has(f) ? open.get(f).text : ts.sys.readFile(f),
    readDirectory: ts.sys.readDirectory,
    directoryExists: ts.sys.directoryExists,
    getDirectories: ts.sys.getDirectories,
    realpath: ts.sys.realpath,
  };
  p = { open, ls: ts.createLanguageService(host, ts.createDocumentRegistry()), n: 0 };
  projects.set(key, p);
  return p;
}

// ------------------------------------------------------------ the protocol

function send(msg) {
  const body = JSON.stringify(msg);
  process.stdout.write('Content-Length: ' + Buffer.byteLength(body) + '\r\n\r\n' + body);
}

// The editor gone (even without saying so): so is this.
process.stdin.on('end', () => process.exit(0));

let input = Buffer.alloc(0);
process.stdin.on('data', d => {
  input = Buffer.concat([input, d]);
  for (;;) {
    const h = input.indexOf('\r\n\r\n');
    if (h < 0) return;
    const m = /content-length: *(\d+)/i.exec(input.slice(0, h).toString());
    const n = m ? +m[1] : 0;
    if (input.length < h + 4 + n) return;
    const body = input.slice(h + 4, h + 4 + n).toString('utf8');
    input = input.slice(h + 4 + n);
    let msg;
    try { msg = JSON.parse(body); } catch { continue; }
    let result = null, error = null;
    try { result = handle(msg); } catch (e) { error = { code: -32603, message: String(e && e.message || e) }; }
    if (msg.id !== undefined && msg.method) send(error ? { jsonrpc: '2.0', id: msg.id, error } : { jsonrpc: '2.0', id: msg.id, result: result ?? null });
  }
});

function fileOf(uri) {
  let p = decodeURIComponent(new URL(uri).pathname);
  if (/^\/[A-Za-z]:/.test(p)) p = p.slice(1);
  return norm(p);
}

function uriOf(file) {
  const p = norm(file);
  return 'file://' + (p.startsWith('/') ? '' : '/') + p.split('/').map(encodeURIComponent).join('/').replace(/%3A/g, ':');
}

const docs = new Map(); // file -> { uri, text, version }

function open(uri, text, version) {
  const file = fileOf(uri);
  docs.set(file, { uri, text, version });
  const p = projectFor(file);
  p.open.set(file, { version: ++p.n, text });
  publish(file);
}

function sourceOf(p, file) {
  return p.ls.getProgram().getSourceFile(file);
}

function offsetAt(file, pos) {
  const d = docs.get(file);
  const text = d ? d.text : ts.sys.readFile(file) || '';
  let line = 0, i = 0;
  while (line < pos.line) {
    const nl = text.indexOf('\n', i);
    if (nl < 0) return text.length;
    i = nl + 1;
    line++;
  }
  const end = text.indexOf('\n', i);
  return Math.min(i + pos.character, end < 0 ? text.length : end);
}

function rangeOf(sf, start, length) {
  const a = sf.getLineAndCharacterOfPosition(start);
  const b = sf.getLineAndCharacterOfPosition(start + length);
  return { start: { line: a.line, character: a.character }, end: { line: b.line, character: b.character } };
}

function publish(file) {
  const d = docs.get(file);
  if (!d) return;
  const p = projectFor(file);
  const sf = sourceOf(p, file);
  const diagnostics = [];
  if (sf) for (const x of [...p.ls.getSyntacticDiagnostics(file), ...p.ls.getSemanticDiagnostics(file)]) {
    if (x.start === undefined || skip.has(x.code) || x.category !== ts.DiagnosticCategory.Error) continue;
    diagnostics.push({
      range: rangeOf(sf, x.start, x.length || 0),
      severity: 1,
      code: x.code,
      source: 'ts',
      message: ts.flattenDiagnosticMessageText(x.messageText, ' ').replace(/\s+/g, ' '),
    });
  }
  send({ jsonrpc: '2.0', method: 'textDocument/publishDiagnostics', params: { uri: d.uri, version: d.version, diagnostics } });
}

// Auto-imports: suggest what other modules export, and import it on pick.
const preferences = {
  includeCompletionsWithInsertText: true,
  includeCompletionsForModuleExports: true,
  includeCompletionsForImportStatements: true,
  importModuleSpecifierPreference: 'shortest',
};

// The typed word's letters in order in the name, starting with its first.
function fits(name, typed) {
  if (name[0] !== typed[0]) return false;
  let i = 1;
  for (let j = 1; j < name.length && i < typed.length; j++) if (name[j] === typed[i]) i++;
  return i === typed.length;
}

// Where an auto-import comes from, as the import will say it: a package
// name, or a path relative to the file.
function moduleOf(file, e) {
  if (e.sourceDisplay && e.sourceDisplay.length) return ts.displayPartsToString(e.sourceDisplay);
  const spec = (e.data && e.data.moduleSpecifier) || e.source;
  if (!spec || !path.isAbsolute(spec)) return spec;
  let rel = norm(path.relative(path.dirname(file), spec)).replace(/(\.d)?\.[cm]?[jt]sx?$/, '').replace(/\/index$/, '');
  return rel.startsWith('.') ? rel : './' + rel;
}

// CompletionItemKind for TypeScript's ScriptElementKind.
function kindOf(k) {
  const K = ts.ScriptElementKind;
  switch (k) {
    case K.functionElement: case K.localFunctionElement: return 3;
    case K.memberFunctionElement: case K.constructSignatureElement: case K.callSignatureElement: return 2;
    case K.memberVariableElement: case K.memberGetAccessorElement: case K.memberSetAccessorElement: return 10;
    case K.classElement: case K.localClassElement: return 7;
    case K.interfaceElement: case K.typeElement: case K.typeParameterElement: return 8;
    case K.enumElement: return 13;
    case K.enumMemberElement: return 20;
    case K.moduleElement: case K.externalModuleName: return 9;
    case K.keyword: return 14;
    case K.constElement: return 21;
    default: return 6;
  }
}

function fileChanges(p, changes, extra) {
  const out = {};
  for (const fc of changes) {
    if (fc.isNewFile) continue;
    const file = norm(fc.fileName);
    const sf = sourceOf(p, file);
    if (!sf) continue;
    const list = out[uriOf(file)] || (out[uriOf(file)] = []);
    for (const tc of fc.textChanges) list.push({ range: rangeOf(sf, tc.span.start, tc.span.length), newText: tc.newText });
  }
  return out;
}

function handle(msg) {
  const q = msg.params || {};
  switch (msg.method) {
    case 'initialize':
      return {
        capabilities: {
          textDocumentSync: 1,
          hoverProvider: true,
          definitionProvider: true,
          completionProvider: { triggerCharacters: ['.', '"', "'", '/', '@', '<'], resolveProvider: true },
          renameProvider: true,
          codeActionProvider: true,
        },
        serverInfo: { name: 'byte code typescript', version: ts.version },
      };
    case 'shutdown': return null;
    case 'exit': process.exit(0);
    case 'textDocument/didOpen':
      return open(q.textDocument.uri, q.textDocument.text, q.textDocument.version);
    case 'textDocument/didChange': {
      const changes = q.contentChanges || [];
      if (changes.length) open(q.textDocument.uri, changes[changes.length - 1].text, q.textDocument.version);
      return;
    }
    case 'textDocument/didClose': {
      const file = fileOf(q.textDocument.uri);
      docs.delete(file);
      projectFor(file).open.delete(file);
      return;
    }
    case 'textDocument/hover': {
      const file = fileOf(q.textDocument.uri);
      const p = projectFor(file);
      const info = p.ls.getQuickInfoAtPosition(file, offsetAt(file, q.position));
      if (!info) return null;
      let value = '```ts\n' + ts.displayPartsToString(info.displayParts) + '\n```';
      const doc = ts.displayPartsToString(info.documentation || []);
      if (doc) value += '\n\n' + doc;
      for (const tag of info.tags || []) {
        const text = Array.isArray(tag.text) ? ts.displayPartsToString(tag.text) : (tag.text || '');
        value += '\n\n@' + tag.name + (text ? ' ' + text : '');
      }
      return { contents: { kind: 'markdown', value } };
    }
    case 'textDocument/definition': {
      const file = fileOf(q.textDocument.uri);
      const p = projectFor(file);
      const defs = p.ls.getDefinitionAtPosition(file, offsetAt(file, q.position)) || [];
      const out = [];
      for (const d of defs) {
        const f = norm(d.fileName);
        const sf = sourceOf(p, f);
        if (sf) out.push({ uri: uriOf(f), range: rangeOf(sf, d.textSpan.start, d.textSpan.length) });
      }
      return out;
    }
    case 'textDocument/completion': {
      const file = fileOf(q.textDocument.uri);
      const p = projectFor(file);
      const trigger = q.context && q.context.triggerCharacter;
      const pos = offsetAt(file, q.position);
      const list = p.ls.getCompletionsAtPosition(file, pos, {
        triggerCharacter: ['.', '"', "'", '/', '@', '<'].includes(trigger) ? trigger : undefined,
        ...preferences,
      });
      if (!list) return [];
      // With the exports of every module the list is huge: only what fits
      // the word typed so far goes back, and the editor asks again as it
      // grows while the list is cut short.
      const d = docs.get(file);
      const text = d ? d.text : '';
      let s = pos;
      while (s > 0 && /[\w$]/.test(text[s - 1])) s--;
      const typed = text.slice(s, pos).toLowerCase();
      let entries = list.entries;
      if (typed) entries = entries.filter(e => fits(e.name.toLowerCase(), typed));
      const cap = 2000;
      const cut = entries.length > cap || (!typed && entries.some(e => e.source));
      return {
        isIncomplete: cut,
        items: entries.slice(0, cap).map(e => {
          const from = e.source ? moduleOf(file, e) : undefined;
          return {
            label: e.name,
            kind: kindOf(e.kind),
            sortText: e.sortText,
            insertText: e.insertText,
            labelDetails: from ? { description: from } : undefined,
            // What resolving needs to work out the import.
            data: e.source || e.hasAction ? { file, pos, name: e.name, source: e.source, data: e.data } : undefined,
          };
        }),
      };
    }
    case 'completionItem/resolve': {
      const d = q.data;
      if (!d) return q;
      const p = projectFor(d.file);
      const details = p.ls.getCompletionEntryDetails(d.file, d.pos, d.name, ts.getDefaultFormatCodeSettings(), d.source, preferences, d.data);
      if (!details) return q;
      const sf = sourceOf(p, d.file);
      const additionalTextEdits = [];
      for (const action of details.codeActions || []) for (const fc of action.changes) {
        if (norm(fc.fileName) !== d.file || !sf) continue;
        for (const tc of fc.textChanges) additionalTextEdits.push({ range: rangeOf(sf, tc.span.start, tc.span.length), newText: tc.newText });
      }
      return { ...q, detail: ts.displayPartsToString(details.displayParts), additionalTextEdits };
    }
    case 'textDocument/rename': {
      const file = fileOf(q.textDocument.uri);
      const p = projectFor(file);
      const at = offsetAt(file, q.position);
      const info = p.ls.getRenameInfo(file, at, { allowRenameOfImportPath: false });
      if (!info.canRename) throw new Error(info.localizedErrorMessage);
      const locs = p.ls.findRenameLocations(file, at, false, false, { providePrefixAndSuffixTextForRename: true }) || [];
      const changes = {};
      for (const l of locs) {
        const f = norm(l.fileName);
        const sf = sourceOf(p, f);
        if (!sf) continue;
        (changes[uriOf(f)] || (changes[uriOf(f)] = [])).push({
          range: rangeOf(sf, l.textSpan.start, l.textSpan.length),
          newText: (l.prefixText || '') + q.newName + (l.suffixText || ''),
        });
      }
      return { changes };
    }
    case 'textDocument/codeAction': {
      const file = fileOf(q.textDocument.uri);
      const p = projectFor(file);
      const start = offsetAt(file, q.range.start), end = offsetAt(file, q.range.end);
      const actions = [];
      const seen = new Set();
      const diags = [...p.ls.getSyntacticDiagnostics(file), ...p.ls.getSemanticDiagnostics(file)];
      for (const d of diags) {
        if (d.start === undefined) continue;
        const dEnd = d.start + (d.length || 0);
        if (dEnd < start || d.start > end) continue;
        let fixes = [];
        try { fixes = p.ls.getCodeFixesAtPosition(file, d.start, dEnd, [d.code], {}, {}); } catch {}
        for (const fix of fixes) {
          if (seen.has(fix.description)) continue;
          seen.add(fix.description);
          actions.push({ title: fix.description, kind: 'quickfix', isPreferred: fix.fixName === 'import', edit: { changes: fileChanges(p, fix.changes) } });
        }
      }
      return actions;
    }
    default:
      return null;
  }
}
