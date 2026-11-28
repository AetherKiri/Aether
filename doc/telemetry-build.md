# Telemetry build configuration

## Packaging

Set `AETHER_TELEMETRY_ENDPOINT` in the environment of `build.sh` or the Godot exporter. The value is a public HTTPS origin such as `https://telemetry.example.org` or the full `https://telemetry.example.org/v1/events` URL. An optional port is allowed. The exporter embeds the URL in the app, so keep credentials, query parameters, and secrets out of it. If the URL is missing or invalid, the exported app cannot send telemetry. User consent is required even when an endpoint is configured.

```sh
AETHER_TELEMETRY_ENDPOINT=https://telemetry.example.org \
AETHER_TELEMETRY_CHANNEL=preview \
./build.sh linux release
```

The endpoint and channel are fixed when the resource pack is exported. Standard Godot exports use the project’s enabled editor export plugin. The iOS and macOS build scripts also stage the config for exports that use Godot recovery mode. Launching directly from source uses the `source` channel with telemetry unavailable. Windows source builders can use the `Windows Release` preset in Godot after staging the native Release DLLs with the existing CMake build. For self-hosted Web exports, the endpoint must also answer the browser’s CORS preflight for JSON POSTs.

`AETHER_TELEMETRY_CHANNEL` overrides the default when it matches `[a-z0-9][a-z0-9_-]{0,39}`.

| Distribution | Default channel |
| --- | --- |
| Release-mode test packages from trusted pull requests and opted-in manual Build runs | `github_test` |
| Tagged CI releases for Android and Linux (x86-64 and ARM64) | `github_release` |
| macOS and iOS/iPadOS release exports | `apple_release` |
| Web release exports | `self_hosted` |
| Windows release exports and direct source runs | `source` |
| Debug exports | `debug` |
| Other release exports | `release` |

Apple release builds share a resource pack between Store and sideload distributions. Their channel describes the original export. To label independently built artifacts, pass a different channel to each export.

## GitHub test packages

Configure `AETHER_TELEMETRY_ENDPOINT` under **Settings → Secrets and variables → Actions → Variables**. The **Build** workflow embeds the endpoint and the `github_test` channel in release-mode packages and the Android debug APK for the same-repository `feat/opt-in-telemetry` pull request, including while it is a draft. To test another branch, select it under **Actions → Build → Run workflow** and enable **Embed and verify the telemetry endpoint in test packages**. The jobs fail if the endpoint is missing or invalid, or if the exported APK or Godot resource pack contains different settings. Other PRs, fork or bot PRs, regular pushes, manual builds with the switch off, and other debug exports have no endpoint.

Download a package under **Artifacts** on the completed **Build** run for the commit you want to test.

| Platform | Artifact |
| --- | --- |
| Android | `android-release-apk` |
| iOS/iPadOS | `ios-release-unsigned-ipa` (requires signing for installation) |
| macOS | `macos-release-app` |
| Linux | `linux-release-x86_64-app` or `linux-release-arm64-app` |

After installing the package, opt in to telemetry in the app, then launch or restart it. Ingestion events from these builds carry `channel=github_test`. Windows and Web have local export presets. Set the endpoint and `AETHER_TELEMETRY_CHANNEL=github_test` in the exporter environment for a local test build on those platforms.

## Tagged GitHub releases

Tagged builds use the same `AETHER_TELEMETRY_ENDPOINT` variable and may set `AETHER_TELEMETRY_CHANNEL` to override the platform default. The version-update script sets the app’s SemVer and numeric build number in the Godot project and updates the corresponding Apple and Android package metadata. The channel is independent of SemVer, including any prerelease suffix.
