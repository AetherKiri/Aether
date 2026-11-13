# Lua download fallback

This overlay preserves the Lua 5.4.8 port selected by the root manifest's
override. It is copied from microsoft/vcpkg port tree
`062ae235ae46d4bce8b00be2c74667e0763cc2c1`; the only functional change is the
download URL list.

Android build job [131700807349](https://github.com/AetherKiri/Aether/actions/runs/43357510649/job/131700807349)
failed downloading the archive from `www.lua.org` with curl error 35 (TLS
handshake failure). vcpkg treats that error as non-transient and does not retry
the same URL. The port now falls back to the PUC-Rio mirror listed on
[Lua's mirrors page](https://www.lua.org/mirrors.html).

Both HTTPS endpoints must produce the existing SHA-512 checksum. Lua's version,
patches, build options, exported targets and package layout remain unchanged.
Keep this overlay aligned with the root Lua version override when updating it.
