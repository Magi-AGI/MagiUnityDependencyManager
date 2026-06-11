param(
    [switch]$KeepWorkDir
)

$ErrorActionPreference = 'Stop'

function Assert([bool]$condition, [string]$message) {
    if (-not $condition) { throw "ASSERT FAILED: $message" }
}

function Assert-Equal($expected, $actual, [string]$message) {
    if ($expected -ne $actual) {
        throw ("ASSERT FAILED: {0}`n  expected: {1}`n  actual:   {2}" -f $message, $expected, $actual)
    }
}

function Expect-Throws([scriptblock]$action, [string]$messageContains) {
    $threw = $false
    try {
        & $action
    }
    catch {
        $threw = $true
        if (-not [string]::IsNullOrWhiteSpace($messageContains)) {
            $msg = $_.Exception.Message
            Assert ($msg -like "*$messageContains*") ("Expected error message to contain '{0}', got: {1}" -f $messageContains, $msg)
        }
    }
    Assert ($threw) "Expected command to throw."
}

$repoRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$magiDeps = Join-Path $repoRoot 'magi-deps.ps1'
Assert (Test-Path -LiteralPath $magiDeps) "Expected magi-deps.ps1 at $magiDeps"

function New-TestUnityProject([string]$workDir, [string]$name) {
    $projectDir = Join-Path $workDir $name
    New-Item -ItemType Directory -Force -Path $projectDir | Out-Null

    New-Item -ItemType Directory -Force -Path (Join-Path $projectDir 'Assets') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $projectDir 'Packages') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $projectDir 'ProjectSettings') | Out-Null

    Set-Content -LiteralPath (Join-Path $projectDir 'ProjectSettings/ProjectVersion.txt') -Value "m_EditorVersion: 6000.2.0f1`n" -Encoding UTF8

    return $projectDir
}

function Write-Depfile([string]$projectDir, [string]$content) {
    $depfilePath = Join-Path $projectDir 'depfile.yaml'
    Set-Content -LiteralPath $depfilePath -Value $content -Encoding UTF8
}

function Read-Manifest([string]$projectDir) {
    $manifestPath = Join-Path $projectDir 'Packages/manifest.json'
    Assert (Test-Path -LiteralPath $manifestPath) "Expected manifest.json at $manifestPath"
    return Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
}

$workDir = Join-Path $repoRoot '.self-test-work'
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
try {
    Write-Host "Case: v1 schema (comments, local pkg, single-scope array)" -ForegroundColor Cyan
    $projectDir = New-TestUnityProject -workDir $workDir -name 'case-v1-basic'
    $localPkgDir = Join-Path $projectDir 'LocalPkg'
    New-Item -ItemType Directory -Force -Path $localPkgDir | Out-Null

    Write-Depfile -projectDir $projectDir -content @"
version: 1.0

project:
  name: SelfTestProject
  unityVersion: 6000.2.0f1

registries:
  - name: Unity # inline comment
    url: https://packages.unity.com
    scopes:
      - com.unity # inline comment
  - name: Example Private
    url: https://registry.example.com
    scopes:
      - com.example

packages:
  - name: com.unity.nuget.newtonsoft-json
    version: 3.2.1
    source: registry
  - name: com.example.localpkg
    path: LocalPkg # inline comment
    source: local

policy:
  allowGitDependencies: false
  bannedAPIs:
    - GameObject.Find # inline comment
"@

    & $magiDeps validate -ProjectPath $projectDir
    & $magiDeps apply -ProjectPath $projectDir

    $manifest = Read-Manifest -projectDir $projectDir
    Assert ($null -ne $manifest.scopedRegistries) "Expected scopedRegistries to exist"
    Assert ($manifest.scopedRegistries.Count -eq 2) "Expected 2 scoped registries"

    $unityRegistry = $manifest.scopedRegistries | Where-Object { $_.name -eq 'Unity' } | Select-Object -First 1
    Assert ($null -ne $unityRegistry) "Expected Unity scoped registry"
    Assert ($unityRegistry.scopes -is [System.Array]) "Expected Unity registry scopes to be an array (not a single string)."
    Assert-Equal 'com.unity' $unityRegistry.scopes[0] "Expected Unity registry scope to be com.unity"

    $privateRegistry = $manifest.scopedRegistries | Where-Object { $_.name -eq 'Example Private' } | Select-Object -First 1
    Assert ($null -ne $privateRegistry) "Expected Example Private scoped registry"
    Assert ($privateRegistry.scopes -is [System.Array]) "Expected Example Private registry scopes to be an array."
    Assert-Equal 'com.example' $privateRegistry.scopes[0] "Expected Example Private registry scope to be com.example"

    foreach ($reg in $manifest.scopedRegistries) {
        Assert (-not [string]::IsNullOrWhiteSpace($reg.name)) "Registry missing name"
        Assert (-not [string]::IsNullOrWhiteSpace($reg.url)) "Registry '$($reg.name)' missing url"
        Assert ($null -ne $reg.scopes -and $reg.scopes.Count -ge 1) "Registry '$($reg.name)' scopes must contain at least 1 item"
    }

    Assert ($manifest.dependencies.'com.unity.nuget.newtonsoft-json' -eq '3.2.1') "Expected com.unity.nuget.newtonsoft-json=3.2.1"
    $localSpec = $manifest.dependencies.'com.example.localpkg'
    Assert-Equal 'file:..\LocalPkg' $localSpec "Expected com.example.localpkg to be a file: dependency relative to Packages/"

    $localPkgJson = Join-Path $localPkgDir 'package.json'
    Assert (Test-Path -LiteralPath $localPkgJson) "Expected package.json to be created for local package"

    foreach ($junkKey in @('path','version','source','policyException')) {
        Assert (-not ($manifest.dependencies.PSObject.Properties.Name -contains $junkKey)) "Did not expect junk dependency key '$junkKey' in manifest.json"
    }

    Write-Host "Case: v1 schema preserves git URL fragments (#...)" -ForegroundColor Cyan
    $projectGit = New-TestUnityProject -workDir $workDir -name 'case-v1-git-fragment'
    Write-Depfile -projectDir $projectGit -content @"
version: 1.0
project:
  name: SelfTestProject
  unityVersion: 6000.2.0f1
registries:
  - name: Unity
    url: https://packages.unity.com
    scopes:
      - com.unity
packages:
  - name: com.example.tooling
    url: https://github.com/example/tooling.git#v1.2.3
    source: git
"@
    & $magiDeps validate -ProjectPath $projectGit
    & $magiDeps apply -ProjectPath $projectGit
    $manifestGit = Read-Manifest -projectDir $projectGit
    Assert-Equal 'https://github.com/example/tooling.git#v1.2.3' $manifestGit.dependencies.'com.example.tooling' "Expected git URL fragment to be preserved"

    Write-Host "Case: legacy schema still supported" -ForegroundColor Cyan
    $projectLegacy = New-TestUnityProject -workDir $workDir -name 'case-legacy'
    Write-Depfile -projectDir $projectLegacy -content @"
registries:
  Unity: https://packages.unity.com
  Example: https://registry.example.com
scopes:
  - com.unity
  - com.example
unity:
  editor: 6000.2.0f1
packages:
  com.unity.nuget.newtonsoft-json: 3.2.1
policy:
  allowGitDependencies: false
  bannedApis:
    - GameObject.Find
"@
    & $magiDeps validate -ProjectPath $projectLegacy
    & $magiDeps apply -ProjectPath $projectLegacy
    $manifestLegacy = Read-Manifest -projectDir $projectLegacy
    Assert ($manifestLegacy.scopedRegistries.Count -eq 2) "Expected 2 registries in legacy manifest"
    foreach ($reg in $manifestLegacy.scopedRegistries) {
        Assert ($reg.scopes -is [System.Array]) "Expected legacy registry scopes to be an array."
        Assert ($reg.scopes.Count -eq 2) "Expected legacy registry scopes to include 2 items."
    }

    Write-Host "Case: rejects duplicate registry names" -ForegroundColor Cyan
    $projectDupReg = New-TestUnityProject -workDir $workDir -name 'case-dup-registry'
    Write-Depfile -projectDir $projectDupReg -content @"
version: 1.0
project:
  name: SelfTestProject
  unityVersion: 6000.2.0f1
registries:
  - name: Unity
    url: https://packages.unity.com
    scopes:
      - com.unity
  - name: Unity
    url: https://packages.unity.com
    scopes:
      - com.unity
packages: []
"@
    Expect-Throws { & $magiDeps validate -ProjectPath $projectDupReg } "Duplicate registry name"

    Write-Host "Case: rejects duplicate package names" -ForegroundColor Cyan
    $projectDupPkg = New-TestUnityProject -workDir $workDir -name 'case-dup-package'
    Write-Depfile -projectDir $projectDupPkg -content @"
version: 1.0
project:
  name: SelfTestProject
  unityVersion: 6000.2.0f1
registries:
  - name: Unity
    url: https://packages.unity.com
    scopes:
      - com.unity
packages:
  - name: com.unity.nuget.newtonsoft-json
    version: 3.2.1
    source: registry
  - name: com.unity.nuget.newtonsoft-json
    version: 3.2.1
    source: registry
"@
    Expect-Throws { & $magiDeps validate -ProjectPath $projectDupPkg } "Duplicate package name"

    Write-Host "Case: rejects empty registry scopes" -ForegroundColor Cyan
    $projectEmptyScopes = New-TestUnityProject -workDir $workDir -name 'case-empty-scopes'
    Write-Depfile -projectDir $projectEmptyScopes -content @"
version: 1.0
project:
  name: SelfTestProject
  unityVersion: 6000.2.0f1
registries:
  - name: Broken
    url: https://registry.example.com
    scopes: []
packages: []
"@
    Expect-Throws { & $magiDeps validate -ProjectPath $projectEmptyScopes } "scopes must contain at least 1 item"

    Write-Host "Case: rejects non-Unity ProjectPath" -ForegroundColor Cyan
    Expect-Throws { & $magiDeps validate -ProjectPath $workDir } "does not look like a Unity project root"

    Write-Host "Case: rejects non-Unity folder even if Packages/manifest.json exists" -ForegroundColor Cyan
    $nonUnityWithPackages = Join-Path $workDir 'case-nonunity-with-packages'
    New-Item -ItemType Directory -Force -Path $nonUnityWithPackages | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $nonUnityWithPackages 'Packages') | Out-Null
    Set-Content -LiteralPath (Join-Path $nonUnityWithPackages 'Packages/manifest.json') -Value "{}`n" -Encoding UTF8
    Expect-Throws { & $magiDeps validate -ProjectPath $nonUnityWithPackages } "does not look like a Unity project root"

    Write-Host "Case: rejects invalid package names in depfile" -ForegroundColor Cyan
    $projectInvalidName = New-TestUnityProject -workDir $workDir -name 'case-invalid-package-name'
    Write-Depfile -projectDir $projectInvalidName -content @"
version: 1.0
project:
  name: SelfTestProject
  unityVersion: 6000.2.0f1
registries:
  - name: Unity
    url: https://packages.unity.com
    scopes:
      - com.unity
packages:
  - name: path
    version: 1.0.0
    source: registry
"@
    Expect-Throws { & $magiDeps validate -ProjectPath $projectInvalidName } "Invalid package name"

    Write-Host "Case: rejects invalid dependency specs in depfile" -ForegroundColor Cyan
    $projectInvalidSpec = New-TestUnityProject -workDir $workDir -name 'case-invalid-dependency-spec'
    Write-Depfile -projectDir $projectInvalidSpec -content @"
version: 1.0
project:
  name: SelfTestProject
  unityVersion: 6000.2.0f1
registries:
  - name: Unity
    url: https://packages.unity.com
    scopes:
      - com.unity
packages:
  - name: com.example.bad
    version: registry
    source: registry
"@
    Expect-Throws { & $magiDeps validate -ProjectPath $projectInvalidSpec } "Invalid dependency spec"

    Write-Host "Case: ignores broken base manifest entries" -ForegroundColor Cyan
    $projectBaseManifest = New-TestUnityProject -workDir $workDir -name 'case-base-manifest-junk'
    $baseManifestPath = Join-Path $projectBaseManifest 'Packages/manifest.json'
    Set-Content -LiteralPath $baseManifestPath -Value @"
{
  ""scopedRegistries"": [
    { ""name"": ""Broken"", ""url"": ""https://registry.example.com"", ""scopes"": [] }
  ],
  ""dependencies"": {
    ""path"": ""../SomePath"",
    ""policyException"": ""development-tool"",
    ""source"": ""registry"",
    ""version"": ""17.0.3"",
    ""com.unity.nuget.newtonsoft-json"": ""3.2.1""
  }
}
"@ -Encoding UTF8

    Write-Depfile -projectDir $projectBaseManifest -content @"
version: 1.0
project:
  name: SelfTestProject
  unityVersion: 6000.2.0f1
registries:
  - name: Unity
    url: https://packages.unity.com
    scopes:
      - com.unity
packages:
  - name: com.unity.nuget.newtonsoft-json
    version: 3.2.1
    source: registry
"@
    & $magiDeps apply -ProjectPath $projectBaseManifest
    $manifestBase = Read-Manifest -projectDir $projectBaseManifest
    foreach ($junkKey in @('path','version','source','policyException')) {
        Assert (-not ($manifestBase.dependencies.PSObject.Properties.Name -contains $junkKey)) "Did not expect junk dependency key '$junkKey' in manifest.json"
    }
    Assert ($manifestBase.scopedRegistries.name -contains 'Unity') "Expected Unity registry to be present"
    Assert (-not ($manifestBase.scopedRegistries.name -contains 'Broken')) "Did not expect Broken registry to carry over when depfile registries are present"

    Write-Host "Case: rejects local package paths outside workspace root" -ForegroundColor Cyan
    $projectOutside = New-TestUnityProject -workDir $workDir -name 'case-outside-workspace'
    Write-Depfile -projectDir $projectOutside -content @"
version: 1.0
project:
  name: SelfTestProject
  unityVersion: 6000.2.0f1
registries:
  - name: Unity
    url: https://packages.unity.com
    scopes:
      - com.unity
packages:
  - name: com.example.outside
    path: ..\\..\\..\\..\\OutsidePkg
    source: local
"@
    Expect-Throws { & $magiDeps validate -ProjectPath $projectOutside } "resolves outside the workspace root"

    Write-Host "self-test: OK" -ForegroundColor Green
}
finally {
    if (-not $KeepWorkDir -and (Test-Path -LiteralPath $workDir)) {
        try {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction Stop
        }
        catch {
            Write-Host "self-test: cleanup failed (leaving work dir): $workDir" -ForegroundColor Yellow
        }
    }
    elseif ($KeepWorkDir) {
        Write-Host "self-test: kept work dir: $workDir" -ForegroundColor Yellow
    }
}
