# Setup script for external Unity dependencies
# Manages Magi-AGI forks of external packages

param(
    [string]$DependenciesPath = "..\ExternalDependencies",
    [switch]$VerifyOnly
)

$ErrorActionPreference = "Stop"

Write-Host "Managing Magi External Unity Dependencies..." -ForegroundColor Green

# Resolve full path
$DepsDir = Resolve-Path -Path $DependenciesPath -ErrorAction SilentlyContinue
if (!$DepsDir) {
    $DepsDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot $DependenciesPath))
}

# Create ExternalDependencies directory if it doesn't exist
if (!(Test-Path $DepsDir) -and !$VerifyOnly) {
    Write-Host "Creating $DepsDir..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $DepsDir | Out-Null
}

# Define dependencies - using Magi-AGI forks
$dependencies = @(
    @{
        Name = "UniRx"
        Fork = "https://github.com/Magi-AGI/UniRx.git"
        Upstream = "https://github.com/neuecc/UniRx.git"
        Path = "$DepsDir\UniRx"
        Branch = "master"
        PackagePath = "Assets\Plugins\UniRx\Scripts"
        NeedsPackageJson = $true
    },
    @{
        Name = "UniTask"
        Fork = "https://github.com/Magi-AGI/UniTask.git"
        Upstream = "https://github.com/Cysharp/UniTask.git"
        Path = "$DepsDir\UniTask"
        Branch = "master"
        PackagePath = "src\UniTask\Assets\Plugins\UniTask"
        NeedsPackageJson = $false  # UniTask includes its own
    }
)

if ($VerifyOnly) {
    Write-Host "`nVerifying fork configuration..." -ForegroundColor Cyan
}

foreach ($dep in $dependencies) {
    Write-Host "`n=== $($dep.Name) ===" -ForegroundColor Yellow

    if (!(Test-Path $dep.Path)) {
        if ($VerifyOnly) {
            Write-Warning "  $($dep.Name) not found at $($dep.Path)"
            continue
        }

        # Clone the fork
        Write-Host "  Cloning $($dep.Name) from Magi-AGI fork..." -ForegroundColor Cyan
        $cloneResult = git clone $dep.Fork $dep.Path --branch $dep.Branch --single-branch 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  ✓ Cloned $($dep.Name)" -ForegroundColor Green

            # Add upstream remote
            Push-Location $dep.Path
            $addUpstreamResult = git remote add upstream $dep.Upstream 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  ✓ Added upstream remote" -ForegroundColor Green
            }
            else {
                Write-Warning "  Could not add upstream remote"
            }
            Pop-Location
        }
        else {
            Write-Error "  Failed to clone $($dep.Name): $cloneResult"
            continue
        }
    }
    else {
        # Repository exists, verify configuration
        Push-Location $dep.Path

        # Check origin remote
        $originUrl = git remote get-url origin 2>$null
        if ($originUrl) {
            if ($originUrl -eq $dep.Fork) {
                Write-Host "  ✓ Origin points to Magi-AGI fork" -ForegroundColor Green
            }
            else {
                Write-Warning "  Origin points to: $originUrl"
                if (!$VerifyOnly) {
                    Write-Host "  Setting origin to Magi-AGI fork..." -ForegroundColor Yellow
                    git remote set-url origin $dep.Fork
                    Write-Host "  ✓ Updated origin" -ForegroundColor Green
                }
            }
        }

        # Check upstream remote
        $upstreamUrl = git remote get-url upstream 2>$null
        if ($upstreamUrl) {
            if ($upstreamUrl -eq $dep.Upstream) {
                Write-Host "  ✓ Upstream points to original repo" -ForegroundColor Green
            }
            else {
                Write-Warning "  Upstream points to: $upstreamUrl"
                if (!$VerifyOnly) {
                    git remote set-url upstream $dep.Upstream
                    Write-Host "  ✓ Updated upstream" -ForegroundColor Green
                }
            }
        }
        else {
            if (!$VerifyOnly) {
                Write-Host "  Adding upstream remote..." -ForegroundColor Yellow
                git remote add upstream $dep.Upstream
                Write-Host "  ✓ Added upstream" -ForegroundColor Green
            }
            else {
                Write-Warning "  No upstream remote configured"
            }
        }

        # Show status
        $branch = git branch --show-current
        $lastCommit = git log -1 --oneline 2>$null
        Write-Host "  Branch: $branch" -ForegroundColor Cyan
        if ($lastCommit) {
            Write-Host "  Latest: $lastCommit" -ForegroundColor Cyan
        }

        if (!$VerifyOnly) {
            # Pull latest from fork
            Write-Host "  Updating from fork..." -ForegroundColor Cyan
            $pullResult = git pull origin $dep.Branch 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  ✓ Updated" -ForegroundColor Green
            }
            else {
                Write-Warning "  Could not update: $pullResult"
            }
        }

        Pop-Location
    }

    # Create package.json if needed
    if ($dep.NeedsPackageJson -and !$VerifyOnly) {
        $packageJsonPath = Join-Path $dep.Path $dep.PackagePath "package.json"
        if (!(Test-Path $packageJsonPath)) {
            Write-Host "  Creating package.json..." -ForegroundColor Yellow

            $packageJson = @"
{
  "name": "com.neuecc.unirx",
  "displayName": "UniRx - Reactive Extensions for Unity",
  "version": "7.1.0",
  "unity": "2019.4",
  "description": "Reactive Extensions for Unity (Magi-AGI Fork)",
  "keywords": ["reactive", "rx", "frp", "linq"],
  "author": {
    "name": "Yoshifumi Kawai",
    "url": "https://github.com/neuecc"
  },
  "dependencies": {}
}
"@
            $packageDir = Split-Path -Parent $packageJsonPath
            if (!(Test-Path $packageDir)) {
                New-Item -ItemType Directory -Path $packageDir -Force | Out-Null
            }
            $packageJson | Out-File -FilePath $packageJsonPath -Encoding UTF8
            Write-Host "  ✓ Created package.json" -ForegroundColor Green
        }
        else {
            Write-Host "  ✓ package.json exists" -ForegroundColor Green
        }
    }
}

Write-Host "`n" -NoNewline
Write-Host "=========================" -ForegroundColor Cyan
if ($VerifyOnly) {
    Write-Host "Verification Complete!" -ForegroundColor Green
}
else {
    Write-Host "Setup Complete!" -ForegroundColor Green
}
Write-Host "=========================" -ForegroundColor Cyan

Write-Host "`nUseful commands:" -ForegroundColor Yellow
Write-Host "  Sync with upstream:" -ForegroundColor White
Write-Host "    cd $DepsDir\UniRx"
Write-Host "    git fetch upstream"
Write-Host "    git merge upstream/master"
Write-Host "    git push origin master"

Write-Host "`n  Check for updates:" -ForegroundColor White
Write-Host "    git fetch upstream"
Write-Host "    git log HEAD..upstream/master --oneline"

Write-Host "`nNext steps:" -ForegroundColor Yellow
Write-Host "  1. Run: .\magi-deps.ps1 apply -ProjectPath ..\Inkling"
Write-Host "  2. Open Unity and verify packages import correctly"