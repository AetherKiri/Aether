"""Original fixture for game-owned Python modules and renderer hooks."""
import renpy

_installed = False


def install():
    global _installed
    if _installed:
        return False
    _installed = True
    render_screen = renpy.display.render.render_screen
    render_blits = renpy.text.text.Text.render_blits
    fresh = not any(getattr(method, "_aether_probe_hook", False) for method in (render_screen, render_blits))

    def screen(*args, **kwargs):
        return render_screen(*args, **kwargs)

    def blits(*args, **kwargs):
        return render_blits(*args, **kwargs)

    screen._aether_probe_hook = blits._aether_probe_hook = True
    renpy.display.render.render_screen = screen
    renpy.text.text.Text.render_blits = blits
    return fresh
