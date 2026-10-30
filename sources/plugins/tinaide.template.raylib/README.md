# raylib Project Template

Version 1.0.1 creates a CMake shared-library project for TinaIDE's Android
NativeActivity host. The project provides a plain `int main(void)`; raylib's
Android backend exports `ANativeActivity_onCreate`. SDL is not used.

## Requirements

- TinaIDE 0.18.36 or newer.
- Install raylib 6.0 package revision 2 from the current Registry. Its immutable
  artifacts are published under `packages/raylib/6.0-r2/`; the archive's
  `package.json` records `version: "6.0"` and `packageRevision: 2`.
- Older raylib/SDL binary packages are unsupported. Updating TinaIDE alone does
  not replace an installed native library: reinstall raylib and rebuild projects.

Revision 2 preserves upstream configuration defaults, restoring buffer swapping,
input polling, and frame timing in `EndDrawing()`. Both arm64-v8a and x86_64 are
available.

## Exit handling

The template drains `GetKeyPressed()` before each frame, exits on Android Back
or Escape, and calls `CloseWindow()`. Queued events also cover a short press whose
DOWN and UP events arrive in one frame. A template update does not rewrite
existing project sources.

## Build and validate

From the Registry root:

```powershell
pwsh ./scripts/build-registry.ps1
pwsh ./scripts/validate-registry.ps1 -SkipBuild -SkipGitDiffCheck
```

The source is mirrored by TinaIDE's `test-plugins/tinaide.template.raylib` fixture;
keep `manifest.json` and `templates/raylib_cmake.zip` synchronized. Published
`.tinaplug` artifacts are immutable; change the plugin version before editing a
published source package.

## License

GPL-3.0-or-later, inherited from TinaIDE; see `LICENSE.txt`. The separately
installed raylib package carries its upstream zlib license.
