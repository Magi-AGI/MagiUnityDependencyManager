Param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateSet('apply','verify','policy','init','validate')]
    [string]$Command,

    [string]$ProjectPath = '.',
    [string]$Depfile = 'depfile.yaml',
    [switch]$Strict
)

function Resolve-UnityProjectPath([string]$projectPath) {
    if ([string]::IsNullOrWhiteSpace($projectPath)) { throw "ProjectPath is required." }
    $resolved = (Resolve-Path -LiteralPath $projectPath -ErrorAction Stop).Path

    $assetsDir = Join-Path $resolved 'Assets'
    $projectVersion = Join-Path (Join-Path $resolved 'ProjectSettings') 'ProjectVersion.txt'
    if (-not (Test-Path -LiteralPath $assetsDir) -or -not (Test-Path -LiteralPath $projectVersion)) {
        throw "ProjectPath '$resolved' does not look like a Unity project root. Expected 'Assets/' and 'ProjectSettings/ProjectVersion.txt'."
    }

    return $resolved
}

function Test-UpmPackageName([string]$name) {
    if ([string]::IsNullOrWhiteSpace($name)) { return $false }
    return ($name -match '^[A-Za-z0-9_][A-Za-z0-9_-]*(\.[A-Za-z0-9_][A-Za-z0-9_-]*)+$')
}

function Test-SemVer([string]$version) {
    if ([string]::IsNullOrWhiteSpace($version)) { return $false }
    # Minimal SemVer (with optional pre-release/build), matching Unity's manifest expectations.
    return ($version -match '^\d+\.\d+\.\d+(-[0-9A-Za-z][0-9A-Za-z\.-]*)?(\+[0-9A-Za-z][0-9A-Za-z\.-]*)?$')
}

function Test-UpmDependencySpec([string]$spec) {
    if ([string]::IsNullOrWhiteSpace($spec)) { return $false }
    if ($spec -match '^file:') { return $true }
    if (Test-SemVer $spec) { return $true }
    if ($spec -match '^(git:|git\+)') { return $true }
    if ($spec -match '\.git(#.*)?$') { return $true }
    return $false
}

function Parse-Depfile($path) {
    if (!(Test-Path -LiteralPath $path)) { throw "depfile not found: $path" }

    $resolvedDepfile = (Resolve-Path -LiteralPath $path).Path
    $projectRoot = Split-Path -Parent $resolvedDepfile
    $packagesDir = Join-Path $projectRoot 'Packages'

    $lines = Get-Content -LiteralPath $resolvedDepfile

    $result = [ordered]@{
        registries = @()
        packages   = @{}
        unity      = @{}
        policy     = @{
            bannedApis          = @()
            allowGitDependencies = $false
        }
    }

    function Get-YamlIndent([string]$text) {
        return ([Regex]::Match($text, '^\s*').Value.Length)
    }

    function Unquote-YamlScalar([string]$value) {
        if ($null -eq $value) { return $null }
        $trimmed = $value.Trim()

        # Strip trailing inline YAML comments (" # comment") while preserving URL fragments ("#v1.2.3") and quoted values.
        $inSingle = $false
        $inDouble = $false
        for ($i = 0; $i -lt $trimmed.Length; $i++) {
            $ch = $trimmed[$i]
            if ($ch -eq "'" -and -not $inDouble) { $inSingle = -not $inSingle; continue }
            if ($ch -eq '"' -and -not $inSingle) { $inDouble = -not $inDouble; continue }
            if (-not $inSingle -and -not $inDouble -and $ch -eq '#') {
                $prevIsWhitespace = ($i -eq 0) -or [char]::IsWhiteSpace($trimmed[$i - 1])
                if ($prevIsWhitespace) {
                    $trimmed = $trimmed.Substring(0, $i).TrimEnd()
                    break
                }
            }
        }

        if ($trimmed.Length -ge 2) {
            $first = $trimmed.Substring(0, 1)
            $last = $trimmed.Substring($trimmed.Length - 1, 1)
            if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
                return $trimmed.Substring(1, $trimmed.Length - 2)
            }
        }
        return $trimmed
    }

    function Add-Registry([hashtable]$registry) {
        if ($null -eq $registry) { return }
        if ([string]::IsNullOrWhiteSpace($registry.name)) { throw "Invalid registry entry: missing name" }
        if ([string]::IsNullOrWhiteSpace($registry.url)) { throw "Invalid registry '$($registry.name)': missing url" }
        foreach ($existing in $result.registries) {
            if ($existing.name -eq $registry.name) { throw "Duplicate registry name in depfile: $($registry.name)" }
        }
        $scopes = @(@($registry.scopes) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($scopes.Count -lt 1) { throw "Invalid registry '$($registry.name)': scopes must contain at least 1 item" }
        $result.registries += [ordered]@{
            name   = $registry.name
            url    = $registry.url
            scopes = $scopes
        }
    }

    function Add-Package([hashtable]$pkg) {
        if ($null -eq $pkg) { return }
        if ([string]::IsNullOrWhiteSpace($pkg.name)) { throw "Invalid package entry: missing name" }
        if (-not (Test-UpmPackageName $pkg.name)) { throw "Invalid package name in depfile: '$($pkg.name)'. Expected a UPM package name like 'com.company.package'." }
        if ($result.packages.ContainsKey($pkg.name)) { throw "Duplicate package name in depfile: $($pkg.name)" }

        $spec = $null
        if (-not [string]::IsNullOrWhiteSpace($pkg.path)) {
            $pkgPath = Unquote-YamlScalar $pkg.path
            $fullPath = [System.IO.Path]::GetFullPath((Join-Path $projectRoot $pkgPath))
            $relative = Get-RelativePath $packagesDir $fullPath
            $spec = "file:$relative"
        }
        elseif (-not [string]::IsNullOrWhiteSpace($pkg.url)) {
            $spec = Unquote-YamlScalar $pkg.url
        }
        elseif (-not [string]::IsNullOrWhiteSpace($pkg.version)) {
            $spec = Unquote-YamlScalar $pkg.version
        }

        if ([string]::IsNullOrWhiteSpace($spec)) {
            throw "Invalid package '$($pkg.name)': must specify one of 'version', 'path', or 'url'"
        }
        if (($spec -is [string]) -and (-not (Test-UpmDependencySpec $spec))) {
            throw "Invalid dependency spec for package '$($pkg.name)': '$spec'. Expected a SemVer value, a 'file:' specifier, or a Git URL."
        }

        $result.packages[$pkg.name] = $spec
    }

    $usesV1Schema = $false
    foreach ($raw in $lines) {
        $candidate = $raw.Trim()
        if ($candidate.Length -eq 0) { continue }
        if ($candidate.StartsWith('#')) { continue }
        if ($candidate -match '^-\s*name:\s*\S') { $usesV1Schema = $true; break }
    }

    if ($usesV1Schema) {
        $section = $null

        $currentRegistry = $null
        $inRegistryScopes = $false
        $registryScopesIndent = 0

        $currentPackage = $null

        $inPolicyList = $false
        $policyListIndent = 0
        $policyListTarget = $null

        foreach ($raw in $lines) {
            $line = $raw.TrimEnd()
            if ($line -match '^\s*$') { continue }
            if ($line.TrimStart().StartsWith('#')) { continue }

            $indent = Get-YamlIndent $line
            $trimmed = $line.TrimStart()

            if ($indent -eq 0 -and $trimmed -match '^([A-Za-z0-9_]+):\s*(.*)$') {
                # Section boundary; finalize any open item state.
                Add-Registry $currentRegistry
                $currentRegistry = $null
                $inRegistryScopes = $false

                Add-Package $currentPackage
                $currentPackage = $null

                $inPolicyList = $false
                $policyListTarget = $null

                $section = $Matches[1]
                continue
            }

            switch ($section) {
                'project' {
                    if ($trimmed -match '^unityVersion:\s*(.+)$') {
                        $result.unity.editor = Unquote-YamlScalar $Matches[1]
                    }
                }
                'unity' {
                    if ($trimmed -match '^([A-Za-z0-9_-]+):\s*(.+)$') {
                        $result.unity[$Matches[1]] = Unquote-YamlScalar $Matches[2]
                    }
                }
                'registries' {
                    if ($trimmed -match '^-\s*name:\s*(.+)$') {
                        Add-Registry $currentRegistry
                        $currentRegistry = @{
                            name   = Unquote-YamlScalar $Matches[1]
                            url    = $null
                            scopes = @()
                        }
                        $inRegistryScopes = $false
                        continue
                    }

                    if ($null -eq $currentRegistry) { continue }

                    if ($inRegistryScopes -and $indent -le $registryScopesIndent) {
                        $inRegistryScopes = $false
                    }

                    if ($trimmed -match '^url:\s*(.+)$') {
                        $currentRegistry.url = Unquote-YamlScalar $Matches[1]
                        continue
                    }

                    if ($trimmed -match '^scopes:\s*$') {
                        $inRegistryScopes = $true
                        $registryScopesIndent = $indent
                        continue
                    }

                    if ($inRegistryScopes -and $indent -gt $registryScopesIndent -and $trimmed -match '^-\s*(\S.*)$') {
                        $currentRegistry.scopes += (Unquote-YamlScalar $Matches[1])
                        continue
                    }
                }
                'packages' {
                    if ($trimmed -match '^-\s*name:\s*(.+)$') {
                        Add-Package $currentPackage
                        $currentPackage = @{
                            name    = Unquote-YamlScalar $Matches[1]
                            version = $null
                            path    = $null
                            url     = $null
                            source  = $null
                        }
                        continue
                    }

                    if ($null -eq $currentPackage) { continue }

                    if ($trimmed -match '^version:\s*(.+)$') { $currentPackage.version = Unquote-YamlScalar $Matches[1]; continue }
                    if ($trimmed -match '^path:\s*(.+)$') { $currentPackage.path = Unquote-YamlScalar $Matches[1]; continue }
                    if ($trimmed -match '^url:\s*(.+)$') { $currentPackage.url = Unquote-YamlScalar $Matches[1]; continue }
                    if ($trimmed -match '^source:\s*(.+)$') { $currentPackage.source = Unquote-YamlScalar $Matches[1]; continue }
                }
                'policy' {
                    if ($inPolicyList -and $indent -le $policyListIndent) {
                        $inPolicyList = $false
                        $policyListTarget = $null
                    }

                    if ($trimmed -match '^allowGitDependencies:\s*(true|false)\s*$') {
                        $result.policy.allowGitDependencies = [System.Convert]::ToBoolean($Matches[1])
                        continue
                    }

                    if ($trimmed -match '^(bannedAPIs|bannedApis):\s*$') {
                        $inPolicyList = $true
                        $policyListIndent = $indent
                        $policyListTarget = 'bannedApis'
                        continue
                    }

                    if ($inPolicyList -and $policyListTarget -eq 'bannedApis' -and $indent -gt $policyListIndent -and $trimmed -match '^-\s*(\S.*)$') {
                        $result.policy.bannedApis += (Unquote-YamlScalar $Matches[1])
                        continue
                    }
                }
            }
        }

        Add-Registry $currentRegistry
        Add-Package $currentPackage
        return $result
    }

    # Legacy schema (mapping-based) parsing
    $legacy = @{ registries = @{}; scopes = @(); unity = @{}; packages = @{}; policy = @{ bannedApis = @(); allowGitDependencies = $false } }
    $section = ''
    foreach ($raw in $lines) {
        $line = $raw.TrimEnd()
        if ($line -match '^\s*$') { continue }
        if ($line.TrimStart().StartsWith('#')) { continue }
        if ($line -match '^(registries|scopes|unity|packages|policy):\s*$') {
            $section = $Matches[1]
            continue
        }
        switch ($section) {
            'registries' {
                if ($line -match '^\s{2,}([\w\-]+):\s*(\S+)\s*$') {
                    $name = $Matches[1]; $url = $Matches[2]
                    $legacy.registries[$name] = $url
                }
            }
            'scopes' {
                if ($line -match '^\s{2,}-\s*(\S+)\s*$') { $legacy.scopes += $Matches[1] }
            }
            'unity' {
                if ($line -match '^\s{2,}([\w\-]+):\s*(\S+)\s*$') { $legacy.unity[$Matches[1]] = $Matches[2] }
            }
            'packages' {
                if ($line -match '^\s{2,}([\w\.\-]+):\s*(\S+)\s*$') { $legacy.packages[$Matches[1]] = $Matches[2] }
            }
            'policy' {
                if ($line -match '^\s{2,}allowGitDependencies:\s*(true|false)\s*$') { $legacy.policy.allowGitDependencies = [System.Convert]::ToBoolean($Matches[1]) }
                if ($line -match '^\s{2,}bannedApis:\s*$') { continue }
                if ($line -match '^\s{4,}-\s*(\S+)\s*$') { $legacy.policy.bannedApis += $Matches[1] }
            }
        }
    }

    $result.unity = $legacy.unity
    $result.policy.allowGitDependencies = $legacy.policy.allowGitDependencies
    $result.policy.bannedApis = @($legacy.policy.bannedApis)
    $result.packages = $legacy.packages

    foreach ($name in ($legacy.registries.Keys | Sort-Object)) {
        $scopes = @($legacy.scopes)
        if ($scopes.Count -lt 1) { continue }
        $result.registries += [ordered]@{ name = $name; url = $legacy.registries[$name]; scopes = $scopes }
    }

    return $result
}

function Make-Manifest($dep, $projectPath) {
    $baseManifest = $null
    try { $baseManifest = Load-Manifest $projectPath } catch { $baseManifest = $null }

    $deps = [ordered]@{}
    if ($baseManifest -and $baseManifest.dependencies) {
        foreach ($prop in $baseManifest.dependencies.PSObject.Properties) {
            if (Test-UpmPackageName $prop.Name) {
                $deps[$prop.Name] = $prop.Value
            }
        }
    }

    $lockDeps = Load-LockDependencies $projectPath
    foreach ($name in ($lockDeps.Keys | Sort-Object)) {
        if ((Test-UpmPackageName $name) -and (-not $deps.Contains($name))) {
            $deps[$name] = $lockDeps[$name]
        }
    }

    foreach ($k in ($dep.packages.Keys | Sort-Object)) {
        if (-not (Test-UpmPackageName $k)) {
            throw "Invalid package name produced from depfile parsing: '$k'. Expected a UPM package name like 'com.company.package'."
        }
        $deps[$k] = $dep.packages[$k]
    }
    if ($dep.unity.rp -eq 'urp' -and $dep.unity.rp_version) { $deps['com.unity.render-pipelines.universal'] = $dep.unity.rp_version }
    if ($dep.unity.rp -eq 'hdrp' -and $dep.unity.rp_version) { $deps['com.unity.render-pipelines.high-definition'] = $dep.unity.rp_version }

    $scoped = @()
    if ($dep.registries -and $dep.registries.Count -gt 0) {
        $scopedMap = [ordered]@{}
        foreach ($entry in $dep.registries) {
            if ($null -eq $entry) { continue }
            $name = $entry.name
            $url = $entry.url
            $scopes = @(@($entry.scopes) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object)

            if ([string]::IsNullOrWhiteSpace($name)) { throw "Invalid registry entry: missing name" }
            if ([string]::IsNullOrWhiteSpace($url)) { throw "Invalid registry '$name': missing url" }
            if ($scopes.Count -lt 1) { throw "Invalid registry '$name': scopes must contain at least 1 item" }
            if ($scopedMap.Contains($name)) { throw "Duplicate registry name in depfile: $name" }

            $scopedMap[$name] = [ordered]@{ name = $name; url = $url; scopes = $scopes }
        }

        foreach ($key in ($scopedMap.Keys | Sort-Object)) { $scoped += $scopedMap[$key] }
    }
    elseif ($baseManifest -and $baseManifest.scopedRegistries) {
        foreach ($entry in $baseManifest.scopedRegistries) {
            if ($null -eq $entry) { continue }
            if (-not $entry.PSObject.Properties['name']) { continue }
            if (-not $entry.PSObject.Properties['url']) { continue }
            if (-not $entry.PSObject.Properties['scopes']) { continue }
            if ($null -eq $entry.scopes -or $entry.scopes.Count -lt 1) { continue }
            $entry.scopes = @(@($entry.scopes) | Sort-Object)
            $scoped += $entry
        }
    }

    $depsNormalized = [ordered]@{}
    foreach ($depName in ($deps.Keys | Sort-Object)) {
        $normalized = Normalize-FileSpec $projectPath $deps[$depName]
        if (($normalized -is [string]) -and (-not (Test-UpmDependencySpec $normalized))) {
            throw "Invalid dependency spec for '$depName': '$normalized'. Expected a SemVer value, a 'file:' specifier, or a Git URL."
        }
        $depsNormalized[$depName] = $normalized
    }

    $scopedNormalized = @(@($scoped | Sort-Object -Property name))

    return @{ dependencies = $depsNormalized; scopedRegistries = $scopedNormalized }
}



function Get-WorkspaceRoot([string]$projectPath) {
    if ($env:MAGI_WORKSPACE_ROOT) {
        return [System.IO.Path]::GetFullPath($env:MAGI_WORKSPACE_ROOT)
    }
    if ($PSScriptRoot) {
        return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    }
    if ([string]::IsNullOrEmpty($projectPath)) { return $null }
    return [System.IO.Path]::GetFullPath([System.IO.Path]::GetDirectoryName($projectPath))
}

function Ensure-WorkspacePath([string]$candidatePath, [string]$projectPath, [string]$specifier) {
    $root = Get-WorkspaceRoot $projectPath
    if ([string]::IsNullOrEmpty($root)) { return [System.IO.Path]::GetFullPath($candidatePath) }
    $normalizedRoot = [System.IO.Path]::GetFullPath($root)
    if (-not $normalizedRoot.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $normalizedRoot += [System.IO.Path]::DirectorySeparatorChar
    }
    $normalizedCandidate = [System.IO.Path]::GetFullPath($candidatePath)
    $platform = [System.Environment]::OSVersion.Platform
    $comparison = if ($platform -eq [System.PlatformID]::Unix -or $platform -eq [System.PlatformID]::MacOSX) { [System.StringComparison]::Ordinal } else { [System.StringComparison]::OrdinalIgnoreCase }
    if (-not $normalizedCandidate.StartsWith($normalizedRoot, $comparison)) {
        throw "Local package path '$specifier' resolves outside the workspace root '$normalizedRoot'. Update the 'file:' reference so it stays within the workspace."
    }
    return $normalizedCandidate
}

function Get-RelativePath($fromPath, $toPath) {
    $fromFull = [System.IO.Path]::GetFullPath($fromPath)
    $toFull = [System.IO.Path]::GetFullPath($toPath)
    if (-not $fromFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $fromFull += [System.IO.Path]::DirectorySeparatorChar
    }
    $fromUri = New-Object System.Uri($fromFull)
    $toUri = New-Object System.Uri($toFull)
    $relativeUri = $fromUri.MakeRelativeUri($toUri)
    $relativePath = [System.Uri]::UnescapeDataString($relativeUri.ToString())
    return $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
}

function Normalize-FileSpec($projectPath, $spec) {
    if (-not ($spec -is [string])) { return $spec }
    if ($spec -notmatch '^file:') { return $spec }
    $absolute = Resolve-LocalPackagePath $projectPath $spec
    if (-not $absolute) { return $spec }
    $resolvedProject = (Resolve-Path -Path $projectPath).Path
    $packagesDir = Join-Path $resolvedProject 'Packages'
    $relative = Get-RelativePath $packagesDir $absolute
    return "file:$relative"
}

function Resolve-LocalPackagePath($projectPath, $spec) {
    if (-not ($spec -is [string])) { return $null }
    if ($spec -notmatch '^file:') { return $null }
    $rel = $spec.Substring(5)
    # Manifest paths are relative to Packages/ directory, not project root
    $base = (Resolve-Path -Path $projectPath).Path
    $packagesDir = Join-Path $base 'Packages'
    $full = [System.IO.Path]::GetFullPath((Join-Path $packagesDir $rel))
    return Ensure-WorkspacePath -candidatePath $full -projectPath $base -specifier $spec
}

function Read-JsonFile($path) {
    try { return Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json } catch { return $null }
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
    $resolvedProject = (Resolve-Path -Path $projectPath).Path
    $packagesPath = Join-Path $resolvedProject 'Packages'
    if (!(Test-Path $packagesPath)) {
        New-Item -ItemType Directory -Force -Path $packagesPath | Out-Null
    }
    $manifestPath = Join-Path $packagesPath 'manifest.json'
    $json = $manifestObj | ConvertTo-Json -Depth 5
    # Write without BOM for Unity compatibility
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($manifestPath, $json, $utf8NoBom)
    Write-Host "Wrote manifest: $manifestPath"
}

function Normalize-ManifestForComparison($manifest) {
    if ($null -eq $manifest) { return $null }

    $dependencies = [ordered]@{}
    $depsObj = $manifest.dependencies
    if ($depsObj) {
        $keys = @()
        if ($depsObj -is [System.Collections.IDictionary]) {
            $keys = @($depsObj.Keys)
        }
        else {
            $keys = @($depsObj.PSObject.Properties | ForEach-Object { $_.Name })
        }

        foreach ($k in ($keys | Sort-Object)) {
            $value = if ($depsObj -is [System.Collections.IDictionary]) { $depsObj[$k] } else { $depsObj.$k }
            $dependencies[$k] = $value
        }
    }

    $scoped = @()
    foreach ($entry in @($manifest.scopedRegistries)) {
        if ($null -eq $entry) { continue }

        $name = $null
        $url = $null
        $scopes = @()
        if ($entry -is [System.Collections.IDictionary]) {
            $name = $entry['name']
            $url = $entry['url']
            $scopes = @($entry['scopes'])
        }
        else {
            $name = $entry.name
            $url = $entry.url
            $scopes = @($entry.scopes)
        }

        $scoped += [ordered]@{
            name   = $name
            url    = $url
            scopes = @(@($scopes) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object)
        }
    }

    $scoped = @(@($scoped | Sort-Object -Property name))

    return [ordered]@{ dependencies = $dependencies; scopedRegistries = $scoped }
}

function Compare-Manifests($a, $b) {
    $aJson = (Normalize-ManifestForComparison $a | ConvertTo-Json -Depth 10)
    $bJson = (Normalize-ManifestForComparison $b | ConvertTo-Json -Depth 10)
    return $aJson -eq $bJson
}

function Load-Manifest($projectPath) {
    $path = Join-Path (Join-Path $projectPath 'Packages') 'manifest.json'
    if (!(Test-Path $path)) { return $null }
    return Get-Content $path -Raw | ConvertFrom-Json
}

function Load-LockDependencies($projectPath) {
    $lockPath = Join-Path (Join-Path $projectPath 'Packages') 'packages-lock.json'
    if (!(Test-Path $lockPath)) { return @{} }
    try { $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json } catch { return @{} }

    $deps = @{}
    if ($lock.dependencies) {
        foreach ($prop in $lock.dependencies.PSObject.Properties) {
            $value = $prop.Value
            if ($null -eq $value) { continue }
            if ($value.PSObject.Properties['version']) {
                $deps[$prop.Name] = $value.version
            }
        }
    }
    return $deps
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
                $escaped = [Regex]::Escape($api)
                $pattern = $escaped
                if ($api -notmatch '\(') {
                    $pattern += '\s*(<[^>]+>\s*)?\('
                }
                if ([Regex]::IsMatch($content, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)) {
                    Write-Host "Policy violation: '$api' found in $($f.FullName)" -ForegroundColor Red
                    $ok = $false
                }
            }
        }
    }
    if (-not $ok -and $Strict) { exit 2 }
    return $ok
}

function Resolve-ComputeShaderIncludes($projectPath, $dep) {
    # Resolve compute shader cross-package includes
    # Unity compute shaders cannot reference files from other UPM packages via #include
    # This function creates .asmdef exclude patterns to prevent .cs files in shader directories from being compiled

    Write-Host "Resolving compute shader dependencies..." -ForegroundColor Cyan

    foreach ($pkgName in $dep.packages.Keys) {
        $spec = $dep.packages[$pkgName]
        if (-not ($spec -match '^file:')) { continue }

        $pkgPath = Resolve-LocalPackagePath $projectPath $spec
        if (-not (Test-Path $pkgPath)) { continue }

        # Find compute shader directories
        $computeDirs = Get-ChildItem -Path $pkgPath -Recurse -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq "Compute" }

        foreach ($computeDir in $computeDirs) {
            # Find any .cs files that are used as shader includes (X-Macro pattern)
            $shaderCsFiles = Get-ChildItem -Path $computeDir.FullName -Recurse -Filter "*.cs" -ErrorAction SilentlyContinue

            foreach ($csFile in $shaderCsFiles) {
                # Check if this .cs file is referenced by a shader
                $content = Get-Content $csFile.FullName -Raw -ErrorAction SilentlyContinue
                if ($content -match '#define public' -or $content -match 'CSHARP_7_3_OR_NEWER') {
                    # This is an X-Macro file - create a .meta file to mark it as shader include
                    $metaPath = $csFile.FullName + ".meta"
                    if (-not (Test-Path $metaPath)) {
                        # Create meta file that marks this as a non-script asset
                        $metaContent = @"
fileFormatVersion: 2
guid: $([guid]::NewGuid().ToString("N"))
DefaultImporter:
  externalObjects: {}
  userData:
  assetBundleName:
  assetBundleVariant:
"@
                        Set-Content -Path $metaPath -Value $metaContent -Encoding UTF8
                        Write-Host "    Created .meta for X-Macro file: $($csFile.Name)" -ForegroundColor Green
                    }
                }
            }
        }

        # Original cross-package include resolution (now disabled - rely on Unity's package system)
        # Keeping this commented for reference
        <#
        $pkgPath = Resolve-LocalPackagePath $projectPath $spec
        if (-not (Test-Path $pkgPath)) { continue }

        # Find all compute shaders and shader includes in this package
        $shaderFiles = @()
        $shaderFiles += Get-ChildItem -Path $pkgPath -Recurse -Filter "*.compute" -ErrorAction SilentlyContinue
        $shaderFiles += Get-ChildItem -Path $pkgPath -Recurse -Filter "*.hlsl" -ErrorAction SilentlyContinue

        foreach ($shader in $shaderFiles) {
            $content = Get-Content $shader.FullName -Raw

            # Find cross-package includes (e.g., "../../PackageName/...")
            $includePattern = '#include\s+"(\.\./.*?)"'
            $matches = [regex]::Matches($content, $includePattern)

            if ($matches.Count -eq 0) { continue }

            Write-Host "  Processing $($shader.Name) in $pkgName..." -ForegroundColor Gray

            foreach ($match in $matches) {
                $includePath = $match.Groups[1].Value

                # Resolve the full path of the included file
                $shaderDir = $shader.DirectoryName
                $fullIncludePath = [System.IO.Path]::GetFullPath((Join-Path $shaderDir $includePath))

                # Check if this include crosses package boundaries
                $normalizedPkgPath = [System.IO.Path]::GetFullPath($pkgPath)
                if ($fullIncludePath.StartsWith($normalizedPkgPath, [StringComparison]::OrdinalIgnoreCase)) {
                    # Include is within the same package, no action needed
                    continue
                }

                # Cross-package include detected - need to copy the file
                if (-not (Test-Path $fullIncludePath)) {
                    Write-Host "    WARNING: Include file not found: $includePath" -ForegroundColor Yellow
                    continue
                }

                # Determine the dependency package this file belongs to
                $depPkgName = $null
                foreach ($depName in $dep.packages.Keys) {
                    $depSpec = $dep.packages[$depName]
                    if ($depSpec -notmatch '^file:') { continue }

                    $depPath = Resolve-LocalPackagePath $projectPath $depSpec
                    $normalizedDepPath = [System.IO.Path]::GetFullPath($depPath)
                    if ($fullIncludePath.StartsWith($normalizedDepPath, [StringComparison]::OrdinalIgnoreCase)) {
                        $depPkgName = $depName
                        break
                    }
                }

                if ($null -eq $depPkgName) {
                    Write-Host "    WARNING: Could not determine source package for: $includePath" -ForegroundColor Yellow
                    continue
                }

                # Create a local Includes directory in the shader's package
                $includesDir = Join-Path $shaderDir "Includes"
                if (-not (Test-Path $includesDir)) {
                    New-Item -ItemType Directory -Force -Path $includesDir | Out-Null
                }

                # Copy the include file, renaming .cs to .cginc for X-Macro shader files
                $fileName = [System.IO.Path]::GetFileName($fullIncludePath)
                $destFileName = $fileName
                if ($fileName -match '\.cs$') {
                    $destFileName = $fileName -replace '\.cs$', '.cginc'
                    Write-Host "    Renaming $fileName to $destFileName (X-Macro shader file)" -ForegroundColor Gray
                }
                $destPath = Join-Path $includesDir $destFileName

                Copy-Item -Path $fullIncludePath -Destination $destPath -Force
                Write-Host "    Copied: $fileName from $depPkgName to $pkgName/Includes/ as $destFileName" -ForegroundColor Green

                # Update the compute shader to use the local include with the new filename
                $newInclude = "#include `"Includes/$destFileName`""
                $oldInclude = $match.Value
                $content = $content.Replace($oldInclude, $newInclude)
            }

            # Write the updated shader file
            Set-Content -Path $shader.FullName -Value $content -Encoding UTF8
        }
    }
        #>
    }

    Write-Host "Compute shader dependency resolution complete." -ForegroundColor Cyan
}


switch ($Command) {
    'apply' {
        $resolvedProjectPath = Resolve-UnityProjectPath $ProjectPath
        $dep = Parse-Depfile (Join-Path $resolvedProjectPath $Depfile)

        # Ensure local file: packages have valid package.json before generating manifest
        foreach ($k in $dep.packages.Keys) {
            $spec = $dep.packages[$k]
            Ensure-LocalPackage -projectPath $resolvedProjectPath -pkgName $k -spec $spec -editorVersion $dep.unity.editor
        }

        # Resolve compute shader cross-package includes
        # DISABLED: This feature needs more work to avoid modifying source packages
        # Resolve-ComputeShaderIncludes -projectPath $ProjectPath -dep $dep

        $manifestObj = Make-Manifest -dep $dep -projectPath $resolvedProjectPath
        Write-Manifest -projectPath $resolvedProjectPath -manifestObj $manifestObj
        Check-Policy -projectPath $resolvedProjectPath -dep $dep -Strict:$Strict | Out-Null
    }
    'verify' {
        $resolvedProjectPath = Resolve-UnityProjectPath $ProjectPath
        $dep = Parse-Depfile (Join-Path $resolvedProjectPath $Depfile)
        foreach ($k in $dep.packages.Keys) { Ensure-LocalPackage -projectPath $resolvedProjectPath -pkgName $k -spec $dep.packages[$k] -editorVersion $dep.unity.editor }
        $expected = Make-Manifest -dep $dep -projectPath $resolvedProjectPath
        $actual = Load-Manifest $resolvedProjectPath
        if ($actual -eq $null) { Write-Host "No manifest.json present" -ForegroundColor Yellow; if ($Strict){ exit 3 } else { exit 0 } }
        $same = Compare-Manifests $expected $actual
        if (-not $same) { Write-Host "Lock drift: manifest does not match depfile" -ForegroundColor Red; if ($Strict){ exit 1 } }
        $policyOk = Check-Policy -projectPath $resolvedProjectPath -dep $dep -Strict:$Strict
        if ($same -and $policyOk) { Write-Host "verify: OK" }
    }
    'policy' {
        $resolvedProjectPath = Resolve-UnityProjectPath $ProjectPath
        $dep = Parse-Depfile (Join-Path $resolvedProjectPath $Depfile)
        Write-Host ("allowGitDependencies=" + $dep.policy.allowGitDependencies)
        Write-Host ("bannedApis=[" + ($dep.policy.bannedApis -join ', ') + "]")
        $registryNames = @($dep.registries | ForEach-Object { $_['name'] }) -join ', '
        Write-Host ("registries=" + $registryNames)
    }
    'init' {
        $resolvedProjectPath = Resolve-UnityProjectPath $ProjectPath
        $depfilePath = Join-Path $resolvedProjectPath $Depfile
        if (Test-Path -LiteralPath $depfilePath) { Write-Host "depfile exists: $depfilePath"; exit 0 }
        $content = @"
# Magi Unity Dependency File
version: 1.0

project:
  name: ExampleProject
  unityVersion: 6000.2.0f1
  targetPlatforms:
    - StandaloneWindows64

registries:
  - name: Unity
    url: https://packages.unity.com
    scopes:
      - com.unity
  - name: Magi Private
    url: https://registry.example.com
    scopes:
      - com.magi
      - com.vendor

packages:
  - name: com.unity.inputsystem
    version: 1.7.0
    source: registry
policy:
  allowGitDependencies: false
  bannedAPIs:
    - Resources.Load
    - FindObjectOfType
"@
        Set-Content -LiteralPath $depfilePath -Value $content -Encoding UTF8
        Write-Host "Created depfile: $depfilePath"
    }
    'validate' {
        $resolvedProjectPath = Resolve-UnityProjectPath $ProjectPath
        $dep = Parse-Depfile (Join-Path $resolvedProjectPath $Depfile)
        Make-Manifest -dep $dep -projectPath $resolvedProjectPath | Out-Null
        Write-Host "validate: OK"
    }
}







