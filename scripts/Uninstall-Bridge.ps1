<#
.SYNOPSIS
  Remove UE4SS and the FP2AgentBridge mod from Frostpunk 2. Leaves repo files untouched.
#>
param(
    [string]$GameDir = "C:\Program Files (x86)\Steam\steamapps\common\Frostpunk2"
)
$ErrorActionPreference = "Stop"
$win64 = Join-Path $GameDir "Frostpunk2\Binaries\Win64"
if (Get-Process -Name "Frostpunk2*" -ErrorAction SilentlyContinue) {
    throw "Frostpunk 2 is running. Quit it before uninstalling."
}

# Remove the junction first so recursive deletion can never reach the repo.
$link = Join-Path $win64 "ue4ss\Mods\FP2AgentBridge"
if (Test-Path $link) {
    $item = Get-Item $link -Force
    if ($item.LinkType -eq "Junction") { $item.Delete() } else { throw "$link is not a junction; refusing to delete." }
}
$ue4ss = Join-Path $win64 "ue4ss"
if (Test-Path $ue4ss) { Remove-Item -Recurse -Force $ue4ss }

$dll = Join-Path $win64 "dwmapi.dll"
if (Test-Path $dll) { Remove-Item -Force $dll }
if (Test-Path "$dll.fp2bridge-backup") { Move-Item "$dll.fp2bridge-backup" $dll }
Write-Host "Removed UE4SS and FP2AgentBridge from $win64"
