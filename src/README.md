# Lua source reference

The three Schedule Caller editions use a common engine and retain their own entry point and renderer. Each Lua file is from the corresponding 1.0.0 widget.

| Package path | Source location |
| --- | --- |
| `main.lua` | The corresponding edition directory |
| `lib/render.lua` | The corresponding edition directory |
| `lib/images.lua` | IMAC has its own copy. F3A and Sportflyer use the shared copy. |
| `lib/audio.lua` | [Sportflyer audio](Sportflyer/audio.lua) for Sportflyer, [shared audio](shared/audio.lua) for IMAC and F3A. |
| Other `lib/*.lua` | [Shared modules](shared/) |

Use the [installation packages](https://github.com/bliatun-code/Schedule-Caller/releases) for the complete radio distribution. See [credits and rights](../RIGHTS.md) for the terms covering this source reference and the bundled material.
