'use strict';

// npm source-package test: metadata, exported paths, and that the stub
// C shim / polycall_ffi.h are gone (JuliaPolycall ccalls libpolycall).
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const binding = require('..');
const metadata = require('../package.json');
const manifest = require('../polycall-binding.json');

assert.equal(metadata.name, 'julia-polycall');
assert.equal(metadata.license, 'MIT');
assert.equal(metadata.repository.url, 'git+https://github.com/obinexus/julia-polycall.git');
assert.equal(
  typeof metadata.author === 'string' ? metadata.author : `${metadata.author.name} <${metadata.author.email}>`,
  'Nnamdi Michael Okpala <okpalan@protonmail.com>'
);

for (const [name, file] of Object.entries(binding)) {
  if (name === 'packageName') continue;
  assert.equal(fs.existsSync(file), true, `missing ${name}: ${file}`);
}
const root = path.dirname(binding.juliaProject);
for (const gone of ['generated', 'c_src', 'include']) {
  assert.equal(fs.existsSync(path.join(root, gone)), false, `${gone}/ must not come back`);
}
const project = fs.readFileSync(binding.juliaProject, 'utf8');
assert.match(project, /^version = "(.*)"$/m);
assert.equal(project.match(/^version = "(.*)"$/m)[1], metadata.version);
assert.equal(manifest.version, metadata.version);
assert.equal(manifest.core, 'polycall >= 1.1.0 (binding ABI 1)');
assert.match(project, /\[targets\]\ntest = \["Test"\]/);

console.log('julia-polycall npm package test: PASS');
