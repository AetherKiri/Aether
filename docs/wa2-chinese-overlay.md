# WA2 Chinese text overlay

The `leafttt-engine` branch loads a generated UTF-8 text overlay without replacing the installed game archives. The converter in `packages/AetherInternal/src/leafttt/tools/chinese_overlay` uses the attributed [Kungal 4120 mapping](https://www.kungal.com/topic/4120) with the user’s local `ck-gal.pak`. It verifies 183 matching bytecode pairs and preserves text token order, empty tokens, ASCII controls and resource identifiers. Generated game text is a local deliverable and is not committed to this repository.

Configure the provider before `open_game` with `wa2.patch_dir` pointing to the generated overlay root and `wa2.font_path` pointing to a complete CJK font. The exact marker is `leafttt-text-encoding-v1=utf-8` followed by LF in `leafttt-text-encoding.txt`. Only text actually loaded from the marked overlay uses UTF-8. Retail fallback remains CP932, and each script switch resets the encoding decision. Invalid marked UTF-8, BOM, NUL or unsupported marker values fail explicitly. Name, message and choice display boundaries decode once; saved UTF-8 pages are restored directly. Both the message window’s private renderer and the choices/backlog renderer receive the explicit font.

The Godot probe accepts `engine_options` with these options, `expect_text_encoding: "utf-8"`, and `settled_capture_frames: 120` for a readable, input-free ordinary load capture. The probe continues to use the real compiled provider and `read_frame_rgba` in DebugCPU mode. A pending choice save waits for `saveReady` while preserving its exact VM checkpoint: native saving is unavailable while visual transitions are busy.

Final validation used engine commit `a81e2bca9b046105d1cf73792a395d2a33ecc077` and a normal Release build with cached vcpkg dependencies; the source feature defaults remain enabled. No substitute runtime or testing stub is shipped. The selected NotoSerifCJKsc font covers all 3,720 codepoints in the generated overlay according to the bundled stb font implementation; its SIL Open Font License accompanies the local package.

| Real Godot run | Frames | Captures | Passing checks | Result |
|---|---:|---:|---:|---|
| Title input, Chinese opening and ordinary save/load | 493 | 9 | 13/13 | Same script/PC/page restored, complete Chinese sentence readable |
| Complete Normal route from chapter 2001 | 9,757 | 60 | 34/34 | 15/15 strict selections, flag 20, title return at 2025:36688 |
| Coda chapter 3013 | 1,261 | 20 | 8/8 | 3/3 planned choices; direct chapter sample |
| Additional story from 5000 | 350 | 9 | 5/5 | Reached 5003:23692; direct chapter sample |

All 98 recorded Chinese screenshots were inspected, with contact sheets retaining all route samples and full-resolution expansions where needed. The missing-glyph failure discovered in the first rendering pass is preserved in the reports and closed by actual fresh-frame review. All three full/stage RGBA comparisons for the Normal pending-choice save/load pass. Native busy-save checks pass, and the full standalone suite reports 15/15 passing test targets, including 84 UTF-8 checks and 22 selected-font rendering checks. The converter’s 15 tests and an independent comparison of all 183 generated texts also pass.

This is sampled visual acceptance of the recorded text. It does not claim that every line in all 183 scripts was read, nor that scene artwork has been translated. Coda and additional-story Chinese samples are not complete-route ending tests. Full-route ending coverage belongs to the separate first-phase route evidence. Tests are headless and silent: movie completion acknowledgements and audio lifecycle checks do not certify decoded video or audible quality.
