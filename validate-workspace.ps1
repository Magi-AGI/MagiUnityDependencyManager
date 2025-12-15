param(
    [string]$WorkspaceRoot,
    [switch]$Apply,
    [switch]$Verify
)

$ErrorActionPreference = 'Stop'

function Resolve-WorkspaceRoot([string]$explicitRoot) {
    if (-not [string]::IsNullOrWhiteSpace($explicitRoot)) {
        return (Resolve-Path -LiteralPath $explicitRoot -ErrorAction Stop).Path
    }
    if ($env:MAGI_WORKSPACE_ROOT) {
        return (Resolve-Path -LiteralPath $env:MAGI_WORKSPACE_ROOT -ErrorAction Stop).Path
    }
    return (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..') -ErrorAction Stop).Path
}

function Is-UnityProjectRoot([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return $false }
    return (Test-Path -LiteralPath (Join-Path $path 'Assets')) -and (Test-Path -LiteralPath (Join-Path (Join-Path $path 'ProjectSettings') 'ProjectVersion.txt'))
}

$root = Resolve-WorkspaceRoot $WorkspaceRoot
$magiDeps = Join-Path $PSScriptRoot 'magi-deps.ps1'
if (-not (Test-Path -LiteralPath $magiDeps)) { throw "Expected magi-deps.ps1 at $magiDeps" }

Write-Host "Workspace root: $root" -ForegroundColor Cyan

$excludedSegments = @(
    '\.git\',
    '\Library\',
    '\Temp\',
    '\Logs\',
    '\obj\',
    '\UserSettings\',
    '\.self-test-',
    '\.self-test-work\',
    '\.tmp-'
)
$depfiles = Get-ChildItem -Path $root -Recurse -File -Filter 'depfile.yaml' -ErrorAction SilentlyContinue |
    Where-Object {
        $full = $_.FullName
        foreach ($seg in $excludedSegments) {
            if ($full -like "*$seg*") { return $false }
        }
        return $true
    }

if ($depfiles.Count -eq 0) {
    Write-Host "No depfile.yaml files found." -ForegroundColor Yellow
    exit 0
}

$ok = 0
$failed = 0
$skipped = 0

foreach ($dep in $depfiles) {
    $projectDir = $dep.Directory.FullName
    if (-not (Is-UnityProjectRoot $projectDir)) {
        $skipped++
        Write-Host "skip: $projectDir (not a Unity project root)" -ForegroundColor DarkYellow
        continue
    }

    Write-Host "validate: $projectDir" -ForegroundColor Green
    try {
        & $magiDeps validate -ProjectPath $projectDir | Out-Null

        if ($Apply) {
            & $magiDeps apply -ProjectPath $projectDir | Out-Null
        }
        if ($Verify) {
            & $magiDeps verify -ProjectPath $projectDir -Strict | Out-Null
        }

        $ok++
    }
    catch {
        $failed++
        Write-Host "FAIL: $projectDir" -ForegroundColor Red
        Write-Host ("  " + $_.Exception.Message) -ForegroundColor Red
    }
}

Write-Host ""
Write-Host ("Summary: ok={0}, failed={1}, skipped={2}" -f $ok, $failed, $skipped) -ForegroundColor Cyan

if ($failed -gt 0) { exit 1 }
