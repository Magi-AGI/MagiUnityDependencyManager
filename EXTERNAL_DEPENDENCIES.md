# External Dependencies Management

This document describes how MagiUnityDependencyManager handles external (non-Magi) Unity packages.

## Overview

External dependencies are third-party Unity packages that Magi projects depend on. These are managed as forks under the Magi-AGI organization to ensure stability and control.

## Structure

```
Magi-AGI/
├── MagiUnityDependencyManager/    # This repo (manages dependencies)
│   ├── external-deps-setup.ps1    # Setup/verify script
│   └── EXTERNAL_DEPENDENCIES.md   # This documentation
├── ExternalDependencies/           # Local clones (not in git)
│   ├── UniRx/                     # Fork of UniRx
│   └── UniTask/                   # Fork of UniTask
└── [Project]/                      # Your Unity project
    └── depfile.yaml                # References external deps
```

## Current External Dependencies

### UniRx (Reactive Extensions for Unity)
- **Original**: https://github.com/neuecc/UniRx
- **Fork**: https://github.com/Magi-AGI/UniRx
- **Package ID**: `com.neuecc.unirx`
- **Purpose**: Reactive programming, event streams, observables
- **Version**: 7.1.0

### UniTask (Async/Await for Unity)
- **Original**: https://github.com/Cysharp/UniTask
- **Fork**: https://github.com/Magi-AGI/UniTask
- **Package ID**: `com.cysharp.unitask`
- **Purpose**: Zero-allocation async/await, coroutine replacement
- **Version**: 2.5.0

## Setup Instructions

### Initial Setup

1. **Clone the external dependencies**:
   ```powershell
   cd MagiUnityDependencyManager
   ./external-deps-setup.ps1
   ```

2. **Verify fork configuration**:
   ```powershell
   ./external-deps-setup.ps1 -VerifyOnly
   ```

3. **Apply to your project**:
   ```powershell
   ./magi-deps.ps1 apply -ProjectPath ../YourProject
   ```

### Project Configuration

In your project's `depfile.yaml`:

```yaml
packages:
  # External dependencies (Magi-AGI forks)
  - name: com.neuecc.unirx
    path: ../ExternalDependencies/UniRx/Assets/Plugins/UniRx/Scripts
    source: local

  - name: com.cysharp.unitask
    path: ../ExternalDependencies/UniTask/src/UniTask/Assets/Plugins/UniTask
    source: local
```

## Fork Management

### Why Forks?

1. **Stability**: Protect against breaking changes from upstream
2. **Control**: Review updates before merging
3. **Customization**: Apply Magi-specific patches if needed
4. **Offline Development**: No dependency on external repositories
5. **Security**: Audit code before using

### Syncing with Upstream

To update a fork with the latest upstream changes:

```powershell
cd ../ExternalDependencies/UniRx
git fetch upstream
git log HEAD..upstream/master --oneline  # Review changes
git merge upstream/master                 # Merge if acceptable
git push origin master                     # Push to Magi fork
```

### Creating Custom Branches

For Magi-specific modifications:

```powershell
cd ../ExternalDependencies/UniRx
git checkout -b magi-customizations
# Make your changes
git commit -m "Add Magi-specific feature"
git push origin magi-customizations
```

Then update depfile.yaml to use the custom branch:

```yaml
- name: com.neuecc.unirx
  url: https://github.com/Magi-AGI/UniRx.git#magi-customizations
  source: git
  policyException: approved-customization
```

## Adding New External Dependencies

### 1. Fork the Repository

1. Fork to https://github.com/Magi-AGI/
2. Clone locally to ExternalDependencies/

### 2. Update Setup Script

Edit `external-deps-setup.ps1` to add:

```powershell
@{
    Name = "NewPackage"
    Fork = "https://github.com/Magi-AGI/NewPackage.git"
    Upstream = "https://github.com/Original/NewPackage.git"
    Path = "$DepsDir\NewPackage"
    Branch = "master"
    PackagePath = "relative/path/to/package"
    NeedsPackageJson = $true
}
```

### 3. Create package.json if needed

Some packages don't include Unity package.json. Create one if needed:

```json
{
  "name": "com.vendor.package",
  "displayName": "Package Name",
  "version": "1.0.0",
  "unity": "2019.4",
  "description": "Package description (Magi-AGI Fork)",
  "dependencies": {}
}
```

### 4. Update Documentation

Add the new dependency to this file and project depfile.yaml.

## Troubleshooting

### "Package not found" in Unity
- Run `external-deps-setup.ps1` to ensure cloned
- Verify path in depfile.yaml matches actual location
- Check package.json exists in the package folder

### "Remote origin is not Magi fork"
- Run `external-deps-setup.ps1` without `-VerifyOnly` to fix
- Or manually: `git remote set-url origin https://github.com/Magi-AGI/Package.git`

### "Cannot sync with upstream"
- Ensure upstream remote exists: `git remote -v`
- Add if missing: `git remote add upstream https://github.com/Original/Repo.git`

## Security Considerations

- **Audit before updating**: Review upstream changes before merging
- **Use specific commits**: Reference specific commits/tags in production
- **Verify signatures**: Check GPG signatures on releases when available
- **Monitor CVEs**: Track security advisories for dependencies

## ExternalDependencies Folder

The `ExternalDependencies` folder should **not** be committed to git. Add to `.gitignore`:

```gitignore
# External dependency clones
/ExternalDependencies/
```

This folder contains only cloned repositories and should be reproducible using the setup script.