$ErrorActionPreference = 'Stop'
if (-not (Get-Command bash -ErrorAction SilentlyContinue)) {
    throw 'Git Bash must be on PATH. Run bash scripts/install-hooks.sh explicitly.'
}
& bash (Join-Path $PSScriptRoot 'install-hooks.sh')
exit $LASTEXITCODE
