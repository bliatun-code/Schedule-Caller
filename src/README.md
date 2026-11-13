# Lua source reference

The three Schedule Caller editions use a common engine and retain their own entry point and renderer. Each Lua file is from the corresponding 1.0.4 widget.

| Package path | Source location |
| --- | --- |
| `main.lua` | The corresponding edition directory. A small loader that only registers the widget. |
| `lib/widget.lua` | `widget.lua` in the corresponding edition directory |
| `lib/render.lua` | The corresponding edition directory |
| `lib/images.lua` | IMAC has its own copy. F3A and Sportflyer use the shared copy. |
| `lib/audio.lua` | [Shared audio engine](shared/audio.lua) |
| Other `lib/*.lua` | [Shared modules](shared/) |

Ethos loads `main.lua` for every installed script at power-on. The loader loads `lib/widget.lua` when a model uses the widget and releases it again when the last widget closes, for example after a model change. Ethos keeps the functions a widget gives to its menu and settings form after the widget closes, so those functions are defined in the loader and reach `lib/widget.lua` only while it is loaded. IMAC and F3A load the audio catalogue for the selected schedule when it is needed. Sportflyer uses a single catalogue for its two schedules.

Use the [installation packages](https://github.com/bliatun-code/Schedule-Caller/releases) for the complete radio distribution. See [credits and rights](../RIGHTS.md) for the terms covering this source reference and the bundled material.
