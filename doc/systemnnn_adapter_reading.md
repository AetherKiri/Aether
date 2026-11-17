# SystemNNN adapter source-reading audit

Source-only audit, 2026-11-17 UTC. Scope: the available public other-engine provider adapters, Godot's shared runtime input/presentation/registration boundary, their CMake integration, and the current SystemNNN provider. Only this document is authored by this audit. Other agents are editing implementation concurrently. No REA was used; no build, game execution, or tests were performed by this audit. This is **not a claim to have read the whole project, all upstream engines, or all platform packaging**.

The earlier [selective audit](/var/lib/dsh/systemnnn/AETHER-ADAPTER-AUDIT.md) is context, not transferable evidence that this audit read its files. F/P/U below describe this audit's reads. F = read from line 1 through observed EOF using read calls; P = selected ranges or output needing further recovery, so no complete-read claim; U = not read / unavailable. A complete wrapper read does not imply complete underlying engine coverage. Counts describe snapshots, not immutable repository versions.

## Public provider inventory

All eight available public non-SystemNNN provider implementations were requested through contiguous chunk reads, with EOF checked. These are the relevant common-provider examples; Flash/Tyrano/RenPy use separate player classes.

| Status | File | Observed lines | Read chunks (inclusive) | Main integration pattern |
|---|---|---:|---|---|
| F | [MAGES](../bridge/mages_runtime/src/mages_runtime_provider.cpp) | 712 | 1–240,241–480,481–712; compact recovery 1–180,181–360,361–712 | impacto GPU callback table mandatory at create; native design geometry; CPU capture; delivered serial on successful CPU/native delivery; explicit OpenAL FIFO output |
| F | [N2System](../bridge/n2system_runtime/src/n2system_runtime_provider.cpp) | 368 | 1–190,191–368; recovery 100–269,270–368 | isolated NativeAOT image and private dependencies; dedicated command worker marshals host API; image remains loaded through process exit; CPU RGBA frame and delivered sequence |
| F | [ONScripter](../bridge/onscripter_runtime/src/onscripter_runtime_provider.cpp) | 439 | 1–160,161–320,321–439; compact recovery 1–439 | upstream worker hidden behind Runtime; provider open waits for startup success; committed CPU frame copied/cached for describe/read; host owns scaling |
| F | [RFVP](../bridge/rfvp_runtime/src/rfvp_runtime_provider.cpp) | 305 | 1–160,161–305; recovery 1–110,111–210,211–305 | optional Godot GPU callback/batch bridge, CPU fallback; startup options frozen after open; shared per-game text settings |
| F | [Siglus](../bridge/siglus_runtime/src/siglus_runtime_provider.cpp) | 769 | 1–200,201–400,401–600,601–769; compact recovery 1–300,301–769 | Rust offscreen renderer; shared native frame if publication succeeds, CPU fallback otherwise; native Gameexe geometry; pointer cancellation and detailed IME callbacks |
| F | [System3](../bridge/system3_runtime/src/system3_runtime_provider.cpp) | 705 | 1–180,181–360,361–540,541–705; recovery 95–209,210–325,326–515 | interpreter worker, active-instance exclusion, checkpoints, immutable shared frame snapshots, content-derived save identity, queued SDL input with transition separation |
| F | [xsystem35](../bridge/xsystem35_runtime/src/xsystem35_runtime_provider.cpp) | 814 | 1–180,181–360,361–540,541–720,721–814 | System3-like worker/snapshots; source archive identity; encoding selection and case-insensitive path resolution; SDL audio ownership |
| F | [xsystem4](../bridge/xsystem4_runtime/src/xsystem4_runtime_provider.cpp) | 806 | 1–180,181–360,361–540,541–720,721–806 | worker-owned offscreen GL context, static shader resources, CPU readback snapshots, explicit audio pause; native logical render geometry |

Additional registered families are visible in [Godot registration](../bridge/godot_extension/src/aether_runtime_player.cpp#L14417): WA2, CMVS, Minori, EntisGLS, SoftPal and the aggregate Internal runtime registration. [Runtime switches](../cmake/AetherKiriRuntimes.cmake) also enumerate Artemis, CatSystem2, BGI, SystemC, Escude, YuRis, ADVHD. **U: their actual provider implementations are not read here**; package-provider sources were not returned by provider glob in the local packages subtree. Their registration hooks and consuming build conditions do not establish their graphics or lifecycle behavior. KiriKiri is the special legacy ABI backend, not another one of these eight public provider wrappers.

## CMake inventory

| Status | Files and observed EOF | Read coverage |
|---|---|---|
| F | [root](../CMakeLists.txt), 446; [runtime switches](../cmake/AetherKiriRuntimes.cmake),51 | Root 1–250,251–446; switches 1–51 |
| F | [Godot extension](../bridge/godot_extension/CMakeLists.txt),703 | 1–180,181–360,361–540,541–703 |
| F | [MAGES](../bridge/mages_runtime/CMakeLists.txt),123; [N2System](../bridge/n2system_runtime/CMakeLists.txt),239; [ONScripter](../bridge/onscripter_runtime/CMakeLists.txt),147; [RFVP](../bridge/rfvp_runtime/CMakeLists.txt),132; [Siglus](../bridge/siglus_runtime/CMakeLists.txt),83 | Each 1–EOF |
| F | [System3](../bridge/system3_runtime/CMakeLists.txt),56; [xsystem35](../bridge/xsystem35_runtime/CMakeLists.txt),78; [xsystem4](../bridge/xsystem4_runtime/CMakeLists.txt),164; [SystemNNN](../bridge/systemnnn_runtime/CMakeLists.txt),68 | Each 1–EOF; SystemNNN re-read separately |
| F | [EntisGLS shim](../bridge/entisgls_runtime/CMakeLists.txt),6; [Flash](../bridge/flash_runtime/CMakeLists.txt),57 | Each 1–EOF; EntisGLS only delegates to package-owned build |
| F | [N2System iOS](../bridge/n2system_runtime/cmake/N2SystemIOS.cmake),43; [media image](../bridge/n2system_runtime/cmake/N2SystemMedia.cmake),77 | Each 1–EOF |
| F | [RFVP prepare](../bridge/rfvp_runtime/cmake/PrepareRfvpSources.cmake),233; [Siglus prepare](../bridge/siglus_runtime/cmake/PrepareSiglusRsWorkspace.cmake),167; [Siglus Android audio check](../bridge/siglus_runtime/cmake/CheckSiglusAndroidAudio.cmake),20 | Each 1–EOF |
| F | [Siglus Rust build](../bridge/siglus_runtime/cmake/BuildSiglusRs.cmake),376 | 1–190,191–376 |
| F | [ONScripter prepare](../bridge/onscripter_runtime/cmake/PrepareOnscripterYuriSources.cmake),674 | 1–170,171–340,341–510,511–674 |
| U | [KiriKiri build](../bridge/krkr2_runtime/CMakeLists.txt); remaining toolchain/export/CI/Python packaging scripts, package-owned CMake dependencies | Discovered or referenced only; no complete-read claim |

Build patterns: keep the provider target linked to engine_api and dependencies on the adapter target; only define Godot WITH_* when the corresponding target exists; register at scene initialization. Embedded engines disable standalone launchers and avoid taking ownership of Godot's window. Source-overlay scripts fail on missing upstream anchors instead of silently pretending a patch applied. ONS publishes its completed accumulation surface at upstream present and joins parallel workers before SDL shutdown. RFVP preparation exposes host GPU/audio seams without adding a separate app window. Rust builds map CMake platforms to Rust triples and retain static archives. N2System stages a private dynamic image and dependent media libraries, with a separate iOS static NativeAOT path. xsystem4 explicitly selects Apple/EGL offscreen implementations rather than sharing the Godot GL context.

SystemNNN already follows the independent target/static aggregation path. Its observed [CMake](../bridge/systemnnn_runtime/CMakeLists.txt) links emberfall-scene, FreeType, Iconv, JSON, Threads, OpenAL and FFmpeg; collects native archive targets for downstream packaging; disables Web; uses the common OpenAL link sanitizer. This source reading does not prove those archives/dependencies are correctly present in every exported package.

## Host and supporting-source coverage

| Status | File | Exact coverage / limit |
|---|---|---|
| F | [provider ABI](../abi/include/engine_runtime_provider.h),247 | 1–247; recovery101–247 |
| F | [provider registry](../abi/src/engine_runtime_provider.cpp),218 | 1–218; recovery101–218 |
| P | [ABI dispatch](../abi/src/engine_api_dispatch.cpp),2033 | 620–664,1758–1805,1894–1915; targeted symbol search. No whole-file claim |
| P | [Godot runtime player](../bridge/godot_extension/src/aether_runtime_player.cpp),14574 | 1–180,10242–10461,10800–10894,11052–11211,11630–11759,13250–13384,14360–14574; recovery registration14417–14536. GPU renderer internals and other unlisted methods remain unread |
| P | [app main](../apps/godot_app/scripts/main.gd) | 13750–13789,17254–17366,19042–19094,19230–19354; search only outside these ranges |
| F | [input mapping](../apps/godot_app/scripts/game_input_mapping.gd),156 | 1–156 |
| F | [runtime form dialog](../apps/godot_app/scripts/runtime_form_dialog.gd),166 at read | 1–166; concurrently changed from older161-line audit snapshot |
| F | [Flash player](../bridge/godot_extension/src/flash_player.cpp),156 | 1–156 |
| F | [Tyrano player](../bridge/godot_extension/src/tyrano_player.cpp),160 | 1–160 (read limit260) |
| F | [RenPy player](../bridge/godot_extension/src/renpy_native_player.cpp),230 | 1–230 |
| F | [RenPy Linux](../bridge/godot_extension/src/renpy_native_linux.cpp),322; [macOS](../bridge/godot_extension/src/renpy_native_macos.mm),197; [iOS](../bridge/godot_extension/src/renpy_native_ios.mm),168 | Each 1–EOF (read limit360) |
| F | [RenPy SDL dynamic hook](../bridge/renpy_runtime/sdl_dynamic_hook.cpp),146; [iOS SDL hook](../bridge/renpy_runtime/ios_sdl_adapter.mm),75 | Each 1–EOF |
| F | [RenPy Android native host](../bridge/renpy_runtime/android/native_host.cpp),214 | 1–214; Java activity/host U |
| P | [Tyrano WebView](../bridge/godot_extension/src/tyrano_webview.mm),351 | 1–351 requested in180-line chunks;75–134 recovered separately; combined delivery was abbreviated, so conservative P until all omitted displayed content is recovered |
| F | [MAGES OpenAL](../bridge/mages_runtime/src/mages_audio_output.cpp),223; [Siglus OpenAL](../bridge/siglus_runtime/src/siglus_audio_output.cpp),261 | Each1–EOF |
| F | [offscreen header](../bridge/xsystem4_runtime/src/offscreen_context.h),20; [EGL](../bridge/xsystem4_runtime/src/offscreen_context_egl.cpp),127; [Apple GL](../bridge/xsystem4_runtime/src/offscreen_context_apple.mm),117 | Each1–EOF |
| F | [presentation sprite](../bridge/godot_extension/src/presentation/RuntimePresentationSprite.cpp),82; [header](../bridge/godot_extension/src/presentation/RuntimePresentationSprite.h),28 | Each1–EOF; generic runtime presentation helper, not the CPU frame upload itself |
| U | [ONS runtime internals](../bridge/onscripter_runtime/src/onscripter_runtime.cpp),2057; [Flash Rust engine bridge](../bridge/flash_runtime/src/lib.rs),466; KiriKiri legacy implementation; Siglus shared-frame implementation; remaining GPU/platform internals and engine-package code | Enumerated/measured, not read to completion |

Large combined tool deliveries can abbreviate display output. The core provider read calls acquired contiguous source chunks; key lifecycle/frame/input methods were re-read in compact source form for concrete findings. Supporting files marked P deliberately retain an incomplete claim. This ledger describes source reading, not exhaustive code review or runtime proof.

## Concrete integration contracts for SystemNNN

1. **Independent provider and ABI lifetime.** [ABI](../abi/include/engine_runtime_provider.h#L120) requires process-lifetime descriptors/function pointers, positive probe scores with deterministic score/priority/order selection, and provider-owned runtime instances paired with one destruction. Use the provider version for host validation and ENGINE_API_VERSION for create-desc validation; do not conflate them. [Dispatch](../abi/src/engine_api_dispatch.cpp#L645) supplies a non-null host/create-desc and catches create exceptions, but direct provider clients still need deterministic argument checks.

2. **Frame snapshots, geometry, and serials.** [System3 describe/read](../bridge/system3_runtime/src/system3_runtime_provider.cpp#L445) pins the immutable frame at describe and reads that same snapshot under mutex even if worker rendering publishes a newer frame. xsystem35/xsystem4 use the same approach. [ONS](../bridge/onscripter_runtime/src/onscripter_runtime_provider.cpp#L247) caches the copied committed frame at describe. The host allocates stride*height and then reads; keep description and payload consistent. Do not advance delivered state on a short buffer or failed read. Use tightly packed RGBA8888 for Godot's Image path. [Host CPU presentation](../bridge/godot_extension/src/aether_runtime_player.cpp#L11663) caches on frame serial, reads into reusable storage, forces opaque final alpha, and updates RD/ImageTexture. It does not establish correct intermediate layer blending or text compositing.

3. **Design resolution is engine-owned; presentation resizing is host-owned.** [Siglus](../bridge/siglus_runtime/src/siglus_runtime_provider.cpp#L300) documents the concrete failure when shell dimensions become game logical dimensions: padding and pointer misalignment. ONS/RFVP/System3/xsystem35 keep native frames and accept presentation surface changes without altering script space. SystemNNN should compose at its native canvas size and consume coordinates already mapped to that space.

4. **Input domains and cancellation.** [Godot](../bridge/godot_extension/src/aether_runtime_player.cpp#L11052) builds zero-initialized typed ABI events; key events do not carry a meaningful cursor location. Preserve prior mouse coordinates on key events. ABI buttons are0=left,1=right,2=middle, not SDL numbering. [Siglus](../bridge/siglus_runtime/src/siglus_runtime_provider.cpp#L469) recognizes POINTER_CANCEL before ordinary mouse-up dispatch. System3 separates press/release transitions because upstream observes held state. A cancelled release clears held state and must not activate/advance. Direct API synthetic up-only activation is an existing SystemNNN test expectation per parent; do not introduce a down-edge requirement without changing that contract deliberately.

5. **Pause and teardown.** System3 checkpoints clear pending input, suspend audio, wait interruptibly, and allow stop to wake paused workers. MAGES/Siglus pause both VM and OpenAL output. Native GL must be current only on its owner thread and previous contexts restored. Destroy audio before freeing mixer/VM state, stop/join workers before unloading upstream resources, reset held skip/key state across pause and reopen. [Host pause/resume](../bridge/godot_extension/src/aether_runtime_player.cpp#L10867) drains queued platform requests immediately; provider-specific background behavior is not implied by a generic pause callback.

6. **Modal UI has one edit owner and correlated responses.** [Dispatch](../abi/src/engine_api_dispatch.cpp#L1787) synthesizes active shell IME when provider flags ACTIVE. A host runtime_form already owns editing/focus: returning ACTIVE as well can enable a competing IME surface. [Form dialog](../apps/godot_app/scripts/runtime_form_dialog.gd#L154) includes request_id in submitted results. SystemNNN must reject responses from prior form generations and compare the actual pending modal request, including after title/load/reopen transitions. Keep encodings and byte limits at the engine boundary, not Godot character count.

7. **Capability absence is explicit.** MAGES requires installed GPU callbacks; RFVP accepts expected native-texture NOT_SUPPORTED without destroying useful prior errors; Siglus falls back to CPU when native import/publication fails. SystemNNN's CPU provider need not claim native windows, external textures, or GPU methods. Renderer/debug strings should report its real CPU/FreeType/OpenAL path.

8. **Audio is an adapter-owned transport.** MAGES/Siglus stream interleaved engine PCM into OpenAL on an owned pump thread and stop it before VM destruction. Those examples log and continue silently on init failure; that is precedent, not evidence that silence meets the SystemNNN goal. Flash instead feeds Godot AudioStreamGenerator. N2System keeps its native dependencies isolated. Final OpenAL device/context/platform packaging and actual audible output remain runtime checks.

9. **Stable writable state and paths.** System3/xsystem35/xsystem4 derive save identities from script contents, avoiding mobile container prefix changes. They do not need process-wide chdir to resolve paths. A SystemNNN runtime should isolate saves by game identity under host writable root, preserve CWD, and commit save replacement before acknowledging success. Lifecycle tests should include same-slot different games and reopen in the same process.

## Findings handed to active implementation parent

The provider was changing during the read: initial full snapshot grew from609 to622 lines. These are supported observations and parent coordination, not changes made by this audit.

| Finding | Evidence / status at handback |
|---|---|
| create accepted descriptors without size/version validation | Parent fixed; refreshed create region read415 onward confirms validation. Null host policy must be deliberate; ordinary dispatcher supplies host. |
| form response had no generation correlation | Parent fixed; refreshed [response](../bridge/systemnnn_runtime/src/systemnnn_runtime_provider.cpp#L571) checks modal request against saved id and JSON request_id against form generation. |
| ACTIVE duplicated host dialog IME | Parent fixed; refreshed [text state](../bridge/systemnnn_runtime/src/systemnnn_runtime_provider.cpp#L589) returns flags0 with explicit dialog-owns-IME comment. |
| frame rendered reported true for any existing frame | Parent fixed; refreshed [provider callback](../bridge/systemnnn_runtime/src/systemnnn_runtime_provider.cpp#L615) locks and compares current frame serial with delivered_frame_serial. Reference [MAGES](../bridge/mages_runtime/src/mages_runtime_provider.cpp#L539), [N2System](../bridge/n2system_runtime/src/n2system_runtime_provider.cpp#L346), [RFVP](../bridge/rfvp_runtime/src/rfvp_runtime_provider.cpp#L234). |
| key events reset stored pointer to0,0; middle release could advance | Parent fixed/reported and refreshed input checks observed; [input](../bridge/systemnnn_runtime/src/systemnnn_runtime_provider.cpp#L529) ignores non-left/non-right activation. Parent preserves existing up-only synthetic API behavior. |

Follow-up source check after parent handback: read provider155–179 and245–276. [start_story](../bridge/systemnnn_runtime/src/systemnnn_runtime_provider.cpp#L168) sets the candidate session chart storage to host writable/systemnnn/chart before installing it or stepping it. Both modal action branches capture return_mode before act_modal mutates the modal, and [result2 routing](../bridge/systemnnn_runtime/src/systemnnn_runtime_provider.cpp#L256) calls title only for a captured Title return mode. This verifies the adapter-side change, not all underlying chart persistence or modal semantics.

These corrections require parent-owned build/contract validation. No runtime success claim follows from this document. Remaining U scope is explicit: upstream engine implementations (including most Emberfall), Internal/package providers absent from this checkout, full Godot GPU internals, all export scripts, real device audio and graphics behavior. The available common-provider wrapper scope is covered; the whole product is not.
