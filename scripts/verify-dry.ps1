$ErrorActionPreference = 'Stop'

# Thin-adapter check: JuliaPolycall only ccalls libpolycall.
$root = Split-Path -Parent $PSScriptRoot
$juliaSource = Join-Path $root 'src/JuliaPolycall.jl'
$forbidden = '(^|[^_A-Za-z0-9.])(fopen|open|socket|connect|sscanf|strtok)\('
$found = Select-String -Path $juliaSource -Pattern $forbidden
if ($found) {
    $found | ForEach-Object { Write-Error $_.Line }
    throw 'julia-polycall must not parse configuration or implement runtime logic'
}
$julia = Get-Content -Raw $juliaSource
foreach ($needle in @('POLYCALL_LIBRARY', 'polycall_ffi_abi_version',
                      'ccall(fnptr(:polycall_ffi_run_config), Cint, (Cstring, Cint), path, 1)')) {
    if (-not $julia.Contains($needle)) { throw "julia-polycall: missing '$needle'" }
}
Write-Output 'julia-polycall thin-adapter check: PASS'
