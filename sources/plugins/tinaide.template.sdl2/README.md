# SDL2 Project Template Plugin

This plugin adds an `SDL2 + CMake` template to TinaIDE's New Project flow.

The generated project builds a shared library named `libmain.so`, which is the
entry library expected by TinaIDE's SDL2 graphical runtime. Install the
Registry package `sdl2` before building the generated project.

The template uses the classic SDL2 `SDL_main` entry point and is intentionally
separate from the SDL3 callback-based template.

## Package

PowerShell:

```powershell
Compress-Archive -Path .\* -DestinationPath ..\tinaide.template.sdl2.tinaplug
```

## Install

TinaIDE -> Settings -> Plugins -> Install from file

Select `tinaide.template.sdl2.tinaplug`.
