extends SceneTree

const YurisEngineOptions = preload("res://scripts/yuris_engine_options.gd")

func _init() -> void:
    # Normal GUI launches must retain the complete effect pass tested by the
    # native frame-cadence fixture; a host override must not silently slice it.
    assert(YurisEngineOptions.worker_step_budget() == 65536)
    assert(YurisEngineOptions.worker_step_budget("invalid") == 65536)
    assert(YurisEngineOptions.worker_step_budget("  ") == 65536)
    assert(YurisEngineOptions.worker_step_budget(" 2048 ") == 2048)
    assert(YurisEngineOptions.worker_step_budget("0") == 256)
    assert(YurisEngineOptions.worker_step_budget("1000000") == 65536)
    # Translation patches can change YBN text encoding without changing the
    # executable format. Keep that choice per game and apply it before open.
    assert(YurisEngineOptions.script_encoding({}) == "CP932")
    var translated := {YurisEngineOptions.SCRIPT_ENCODING_FIELD: "GBK"}
    assert(YurisEngineOptions.script_encoding(translated) == "GBK")
    assert(YurisEngineOptions.script_encoding(translated, " utf8 ") == "UTF-8")
    assert(YurisEngineOptions.script_encoding(translated, "invalid") == "GBK")
    assert(YurisEngineOptions.script_encoding({}) == "CP932")
    assert(YurisEngineOptions.script_encoding({YurisEngineOptions.SCRIPT_ENCODING_FIELD: "invalid"}) == "CP932")
    assert(YurisEngineOptions.normalize_encoding("shift_jis") == "CP932")
    assert(YurisEngineOptions.normalize_encoding("cp936") == "GBK")
    var first := YurisEngineOptions.legacy_user_directory("/host", "/games/first")
    assert(first.begins_with("/host/yuris/"))
    assert(first == YurisEngineOptions.legacy_user_directory("/host", "/games/first/"))
    assert(first == YurisEngineOptions.legacy_user_directory("/host", "/games/other/../first"))
    assert(first != YurisEngineOptions.legacy_user_directory("/host", "/games/second"))
    assert(YurisEngineOptions.user_directory("/host", "") == "/host")
    print("YU-RIS GUI effect-pass budget defaults and diagnostic overrides passed")
    quit(0)
