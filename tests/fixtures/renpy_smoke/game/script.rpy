# Minimal source fixture written for the official Ren'Py SDK.
# It intentionally uses only built-in displayables and script statements.

define smoke = Character("Smoke")

default smoke_choice = ""

label start:
    scene black
    with None

    "AetherKiri Ren'Py SDK smoke fixture."
    call screen aetherkiri_e2e_choice

    $ open(renpy.config.gamedir + "/aetherkiri-choice", "w").write(smoke_choice + "\n")
    if smoke_choice == "continue":
        smoke "Choice input is working."
    else:
        smoke "The default path is working."

    "Ren'Py smoke test complete."
    return

screen aetherkiri_e2e_choice():
    modal True
    button:
        xysize (640, 360)
        action [SetVariable("smoke_choice", "continue"), Return()]
        text "Continue the smoke test"
