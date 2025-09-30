Param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateSet('apply','verify','policy','init')]
    [string]$Command,

    [string]$ProjectPath = '.',
    [string]$Depfile = 'depfile.yaml',
    [switch]$Strict
)

function Parse-Depfile($path) {
    if (!(Test-Path $path)) { throw "depfile not found: $path" }
    $lines = Get-Content $path
    $result = @{ registries = @{}; scopes = @(); unity = @{}; packages = @{}; policy = @{ bannedApis = @(); allowGitDependencies = $false } }
    $section = ''
    foreach ($raw in $lines) {
        $line = $raw.TrimEnd()
        if ($line -match '^\s*$' -or $line -match '^#') { continue }
        if ($line -match '^(registries|scopes|unity|packages|policy):\s*$') {
            $section = $Matches[1]
            continue
        }
        switch ($section) {
            'registries' {
                if ($line -match '^\s{2,}([\w\-]+):\s*(\S+)\s*$') {
                    $name = $Matches[1]; $url = $Matches[2]
                    $result.registries[$name] = $url
                }
            }
            'scopes' {
                if ($line -match '^\s{2,}-\s*(\S+)\s*$') { $result.scopes += $Matches[1] }
            }
            'unity' {
                if ($line -match '^\s{2,}([\w\-]+):\s*(\S+)\s*$') { $result.unity[$Matches[1]] = $Matches[2] }
            }
            'packages' {
                if ($line -match '^\s{2,}([\w\.\-]+):\s*(\S+)\s*$') { $result.packages[$Matches[1]] = $Matches[2] }
            }
            'policy' {
                if ($line -match '^\s{2,}allowGitDependencies:\s*(true|false)\s*$') { $result.policy.allowGitDependencies = [System.Convert]::ToBoolean($Matches[1]) }
                if ($line -match '^\s{2,}bannedApis:\s*$') { continue }
                if ($line -match '^\s{4,}-\s*(\S+)\s*$') { $result.policy.bannedApis += $Matches[1] }
            }
        }
    }
    return $result
}

function Make-Manifest($dep) {
    $deps = @{}
    foreach ($k in $dep.packages.Keys) { $deps[$k] = $dep.packages[$k] }
    if ($dep.unity.rp -eq 'urp' -and $dep.unity.rp_version) { $deps['com.unity.render-pipelines.universal'] = $dep.unity.rp_version }
    if ($dep.unity.rp -eq 'hdrp' -and $dep.unity.rp_version) { $deps['com.unity.render-pipelines.high-definition'] = $dep.unity.rp_version }
    $scoped = @()
    foreach ($name in $dep.registries.Keys) {
        $scoped += @{ name = $name; url = $dep.registries[$name]; scopes = @($dep.scopes) }
    }
    return @{ dependencies = $deps; scopedRegistries = $scoped }
}

function Resolve-LocalPackagePath($projectPath, $spec) {
    if (-not ($spec -is [string])) { return $null }
    if ($spec -notmatch '^file:') { return $null }
    $rel = $spec.Substring(5)
    $base = Resolve-Path -Path $projectPath
    $full = [System.IO.Path]::GetFullPath((Join-Path $base $rel))
    return $full
}

function Read-JsonFile($path) {
    try { return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { return $null }
}

function Write-JsonFile($path, $obj) {
    $json = $obj | ConvertTo-Json -Depth 10
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($path)) | Out-Null
    [System.IO.File]::WriteAllText($path, $json, $utf8NoBom)
}

function Derive-DisplayName($name) {
    if ($name -match '^com\.[^.]+\.(.+)$') { return ($Matches[1] -replace '\.', ' ') -replace '(?<=.)([A-Z])',' $1' }
    return $name
}

function Ensure-LocalPackage($projectPath, $pkgName, $spec, $editorVersion) {
    $pkgRoot = Resolve-LocalPackagePath $projectPath $spec
    if (-not $pkgRoot) { return }

    $pkgJsonPath = Join-Path $pkgRoot 'package.json'
    $existing = Read-JsonFile $pkgJsonPath

    # Derive defaults
    $unityField = if ($editorVersion) { ($editorVersion -split '\.')[0..1] -join '.' } else { '2023.3' }
    $display = Derive-DisplayName $pkgName

    if ($null -eq $existing) {
        $obj = [ordered]@{
            name        = $pkgName
            displayName = $display
            version     = '0.0.0-dev'
            unity       = $unityField
            description = "Local package for $pkgName"
            author      = @{ name = 'Magi-AGI' }
            dependencies= @{}
        }
        Write-JsonFile -path $pkgJsonPath -obj $obj
        Write-Host "Created package.json for $pkgName at $pkgJsonPath" -ForegroundColor Yellow
    }
    else {
        $changed = $false
        if (-not $existing.name -or ($existing.name -ne $pkgName)) { $existing | Add-Member -NotePropertyName name -NotePropertyValue $pkgName -Force; $changed = $true }
        if (-not $existing.displayName) { $existing | Add-Member -NotePropertyName displayName -NotePropertyValue $display -Force; $changed = $true }
        if (-not $existing.version) { $existing | Add-Member -NotePropertyName version -NotePropertyValue '0.0.0-dev' -Force; $changed = $true }
        if (-not $existing.unity) { $existing | Add-Member -NotePropertyName unity -NotePropertyValue $unityField -Force; $changed = $true }
        if ($changed) { Write-JsonFile -path $pkgJsonPath -obj $existing; Write-Host "Normalized package.json for $pkgName" -ForegroundColor Yellow }
    }

    $runtime = Join-Path $pkgRoot 'Runtime'
    if (-not (Test-Path $runtime)) { New-Item -ItemType Directory -Force -Path $runtime | Out-Null }
}

function Write-Manifest($projectPath, $manifestObj) {
    $packagesPath = Join-Path $projectPath 'Packages'
    if (!(Test-Path $packagesPath)) { New-Item -ItemType Directory -Force -Path $packagesPath | Out-Null }
    $manifestPath = Join-Path $packagesPath 'manifest.json'
    # Resolve to absolute path
    $manifestPath = [System.IO.Path]::GetFullPath($manifestPath)
    $json = $manifestObj | ConvertTo-Json -Depth 5
    # Write without BOM for Unity compatibility
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($manifestPath, $json, $utf8NoBom)
    Write-Host "Wrote manifest: $manifestPath"
}

function Compare-Manifests($a, $b) {
    $aJson = ($a | ConvertTo-Json -Depth 5)
    $bJson = ($b | ConvertTo-Json -Depth 5)
    return $aJson -eq $bJson
}

function Load-Manifest($projectPath) {
    $path = Join-Path (Join-Path $projectPath 'Packages') 'manifest.json'
    if (!(Test-Path $path)) { return $null }
    return Get-Content $path -Raw | ConvertFrom-Json
}

function Check-Policy($projectPath, $dep, [switch]$Strict) {
    $ok = $true
    # 1) Git deps banned
    $manifest = Load-Manifest $projectPath
    if ($manifest -ne $null) {
        foreach ($k in $manifest.dependencies.PSObject.Properties.Name) {
            $v = $manifest.dependencies.$k
            if ($v -match '^(https?://|git\+)') {
                if (-not $dep.policy.allowGitDependencies) {
                    Write-Host "Policy violation: Git/URL dependency for $k -> $v" -ForegroundColor Red
                    $ok = $false
                }
            }
        }
    }
    # 2) Banned APIs scan (only if Assets exists)
    $assets = Join-Path $projectPath 'Assets'
    if ((Test-Path $assets) -and ($dep.policy.bannedApis.Count -gt 0)) {
        $csFiles = Get-ChildItem -Path $assets -Recurse -Include *.cs -ErrorAction SilentlyContinue
        foreach ($f in $csFiles) {
            $content = Get-Content $f.FullName -Raw
            foreach ($api in $dep.policy.bannedApis) {
                if ($content -match [Regex]::Escape($api)) {
                    Write-Host "Policy violation: '$api' found in $($f.FullName)" -ForegroundColor Red
                    $ok = $false
                }
            }
        }
    }
    if (-not $ok -and $Strict) { exit 2 }
    return $ok
}

switch ($Command) {
    'apply' {
        $dep = Parse-Depfile (Join-Path $ProjectPath $Depfile)

        # Ensure local file: packages have valid package.json before generating manifest
        foreach ($k in $dep.packages.Keys) {
            $spec = $dep.packages[$k]
            Ensure-LocalPackage -projectPath $ProjectPath -pkgName $k -spec $spec -editorVersion $dep.unity.editor
        }
        $manifestObj = Make-Manifest $dep
        Write-Manifest -projectPath $ProjectPath -manifestObj $manifestObj
        Check-Policy -projectPath $ProjectPath -dep $dep -Strict:$Strict | Out-Null
    }
    'verify' {
        $dep = Parse-Depfile (Join-Path $ProjectPath $Depfile)
        foreach ($k in $dep.packages.Keys) { Ensure-LocalPackage -projectPath $ProjectPath -pkgName $k -spec $dep.packages[$k] -editorVersion $dep.unity.editor }
        $expected = Make-Manifest $dep
        $actual = Load-Manifest $ProjectPath
        if ($actual -eq $null) { Write-Host "No manifest.json present" -ForegroundColor Yellow; if ($Strict){ exit 3 } else { exit 0 } }
        $same = Compare-Manifests $expected $actual
        if (-not $same) { Write-Host "Lock drift: manifest does not match depfile" -ForegroundColor Red; if ($Strict){ exit 1 } }
        $policyOk = Check-Policy -projectPath $ProjectPath -dep $dep -Strict:$Strict
        if ($same -and $policyOk) { Write-Host "verify: OK" }
    }
    'policy' {
        $dep = Parse-Depfile (Join-Path $ProjectPath $Depfile)
        Write-Host ("allowGitDependencies=" + $dep.policy.allowGitDependencies)
        Write-Host ("bannedApis=[" + ($dep.policy.bannedApis -join ', ') + "]")
        Write-Host ("registries=" + ($dep.registries.Keys -join ', '))
    }
    'init' {
        $depfilePath = Join-Path $ProjectPath $Depfile
        if (Test-Path $depfilePath) { Write-Host "depfile exists: $depfilePath"; exit 0 }
        $content = @"
registries:
  magi: https://registry.example.com
scopes:
  - com.magi
  - com.vendor
unity:
  editor: 6000.2.0f1
  rp: urp
  rp_version: 17.0.3
packages:
  com.unity.inputsystem: 1.7.0
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
