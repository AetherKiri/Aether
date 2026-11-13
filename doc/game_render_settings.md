# Per-game rendering settings

The optional Astryx game detail page exposes **Graphics & rendering**. Scaling,
output resolution and enhancement use the same catalog as app Settings, with
an additional **Use app settings** choice. Each detail row has its own editor:
Edit disappears while the editor is open, with Save and Cancel below the inputs.
Choices stay in a temporary draft until Save writes `aether_config.json` in that
game's directory. Cancel performs no file writes. Enhancement kind, preset and
custom steps are saved or cancelled together. Failed saves keep the editor and
draft open with an error message. Rotation preserves the draft; leaving the
detail page, switching games or closing its section discards it. These edits
are independent of the global settings draft and its Save/Cancel actions.

```json
{
  "rendering": {
    "upscale_algorithm": "nearest",
    "output_resolution": "",
    "frame_enhancement_kind": "preset",
    "frame_enhancement_mode": "chain_soft",
    "frame_enhancement_custom_chain": [
      "anime4k_upscale_s", "bicubic", "anime4k_restore_soft_s"
    ]
  }
}
```

The three primary fields independently use an empty string (`""`) to inherit
the current app setting. In this example, the game uses Nearest and Soft Clarity
while its output resolution follows the app. `frame_enhancement_kind: "off"`
explicitly disables enhancement even when the app enables it; `""` inherits
the app's enhancement kind and its preset/custom chain together.

| Field | Supported values, in addition to inheritance where applicable |
| --- | --- |
| `upscale_algorithm` | `smooth`, `linear`, `nearest`, `bicubic`, `lanczos`, `metalfx_spatial` |
| `output_resolution` | `original`, `1080p`, `2k`, `4k` |
| `frame_enhancement_kind` | `off`, `preset`, `custom` |
| `frame_enhancement_mode` | `chain_4k_max`, `chain_lossless`, `chain_ultra`, `chain_detail`, `chain_balanced`, `chain_soft`, `chain_light`, `chain_basic` |
| `frame_enhancement_custom_chain` | Ordered array of up to 32 algorithm IDs |

Preset and chain fields belong to the game's explicit enhancement choice.
They are ignored when enhancement follows the app, and retained when switching
modes. Choosing Preset or Custom saves the displayed defaults if needed.
An absent/invalid preset defaults to `chain_soft`. An absent/invalid custom chain
defaults to the three algorithms in the example. An empty array is valid and
means no processing steps.

Custom algorithm IDs are `anime4k_upscale_s`, `anime4k_upscale_l`,
`anime4k_upscale_vl`, `anime4k_restore_s`, `anime4k_restore_soft_s`,
`anime4k_restore_soft_m`, `anime4k_restore_l`, `anime4k_restore_vl`, `fsr1_easu`,
`fsr1_rcas`, `bicubic`, `lanczos`, `fxaa`, `ravu_lite_r2`, `cunny_2x4c` and
`nnedi3_nns16`. Runtime/platform support is the same as for global rendering
settings; MetalFX retains its existing Bicubic fallback. These options configure
the Godot frame pipeline and do not add enhancement to separate web/native views.

At each game launch, the shell reads this file before opening the runtime and
configuring its output surface. It applies valid overrides to sampling, output
size and enhancement without changing global preferences. Teardown or launch
failure clears the override. Games without a file inherit everything, including
later global changes; simply opening their details or launching them creates no
file. A configured launch entry nested inside a library game uses the library's
root directory. A standalone archive/file uses its containing directory.

Missing, empty, wrongly typed or unsupported primary fields inherit individually.
Malformed JSON, a non-object root/rendering section, or unreadable files are
logged and fall back to app settings. Editing does not overwrite a malformed or
unreadable file; save errors are shown in the UI. Successful saves preserve
unrelated JSON keys and replace the file through a sibling temporary file.
Existing name, cover and launch-entry storage is unchanged. The same document
also supports [per-game text encoding and fonts](game_text_settings.md).

`game_render_config_test.gd` covers disk round trips, validation, preservation,
the real shell launch sequence with a recording runtime, output/sampling,
inheritance, engine failures and switching games. `astryx_shell_test.gd` exercises
the actual per-game controls and JSON writes in isolated temporary directories,
including phone and tablet custom-chain layouts.
