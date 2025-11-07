# Compute Shader Cross-Package Include Resolution

## Problem

Unity's Package Manager doesn't support cross-package file includes for compute shaders. When a compute shader in one package tries to `#include` a file from another package, Unity cannot resolve the path, resulting in compilation errors like:

```
Fluids.compute: Kernel at index (X) is invalid
```

This happens because:
1. C# code can reference other packages via assembly definitions
2. Compute shaders (HLSL/Cg) can only use relative file paths
3. Package isolation breaks relative paths that cross package boundaries

## Solution

The `magi-deps.ps1` script now automatically detects and resolves cross-package includes when you run `apply`:

### How It Works

1. **Scan Phase**: Scans all `.compute` and `.hlsl` files in local packages for includes like `#include "../../OtherPackage/file.hlsl"`

2. **Detection**: Identifies includes that reference files outside the current package boundary

3. **Resolution**:
   - Copies the referenced file into the consuming package's `Includes/` directory
   - Updates the `#include` statement to use the local copy: `#include "Includes/file.hlsl"`

4. **Propagation**: Recursively resolves nested includes (e.g., if an included `.hlsl` file itself includes files from other packages)

### Example

**Before (in com.inktools.sim package):**
```hlsl
// Fluids.compute
#include "../../Core/Scripts/iparticle.cs"  // ❌ Cross-package include
```

**After running `magi-deps.ps1 apply`:**
```hlsl
// Fluids.compute
#include "Includes/iparticle.cs"  // ✅ Local include
```

**File structure:**
```
com.inktools.sim/
├── Compute/
│   ├── Fluids.compute (updated)
│   └── Includes/
│       └── iparticle.cs (copied from com.inktools.core)
```

## Usage

Simply run the dependency manager as normal:

```powershell
./magi-deps.ps1 apply -ProjectPath ../Inkling/Inkling
```

Output will show which files were copied:
```
Resolving compute shader dependencies...
  Processing Fluids.compute in com.inktools.sim...
    Copied: iparticle.cs from com.inktools.core to com.inktools.sim/Includes/
  Processing SimulationTypes.hlsl in com.inktools.sim...
    Copied: InkToolsTypes.hlsl from com.inktools.core to com.inktools.sim/Includes/
Compute shader dependency resolution complete.
```

## File Types Supported

- `.compute` - Compute shaders
- `.hlsl` - HLSL include files
- `.cginc` - Cg include files (if present)
- `.cs` - X-Macro pattern files (C# files compiled as HLSL in shader context)

## Automatic Features

### Source Package Detection
Automatically determines which package the included file belongs to by checking all packages in `depfile.yaml`.

### Path Normalization
Handles various relative path formats:
- `../../PackageName/file.hlsl`
- `../../../Core/Compute/file.hlsl`
- `../../Scripts/file.cs`

### Recursive Resolution
If an included file itself includes cross-package files, those are also resolved automatically.

### Idempotent Operation
Running `apply` multiple times is safe - it will update files if dependencies change but won't create duplicates.

## Best Practices

### 1. Don't Manually Edit Generated Includes
The `Includes/` directories are managed automatically. Files will be overwritten on next `apply`.

### 2. Use Package Dependencies
Ensure cross-package shader includes are backed by proper package dependencies in `package.json`:

```json
{
  "dependencies": {
    "com.inktools.core": "0.1.0"
  }
}
```

### 3. Run After Package Updates
Whenever you update a dependency package, run `magi-deps.ps1 apply` to refresh shader includes.

### 4. Commit the Includes Directory
While the files are generated, you should commit them to version control for:
- Offline building
- CI/CD pipelines
- Teammate sync

## Troubleshooting

### Warning: Include file not found
```
WARNING: Include file not found: ../../OtherPackage/missing.hlsl
```
**Solution**: Ensure the referenced file exists in the source package.

### Warning: Could not determine source package
```
WARNING: Could not determine source package for: ../../Unknown/file.hlsl
```
**Solution**: Add the package containing the file to `depfile.yaml`.

### Shader still shows "Kernel at index (X) is invalid"
**Solutions**:
1. Run `magi-deps.ps1 apply` again
2. Restart Unity to force shader recompilation
3. Check Unity Console for actual shader compilation errors
4. Verify all nested includes were resolved

## Implementation Details

The resolution function is in `magi-deps.ps1`:

```powershell
function Resolve-ComputeShaderIncludes($projectPath, $dep) {
    # Scans packages for .compute and .hlsl files
    # Finds cross-package #include statements
    # Copies files and updates paths
}
```

Integrated into the `apply` command:
```powershell
'apply' {
    # ... existing code ...
    Resolve-ComputeShaderIncludes -projectPath $ProjectPath -dep $dep
    # ... rest of apply ...
}
```

## Related Documentation

- [Main README](README.md) - Overall dependency manager documentation
- [depfile.yaml Schema](depfile.schema.yaml) - Package configuration format
- [Unity Package Manager](https://docs.unity3d.com/Manual/upm-ui.html) - Unity's official docs
