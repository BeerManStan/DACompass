# Syntax-checks every addon .lua in the repo, then runs the test suites.
# Run this before copying anything into the game folder.
#
#   .\check.ps1              # syntax + tests
#   .\check.ps1 -SyntaxOnly  # parse only
#
# LuaJIT (Lua 5.1) is what Ashita v4 embeds, so this is the same parser the
# game will use. Install: winget install DEVCOM.LuaJIT

param(
    [switch]$SyntaxOnly
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

# Locate luajit: PATH first, then the winget install location.
$luajit = $null
$cmd = Get-Command luajit -ErrorAction SilentlyContinue
if ($cmd) {
    $luajit = $cmd.Source
} else {
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\LuaJIT\bin\luajit.exe",
        "$env:ProgramFiles\LuaJIT\bin\luajit.exe",
        "${env:ProgramFiles(x86)}\LuaJIT\bin\luajit.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { $luajit = $c; break } }
}
if (-not $luajit) {
    Write-Host "luajit.exe not found. Install with: winget install DEVCOM.LuaJIT" -ForegroundColor Red
    exit 2
}
Write-Host "luajit: $luajit" -ForegroundColor DarkGray

# Check the addon, tools, and tests. Skip any local map cache folders.
$files = Get-ChildItem $root -Recurse -Filter *.lua |
    Where-Object { $_.FullName -notmatch '\\maps\\' } |
    Sort-Object FullName

Write-Host "`n=== syntax ===" -ForegroundColor Cyan
# Out-Host keeps LuaJIT output in order with the headings above and below it.
& $luajit "$root\tools\syntax_check.lua" @($files.FullName) | Out-Host
$syntaxOk = ($LASTEXITCODE -eq 0)
if (-not $syntaxOk) {
    Write-Host "`nSYNTAX FAILED" -ForegroundColor Red
    exit 1
}

if ($SyntaxOnly) {
    Write-Host "`nSYNTAX OK (tests skipped)" -ForegroundColor Green
    exit 0
}

Write-Host "`n=== tests ===" -ForegroundColor Cyan
$specs = Get-ChildItem "$root\tests" -Filter *_spec.lua -ErrorAction SilentlyContinue | Sort-Object Name
if (-not $specs) {
    Write-Host "no *_spec.lua found in tests/" -ForegroundColor Yellow
    exit 0
}

$failed = 0
foreach ($spec in $specs) {
    & $luajit $spec.FullName | Out-Host
    if ($LASTEXITCODE -ne 0) { $failed++ }
}

if ($failed -gt 0) {
    Write-Host "`n$failed spec file(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "`nALL GREEN" -ForegroundColor Green
exit 0
