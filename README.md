# MagiUnityDependencyManager

Authoritative dependency management system for Unity Package Manager (UPM) projects in the Magi ecosystem.

## Overview

MagiUnityDependencyManager provides centralized, policy-driven dependency management for Unity projects. It replaces manual `manifest.json` editing with a declarative `depfile.yaml` approach, ensuring consistency across projects and enforcing organizational standards.

## Key Features

- **Single Source of Truth**: `depfile.yaml` drives `Packages/manifest.json` generation
- **Policy Enforcement**: Configurable rules for API usage, dependency sources, and version constraints
- **Lock File Awareness**: Reads `packages-lock.json` when present (Unity still owns lockfile generation)
- **Registry Management**: Support for Unity, npm, and private scoped registries
- **Batch Operations**: Manage multiple Unity projects from a single location

## Installation

1. Clone the repository:
   ```bash
   git clone <repo-url> MagiUnityDependencyManager
   ```

2. Ensure PowerShell execution policy allows scripts:
   ```powershell
   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
   ```

## Usage

### Commands

All commands are executed via the `magi-deps.ps1` PowerShell script:

#### Initialize a new project
```powershell
./magi-deps.ps1 init -ProjectPath ../Inkling
```
Creates a starter `depfile.yaml` template.

#### Apply dependencies
```powershell
./magi-deps.ps1 apply -ProjectPath ../Inkling
```
Generates `Packages/manifest.json` from `depfile.yaml`.

#### Verify dependencies
```powershell
./magi-deps.ps1 verify -ProjectPath ../Inkling -Strict
```
Checks for manifest drift and policy violations.

#### Show active policy
```powershell
./magi-deps.ps1 policy -ProjectPath ../Inkling
```
Displays current policy rules and banned APIs.

#### Validate depfile.yaml
```powershell
./magi-deps.ps1 validate -ProjectPath ../Inkling
```
Validates depfile parsing and manifest generation without writing files.

### Tests

```powershell
# Regression test suite for common failure cases
./self-test.ps1

# Validate all Unity projects in a workspace (depfile.yaml must be in the Unity project root)
./validate-workspace.ps1 -WorkspaceRoot ..
```

### depfile.yaml Structure

```yaml
# Magi Unity Dependency File
version: 1.0

project:
  name: Inkling
  unityVersion: 2022.3.10f1
  targetPlatforms:
    - iOS
    - Android

registries:
  - name: Unity
    url: https://packages.unity.com
    scopes:
      - com.unity
  - name: Magi Private
    url: https://npm.magi.dev
    scopes:
      - com.magi
    auth:
      token: ${MAGI_NPM_TOKEN}

packages:
  # Unity packages
  - name: com.unity.render-pipelines.universal
    version: 14.0.8
    source: registry

  # Local packages
  - name: com.magi.unitytools
    path: ../MagiUnityTools/Packages/com.magi.unitytools
    source: local

  - name: com.inktools.sim
    path: ../InkTools/Packages/com.inktools.sim
    source: local

  # Git dependencies (requires policy exception)
  - name: com.example.tool
    url: https://github.com/example/tool.git#v1.0.0
    source: git
    policyException: approved-by-lead

# ML-specific packages
ml:
  - name: com.unity.sentis
    version: 1.2.0

# Platform-specific overrides
platformOverrides:
  iOS:
    - name: com.unity.ios.support
      version: 1.0.0
  Android:
    - name: com.unity.android.support
      version: 1.0.0

# Policy configuration
policy:
  allowGitDependencies: false
  allowPrerelease: false
  requireLockFile: true
  bannedAPIs:
    - Resources.Load
    - GameObject.Find
    - SendMessage
  requiredPackages:
    - com.magi.unitytools
  maxPackageCount: 50
```

## Policy System

Note: The current `magi-deps.ps1` policy checks are intentionally minimal (Git/URL dependency blocking and banned API scanning).

### Default Policies

1. **No Git Dependencies**: Packages must come from registries or local paths
2. **No Prerelease Versions**: Only stable versions in production
3. **Lock File Required**: `packages-lock.json` must be committed
4. **API Restrictions**: Certain Unity APIs are banned for performance/architecture reasons
5. **Required Packages**: Ensure critical packages are always included

### Custom Policies

Create a `magi-policy.yaml` in the project root:

```yaml
policy:
  allowGitDependencies: true  # Override default
  customRules:
    - rule: no-legacy-input
      description: "Use new Input System only"
      bannedPackages:
        - com.unity.inputsystem.legacy
    - rule: performance-critical
      description: "Require performance packages"
      requiredPackages:
        - com.unity.burst
        - com.unity.collections
```

## Integration with Unity Projects

### Project Structure

```
YourUnityProject/
├── depfile.yaml              # Dependency declaration
├── magi-policy.yaml          # Optional custom policies
├── Packages/
│   ├── manifest.json         # Generated - do not edit
│   └── packages-lock.json    # Unity's lock file
└── Assets/
```

### CI/CD Integration

```yaml
# Example GitHub Actions workflow
name: Verify Dependencies

on: [push, pull_request]

jobs:
  verify:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v2

      - name: Verify Dependencies
        run: |
          ../MagiUnityDependencyManager/magi-deps.ps1 verify `
            -ProjectPath . `
            -Strict

      - name: Show Policy
        run: |
          ../MagiUnityDependencyManager/magi-deps.ps1 policy `
            -ProjectPath .
```

## Advanced Features

### Batch Processing

Process multiple projects:

```powershell
# Update all projects
Get-ChildItem -Directory | ForEach-Object {
    ./magi-deps.ps1 apply -ProjectPath $_.FullName
}
```

## Best Practices

1. **Consistent Folder Layout**: Keep runtime scripts under `Assets/_Project/Scripts/...` and editor-only utilities under `Assets/_Project/Editor/...`. Avoid project-name folders; prefer feature-based subfolders such as `Scripts/Core` or `Scripts/BoardGame/Rules`.
2. **Package Roots**: Point each `file:` dependency at the folder that contains `package.json` and the primary asmdef (for example `Assets/_Project/Scripts`). Keep the asmdef and manifest in the package root.
3. **Version Control**: Always commit both `depfile.yaml` and `Packages/packages-lock.json`.
4. **Regular Verification**: Run `./magi-deps.ps1 verify -Strict` locally and in CI before merging.
5. **Policy Documentation**: Record exceptions in `depfile.yaml` so reviewers understand intentional deviations.
6. **Production Builds**: Prefer registry packages with fixed versions; restrict `file:` references to active development.

## Troubleshooting

### Common Issues

#### "Policy violation detected"
- Check `magi-deps.ps1 policy` for active rules
- Add `policyException` with justification if needed

#### "Lock file out of sync"
- Run `magi-deps.ps1 apply` to regenerate manifest
- Open Unity to update lock file
- Commit both files together

#### "Package not found"
- Verify registry configuration
- Check network access to registry URLs
- Ensure authentication tokens are set

## Schema Reference

See [depfile.schema.yaml](depfile.schema.yaml) for an example schema and format reference.

## Related Projects

- **[Inkling](../Inkling)**: Example Unity project using this system
- **[InkTools](../InkTools)**: Package managed by this system
- **[MagiUnityTools](../MagiUnityTools)**: Core utilities package

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development guidelines.

## License

See [LICENSE](LICENSE) for details.
