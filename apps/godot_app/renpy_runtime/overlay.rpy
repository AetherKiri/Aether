# Aether-owned overlay, staged into a private writable copy of the game.
init 999 python:
    import aether_renpy_host
    aether_renpy_host.install()

style _aether_host_button is default:
    background "#202028bb"
    hover_background "#465481ee"
    padding (14, 8)

style _aether_host_button_text is default:
    font "_aether_ui_font.otf"
    size 24
    color "#ffffff"

screen _aether_renpy_overlay():
    zorder 10000
    style_prefix "_aether_host"

    textbutton aether_renpy_host.text("menu"):
        align (0.99, 0.01)
        background "#202028aa"
        padding (14, 8)
        action Function(aether_renpy_host.toggle_menu)

    if aether_renpy_host.menu_visible:
        frame:
            align (0.99, 0.1)
            background "#202028ee"
            padding (18, 14)
            vbox:
                spacing 12
                textbutton aether_renpy_host.text("keys"):
                    action Function(aether_renpy_host.toggle_controls)
                textbutton aether_renpy_host.text("back"):
                    action Function(aether_renpy_host.quit_game)

    if aether_renpy_host.controls_visible:
        frame:
            align (0.02, 0.95)
            background "#202028aa"
            padding (12, 12)
            vbox:
                spacing 10
                for caption, key_name in [("Esc", "esc"), ("Up", "up"), ("Down", "down"), ("Left", "left"), ("Right", "right")]:
                    textbutton caption:
                        action Function(aether_renpy_host.tap_key, key_name)
        frame:
            align (0.98, 0.95)
            background "#202028aa"
            padding (12, 12)
            vbox:
                spacing 10
                for caption, key_name in [("PgUp", "pgup"), ("PgDn", "pgdn"), ("Space", "space"), ("Enter", "enter")]:
                    textbutton caption:
                        action Function(aether_renpy_host.tap_key, key_name)
