# Only composite Godot's existing GameVirtualControls on platforms without
# a native overlay surface. There are no engine-specific buttons or actions.
init 999 python:
    import aether_renpy_host
    aether_renpy_host.install()

    class _AetherControlsLayer(renpy.Displayable):
        def render(self, width, height, st, at):
            self.width, self.height = width, height
            image = aether_renpy_host._controls_image
            if image is None:
                return renpy.Render(width, height)
            child = renpy.display.transform.Transform(image, xysize=(width, height))
            return renpy.render(child, width, height, st, at)

        def event(self, ev, x, y, st):
            if aether_renpy_host._controls_image is not None and aether_renpy_host.controls_pointer(
                    ev, x, y, getattr(self, "width", 1), getattr(self, "height", 1)):
                raise renpy.IgnoreEvent()

screen _aether_renpy_overlay():
    zorder 10000
    add _AetherControlsLayer()
