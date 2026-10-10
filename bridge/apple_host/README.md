# bridge/apple_host

Apple 原生宿主的 C++/ObjC++ 侧实现（CMake 构建），与 `bridge/godot_extension` 平级：

- `aether_apple_host_core`：链接 engine_api + krkr2 glue + provider runtimes（复用现有 CMake 目标与 vcpkg 依赖）
- Metal 绘制桥实现（`engine_gpu_bridge.h` 回调表，见 `doc/apple_host_seam_inventory.md` B 节）
- 宿主钩子：纹理回收 drain、音频会话（iOS）

详见 `doc/apple_host.md`。
