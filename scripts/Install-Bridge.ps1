<#
.SYNOPSIS
  Install UE4SS + the FP2AgentBridge Lua mod into Frostpunk 2.
.DESCRIPTION
  Copies UE4SS (from .runtime/ue4ss-dist, see -Download) into Binaries\Win64, links
  mod/FP2AgentBridge into ue4ss\Mods via a directory junction (edits are live; reload
  with Ctrl+R in game or restart), enables it, and creates the bridge directory.
  Idempotent: re-running repairs a partial install. Undo with Uninstall-Bridge.ps1.
#>
param(
    [string]$GameDir = "C:\Program Files (x86)\Steam\steamapps\common\Frostpunk2",
    [switch]$Download
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $root ".runtime\ue4ss-dist"
$win64 = Join-Path $GameDir "Frostpunk2\Binaries\Win64"
$modSrc = Join-Path $root "mod\FP2AgentBridge"
$bridgeDir = Join-Path $modSrc "bridge"

if (Get-Process -Name "Frostpunk2*" -ErrorAction SilentlyContinue) {
    throw "Frostpunk 2 is running. Quit it before installing."
}
if (-not (Test-Path $win64)) { throw "Game binaries not found: $win64" }

if ($Download -or -not (Test-Path (Join-Path $dist "dwmapi.dll"))) {
    $dl = Join-Path $root ".runtime\download"
    New-Item -ItemType Directory -Force $dl | Out-Null
    $rel = Invoke-RestMethod "https://api.github.com/repos/UE4SS-RE/RE-UE4SS/releases/tags/experimental-latest"
    $asset = $rel.assets | Where-Object { $_.name -like "UE4SS_v*.zip" } | Select-Object -First 1
    Write-Host "Downloading $($asset.name) ($([math]::Round($asset.size/1MB,1)) MB)"
    $zip = Join-Path $dl "UE4SS.zip"
    Invoke-WebRequest $asset.browser_download_url -OutFile $zip
    if (Test-Path $dist) { Remove-Item -Recurse -Force $dist }
    Expand-Archive $zip -DestinationPath $dist
}

# 1. UE4SS loader + runtime
$dstDll = Join-Path $win64 "dwmapi.dll"
if ((Test-Path $dstDll) -and -not (Test-Path (Join-Path $win64 "ue4ss"))) {
    Copy-Item $dstDll "$dstDll.fp2bridge-backup" -Force
    Write-Host "Backed up existing dwmapi.dll"
}
Copy-Item (Join-Path $dist "dwmapi.dll") $dstDll -Force
$ue4ss = Join-Path $win64 "ue4ss"
New-Item -ItemType Directory -Force $ue4ss | Out-Null
Get-ChildItem (Join-Path $dist "ue4ss") | Where-Object { $_.Name -ne "Mods" } |
    ForEach-Object { Copy-Item $_.FullName $ue4ss -Recurse -Force }
$mods = Join-Path $ue4ss "Mods"
New-Item -ItemType Directory -Force $mods | Out-Null
Get-ChildItem (Join-Path $dist "ue4ss\Mods") | ForEach-Object {
    $target = Join-Path $mods $_.Name
    if ($_.Name -in @("mods.txt", "mods.json")) {
        if (-not (Test-Path $target)) { Copy-Item $_.FullName $target }
    } else {
        Copy-Item $_.FullName $mods -Recurse -Force
    }
}

# 2. Settings: hot reload on (Ctrl+R) so mod edits can be applied without a restart.
$ini = Join-Path $ue4ss "UE4SS-settings.ini"
(Get-Content $ini) -replace '^EnableHotReloadSystem = .*', 'EnableHotReloadSystem = 1' |
    Set-Content $ini -Encoding utf8

# 3. Mod junction
$link = Join-Path $mods "FP2AgentBridge"
if (Test-Path $link) {
    $item = Get-Item $link -Force
    if ($item.LinkType -ne "Junction") { throw "$link exists and is not a junction; remove it manually." }
} else {
    New-Item -ItemType Junction -Path $link -Target $modSrc | Out-Null
}
New-Item -ItemType File -Force (Join-Path $modSrc "enabled.txt") | Out-Null

# 4. Enable in mods.txt (before the Keybinds line) and mods.json
$txt = Join-Path $mods "mods.txt"
$lines = Get-Content $txt | Where-Object { $_ -notmatch '^FP2AgentBridge\s*:' }
$i = [array]::FindIndex([string[]]$lines, [Predicate[string]]{ param($l) $l -match '^; Built-in keybinds' })
if ($i -lt 0) { $lines += "FP2AgentBridge : 1" } else { $lines = $lines[0..($i-1)] + "FP2AgentBridge : 1" + $lines[$i..($lines.Count-1)] }
$lines | Set-Content $txt -Encoding utf8

$jsonPath = Join-Path $mods "mods.json"
$list = @(Get-Content $jsonPath -Raw | ConvertFrom-Json | Where-Object { $_.mod_name -ne "FP2AgentBridge" })
$list += [pscustomobject]@{ mod_name = "FP2AgentBridge"; mod_enabled = $true }
ConvertTo-Json $list -Depth 3 | Set-Content $jsonPath -Encoding utf8

# 5. Bridge directory
New-Item -ItemType Directory -Force $bridgeDir | Out-Null

Write-Host "Installed. UE4SS: $ue4ss"
Write-Host "Mod junction: $link -> $modSrc"
Write-Host "Bridge dir: $bridgeDir"
