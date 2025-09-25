Param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateSet('apply','verify','policy','init')]
    [string]$Command,

    [string]$ProjectPath = '.',
    [string]$Depfile = 'depfile.yaml'
)

function Read-Yaml($path) {
    # Minimal YAML reader placeholder (expects simple key: value / lists). Replace with robust parser later.
    if (!(Test-Path $path)) { throw "depfile not found: $path" }
    Get-Content $path -Raw
}

function Write-Manifest($projectPath, $depYaml) {
    $packagesPath = Join-Path $projectPath 'Packages'
    if (!(Test-Path $packagesPath)) { New-Item -ItemType Directory -Force -Path $packagesPath | Out-Null }
    $manifestPath = Join-Path $packagesPath 'manifest.json'
    # Placeholder manifest to be replaced with parsed content from depfile
    $manifest = @{ dependencies = @{ 'com.unity.inputsystem' = '1.7.0' } } | ConvertTo-Json -Depth 5
    Set-Content -LiteralPath $manifestPath -Value $manifest -Encoding UTF8
    Write-Host "Wrote manifest: $manifestPath"
}

switch ($Command) {
    'apply' {
        $depYaml = Read-Yaml (Join-Path $ProjectPath $Depfile)
        Write-Manifest -projectPath $ProjectPath -depYaml $depYaml
    }
    'verify' {
        Write-Host "verify: lockfile drift and policy checks (stub)"
        exit 0
    }
    'policy' {
        Write-Host "Policy: allowGitDependencies=false; bannedApis=[Resources.Load, FindObjectOfType] (stub)"
    }
    'init' {
        $depfilePath = Join-Path $ProjectPath $Depfile
        if (Test-Path $depfilePath) { Write-Host "depfile exists: $depfilePath"; exit 0 }
        $content = @"
registries:
  inkling: https://registry.inkling.dev
scopes:
  - com.inktools
  - com.magi
unity:
  editor: 6000.2.0f1
  rp: urp
  rp_version: 17.0.3
packages:
  com.unity.inputsystem: 1.7.0
  com.unity.sentis: 2.0.0
policy:
  allowGitDependencies: false
  bannedApis:
    - Resources.Load
    - FindObjectOfType
"@
        Set-Content -LiteralPath $depfilePath -Value $content -Encoding UTF8
        Write-Host "Created depfile: $depfilePath"
    }
}

