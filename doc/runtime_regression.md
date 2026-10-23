# Runtime regressions on macOS and iPad

`tools/run_runtime_regression.py` runs a JSON case in a visible Godot app, drives
the existing player input API, checks runtime state after each action, and
collects a structured result plus console logs. It captures no images.

The installed app or Godot project must include
`res://scripts/runtime_regression_probe.gd`. Normal launches do not run it.
The host tool enables the probe explicitly using the existing CLI probe
environment variables and gives every run a new writable directory beneath
`user://regressions/`. Engine saves and settings go into that directory.
`--seed` optionally copies an existing writable-state tree into the isolated
directory; it never passes the original save directory to the engine.

## Run a case

macOS, with a built native extension in the project:

```sh
python3 tools/run_runtime_regression.py /path/to/case.json \
  --platform macos --project apps/godot_app \
  --user-data-dir '/path/to/the/project/user-data-directory' \
  --game '/path/to/game' --seed /path/to/writable-state-copy \
  --output /path/to/regression-artifacts
```

iPad, with the development app already installed and trusted, the game already
in its Documents directory, and the device unlocked:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
python3 tools/run_runtime_regression.py /path/to/case.json \
  --platform ios --device DEVICE_ID --bundle DEVELOPMENT_BUNDLE_ID \
  --pointer-input touch \
  --game 'Documents/Games/Game' --seed /path/to/writable-state-copy \
  --output /path/to/regression-artifacts --timeout 240
```

`--game` overrides the case's `game_path`. The iOS path uses the same relative
Documents convention as the existing game launch probes. The host tool launches
the app, polls its persisted report, and requires a `cleanup_complete` event
written after the engine is destroyed. A preceding `passed` event alone is
insufficient. It then checks the launched process's identity and stops that
process, without waiting for the iOS app to exit itself. Assertions, crashes,
launch failures, incomplete teardown, and timeouts return nonzero. A locked
device must be unlocked before a run can start.

For a currently locked iPad, `--prepare-only` queues the case using the existing
one-shot probe request file. The next normal launch consumes the request,
executes the case, and saves its result and cleanup event. Stop and relaunch the
app afterwards to return to normal use.
The host summary records the device's `result_source`. Retrieve it afterwards
with `devicectl device copy from` using the same app data-container domain.
A prepared case is not a passed test. This option runs one case on one launch;
it does not enable recurring background execution.

Each artifact directory contains the effective case, `regression-result.json`,
and `summary.json`. macOS saves console output; iOS saves the device probe log
and SDK command results, including the engine cleanup status and process ID.
Keep these artifacts and game-specific cases outside the public repo;
private runtime packages own cases requiring private callback identifiers.
Run directories are retained for investigation and can be removed afterwards.

## Case format

```json
{
  "name": "return-to-saved-line",
  "surface_size": [1280, 720],
  "startup_timeout_frames": 1800,
  "steps": [
    {
      "type": "wait",
      "label": "dialogue-ready",
      "until": [{"field": "dialogue_active", "equals": 1}]
    },
    {"type": "snapshot", "label": "saved-line"},
    {"type": "key", "key_code": 13, "after_frames": 90},
    {
      "type": "assert",
      "conditions": [{"field": "dialogue_key", "changed_from": "saved-line.dialogue_key"}]
    }
  ]
}
```

Actions are `move`, `click`, `tap`, `two_finger_tap`, `key`, `wait`, `snapshot`, `assert`, and `reopen`. Pointer
coordinates use the source frame's pixels. A click can select a visible, enabled
button with a partial `button` dictionary instead of coordinates, or use
`point_from` to find a saved rectangle (`x`, `y`, `w`, `h`).

`tap` converts the target from source-frame pixels to viewport coordinates and
passes a press and release through the app's normal ScreenTouch handler. This
exercises coordinate mapping, gesture classification, suppression, and the
mobile delayed-release path. The step fails if the coordinates do not round
trip, input is suppressed or rejected, or the release does not finish.
`--pointer-input touch` (or `"pointer_input": "touch"` in the case) makes every
`click` use this path. Use it for iOS button regressions; ordinary `click`
defaults to direct player pointer input. Touch supports only the primary
button; `hold_frames` defaults to 1 and larger values also exercise stationary
holds.

`two_finger_tap` sends two simultaneous contacts through the same handler and
requires a forwarded secondary gesture. It exercises two-finger return without
bypassing gesture recognition by sending a native right-click directly.

Conditions use dot paths through dictionaries and arrays. Supported comparisons
are `equals`, `not_equals`, `same_as` and `changed_from` (against a named
snapshot), `contains` (a partial dictionary inside an array), and `not_contains`
(no matching array item). Missing fields
or snapshot references fail the condition. `until_any` accepts alternative
condition arrays, useful when a saved setting controls a confirmation dialog;
`when` makes an action conditional. Finish such a flow with a destination
assertion so either branch must reach the intended state.

State snapshots include a generic `host` dictionary with `library_visible`,
`route`, `library_mode`, `game_running`, and `frame_texture_cleared`. An exit
case should wait for `host.library_visible == true`, `host.library_mode ==
"game"`, and the cleared frame texture. A stopped interpreter alone does not
prove that the application returned to the library. Once the library is
visible, the probe observes UI frames without querying or ticking the destroyed
engine handle.

`reopen` requires the library to be visible, recreates the player handle, and
opens the same game using the probe configuration and isolated writable root.
Follow it with runtime-specific startup assertions and another exit to test
repeated sessions in one app process.

Waits have a wall-clock `timeout_ms` (default 15000) and require `stable_frames`
consecutive matches (default 3). Other actions support `after_frames`; click and
key actions also support `hold_frames`. The host has a separate overall
`--timeout` watchdog for stalls that prevent the probe from running.

These checks cover engine input, touch handling after Godot dispatch, runtime
navigation, save restoration, and render-state metadata. They do not compare
visual pixels, exercise physical touch hardware, or test OS event dispatch.
Use precise target identities and cleared navigation flags as
the success criteria; absence of an error message alone is insufficient.
