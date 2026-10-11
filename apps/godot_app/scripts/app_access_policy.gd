extends RefCounted

static func purchases_supported(platform_name: String) -> bool:
    return platform_name in ["iOS", "macOS"]

static func catalog_limit_enabled(platform_name: String, debug_build: bool, secret_unlocked: bool) -> bool:
    return purchases_supported(platform_name) and not debug_build and not secret_unlocked

static func beta_access_enforced(platform_name: String, debug_build: bool) -> bool:
    return purchases_supported(platform_name) and not debug_build

static func coffee_sponsorship_available(platform_name: String) -> bool:
    return platform_name in ["Android", "Linux"]
