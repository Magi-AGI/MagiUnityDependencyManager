# Bug Fix: File Path Resolution for Manifest Dependencies

**Date**: 2025-11-30
**Status**: ✅ Fixed
**Affected**: All Unity projects using local `file:` dependencies

## Problem

The `Resolve-LocalPackagePath` function incorrectly resolved paths relative to the **project root** instead of the **Packages/ directory**, causing workspace validation failures for nested repository structures.

### Symptoms
- Error: `"Local package path 'file:...' resolves outside the workspace root"`
- Paths with correct relative references (e.g., `../../MagiUnityTools`) failed validation
- Projects with `RepoName/UnityProject/` structure couldn't use dependency manager

### Root Cause

In Unity's `manifest.json`, file paths are **always relative to the `Packages/` directory**, not the project root.

The original code (line 159-166):
```powershell
function Resolve-LocalPackagePath($projectPath, $spec) {
    ...
    $rel = $spec.Substring(5)  # Remove "file:" prefix
    $base = (Resolve-Path -Path $projectPath).Path  # ❌ WRONG: Using project root
    $full = [System.IO.Path]::GetFullPath((Join-Path $base $rel))
    ...
}
```

This caused:
- `file:../../../MagiUnityTools` + `/Magi-AGI/LedgeBoardGame/LedgeBoardGame`
- = `/magi/MagiUnityTools` (stub directory, outside workspace)
- ❌ Instead of `/Magi-AGI/MagiUnityTools` (correct location)

## Solution

**Fixed Code** (line 159-168):
```powershell
function Resolve-LocalPackagePath($projectPath, $spec) {
    ...
    $rel = $spec.Substring(5)
    # Manifest paths are relative to Packages/ directory, not project root
    $base = (Resolve-Path -Path $projectPath).Path
    $packagesDir = Join-Path $base 'Packages'  # ✅ CORRECT: Use Packages/ as base
    $full = [System.IO.Path]::GetFullPath((Join-Path $packagesDir $rel))
    ...
}
```

Now:
- `file:../../../MagiUnityTools` + `/Magi-AGI/LedgeBoardGame/LedgeBoardGame/Packages`
- = `/Magi-AGI/MagiUnityTools` ✅ Correct!

## Impact

### Before Fix
- ❌ Nested structures (`Magi-AGI/LedgeBoardGame/LedgeBoardGame/`) failed
- ❌ Workspace validation rejected valid paths
- ⚠️ Manual manifest.json editing required

### After Fix
- ✅ Nested structures work correctly
- ✅ Flat structures (`Magi-AGI/cardcore/`) still work
- ✅ All projects can use `magi-deps.ps1 apply`

## Testing

Verified on:
- ✅ **LedgeBoardGame** (nested: `LedgeBoardGame/LedgeBoardGame/`)
- ✅ **Inkling** (nested: `Inkling/Inkling/`)
- ✅ **cardcore** (flat: `cardcore/`)

All projects now correctly resolve local file dependencies.

## Related Files

- `magi-deps.ps1` (line 159-168) - Fixed function
- `LedgeBoardGame/depfile.yaml` - Now works with auto-apply
- `BUILD_FIXES.md` (LedgeBoardGame) - Build error resolutions

## Backwards Compatibility

✅ **Fully backwards compatible** - This fix corrects the behavior to match Unity's actual path resolution semantics. Projects that worked before will continue to work.

## See Also

- Unity Documentation: [Package Manifest](https://docs.unity3d.com/Manual/upm-manifestPkg.html)
- Unity's manifest.json paths are **always** relative to `Packages/` directory

---

**Fix committed**: This fix benefits all current and future Magi Unity projects.
