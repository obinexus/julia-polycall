'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const binding = require('..');
const metadata = require('../package.json');

assert.equal(metadata.name, '@obinexusltd/julia-polycall');
assert.equal(metadata.license, 'MIT');
assert.equal(metadata.publishConfig.access, 'public');

const author = typeof metadata.author === 'string'
  ? metadata.author
  : `${metadata.author?.name} <${metadata.author?.email}>`;

assert.equal(
  author,
  'Nnamdi Michael Okpala <okpalan@protonmail.com>',
  'package author must include the expected name and email'
);

for (const [name, file] of Object.entries(binding)) {
  if (name === 'packageName') continue;
  assert.equal(fs.existsSync(file), true, `missing ${name}: ${file}`);
}

console.log('julia-polycall npm package test: PASS');
