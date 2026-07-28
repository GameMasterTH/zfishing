// Minimal Lua test runner for the zfishing spec tests.
//
// There is no native Lua interpreter on this machine, so we run the plain-Lua
// harness under a Lua 5.4 VM (wasmoon, resolved from web/node_modules). The real
// resource files are mounted into the VM's virtual FS at their repository-root
// relative paths, so `dofile('client/main.lua')` inside the test resolves to the
// actual shipped code — exactly as `lua tests/<file>.test.lua` would from root.
//
// Usage:  node tests/luarun.mjs <test-file-relative-to-resource-root>
// Example: node tests/luarun.mjs tests/water_validation_preservation.test.lua

import { createRequire } from 'node:module';
import { readFileSync, writeFileSync, readdirSync, existsSync } from 'node:fs';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const RESOURCE_ROOT = resolve(__dirname, '..');

// wasmoon is a devDependency of this test harness (tests/node_modules).
const require = createRequire(import.meta.url);
const { LuaFactory } = require('wasmoon');

const testFile = process.argv[2];
if (!testFile) {
    console.error('usage: node tests/luarun.mjs <test-file>');
    process.exit(2);
}

// Every resource file the harness may `dofile`, mounted at its root-relative path.
// The test itself plus all shipped Lua under client/, server/ and shared/ so any
// test (client- or server-side) resolves `dofile('server/foo.lua')` to real code.
const luaDirs = ['client', 'server', 'shared'];
const filesToMount = [testFile];
for (const dir of luaDirs) {
    const abs = join(RESOURCE_ROOT, dir);
    if (!existsSync(abs)) continue;
    for (const name of readdirSync(abs)) {
        if (name.endsWith('.lua')) filesToMount.push(`${dir}/${name}`);
    }
}

const out = [];
const log = (s) => { out.push(s); process.stdout.write(s + '\n'); };

const factory = new LuaFactory();
for (const rel of filesToMount) {
    const contents = readFileSync(join(RESOURCE_ROOT, rel), 'utf8');
    await factory.mountFile(rel, contents);
}

const lua = await factory.createEngine();
// route Lua print / io.write into our captured buffer
lua.global.set('__print', (...args) => log(args.map((a) => (a === undefined ? 'nil' : String(a))).join('\t')));

let failed = false;
try {
    // Redirect print + io.stderr:write to the captured logger, then run the file.
    await lua.doString(`
        print = function(...)
            local t = {}
            for i = 1, select('#', ...) do t[i] = tostring((select(i, ...))) end
            __print(table.concat(t, '\\t'))
        end
        io = io or {}
        io.stderr = { write = function(_, s) __print(tostring(s):gsub('\\n$','')) end }
    `);
    await lua.doFile(testFile);
} catch (err) {
    failed = true;
    log('RUNNER ERROR: ' + (err && err.message ? err.message : String(err)));
} finally {
    lua.global.close();
}

const resultsPath = join(RESOURCE_ROOT, 'tests', 'last-run.txt');
writeFileSync(resultsPath, out.join('\n') + '\n', 'utf8');
process.exit(failed ? 1 : 0);
