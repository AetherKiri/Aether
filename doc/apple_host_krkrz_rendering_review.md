# krkrz 上游渲染生命周期对照

审查日期：2026-10-11。范围是渲染所有权、呈现和关闭顺序，不是性能对比。
wamsoft/krkrz 源码固定到 `b6485e20b82e7626b6bc6ed7ae41dca585fde443`；
原版 krkrz/krkrz 仅辅助核对脚本关闭惯例。以下结论来自实现，不依赖 README。

## 直接绘制与所有权

[OGLDrawDevice.cpp](https://github.com/wamsoft/krkrz/blob/b6485e20b82e7626b6bc6ed7ae41dca585fde443/common/visual/opengl/OGLDrawDevice.cpp)
的 `Show()` 先 MakeCurrent。普通路径直接把 TextureInstance 的 GL 纹理交给
TextureDrawer 绘制，最后 Swap；Canvas 路径由 BeginDrawing / onDraw /
EndDrawing 组织绘制。这里没有 Aether 当前呈现阶段每帧创建不可变纹理并整帧
blit 的步骤，但不能据此推断所有上游绘制都没有复制或上传。

同一文件的 NotifyBitmapCompleted / EndBitmapCompletion 仍接收软件 bitmap，
通过 TextureUpdateRect 更新纹理。因此「上游直接呈现」不等于「旧 Layer 全部
直接用 GPU 合成」。Canvas 是另一条绘制路径，迁移呈现协议不要求先重写 TJS Layer。

[CanvasIntf.cpp](https://github.com/wamsoft/krkrz/blob/b6485e20b82e7626b6bc6ed7ae41dca585fde443/common/visual/opengl/CanvasIntf.cpp)
的 BeginDrawing 在 clear 前确定窗口或 Offscreen framebuffer；EndDrawing 恢复
绘制目标并清理未配对 effect/mask 状态。这说明绘制目标和作用域需要显式管理。

## 关闭顺序

OGLDrawDevice 的 DoneContext 保持 context current，发送 onDone，再销毁内部
Texture、Canvas、绘制辅助资源和壁纸，最后 Release context。视频纹理由独立
presenter 所有，DrawDevice 在关闭时停止 pull，不能把它当作自己的资源删除。
DestroyTexture 先 Invalidate TJS Texture，再清除持有的 variant 和 native 指针。

[TextureIntf.cpp](https://github.com/wamsoft/krkrz/blob/b6485e20b82e7626b6bc6ed7ae41dca585fde443/common/visual/opengl/TextureIntf.cpp)
的 Invalidate 显式销毁 GPU 纹理；
[GLTexture.cpp](https://github.com/wamsoft/krkrz/blob/b6485e20b82e7626b6bc6ed7ae41dca585fde443/common/visual/opengl/GLTexture.cpp)
的 destory 删除 GL texture/PBO 后清零句柄和更新统计。资源失效与脚本对象最终
引用计数归零是不同阶段。

[ScriptMgnIntf.cpp](https://github.com/wamsoft/krkrz/blob/b6485e20b82e7626b6bc6ed7ae41dca585fde443/common/base/ScriptMgnIntf.cpp)
在 Uninit 时调用 Shutdown 再 Release；
[tjs.cpp](https://github.com/wamsoft/krkrz/blob/b6485e20b82e7626b6bc6ed7ae41dca585fde443/common/tjs2/tjs.cpp)
的 Shutdown 先 compact variant stack，再 Clear/Release global 并删除 cache。
Aether 的 ScriptMgnIntf 当前仅卸载内部插件并 Release，Shutdown 被注释；Cleanup
仅 Release global。这是需要调查的语义差异，尚不是残留纹理根因证明。
直接恢复 Shutdown 或遍历 Window 强制失效必须先覆盖 finalizer/close 回调重入；
运行时已有多窗口递归 Finalize 崩溃警告，插件卸载也必须在 global 有效时执行。

## 对 Apple 内部接口的落实方向

1. RenderSession 作为窗口绘制资源的所有者，集中管理输出目标、提交和关闭。
   共享 device/管线保留进程级缓存；控制、输入、平台请求公共 ABI 保留。
2. 内部 FrameLease 表达 generation、serial、纹理与 GPU 完成后的归还。
   生产、呈现和复用由一个协议排序，再用纹理池替代每帧分配/整帧复制。
3. OpenGL 的 current-context 调用顺序不能直接替代 Metal 的完成协议。
   当前 replaceRegion 是 CPU 写入；同一 command queue 不能阻止它覆盖仍被 GPU
   呈现读取的纹理。需要 lease/池或受控上传，不能直接借用裸 token 去掉快照。
4. 关闭先停止生产和呈现，完成已提交命令/回调，归还 lease，再按所有权失效
   会话资源。脚本引用图修复独立验证；不能通过清空 token 表掩盖仍存活对象。
5. 截图、deferred 呈现和遮挡恢复需要明确保留哪一帧；窗口 drawable 暂不可用时
   不应让游戏逻辑或关闭流程依赖取得 drawable。

## 本轮对照与边界

compact + 销毁后 RecycleProcess 实验没有改善隐式关闭：单窗口残留 2 张、双窗口
4 张纹理；显式清根并失效对象图都为 0。四轮退出码均 0，failures/inflight 均 0。
证据：`out/apple_host/evidence/texture-close-compact-{single,multi}/result.json`。
无效实验不进入实现，当前源码保持既有关闭流程，重新构建 core 和 Debug 宿主。

本轮没有修改渲染算法，没有实现 FrameLease，也没有运行上游性能基准。
源码对照支持统一生命周期的架构方向，不能证明 Aether 已比 Godot 更快。
