'use strict';

const path = require('node:path');

const fromPackageRoot = (...parts) => path.join(__dirname, ...parts);

module.exports = Object.freeze({
  packageName: '@obinexusltd/julia-polycall',
  juliaProject: fromPackageRoot('Project.toml'),
  juliaSource: fromPackageRoot('src', 'JuliaPolycall.jl'),
  nativeSource: fromPackageRoot('c_src', 'julia_polycall.c'),
  nativeHeader: fromPackageRoot('include', 'julia_polycall.h'),
  ffiHeader: fromPackageRoot('generated', 'polycall', 'polycall_ffi.h'),
  config: fromPackageRoot('julia-polycallrc'),
  manifest: fromPackageRoot('polycall-binding.json'),
  makefile: fromPackageRoot('Makefile')
});
