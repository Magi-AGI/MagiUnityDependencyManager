MagiUnityDependencyManager
==========================

Goal: Authoritative dependency manager for Unity (UPM) projects in the Magi-AGI org.

Key features
- Single `depfile.yaml` in the Unity game repo drives `Packages/manifest.json` and verifies `packages-lock.json`.
- Enforces policy (e.g., ban `Resources.Load`, disallow Git deps unless explicitly allowed).
- Supports private scoped registries and version pins.

Commands (planned)
- `ink-deps apply`   -> materialize `Packages/manifest.json` from `depfile.yaml`.
- `ink-deps verify`  -> check lockfile drift and policy violations.
- `ink-deps policy`  -> print active policy and banned APIs.
- `ink-deps init`    -> scaffold a starter `depfile.yaml` in a Unity project.

See `depfile.schema.yaml` for the expected format.

