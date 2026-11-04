// Opt-in functional probe for a built public MemoryCore package. Uses data URLs
// only: no listeners, remote requests, credentials, service state or config.
// Exit 0: selected contexts pass; 1: regression; 2: incomplete. By default only
// npm copies gate success. --require-bundled also gates Node's global fetch.
import {createHash} from 'node:crypto';
import {realpathSync} from 'node:fs';
import {createRequire} from 'node:module';
import {resolve} from 'node:path';

const args = process.argv.slice(2);
const requireBundled = args[0] === '--require-bundled';
if (requireBundled) args.shift();
const [root] = args;
if (args.length !== 1 || !root?.startsWith('/')) {
  process.stderr.write('Usage: node probe_memory_http.mjs [--require-bundled] /absolute/core-output\n');
  process.exit(2);
}

const payload = 'nixi synthetic integrity fixture';
const hash = value => createHash('sha256').update(value).digest('base64');
const cases = [
  {name: 'valid-lowercase', integrity: `sha256-${hash(payload)}`, expected: true},
  {name: 'valid-uppercase', integrity: `SHA256-${hash(payload)}`, expected: true},
  {name: 'wrong-lowercase', integrity: `sha256-${hash('different bytes')}`, expected: false},
  {name: 'wrong-uppercase', integrity: `SHA256-${hash('different bytes')}`, expected: false},
];

async function probe(fetch) {
  const results = [];
  for (const fixture of cases) {
    let accepted = false;
    try {
      const response = await fetch(`data:text/plain,${encodeURIComponent(payload)}`, {
        integrity: fixture.integrity,
        signal: AbortSignal.timeout(3000),
      });
      accepted = await response.text() === payload;
    } catch (error) {
      if (!(error instanceof TypeError)) throw error;
    }
    results.push({name: fixture.name, accepted, expected: fixture.expected});
  }
  return {pass: results.every(result => result.accepted === result.expected), cases: results};
}

try {
  const requireFrom = relative => createRequire(realpathSync(resolve(root, 'lib/memory-core', relative)));
  const core = requireFrom('package.json');
  const contexts = [
    ['core', core],
    ['provider-utils', requireFrom('node_modules/@ai-sdk/provider-utils/package.json')],
    ['memory-sdk', requireFrom('node_modules/@tencentdb-agent-memory/memory-sdk-ts-v2/package.json')],
  ];
  const packages = [];
  for (const [name, require] of contexts) {
    const version = require('undici/package.json').version;
    packages.push({name, version, ...await probe(require('undici').fetch)});
  }
  const bundled = {node: process.versions.node, undici: process.versions.undici, ...await probe(globalThis.fetch)};
  const status = !packages.every(result => result.pass) ? 'npm-regression'
    : requireBundled && !bundled.pass ? 'bundled-regression'
    : requireBundled ? 'all-contexts-pass' : 'npm-copies-pass';
  process.stdout.write(JSON.stringify({status, requireBundled, packages, bundled,
    scope: 'Synthetic SRI case handling only; excludes other advisories and consumer reachability.'}, null, 2) + '\n');
  process.exitCode = ['npm-copies-pass', 'all-contexts-pass'].includes(status) ? 0 : 1;
} catch {
  process.stderr.write('MemoryCore HTTP probe incomplete; package loading or fixture failed.\n');
  process.exitCode = 2;
}
