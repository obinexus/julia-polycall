$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$nativeSource = Join-Path $root 'c_src/julia_polycall.c'
$juliaSource = Join-Path $root 'src/JuliaPolycall.jl'
$forbidden = 'fopen|open\(|CreateFile|sscanf|strtok|socket\(|connect\('
$matches = Select-String -Path $nativeSource,$juliaSource -Pattern $forbidden

if ($matches) {
    $matches | ForEach-Object { Write-Error $_.Line }
    throw 'julia-polycall must not parse configuration or implement runtime logic'
}

$adapter = Get-Content -Raw $nativeSource
$julia = Get-Content -Raw $juliaSource
if (-not $adapter.Contains('polycall_ffi_run_config(config_path, 1)')) {
    throw 'julia-polycall does not forward through polycall_ffi_run_config'
}
if (-not $julia.Contains('ccall(')) {
    throw 'julia-polycall does not declare a Julia C-call boundary'
}
if (-not $julia.Contains('(Cstring,)')) {
    throw 'julia-polycall does not marshal config paths as C strings'
}

Write-Output 'julia-polycall thin-adapter check: PASS'
