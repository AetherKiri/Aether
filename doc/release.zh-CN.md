# 标签发布（Tagged Releases）

`Release` workflow 的维护者指南。日常构建与各平台启动流程见
[development.zh-CN.md](development.zh-CN.md)。

## 流程

推送形如 `0.3.0` 或 `0.3.0-beta.1` 的 SemVer 标签即可触发 `Release` workflow。
去掉可选前导 `v` 的标签即 Aether 应用内显示的版本号，同时作为 Android
`versionName`。SemVer 数字核心作为 iOS/macOS 营销版本号；GitHub run 号与
attempt 组合出单调递增的 Apple build number 和 Android `versionCode`。

iOS 和 macOS 构建 job 使用 GitHub 托管的 `xcode-27` ARM64 镜像，该镜像目前
处于公开预览阶段。两者均通过
`DEVELOPER_DIR=/Applications/Xcode_27.1.app/Contents/Developer` 固定使用
Xcode 27.1，并在构建前校验版本。[镜像软件清单](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)
列出了该版本携带的 iOS 27.1 和 macOS 27.0 SDK。编译缓存按平台及 Xcode
版本隔离。常规 CI 仍产出未签名 IPA 用于验证。标签发布要求两个 Apple 平台都完成 App Store
签名。将 `AETHERID` 设为已注册的 Bundle ID `com.liuyu.aether.aether`，并配置
以下仓库 Actions secrets：

- `IOS_DISTRIBUTION_CERTIFICATE_BASE64`：base64 编码的 Apple Distribution
  `.p12` 证书与私钥。
- `IOS_DISTRIBUTION_CERTIFICATE_PASSWORD`：该 `.p12` 的密码。
- `IOS_PROVISIONING_PROFILE_BASE64`：base64 编码的 App Store provisioning
  profile，对应 `com.liuyu.aether.aether` 与 team `3JL7FE9XQT`，并启用 App Group
  `group.com.liuyu.aether.aether.game-import`。
- `IOS_GAME_IMPORT_PROVISIONING_PROFILE_BASE64`：base64 编码的 App Store
  profile，对应 `com.liuyu.aether.aether.GameImport`，使用相同 team 与 App Group。
- `MACOS_INSTALLER_CERTIFICATE_BASE64`：base64 编码的 Mac Installer
  Distribution `.p12` 证书与私钥。
- `MACOS_INSTALLER_CERTIFICATE_PASSWORD`：Mac installer `.p12` 的密码。
- `MACOS_PROVISIONING_PROFILE_BASE64`：base64 编码的 Mac App Store
  provisioning profile，对应 `com.liuyu.aether.aether` 与 team `3JL7FE9XQT`。
- `APP_STORE_CONNECT_API_KEY_ID`：App Store Connect API key ID。
- `APP_STORE_CONNECT_API_ISSUER_ID`：App Store Connect issuer ID。
- `APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64`：base64 编码的 App Store
  Connect `AuthKey_*.p8` 文件。

## 商店打包

发布文件夹导入功能前，需要在 Apple Developer 账户注册导入扩展的 App ID 和
共享 App Group，将两个 iOS App ID 都加入该 Group，并重新生成两个 profile。
Xcode 导出工程会自动嵌入操作扩展；手动打包会为主应用和扩展分别指定 profile。
使用其他 Bundle ID 时，扩展 ID 为 `<bundle-id>.GameImport`，Group 为
`group.<bundle-id>.game-import`。

iOS 分享面板应用行的 **Aether** 入口会打开 Aether，将整个文件夹复制到
`Documents/Games`。操作列表中的 **发送到 Aether 视觉小说目录** 先接收到共享
容器，打开 Aether 时自动移入 Games；扩展无法直接访问主应用的 Documents。
两个入口都保留原文件夹及其存档，重名时添加编号，复制未完成的内容不会显示在游戏列表。

macOS App Store 包仅支持 Apple Silicon，启用 App Sandbox，并允许读写用户
选中的文件。Release workflow 会校验签名后的 iOS IPA 与 macOS installer 包，
先上传到 App Store Connect，再发布 GitHub Release。Apple 对已接收的上传做
异步处理；挑选处理完成的构建并提交 App Review 是独立的 App Store Connect
操作。签名或 API 凭据缺失、不完整时，标签发布会直接失败，而不是静默发布
未签名的商店产物。
