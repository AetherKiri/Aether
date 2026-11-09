[CmdletBinding()]
param(
    [string]$GameRoot = "D:/ollama/WA2/game/WHITE ALBUM2",
    [string]$GodotExe = "D:/ollama/lib/godot/Godot_v4.7-stable_win64_console.exe",
    [string]$PatchDir = "",
    [switch]$AutoLaunch,
    [switch]$Silent
)
$ErrorActionPreference = "Stop"
$aetherRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$projectPath = Join-Path $aetherRoot "apps/godot_app"
$extensionPath = Join-Path $projectPath "bin/windows/release/aether_kiri_godot.dll"
if (!(Test-Path -LiteralPath $extensionPath -PathType Leaf)) { throw "Build the Release aether_kiri_godot target before starting this UI." }
$godotPath = (Resolve-Path -LiteralPath $GodotExe).Path
$gamePath = (Resolve-Path -LiteralPath $GameRoot).Path
if (!(Test-Path -LiteralPath (Join-Path $gamePath "script.pak") -PathType Leaf)) { throw "GameRoot must contain the installed game script.pak." }
$previousPatch = $env:AETHER_WA2_PATCH_DIR
$previousSilent = $env:AETHER_WA2_SILENT
try {
    if ($PatchDir) { $env:AETHER_WA2_PATCH_DIR = (Resolve-Path -LiteralPath $PatchDir).Path }
    if ($Silent) { $env:AETHER_WA2_SILENT = "1" }
    $launchArgs = @("--path", $projectPath, "--rendering-method", "gl_compatibility", "--resolution", "1280x720", "--", "--wa2-game-root", $gamePath)
    if ($AutoLaunch) { $launchArgs += "--wa2-auto-launch" }
    Write-Host "Opening the official Aether library UI. Game: $gamePath"
    & $godotPath @launchArgs
    $launchCode = $LASTEXITCODE
} finally {
    $env:AETHER_WA2_PATCH_DIR = $previousPatch
    $env:AETHER_WA2_SILENT = $previousSilent
}
exit $launchCode
