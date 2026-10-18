define config.name = _("Aether Ren'Py 验证")
define config.screen_width = 960
define config.screen_height = 540
define config.save_directory = "aether_renpy_probe"
define config.developer = False
define config.default_fullscreen = False

style default:
    font "probe.ttf"
    size 28
    color "#ffffff"

init python:
    config.overlay_screens.append("_aether_probe_actions")
