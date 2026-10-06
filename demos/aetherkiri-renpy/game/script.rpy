define narrator = Character(None)
define fixture = Character("Fixture")

default player_name = ""

image bg fixture = "scene.svg"

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
