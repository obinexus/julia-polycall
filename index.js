'use strict';

// Source-package index: absolute paths of the Julia package files. This npm
// package contains no JavaScript implementation; JuliaPolycall ccalls
// libpolycall (polycall >= 1.1.0) directly.
const path = require('node:path');

const fromPackageRoot = (...parts) => path.join(__dirname, ...parts);

module.exports = Object.freeze({
  packageName: 'julia-polycall',
  juliaProject: fromPackageRoot('Project.toml'),
  juliaSource: fromPackageRoot('src', 'JuliaPolycall.jl'),
  juliaTests: fromPackageRoot('test', 'runtests.jl'),
  example: fromPackageRoot('examples', 'basic.jl'),
  config: fromPackageRoot('julia-polycallrc'),
  manifest: fromPackageRoot('polycall-binding.json'),
  makefile: fromPackageRoot('Makefile')
});
