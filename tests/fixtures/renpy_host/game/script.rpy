default aether_probe_step = 0
default aether_probe_route = ""

label main_menu:
    call screen main_menu
    return

label start:
    scene expression Solid("#19274e")
    $ aether_probe_step = 1
    "第一句：Ren'Py 原生引擎已经启动。"
    $ aether_probe_step = 2
    menu:
        "中文选项 A":
            $ aether_probe_route = "A"
        "中文选项 B":
            $ aether_probe_route = "B"
    $ aether_probe_step = 3
    "已选择 [aether_probe_route]，可以验证存档和读取。"
    $ aether_probe_step = 4
    "这是存档后的另一句。"
    jump start
