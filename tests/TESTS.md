# Julia tests

`npm test` runs the native forwarding test, thin-adapter audit, and npm package
integrity test. `npm run test:julia` additionally loads the Julia package and
runs its `ccall` smoke test through a mock native library.
