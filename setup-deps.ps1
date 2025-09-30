# Simple setup script for external dependencies
param(
    [string]$DepsPath = "..\ExternalDependencies"
)

Write-Host "Setting up External Dependencies..." -ForegroundColor Green

# Ensure directory exists
if (!(Test-Path $DepsPath)) {
    New-Item -ItemType Directory -Path $DepsPath | Out-Null
    Write-Host "Created $DepsPath" -ForegroundColor Green
}

# UniRx
Write-Host "`nUniRx:" -ForegroundColor Yellow
$uniRxPath = "$DepsPath\UniRx"
if (!(Test-Path $uniRxPath)) {
    Write-Host "  Cloning UniRx..." -ForegroundColor Cyan
    git clone https://github.com/Magi-AGI/UniRx.git $uniRxPath
    Push-Location $uniRxPath
    git remote add upstream https://github.com/neuecc/UniRx.git
    Pop-Location
    Write-Host "  ✓ Cloned" -ForegroundColor Green
} else {
    Write-Host "  ✓ Already exists" -ForegroundColor Green
}

# Check for package.json
$uniRxPackage = "$uniRxPath\Assets\Plugins\UniRx\Scripts\package.json"
if (!(Test-Path $uniRxPackage)) {
    Write-Host "  Creating package.json..." -ForegroundColor Yellow
    $json = @'
{
  "name": "com.neuecc.unirx",
  "displayName": "UniRx - Reactive Extensions for Unity",
  "version": "7.1.0",
  "unity": "2019.4",
  "description": "Reactive Extensions for Unity (Magi-AGI Fork)",
  "keywords": ["reactive", "rx", "frp"],
  "dependencies": {}
}
'@
    $dir = Split-Path $uniRxPackage -Parent
    if (!(Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $json | Out-File -FilePath $uniRxPackage -Encoding UTF8
    Write-Host "  ✓ Created package.json" -ForegroundColor Green
}

# UniTask
Write-Host "`nUniTask:" -ForegroundColor Yellow
$uniTaskPath = "$DepsPath\UniTask"
if (!(Test-Path $uniTaskPath)) {
    Write-Host "  Cloning UniTask..." -ForegroundColor Cyan
    git clone https://github.com/Magi-AGI/UniTask.git $uniTaskPath
    Push-Location $uniTaskPath
    git remote add upstream https://github.com/Cysharp/UniTask.git
    Pop-Location
    Write-Host "  ✓ Cloned" -ForegroundColor Green
} else {
    Write-Host "  ✓ Already exists" -ForegroundColor Green
    # UniTask includes its own package.json
}

Write-Host "`n✓ Setup complete!" -ForegroundColor Green
Write-Host "Next: .\magi-deps.ps1 apply -ProjectPath ..\Inkling" -ForegroundColor Cyan