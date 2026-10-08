define narrator = Character(None)
define fixture = Character("Fixture")

default player_name = ""

image bg fixture = "scene.svg"

# Device evidence comes from executed Ren'Py statements, never from the host.
# The request is staged only into the debug app's private test project.
init python:
    import json
    import os
    import time

    aether_device_request = {}
    try:
        with open(os.path.join(config.gamedir, "aether-device-request.json"), "r") as request_file:
            aether_device_request = json.load(request_file)
    except (OSError, ValueError):
        pass

    if aether_device_request.get("run_id"):
        # Supported by Ren'Py's common/00start.rpy. The device flow starts at
        # this game's actual start label, independently of SDK menu layout.
        os.environ["RENPY_SKIP_MAIN_MENU"] = "1"

    # Only the private device flow renders these landmarks. Each color changes
    # in the executed game, independently of the host's lifecycle observations.
    aether_device_markers = {
        "start_ready": ("START", "#28b4d2", [40, 180, 210]),
        "post_text_ready": ("WAIT", "#416add", [65, 106, 221]),
        "quit_ready": ("RESUMED", "#eba440", [235, 164, 64]),
    }

    def aether_device_checkpoint(stage, **details):
        if not aether_device_request.get("run_id"):
            return
        if stage in aether_device_markers:
            marker_name, marker_color, marker_rgb = aether_device_markers[stage]
            details.update(logical_canvas=[config.screen_width, config.screen_height],
                           button_bounds=[360, 222, 240, 96],
                           button_rgbs=[[23, 52, 76], [37, 106, 136]],
                           marker_bounds=[360, 350, 240, 40],
                           marker_name=marker_name, marker_rgb=marker_rgb)
        entry = dict(run_id=aether_device_request["run_id"], stage=stage,
                     source="renpy-script", monotonic=time.monotonic(), details=details)
        with open(os.path.join(config.gamedir, "aether-device-checkpoints.jsonl"), "a") as checkpoint_file:
            checkpoint_file.write(json.dumps(entry, ensure_ascii=False) + "\n")
            checkpoint_file.flush()
            os.fsync(checkpoint_file.fileno())

screen fixture_device_button(caption, marker_name, marker_color):
    modal True
    text "AetherKiri real Ren'Py device acceptance" xpos 48 ypos 168 size 28 color "#ffffff"
    textbutton caption:
        xpos 360
        ypos 222
        xsize 240
        ysize 96
        text_size 24
        background Solid("#17344c")
        hover_background Solid("#256a88")
        action Return()
    add Solid(marker_color) xpos 360 ypos 350 xsize 240 ysize 40
    text marker_name xpos 480 ypos 370 anchor (0.5, 0.5) size 24 color "#ffffff"

screen fixture_start():
    modal True
    frame:
        xalign 0.5
        yalign 0.78
        padding (24, 18)
        vbox:
            spacing 12
            text "Tap Start to continue" size 28 xalign 0.5
            textbutton "Start" action Return() xalign 0.5

screen fixture_menu():
    frame:
        xalign 0.5
        yalign 0.82
        padding (20, 14)
        hbox:
            spacing 18
            textbutton "Pause / resume" action Return("pause")
            textbutton "Enter text" action Return("input")
            textbutton "Quit" action Return("quit")

label start:
    if aether_device_request.get("run_id"):
        jump aether_device_acceptance
    scene bg fixture with fade
    narrator "AetherKiri Ren'Py runtime fixture started."
    narrator "This screen is rendered by the real Ren'Py project."
    call screen fixture_start

    $ player_name = renpy.input("Enter your name:", default="Player")
    $ player_name = player_name.strip()
    if not player_name:
        $ player_name = "Player"
    fixture "Hello, [player_name]. Text input reached the game."

label interaction:
    call screen fixture_menu
    if _return == "pause":
        narrator "The game is entering a short blocking pause."
        $ renpy.pause(0.25)
        narrator "The pause returned; the host can resume the runtime now."
        jump interaction
    elif _return == "input":
        $ player_name = renpy.input("Update your name:", default=player_name)
        $ player_name = player_name.strip() or "Player"
        fixture "The current name is [player_name]."
        jump interaction
    else:
        $ renpy.quit()
        return

label aether_device_acceptance:
    scene bg fixture
    $ aether_device_checkpoint("start_ready", button=[480, 270])
    call screen fixture_device_button("Start", aether_device_markers["start_ready"][0], aether_device_markers["start_ready"][1])
    $ aether_device_checkpoint("touch_received")
    $ aether_device_checkpoint("text_ready")
    $ player_name = renpy.input("Enter the cloud acceptance name:", default="", length=32)
    $ aether_device_checkpoint("text_received", text=player_name)
    # The host must background and resume the real application while this
    # interaction is waiting, then deliver another real system touch.
    $ aether_device_checkpoint("post_text_ready", button=[480, 270])
    call screen fixture_device_button("Continue after resume", aether_device_markers["post_text_ready"][0], aether_device_markers["post_text_ready"][1])
    $ aether_device_checkpoint("resumed_touch_received")
    $ aether_device_checkpoint("quit_ready", button=[480, 270])
    call screen fixture_device_button("Quit", aether_device_markers["quit_ready"][0], aether_device_markers["quit_ready"][1])
    $ aether_device_checkpoint("quit_requested")
    $ renpy.quit(confirm=False)
    return
