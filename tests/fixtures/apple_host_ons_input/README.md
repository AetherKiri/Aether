# Apple host ONS input fixture

Asset-free, UTF-8 ONS script. Starts white and advances through red, green,
and blue on click/Return, then loops. Unlike the timed `onscripter_smoke`
fixture, it remains alive for the five-minute G0 gate and provides visible
input evidence. Supply `default_font` through `AETHER_HOST_DEFAULT_FONT`.
