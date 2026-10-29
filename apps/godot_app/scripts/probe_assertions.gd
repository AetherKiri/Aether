extends RefCounted

# Shared by editor and exported-app probes. Invalid or empty assertions must
# fail: a misspelled field must never turn a regression into a passing run.
static func runtime(state: Variant, conditions: Variant) -> String:
    if not state is Dictionary:
        return "runtime did not return a diagnostic object"
    if not conditions is Array or conditions.is_empty():
        return "runtime checkpoint requires conditions"
    for condition in conditions:
        if not condition is Dictionary:
            return "invalid runtime checkpoint condition"
        var key := String(condition.get("key", ""))
        if not state.has(key):
            return "runtime checkpoint missing field: %s" % key
        if not condition.has("equals") and not condition.has("min") and not condition.has("max"):
            return "runtime checkpoint requires equals, min or max: %s" % key
        var value = state[key]
        if condition.has("equals") and value != condition["equals"]:
            return "runtime checkpoint failed: %s value=%s condition=%s" % [key, value, condition]
        for bound in ["min", "max"]:
            if not condition.has(bound):
                continue
            var limit = condition[bound]
            if not (value is int or value is float) or not (limit is int or limit is float):
                return "runtime checkpoint requires numeric bounds: %s" % key
            if (bound == "min" and value < limit) or (bound == "max" and value > limit):
                return "runtime checkpoint failed: %s value=%s condition=%s" % [key, value, condition]
    return ""
