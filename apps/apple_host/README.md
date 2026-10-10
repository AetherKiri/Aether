# Aether Apple Host (SwiftUI + Metal)

Apple 原生宿主（macOS 先行，验证后 iOS/iPadOS）。SwiftUI 壳 + Metal 呈现，直接驱动 `engine_api`，不含 Godot。

- 设计文档：`doc/apple_host.md`
- 宿主职责清单：`doc/apple_host_seam_inventory.md`
- 进度：`doc/apple_host_progress.md`

目录结构（计划）：
```
apps/apple_host/
  project.yml            # xcodegen 工程定义
  AetherHost/            # SwiftUI App：Library / Game / Settings / …
  HostKit/               # ObjC++：EngineSession / MetalPresenter / GameInputView / AudioHost
```

构建（计划）：CMake 产出 `bridge/apple_host` 宿主核心库 → xcodegen 生成工程 → `xcodebuild`。
