# julia-polycall -- Julia binding over the Polycall binding ABI v1.
# There is nothing to compile: JuliaPolycall ccalls libpolycall directly,
# resolving it at run time (POLYCALL_LIBRARY, then libpolycall.so.1 /
# polycall.dll / libpolycall.dll / libpolycall.1.dylib).
#
#   make test        Pkg.test() against the REAL installed libpolycall
#                    (a missing julia is a SKIP, exit 77 -- never a pass)
#   make verify-dry  thin-adapter audit

JULIA ?= julia
JULIA_NUM_THREADS ?= 4
# JuliaPolycall depends only on stdlibs: test without installing a registry
JULIA_PKG_OFFLINE ?= true

.PHONY: all
all:
	@echo "julia-polycall has no build step; run 'make test'"

.PHONY: test
test:
	@command -v $(JULIA) >/dev/null 2>&1 || { echo "SKIP: julia not found; Julia tests did not run" >&2; exit 77; }
	JULIA_PKG_OFFLINE=$(JULIA_PKG_OFFLINE) JULIA_NUM_THREADS=$(JULIA_NUM_THREADS) $(JULIA) --project=. -e 'using Pkg; Pkg.test()'

.PHONY: verify-dry
verify-dry:
	sh scripts/verify-dry.sh
