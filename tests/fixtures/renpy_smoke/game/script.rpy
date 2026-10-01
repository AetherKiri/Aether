# Minimal source fixture written for the official Ren'Py SDK.
# It intentionally uses only built-in displayables and script statements.

define smoke = Character("Smoke")

default smoke_choice = ""

label start:
    scene black
    with None

    "AetherKiri Ren'Py SDK smoke fixture."
    smoke "The official SDK can parse and execute this project."

    menu:
        "Continue the smoke test":
            $ smoke_choice = "continue"
            $ open(renpy.config.gamedir + "/aetherkiri-choice", "w").write("continue\n")
            $ renpy.quit()
        "Finish the smoke test":
            $ smoke_choice = "finish"
            $ open(renpy.config.gamedir + "/aetherkiri-choice", "w").write("finish\n")
            $ renpy.quit()

    if smoke_choice == "continue":
        smoke "Choice input is working."
    else:
        smoke "The default path is working."

    "Ren'Py smoke test complete."
    return
