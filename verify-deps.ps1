# Simple verification script for external dependencies
param(
    [string]$DepsPath = "..\ExternalDependencies"
)

Write-Host "Verifying External Dependencies..." -ForegroundColor Green

$deps = @(
    @{Name="UniRx"; Fork="https://github.com/Magi-AGI/UniRx.git"; Path="$DepsPath\UniRx"},
    @{Name="UniTask"; Fork="https://github.com/Magi-AGI/UniTask"; Path="$DepsPath\UniTask"}
)

foreach ($dep in $deps) {
    Write-Host ""
    Write-Host "$($dep.Name):" -ForegroundColor Yellow

    if (Test-Path $dep.Path) {
        Push-Location $dep.Path
        $origin = git remote get-url origin 2>$null
        Write-Host "  Found at: $($dep.Path)" -ForegroundColor Green
        Write-Host "  Origin: $origin"

        if ($origin -eq $dep.Fork) {
            Write-Host "  OK: Correct fork" -ForegroundColor Green
        } else {
            Write-Host "  WARNING: Different origin" -ForegroundColor Yellow
        }

        $branch = git branch --show-current 2>$null
        Write-Host "  Branch: $branch"
        Pop-Location
    } else {
        Write-Host "  Not found at $($dep.Path)" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "To apply dependencies: .\magi-deps.ps1 apply -ProjectPath ..\Inkling" -ForegroundColor Cyan