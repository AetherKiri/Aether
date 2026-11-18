extends Node

var queue: Array[Dictionary] = []
var worker: Thread
var current: Dictionary

func submit(work: Callable, done: Callable) -> void:
    queue.append({"work": work, "done": done})
    set_process(true)

func _ready() -> void:
    set_process(false)

func _process(_delta: float) -> void:
    if worker != null:
        if worker.is_alive():
            return
        var result = worker.wait_to_finish()
        worker = null
        if current.done.is_valid():
            current.done.call(result)
        current = {}
    if queue.is_empty():
        set_process(false)
        return
    current = queue.pop_front()
    worker = Thread.new()
    if worker.start(current.work) != OK:
        worker = null
        if current.done.is_valid():
            current.done.call({"error": ERR_CANT_CREATE, "bytes": 0})
        current = {}

func _exit_tree() -> void:
    if worker != null and worker.is_started():
        worker.wait_to_finish()
