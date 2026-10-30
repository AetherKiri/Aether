screen main_menu():
    tag menu
    add "probe.svg"
    textbutton "开始验证":
        pos ((0.75, 0.65) if aether_probe_resize else (0.5, 0.5))
        anchor (0.5, 0.5)
        default_focus True
        action Start()

screen say(who, what):
    window:
        id "window"
        yalign 1.0
        ysize 160
        xfill True
        background "#080e22ed"
        text what:
            id "what"
            align (0.5, 0.5)

screen choice(items):
    vbox:
        align (0.5, 0.5)
        spacing 28
        for index, item in enumerate(items):
            textbutton item.caption:
                action item.action
                default_focus (index == 0)

screen _aether_probe_actions():
    key "K_F5" action FileSave("1", confirm=False)
    key "K_F9" action FileLoad("1", confirm=False)
