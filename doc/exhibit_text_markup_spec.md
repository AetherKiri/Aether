# `exhibit_text_markup_spec` — message text pipeline specification (`RetouchAdvCharacter::say`)

> Status: **IN PROGRESS**. Sections are appended/completed as research lands.
> Binary: `resident.dll` (image base `0x10000000`). The provided IDA instance `3a8354b35463`
> (`resident.dll.i64`) was **corrupt** (idalib `error 4`, "Database is empty"); a fresh database was
> built from the raw `resident.dll` via a symlink in the temp workspace. All EAs below refer to that
> image base and match the provided spec's EAs.
> Scenario-body text encoding: **GB18030/GBK** (VM spec errata §11.1; runtime code page 936 via `lang_cns.dll`).
> Markup control codes are given as **hex bytes** throughout; non-ASCII is never pasted as evidence.

---

## 1. The `say` entry point

### 1.1 Call sites — `RetouchSystem::cmdMessage` @ `0x1018C1B0`

`cmdMessage` (VM spec §3.2) calls `say` in exactly two forms (cached decompilation
`decomp_say_cmdMessage_fresh.txt`, lines 239–250 and 259–270):

```c
// form A — no voice/effect script (strings[2] empty), last arg = 0
RetouchAdvCharacter::say(charObj, a2[3]/*params[1] msgId*/, lpString,
    strings[1]/*body*/, params[2]&1, (int)v54/*params[3] & 0x7FFFFFFF*/,
    a2[6], a2[7], a2[8], printParam, 0);
// form B — strings[2] present: compiled by sub_101715E0 into an async effect
// group (svdAppendGroup), this[987] (+3948) = charId for the duration, last arg = 2
```

Character object selection (line 166–168): `v41 = params[0] & 0x7FFFFFFF`;
guard `v41 >= 0 && v41 < this[659]`; `charObj = (RetouchAdvCharacter*)(this[660] + 268*v41)`.
So: **character array at `RetouchSystem.this[660]`, stride 268 bytes, count `this[659]`**.

Speaker-name selection (lines 171–199) — decides the `lpString` passed to `say` *and* the
name sent to the backlog (`rdhCmdMessage`):

- If `charId == 1 || charId == 2 || strings[0] == "*" || strings[0] == NULL`
  (`lstrcmpA(strings[0], "*") == 0`, line 174): `lpString = NULL` for `say`, and the backlog
  gets the character's **registered name** `*(charObj[33] + 20)` (charObj dword[33] → object
  whose +20 is an FCString buffer).
- Otherwise `lpString = strings[0]` (display-name override) and the backlog name is built as
  `strings[0]` + `81 69` + registered name + `81 6a` (full-width parens at `0x10430A6C`/`0x10430A68`,
  lines 189–191) — i.e. `override（registered）`. **Paren wrapping is backlog-only; it never reaches `say`.**
- Corpus: `strings[0] == "*"` in 26,104 / 26,279 records (`op28_markup_stats.txt`) ⇒ the retail game
  almost always takes the NULL-name path and the registered character name is displayed.

Also in `cmdMessage`: `params[3]` is passed masked `& 0x7FFFFFFF`, with bit3 (`0x8`) OR-ed in by the
caller when a skip argument is present (cached `decomp_cmdMessage.txt` / notes line 27); the
text/audio lock guard `sub_1022D1D0`/`sub_1022D1B0` brackets the call when `params[2]&2`.

### 1.2 `RetouchAdvCharacter::say` @ `0x10055250` — signature

9-argument convenience overload @ `0x10055C90` forwards to the 10-argument form with
`name = *(this[33] + 20)` (the character's own registered name) — `decomp_say_1_10055c90.txt`.

10-argument form (`decomp_say.txt`, full decompilation cached):

| # | Decomp name | Call-site source | Meaning / consumption inside `say` |
|---|---|---|---|
| a2 | `const CHAR*` (type confused) | `params[1]` | **Message/frame id (int)**. Voice-file key (`isPlayableVoice(this,(int)a2)` @ `0x10052580`, line 74), passed to system vtbl+32 (line 65, purpose unresolved), stored `PE[+0]`; later `printEx` uses it for the seen/experience-message font gate (`isExperienceMessage`). |
| a3 | `lpString` | `strings[0]` or NULL | **Speaker display name**. Copied into FCString(256) (line 68) and compared against `"$noname$"` (→ PE[36] bit2), `"$dummy$"` (→ bit3), `"c"` (→ lip-sync suppress). NULL ⇒ `messageEngine` falls back to the registered name of `chara(charId)[33]+20` when `3 ≤ charId < this[4336]`. |
| a4 | `const char*` | `strings[1]` | **Body text**, GB18030/GBK bytes, may contain markup (§2). Stored `PE[+12]`. |
| a5 | `bool` | `params[2]&1` | **Wait flag**. `PE[36] bit0`. Also line 77: if `!a5 && voiceEnabled` → `sub_10077630(sys, 256)` else `sub_10077630(sys, 0)` (sets a voice-driven wait mode; inferred). |
| a6 | `int` | `params[3] & 0x7FFFFFFF` (+`0x8` if skip arg) | **Voice/behaviour flags** — bit table below. Stored `PE[+16]` OR-ed with `0x20` when a voice was actually started (lines 136, 199). |
| a7 | `int` | `params[4]` | Voice extension param → `v45[1]`; also stored `PE[+20]`. |
| a8 | `unsigned` | `params[5]` | Two packed u16 voice params (LOWORD/HIWORD used when a6 bits 25/26 set, lines 111–121); stored `PE[+24]`. |
| a9 | `int` | `params[6]` | Stored `PE[+28]`; not otherwise consumed in `say` (unresolved). |
| a10 | `RetouchPrintParam*` | built by `sub_1006C010`/`sub_1006C050` in cmdMessage | Per-message print params (socket string "0;" + rect ints). Stored `PE[+32]`; consumed by `messageEngine` (`printParam[28]&1 → clearShadow(1, printParam[24])`). |
| a11 | `unsigned` | `0` or `2` (form B) | Base of `PE[36]`; bit1 = "voice/effect group attached". |

`a6` bit semantics (all from `decomp_say.txt` lines 72–135):

| bit(s) | value | effect |
|---|---|---|
| 3 | `0x8` | **Mute**: forces `v31 = 0` (no voice even if `isPlayableVoice` says yes), line 74. |
| 4 | `0x10` | Forces `v32 = 1` = same as name `"c"`: suppresses lip-sync animation lookup (`tmGetAnimationForLS` skipped, lines 72, 87–92). |
| 8–15 | `BYTE1(a6)` | Voice index: `v18 = BYTE1 ? BYTE1+1 : 0` → `v45[2]`, lines 98–104. |
| 16–19 | `(a6>>16)&0xF` | Voice param → `v45[3]`, line 105. |
| 25 | `0x2000000` | `a8` LOW word is a valid extra voice param (`v45[4]`, ext-block flag `0x10`), lines 111–116. |
| 26 | `0x4000000` | `a8` HIGH word valid (`v45[5]`, ext-block flag `0x20`), lines 117–122. |
| 28 | `0x10000000` | `stopVoice(sys, -2)` instead of `stopVoice(sys, -1)` before playing (line 84), and same selector into `UxPlayVoiceParam[+24]` (line 128). Exact −1/−2 semantics unresolved. |
| 0 | `0x1` | **Not consumed in `say`**; consumed in `printEngine@0x101B12E0` (lines 57–78): `v3 & 1` → area-driven **name-display gate**. Mode = `(MessageArea[26] >> 20) & 3`: 0 → always show name + clear (`v27 |= 0xA`); 1 → show name only on speaker change (`charId != this[4384]` → `|= 4`); 2 → name + clearMessage (`|= 0xA`). Corpus value: always 1. |
| 29 | `0x20000000` | **Not consumed** by `say`, `printEngine`, or `messageEngine` on the traced paths (corpus `params[3] = 0x20000001` always — bit29 set in all 26,279 records); may be read by save/seen systems. Flagged (§10 R3). |

Voice path (when `v31`): volumes start 256/256, corrected by `correctVoiceVolume(sys, charId, &vL, &vR)`
and `correctVoice@0x10054F20` (only while `charMgr->isEnter(-1)`); `UxPlayVoiceParam` (40 B on stack,
reusing the PE slots): `[+0]` lip-sync animation (`tmGetAnimationForLS(sys+648, this[61])`),
`[+4]` ext-param block ptr (or 0), `[+8]` msgId, `[+12]` charId, `[+16]/[+20]` vol L/R,
`[+24]` stop selector, `[+28]` flags (`|= 4`) → `UxAdvSystem::playVoice` (line 135).
Music ducking from `sreg(38)`: bits 0–6 target volume %, bits 8–15 fade-in time ×10 ms,
bits 16–23 fade-out ×10 ms, bits 24–30 restore % (lines 159–183, 217–222). Loop-effect duck
`volumeLoopEffect(sys,48,48,0,false,16)` when `this[66]&0x10` and voice active (lines 140–153),
restored afterwards. `leaveEnvVoiceEx(sys,-1)` after the print returns (line 214).

### 1.3 `PE_PARAMS` — the 40-byte struct handed to the print engine

Built at lines 184–213, passed via **virtual call `vtbl[+76]` of `this[50]`** (line 213) =
`RetouchSystem::printEngine@0x101B12E0` → `messageEngine@0x101B0110`:

| off | field | value |
|---|---|---|
| +0 | msgId | `a2` |
| +4 | charId | `Character::id(this)` |
| +8 | name | `lpString` (may be NULL) |
| +12 | body | `a4` |
| +16 | flags | `a6 | 0x20` if voice started, else `a6` |
| +20 | voiceParam | `a7` |
| +24 | packedU16s | `a8` |
| +28 | aux | `a9` |
| +32 | printParam* | `a10` |
| +36 | flags2 | `a11` base; bit0 = wait (`a5`), bit1 = voice-group mode (`a11=2`), bit2 = `$noname$`, bit3 = `$dummy$` |

### 1.4 Object fields that matter to text

`RetouchAdvCharacter` (stride 268): `[50]` (+200) = `UxAdvSystem`/`RetouchSystem`;
`[52]` (+208) = `UxAsyncSubsystem`; `[53]` (+212) = `RetouchCharacterManager`;
`[61]` (+244) = lip-sync animation id; `[66]` (+264) bit4 = duck-loop-effect enable;
`[33]` (+132) → object whose +20 = registered name FCString.

**Text state does not live on the character.** It lives on the print manager
(`RetouchPrintManager` = `UxAdvSystem + 3076`) and its print-area object (dword indices → byte
offsets ×4; full layout in §4): pen `[89]/[90]` = +356/+360; printable rect `[84..87]` = +336..+348;
line pitch `[94]` = +376; flags word `[97]` = +388 (0x200 center, 0x2000 right, 0x1000 page mode,
0x400 glyph double-draw); kinsoku pending count `[100]` = +400; colour palettes +484 (main, 8 slots)
/+516 (shadow); ruby/fade nibble byte +584; gray-format byte +585; font-slot `[147]` = +588
(= 16×index, 0..7, `sub_1022D0F0`); HDC +592. **Speed** is a system register:
`msPerChar = sreg(sreg(15)+5)` (`messageEngine`, cached `decomp_say_messageEngine_101b0110.txt`).
Current page = page-mode flag 0x1000 + `UxPrintData` dword +48 flags; cursor = pen +356/+360.

---

## 2. The markup grammar (core deliverable)

The pipeline recognises **three distinct layers** of control sequences. All multi-byte codes are
valid GBK double-byte characters and are matched **as decoded characters, not raw bytes** —
a C++ implementation must scan GBK-wise (decoder rule `sub_101BF270`: lead byte `c` starts a
2-byte char iff `(c+0x7F)&0xFF <= 0x7D`, i.e. `c ∈ [0x81,0xFE]`; token value = `lead<<8 | trail`).

### 2.1 Control-code table (complete; all values are hex bytes)

| Bytes | Layer / recognised at | Meaning | Time / page / state effect |
|---|---|---|---|
| `0A` | tokenizer (`sub_101BF720`, token 10) — `decomp_say_tokparse2_10233E20.txt` | **Line break**: line builder returns 2 (line closed) | advances line; may trigger page-full (§4). Only ASCII control consumed anywhere. |
| `00` | tokenizer | string end | — |
| `81 73` | `printEx@0x100693E0` rich parser; global @ `0x104254D8` (= `81 73 00`, dumped `phaseI_log_utf8.txt`) | **Block delimiter**: splits body into independent print blocks | each block becomes a PrintBlock; state (font/colour) carries, pen continues |
| `81 74` | `printEx` rich parser; global `Control` @ `0x104254C4`; detected as decoded char `33140 = 0x8174` (`cmp eax, 8174h` @ `0x10069732`, via MBCS decode `sub_101C0890`) | **Command introducer**: everything after it up to the next `81 73`/`81 74`/end is `<word>[:<arg>]*`, so plain text immediately following a command is consumed as part of that command's last argument — the corpus never shows this (zero control bytes in 26,279 bodies, §8.8) but a port must reproduce the swallow | per command (§2.2) |
| `81 90 82 6d` | `messageEngine@0x101B0110` only, when its mode arg has `0x80`; global @ `0x104316B0`; xrefs **only** `0x101B02C4`/`0x101B02EB` | **Previous-speaker placeholder**: FCString-replace (`sub_101C2BB0`) in body *and* name with the registered name of `chara(this[4386])` (last speaker, `this[660]+268*id`) | pure textual substitution before parsing. **Reachability**: `printEngine` sets mode `0x80` only when `PE[16] < 0` (bit31), and `cmdMessage` masks `params[3] & 0x7FFFFFFF` ⇒ unreachable via op28 in this title; another `say` caller (9-arg wrapper users) would have to set bit31 (inferred, flagged §10) |
| `81 69` / `81 6A` | `cmdMessage@0x1018C527`/`0x1018C548`; globals @ `0x10430A6C`/`0x10430A68` | full-width `(`/`)` — wraps overridden speaker name **for the backlog only** (`rdhCmdMessage`) | never reaches the text renderer |
| `0C`, `3B`, `,` | `strings[2]` voice/effect script only (compiler `sub_101715E0`) | record/field separators of the effect CSV — **not** body markup | n/a (§7) |

Name-level pseudo-controls (compared in `say`, §1.2): `"$noname$"`, `"$dummy$"`, `"c"`.
`$dummy$` additionally makes `messageEngine` replace the body with `""` and force charId=1.

**Candidates from the brief — verdicts:** page break code: **refuted** (no byte sequence; pages
advance only on area overflow or `0A`, §4). Inline wait code: **refuted** (only speed override `T:`).
Colour change: **confirmed** as `P:` (rich mode only). Ruby/furigana annotation: **refuted as body
markup** — ruby-adjacent fields exist (area byte +584 nibble, kinsoku push-back `sub_10233290`,
pending recommit counter area+400) but **no parser command sets them**; they appear vestigial from
the Japanese engine (inferred). Font/size change: **confirmed** (`C:`, `W:`, `S:`). Character-name
substitution: **confirmed** (`81 90 82 6d`). Speed control: **confirmed** (`T:`). Alignment/
positioning: **confirmed** (`POS:`, `MOV:`; per-area alignment flags 0x200/0x2000, not body codes).

### 2.2 Command grammar (after `81 74`)

Form: `<word>[:<arg>[:<arg>…]]`. Integer args parse via `sub_101C28C0`: prefix `0x` → hex,
`0b` → binary, else `atoi` decimal. Parser string block @ `0x104254C0` contains exactly:
`""`, `81 74`, `MOV`, `POS`, `CH`, `:`, `81 73` (dumped `phaseI_log_utf8.txt`). Each command
becomes a `PrintBlock` (0x2C bytes: `[1]`=type, `[2..4]`=int args, `[5..7]`=FCString str1,
`[8..10]`=str2; ctor `sub_1005DD60`). Types and executors (all EAs from `decomp_say_printEx_100693e0.txt`,
1359 lines fully read; helpers in `phaseI_combined.txt`):

| word | type | args | exec semantics | effect class |
|---|---|---|---|---|
| *(plain text)* | 0 | — | `sub_1005FC60`; printed char-by-char through the typewriter | time |
| *(unknown word)* | 1 | str1=word, str2=arg | `sub_1005FC90`: prints str1 and registers a `PrintLinkBlock` named str2 — clickable link/choice semantics (**inferred**) | state |
| `C:n` | 2 | n = font slot | `sub_1005FCD0` → `sub_1005D8D0` → `sub_1022D0F0`: clamp n to 0..7, area[147] (+588) = 16n; re-inits print data | state (font) |
| `P:a:b:c` | 3 | a=slot, b=main RGB, c=shadow RGB | slot = `min(a,7)`; area +484 = b, area +516 = c, each as **byte-swapped low 24 bits** (0xRRGGBB stored BGR-ish; exact slot stride 4×slot per decomp) | state (colour) |
| `L:x;y:z` | 4 | see note | `sub_1005FB30` (1 rect) / `sub_1005FB90` (3 rects) build a 0x54-byte `PrintLinkBlock` (`[+4]`=arg1, `[+8]`=arg2), positioned vs direction (`sub_1005F7A0(area)-2`), line pitch area+376, margins area+616/620; `appendPlbList`. Arg split/exact meaning **partially unresolved** | state (links) |
| `U:n` | 5 | on/off | underline (`sub_1005FD…` chain into styleset) | state (style) |
| `I:n` | 6 | on/off | italic | state (style) |
| — | 7 | — | bold exists in exec (style bit1) but **no parser command produces it** | — |
| `W:n` | 8 | n (default area `this[21]`) | styleset `sub_1022C680` → font wrapper `sub_1022C5C0` (LOGFONT at area+420, `CreateFontIndirectA`, HFONT at +480, size → +436, style bytes +440/441/442) | state (font) |
| `S:n` | 9 | n (default area `this[23]`) | same styleset path as `W` | state (font) |
| `T:n` | 0xB | ms/char; `-1` = keep | speed override for the remainder (`v153 = arg` when arg ≠ −1) | time |
| `E:n` | 0xA | n | per-char fade: n≠0 → area+4 `|= 0x20000`, area+52 = n | time+state |
| `V:…` | 0 | reg/expr | `str2DirectRegValue@0x10080C10` expands a system-register value to text; fallback = `""` (`byte_104254C0`) | time (prints result) |
| `CH:id:x:y[:z]` | 0xE | z default −12345 | `RetouchAdvCharacter::enter(chara(id), y>>16?, x&0xFFFF?, z, 9, −1, 8, −1, −12345×3, −1)` — spawns a sprite mid-message (arg packing per decomp; **inferred** hi/lo split) | state (stage) |
| `POS:x\|*:y\|*` | 0xC | `*` or empty → −12345 = keep | `getpos` (`sub_1022C250`) then `posset` `sub_10061060(x + sub_1022DE80(area), y + sub_1022DF10(area))` — absolute pen set, area-origin relative | state (pen) |
| `MOV:dx\|*:dy\|*` | 0xD | `*`/empty → 0 | relative pen move | state (pen) |

**Sentinel `−12345` = "keep current"** (POS/MOV/CH and the corpus effect scripts — same constant,
`op28_markup_stats.txt`).

### 2.3 Gating and the two parse paths (`printEx@0x100693E0`)

- Rich mode is enabled iff `(printMgr[43] & 2) && !(printExFlags & 2)`; `messageEngine` sets the
  disable flag from its mode bit `0x100`. Rich off ⇒ body goes verbatim to `printSub` (only `0A` matters).
- Fast path iff `(printMgr[43] & 0x80) && sub_1022C210()`: full command set above; type-1 exec =
  link/choice; name-area print via `printSub@0x10007F40` speed 0; experience-message font gate
  (`a2 ≥ 0 && !isEnterHistory`: font = `(sreg(23)>>8)&7`, ranges from `>>12&7` 1..7 +
  `isExperienceMessage` → `sub_1005D8D0`; `a7 == −1` → default link `this[28]`).
- Deferred path (lines 1069–1348): parses **only types 0–9** (`T`/`E`/`V`/`CH`/`POS`/`MOV` are
  fast-path-only); its case 1 is **centred text** (measure `sub_1005D3C0` → `sub_10234790` GDI
  `SIZE.cx`, centre via `this[82]/[83]`, `sub_10060F60`, nameprint `sub_1005D810`), not a link.
- Backlog replay (`printHistorySub@0x1005EC30`) parses the same grammar: xrefs to `81 73` ×3 and
  `81 74` ×2 — the markup is stored raw and re-parsed at replay time (§6).

### 2.4 Corpus verdict for THIS title (definitive)

`corpus_bytescan.txt` (all 26,279 op28 bodies, byte-exact scan): **zero** occurrences of `0A`, `0D`,
any ASCII < `0x20`, `81 73`, `81 74`, `81 90`, `82 6D`, `81 69`, `81 6A`. The sequences `A2 D9`×311,
`A2 DA`×6, `A2 DB`×7972 are **literal GB18030 text** (circled digits ①②③), not engine controls:
no imm32 reference to `0xA2D9/0xA2DA/0xA2DB` exists in `.text` (positive control: `0x8174` hits
exactly once, the `cmp eax,8174h` above — methodology verified). Occasional ASCII runs are literal
English fragments ("come", 'A'×248, 'c'×205 …).

**Consequence:** the entire rich grammar is engine-general but **dormant in this title's retail
scenario data** — every body is plain GB18030 text. A conforming renderer for this game needs:
GBK char scanning, `0A` line breaks, placeholder substitution at messageEngine level, and
name/body handling; the command parser is still required for engine fidelity and for save-game
backlog replay robustness, but no corpus record exercises it (§8, §10).

---

## 3. Character-by-character reveal (typewriter)

### 3.1 Driver and blocking model

The reveal is an **async effect executed inside a synchronous call chain** — this is why
`cmdMessage` blocks. Per printed line, `printSub_exec@0x10069040` (§4.4) ends with:

```c
tmInitPrint(asyncSys, 0, printData, speed, 0xC8);   // @0x1009C110
return tmExecPrint(asyncSys, 0, false);             // @0x100A08B0
```

- `tmInitPrint` (cached, `core_combined.txt` lines 641–659): destroys any effect in slot (≤1),
  then `new TmAsyncPrint(0x3C bytes)` @ `0x10020E60` with
  `TmAsyncPrint(printData, !isSkip ? speed : 0, 0xC8, 0)` — `isSkip = UxAsyncSubsystem::isSkip(this,false)`;
  **skip mode forces charWait = 0**.
- `tmExecPrint@0x100A08B0` (full text cached): `a2 ≤ 1 && effect && (enableExec, registration, !a3) && tmExitPrint(this, a2, true)` — with `a3=false` it **always** falls into `tmExitPrint(slot, wait=true)`.
- `tmExitPrint@0x1009C360` (full text cached, `phaseJ_combined.txt`): `FCAsyncEffect::wait(effect, INFINITE)` → unregister → return `*(BYTE*)(effect+40)` (the "finished instantly" flag) → destroy.

So the calling thread parks in `FCAsyncEffect::wait` while the frame loop drives
`TmAsyncPrint::exec` until it reports done; completion is signalled by effect state `[5] = −1`
and the wait returning. `say` returns only after `printEngine` → `messageEngine` → `printEx` →
`printSub_parse` → `printSub_exec` all unwind, followed by `messageEngine`'s `hitwait` (click-wait, §3.5).

`TmAsyncPrint` object (0x3C = 15 dwords; field roles from exec @ `0x10020F70`, cached
`decomp_say_tmasync_10020f70.txt` + `phaseJ_combined.txt`): `[5]` state (0 not started / 1 running / −1 done),
`[6]` print-area ptr, `[7]` chars revealed, `[8]` charWait (ms per char), `[9]` start tick,
`[11]` decide-key threshold (0xC8 = 200 ms from ctor), `[12]` loop count, `[13]` pause latch tick,
`[14]` flags, byte `+40` = completed-instantly flag.

### 3.2 Per-frame algorithm (`exec@0x10020F70`, arg = current tick ms)

1. Guards: `[6] == 0` → return; `[5] < 0` → return (done).
2. Flags `[14]`: `0x300` → paused: latch `[13] = tick`, return. `0x10000` → restart: reset char-list
   cursor (`sub_1022F5C0`), clear flag, `[9] = tick`, `[7] = 0`, byte40 = 0. `0x20000` →
   `sub_10231DB0(1)` re-arm (ruby/kinsoku pending; inferred).
3. Pause compensation: `[13] ≠ 0` → `[9] += tick − [13]`; `[13] = 0` (pausing does not lose progress).
4. First run: `[5] == 0` → `[9] = tick`, `[5] = 1`.
5. Reveal budget: `charWait = [8]`.
   - `charWait == 0` → `reveal(−1)` = **whole remainder instantly** (skip mode).
   - else `due = (tick − [9]) / charWait`; if `[7] ≥ due` → nothing new this frame.
     Else if **Ctrl held** (`GetAsyncKeyState(0x11) < 0`) **or** (`tick − [9] > [11]` i.e. >200 ms
     **and** decide key pressed) → `reveal(−1)`, byte40 = 1 ("finished instantly").
     Else → `reveal(due − [7])`; `[7] = due`.
6. On "list exhausted" from reveal: if `[12]` loop ≠ 0 → decrement (−1 = infinite), flags `|= 0x30000`
   (`|= 0x200` if charWait==0) → replay; else `sub_102308E0(area)` (end-print), `FCAsyncEffect::end(this)`, `[5] = −1`.
7. Any glyph blitted this frame → dirty-rect flush `sub_10210260(&rc)`.

**Timing model: purely time-based** — `charsDue = elapsed_ms / msPerChar`; frames only catch up to
the budget. `msPerChar` = the `speed` argument = `sreg(sreg(15)+5)` (message-speed system register,
`messageEngine`), overridable mid-message by `T:` (§2.2). In `printSub_parse@0x10069310` the speed is
applied to the **first executed line only** — after a successful `printSub_exec`, `speed = 0` (observed;
subsequent lines of the same block reveal instantly).

### 3.3 Character blit (`reveal` = `sub_102342B0`, cached `decomp_say_reveal2_102342B0.txt`)

Walks the committed `FCXList<UxPrintableChar>` from a saved cursor (`printData[4]`):
- char code `10` → `sub_102335B0(printData)` = newline (pen advance via `sub_10231980`, §4.3);
  **does not consume the reveal budget**;
- else `sub_1022FFE0(charNode, &rc)` blits the cached gray-bitmap glyph (coloured from the area
  palettes, §5.3) and decrements the budget;
- budget exhausted → save cursor (`sub_10231690`), return 0 (more pending); list end → return 1 (complete).

### 3.4 Interrupts

| source | effect | evidence |
|---|---|---|
| Ctrl (VK 0x11) held | instant full reveal of current line, byte40=1 | exec step 5 |
| decide key after >200 ms of current line | same | exec step 5, threshold `[11]`=0xC8 |
| skip mode (`isSkip` at init; `isDoSkip`/`checkDirectKeySkip(0x707)` in waits) | charWait forced 0 ⇒ instant; `UxAdvSystem::wait@0x1007B550` returns 0 immediately | tmInitPrint; advwait cached |

### 3.5 Post-message wait and auto mode

After the text completes, `messageEngine` calls `hitwait@0x101A8530` (blocks for click / decide key,
skip-aware) when `(mode & 0x40) == 0 && (waitFlag || (mode&0x10) && !(mode&0x20))`. Auto-play timeout:
`autoMessageWait@0x10078A90` = `max(sreg(12) × strlen(body), sreg(13))` ms, or −1 when
`sreg(12) < 0` (cached `phaseJ_combined.txt`); `sreg(12)`/`sreg(13)` = per-char / minimum auto wait.

### 3.6 Synchronous fallback typewriter (`printSub@0x1005E760`, cached `decomp_say_printSub_measure.txt`)

Used for simple strings (name-area prints, history): `speed == 0` → draw whole string
(`sub_102330B0` → GDI text-out path) and return extents; else per character: `_mbccpy` one MBCS char,
draw it, `UxAdvSystem::wait(speed_ms, true, false)` — interruptible by skip/`0x707`; on interrupt the
remainder is drawn at once. `wait@0x1007B550` sleeps in 50 ms (total <1000 ms) or 100 ms granules;
`−1` = wait forever until skip/decide.

---

## 4. Pagination and layout

Two objects drive layout: the **print area** (a per-window object; dword index ×4 = byte offset —
pen `[89]/[90]` = +356/+360, confirmed by disasm `mov [esi+25Ch],ecx` / `[esi+260h]` = +604/+608
line-start pen, this run) and the per-message **UxPrintData** (char list + flags). Field map below;
all from `decomp_say_tokparse2_10233E20.txt`, `phaseJ_combined.txt` (`sub_10231980`, `sub_1022C250`,
`sub_102331C0`), `decomp_say_printEx_100693e0.txt`.

### 4.1 Print-area fields relevant to layout

| offset (dword idx) | content |
|---|---|
| +4 | area flags; `0x20000` = per-char fade armed by `E:`; +52 = fade param n |
| +336..+348 (`[84..87]`) | printable rect left/top/right/bottom **and** the blit/scroll target rect |
| +356/+360 (`[89]/[90]`) | pen x/y |
| +376 (`[94]`) | line pitch (px per line/column advance) |
| +380 (`[95]`) | left/top margin offset (reset to 0 on overflow wrap) |
| +388 (`[97]`) | flags word: `0x200` centre, `0x2000` right-align, `0x1000` **page mode**, `0x400` glyph double-draw (shadow) |
| +400 (`[100]`) | kinsoku push-back pending count (re-committed next line) |
| +420 | LOGFONT; +436 font size; +440/441/442 style bytes; +446 font dirty flag; +448 face name; +480 HFONT (§5.4) |
| +484 / +516 | main / shadow colour palettes, 8 slots (§2.2 `P:`) |
| +584 / +585 | ruby-fade nibble / gray-format selector (§5.2) |
| +588 (`[147]`) | 16 × font slot index (0..7), set by `C:` (`sub_1022D0F0`, read back `sub_1005D8F0`) |
| +592 | HDC for measurement/rasterization |
| +604/+608 | pen at current line start |
| +616/+620 | link margins (`L:` blocks) |

Direction is encoded in area flags (`+4` bits 4/8) as codes **1** = horizontal LTR, **2** = vertical,
columns right→left, **4** = horizontal RTL, **8** = vertical, columns right→left, y from bottom
(`sub_10231980` switch; vertical modes exist but the message window is horizontal — inferred).

### 4.2 Line building (`sub_10233E20(area, printData)`, cached full text)

Per call, builds **one line** into the char list:

1. Source string at area+16; if 0 → return 0. Get HDC (`sub_1022DF90`), line-bounds rect ctor at +332,
   pen snapshot from +356/+360, `fuFormat` from byte +585 (§5.2), outline metrics via `sub_102C7770`
   (= `GetOutlineTextMetricsA` on area HDC +592).
2. Recommit up to `[100]` pending chars (kinsoku push-back from previous line) via `sub_102315F0` pop;
   first committed char records line-start pen (+604/+608).
3. Token loop (`sub_101BF700` init / `sub_101BF720` next; MBCS decode `sub_101BF270`):
   - token `10` (`0A`) → **return 2** (explicit line end);
   - token `0` → end of text → **return 1**;
   - else rasterize glyph (`sub_10230960`, §5.2; failure → debug print `ERR(GetGlyphOutline…): uChar:0x…`
     + char skipped), fetch pen (`sub_1022D340`), **fit test** `sub_100CD270`:
     `rect.left ≤ pt.x < rect.right && rect.top ≤ pt.y < rect.bottom`; fail → line full → **return 2**;
     pass → commit char node (`sub_1022BDB0`).
4. Line-end kinsoku (see 4.5) then return.

### 4.3 Line advance / page break (`sub_10231980(area, a2, a3)`, full walkthrough cached in `phaseJ_combined.txt`)

`pageMode = (a3 & 0x1000) || (area[97] & 0x1000)`.

1. Compute next-line pen from direction: case 1 → `(left + area[95], pen_y + area[94])`;
   case 2 → `(pen_x − area[94], top + area[95])`; case 4 → `(right − area[95] − 1, pen_y + pitch)`;
   case 8 → `(pen_x − pitch, bottom − area[95] − 1)`.
2. **Out of rect** → debug print (rect + pos), `area[95] = 0`, wrap pen to area origin
   (case 1 `(left,top)`; cases 2/4 `(right−1,top)`; case 8 `(right−1,bottom−1)`).
3. Commit pen (`[89]/[90]`); `linefitval sub_1022CEB0(area,x,y,dir)` (dir 1/4 horizontal, 2/8 vertical;
   returns 1 = outside) fail → return 0.
4. `pageMode` → **return 2** (caller must break the page). Else → **scroll mode**: `sub_10230640`
   (crit-section + Interlocked-guarded surface blit of rect +336..+348; capture path on `area[4]&0x80`;
   dispatch vtbls `[8]/[12]/[16]`) + `sub_102C7500` (rect copy + `IsWindow`) + pen reset
   `sub_10231930` → **return 1**.

**Page-break trigger:** there is no page-break *control code*; a page break happens when the next line
leaves the printable rect while page-mode flag `0x1000` is set. In `printSub_parse@0x10069310`, after a
line returns 2: `sub_102335B0(printData)` (which calls `sub_10231980(0, 4096)` = page-mode advance) →
if that returns 2 (page full) → `printSub(this, printData, true, 0)` = **area-overflow path**:
clear2 + `MessageBeep(0x30)` + error log `"%s%s\n"` (observed; the retail flow avoids this by sizing
messages to one page and paging on click via `hitwait` + `clearMessage` on the next message, mode bit `0x2` —
inferred). Without `0x1000` the area scrolls instead (terminal-style).

### 4.4 Line execution and alignment (`printSub_exec@0x10069040`, cached)

`a3 ≠ 0` → overflow error path (above) → false. Else: line extent via `sub_10231DE0(&size, dir)`;
target rect = area +332..+348; pen via `sub_1022C250(area,&x,&y,0)` (`a4=1` returns the cached line
extent point `[151]/[152]` instead — used for link rects); alignment from area `[97]` (+388):
`0x200` **centre** → `pen_x += (right − pen_x − lineWidth + 1) / 2`; `0x2000` **right** →
`pen_x = right − lineWidth − dword_1050BFA0`; vertical analogues for dir 2/8; then set pen
(`sub_10060F60`) and start the typewriter (§3.1). Alignment is therefore a **window property, not body
markup**.

### 4.5 Kinsoku (line-break prohibition)

- Membership: `sub_1022F360(list, C, class)` (cached, 10 lines): disabled when `list[1] & 0x800000`;
  primes cursor pair `[143]/[144]` (class 1) or `[140]/[141]` (class 0); test = `sub_101BEBE0(C)` =
  `_mbschr(setString, C)`. **One shared set string**, two cursors.
- Sets: `enableKinsoku@0x1005E270` (str → assign; flag → assign `""` = disabled; neither → default
  `g_pDefaultKinsoku@0x105095F8` → bytes @ `0x104253A0–0x1042546C`, full hex in `phaseJ_log_utf8.txt`
  (the first dump stopped one byte early, which also cut the closing pair):
  a **cp932 Japanese** set incl. ASCII `5D 5E 3B 3A 29 2D 5F`, `F0xx` pairs and a closing `81 F4`;
  **no `A1xx` GB
  punctuation** ⇒ Chinese punctuation is *not* kinsoku-protected in this title — a real behavioural
  note for the port). `disableKinsoku@0x1005E2F0` → empty set. `rpm_create@0x100612B0` installs the default.
- `messageFrame@0x101730C0` calls `enableKinsoku` twice per frame (0x10173379 str=frameObj+20, flag=0;
  0x10173395 str=frameObj+20, flag=1 — second call wins; NULL string → disabled) — frames may carry a
  custom set.
- Push-back: at line end, if the first char of the next line is in the set (can't start a line) or the
  last char of this line is in the set (can't end a line), `sub_10233290` pops trailing chars off the
  committed list into pending (`[100] += count`), recommitted at 4.2 step 2.
- **GB mode:** `sub_102331C0` (UxPrintData init) sets dword +48 = `0x100` iff cached ACP
  `dword_1050BFA8 ≠ 932` (static init 932; runtime `GetACP` = 936 on this title ⇒ flag set). With
  +48 & 0x100, an extra line-end handler `sub_102334B0` runs (pending += result) — GB-specific
  two-byte-aware line ending (cached `decomp_say_ctl_102334B0.txt`).

### 4.6 Frame / window selection — resolved

`params[1]` (msgId) selects voice, seen-message font gating and history identity (§1), **not** the
window. The print area is chosen in `printEngine@0x101B12E0` (lines 39–43):
`findMessageArea(this, sreg(14) == 255 ? 255 : sreg(14), false)` — **system register 14 is the
message-area selector** (255 = default). When a `printParam` is supplied with `printParam[5] ≥ 0`,
`printEngine` writes `MessageArea[117] = printParam[5]`, `[118] = 138`, `[119] = 139`, `[120] = 141`
(lines 95–120) — **`LID_MESSAGE = 138` confirmed in-binary** — and draws/clears the intelligent-name
area on layer 138 (`sub_10226910(138)`, show at alpha 255 via `sub_10215D50(138, 255)`). Per-area
geometry (rect/pitch/alignment/kinsoku) is installed by `messageFrame@0x101730C0`/`prePrint@0x100667A0`;
the `RetouchMessageParam` table contents were not dumped (§10 R14).

### 4.7 Ruby

No ruby annotation markup exists (§2.1). Ruby-adjacent machinery (pending-char recommit, area byte
+584 nibble, `sub_10231DB0` re-arm flag `0x20000` in the typewriter) is present but no parser command
feeds it; line height is the fixed pitch `[94]` (inferred vestigial).

---

## 5. Text measurement

**Answer up front: measurement is pure Win32 GDI against the real font — `GetGlyphOutlineA` per
character (advance + gray bitmap in one call), `GetOutlineTextMetricsA` per line, `GetTextExtentPoint32A`/
`GetTextExtentExPointA` for whole-string extents, `CreateFontIndirectA` for the font. There is no custom
TTF parser and no cached metrics table.** A host reimplementation must supply per-character advance
widths and anti-aliased glyph bitmaps from a genuine rasterizer/measurer (FreeType, DirectWrite, …);
it cannot be done from static tables.

### 5.1 Where each GDI entry point is used (import xrefs, `phaseG`/`phaseJ` logs; call sites re-verified this run)

| GDI call | engine site | purpose |
|---|---|---|
| `GetGlyphOutlineA` | rasterizer `sub_10230960`, 4 call sites `0x10230A66`/`0x10230AF3` (horizontal pass) and `0x10230DB8`/`0x10230E45` (vertical pass) — pairs = size query + fill | per-char metrics **and** gray bitmap |
| `GetOutlineTextMetricsA` | `sub_102C7770`, called per line from `sub_10233E20` on area HDC (+592) | ascent/baseline for glyph placement |
| `GetTextExtentPoint32A` / `GetTextExtentExPointA` | `sub_10232930`, `sub_10234790` (cached `decomp_say_gdiext_10232930.txt`) | string extent: centred-text measure `sub_1005D3C0` → `SIZE.cx` (printEx deferred case 1), link rects, text-out paths `sub_1022E140`/`sub_1022E950` |
| `CreateFontIndirectA` | font wrapper `sub_1022C5C0` (§5.4) | HFONT from LOGFONT |
| `GetTextMetricsA` | text-out paths | line metrics of simple draw path (`printSub@0x1005E760`) |

### 5.2 Per-character rasterization (`sub_10230960`, cached `decomp_say_ctl_exec_10230960.txt`; disasm verified this run)

Called from the line builder as `sub_10230960(glyphObj, area, uChar, dir, fuFormat, otm)` (call site
`0x10234091`). Per character:

1. `GetGlyphOutlineA(hdc, uChar, fuFormat, &gm, 0, NULL, &mat2Identity)` → size; second call fills the
   buffer at area `[23]` (+92 glyph buffer). Return 0 ⇒ **zero-width glyph**: flag `0x40000000` set,
   width = margins + `otm[4]`, treated as blank/space.
2. **Advance width** stored at glyphObj dword `[2]` = `gm.gmCellIncX + 4`; **height** `[3]` =
   `*(otm + 4)`, i.e. `otmTextMetrics.tmHeight` — *not* `otmAscent`: OUTLINETEXTMETRIC's first
   member is `otmSize`, so the TEXTMETRIC and with it `tmHeight` begin at byte 4, and the earlier
   `otm[8]` reading was wrong. The `+4` is two 2-px side margins from the data globals
   `dword_1050BF94/98` — all four globals statically = 2 (read this run) — and it is baked into
   the **stored cell**: the line builder's step then adds nothing (§9.5). Padding once, at store
   time, is what keeps the two numbers from being double-counted.
3. Bitmap rect from `gmptGlyphOrigin` + `gmBlackBoxX/Y` via `sub_10017430`; baseline =
   `*(otm + 8)` − `gmptGlyphOrigin.y`, where the offsets are bytes into
   OUTLINETEXTMETRIC: +4 is `tmHeight`, +8 is `tmAscent`. Baseline and stored height
   therefore come from adjacent TEXTMETRIC fields, which is exactly the pair item 2
   above conflated.
4. `fuFormat` (computed at `0x10233EFE–0x10233F12`, verified this run):
   `mov al,[esi+249h]; test al,al; setnz cl; lea ecx, ds:1[ecx*4]` ⇒ **fuFormat = 4×(area byte +585 ≠ 0) + 1 ∈ {1, 5}**, passed unchanged to `GetGlyphOutlineA`.
   The unpack code treats `fuFormat == 1` output as **4bpp gray** (nibble → 16-entry BGRA "spread"
   palette `byte_1043B1C0`, entries are 0x00/0x10 component patterns, dumped `phaseJ_log_utf8.txt`)
   and `fuFormat == 5` output as **8bpp gray** (byte copy). Note: 1 and 5 do not match documented
   `GGO_*` constants (1 = `GGO_METRICS`, 6 = `GGO_GRAY4`, 8 = `GGO_GRAY8`) — the practical takeaway is
   *anti-aliased gray glyph bitmaps, format selected by area byte +585*; the exact Windows behaviour for
   these immediates is **unresolved/flagged (§10)**.
5. Vertical directions (2/8) use a transposed copy loop (column-major writes). `area[97] & 0x400` ⇒
   double-size buffer + offset blit = **shadow/double-draw** (glyph drawn twice; matches the separate
   shadow palette at +516 — inferred).
6. Finished glyph committed to the area glyph cache (`sub_1022F900`); last glyph dims written to
   area +60/+64. Failure path logs `ERR(GetGlyphOutline B): uChar:0x…` / `ERR(GetGlyphOutline): uChar:0x…`
   (strings at the call sites, verified this run).

**Fit test** (does the char still fit on the line?) uses the advance: `sub_100CD270` compares the
glyph origin/extent point against the clip rect (§4.2 step 3) — i.e. **layout advance = gmCellIncX + 2**,
never a `GetTextExtentPoint32` call; extents are only used for centring and link rects.

### 5.3 Colour application at blit time

Gray levels are combined with the area palettes in `sub_1022FFE0` (cached `decomp_say_revealchar_1022FFE0.txt`):
main RGB from +484 slot, shadow RGB from +516 slot (`P:` command, byte-swapped low 24 bits), colour-base
word at area +588 region / +552 (per decomp). The renderer therefore needs only **8-bit-or-less gray
coverage + two RGB palettes** — no per-glyph colour.

### 5.4 Font selection (`sub_1022C5C0` + `sub_1022D0F0`, cached `phaseI_combined.txt`)

- LOGFONT lives at area +420; `lfCharSet = 0x86` (**GB2312_CHARSET** — Chinese build); default
  `lfFaceName` dword = `0x706F6D69` = `"imop"` (title's own face, inferred "imopara…"); a face-name
  argument < 32 chars is copied to area +448; `CreateFontIndirectA` → HFONT at area +480; dirty flag
  area +446 = 2 triggers re-create; size arg → +436; style bits from area bytes +440/441/442
  (bold/italic/underline triad fed by `W:`/`S:`/`U:`/`I:` through styleset `sub_1022C680`).
- Font **slot** (0..7) = area +588 = 16×index (`sub_1022D0F0` clamps `n` to 0..7); slot→face resolution
  via `sub_1027B130`; read-back `sub_1005D8F0` = `*(area[5]+588)/16`. `C:n` selects the slot; the
  seen-message path can override the slot from `sreg(23)` (§2.3).

### 5.5 Consequences for the C++ port

- The host must expose: `createFont(faceName, sizePx, styleBits, charset=GB2312)`,
  `glyphAdvance(font, gbChar) -> int` (= rasterizer cell increment + 2 px pad to match metrics),
  `glyphBitmap(font, gbChar) -> gray8 coverage + origin/ascent offsets`, and
  `textExtent(font, byteString) -> cx` for centring. Everything else (fit test, pen advance, pitch,
  alignment) is engine-general arithmetic specified in §4.
- Because layout consumes `gmCellIncX + 2` per char and lines advance by the fixed pitch `[94]`,
  pixel-exact parity requires the same font file at the same size; otherwise only *behavioural* parity
  (line-break positions may shift). Marked as a porting risk (§10).

---

## 6. History / backlog

### 6.1 What is recorded, and when

- Gate: `printEx` flag `a6&1` (`v160`); `messageEngine` sets it via `v25 = (PE[36]&8) == 0` ⇒
  **`$dummy$` messages are never recorded**. `a6&0x10` (`v165`) → history flags `|= 0x1000`.
- `setHistoryRequest@0x10060980` (called from `printEx`): if `this[3] ≥ 0` → `flushDelayHistoryData`
  (the **delayed flush**: history writes are batched while a delay count is active); then
  `MessageContainer::create(this+4, msgId, charId, name, body, flags)`.
- `setHistory@0x1005E950`: `a3 == −1` → separator entry: `this[34] = −2`; if
  `lastEnterCount() == 0` → append a `"\n"` (`0A`) message — backlog entries are newline-separated.
  Otherwise flags `|= 0x1000` when `UxAdvSystem+76` byte `&1`; create container; save-buffer path;
  ring insert `sub_1004E9F0` (copies 11 dwords into the ring node).

### 6.2 Stored form

`MessageContainer::create@0x1004EF50`: two `FCString(256)` **deep copies of name and body as raw
GB18030 bytes — markup is NOT stripped** (proof: the replay parser re-reads `81 73`/`81 74`, §6.4);
`[+1]` = msgId, `[+2]` = charId, `[+3]` = flags. Fixed-capacity **ring buffer** (oldest entries
dropped) at manager+116. Save-game integration: `isValidSaveBuffer() && !(flags & 0x1000)` →
`getSaveBlockSize` → serialize via `sub_101E8A20` into the save `FCFile` ⇒ the backlog persists
across save/load; flag `0x1000` therefore marks volatile/system messages excluded from saves (inferred
from the serialization gate).

The name-area print issued by `messageEngine` goes through `printEx` **without** the history bit
(`v11` lacks bit0), so the name is not recorded twice — the body container carries name+body together.

### 6.3 The parallel HTML log (`rdhCmdMessage`)

`cmdMessage` calls `RetouchSystem::rdhCmdMessage@0x100ED4F0(this, params[1], name, body)` **before**
`say`, independent of the print pipeline; it forwards to `RetouchDramaticHtml::htmlCmdMessage(this[10036])`.
Only in this path the overridden speaker name is wrapped in full-width parens:
FCString = `strings[0]` + `81 69` + registered name + `81 6A` (cmdMessage lines 185–196); the
registered-name path passes `*(charObj[33]+20)` unwrapped. This is the "drama log" HTML export, not
the in-game backlog.

### 6.4 Replay (backlog view)

- `printHistorySub@0x1005EC30` re-parses each stored body with the **same rich grammar** — xrefs to
  `81 73` ×3 and `81 74` ×2 — so replay reproduces fonts/colours/commands, not just plain text.
- View lifecycle: `printHistory@0x10067AB0` / `0x100681E0`, `drawHistory@0x1006B8D0` (paged draw);
  reveal via `TmAsyncPrintHistory::exec@0x1000EC70` with `tmInitPrintHistory@0x100994D0` /
  `tmExitPrintHistory@0x1009D280` — same async machinery as §3 on a separate slot/vtable.
- Helpers `backlog_0..3` @ `0x1013F010` / `0x101941A0` / `0x101952C0` / `0x10195D30`.

### 6.5 Implementer notes

Store `{msgId, charId, flags, nameBytes, bodyBytes}` verbatim; never strip markup at record time;
re-parse at draw time. Honour: `$dummy$` exclusion, `0A` separators, `0x1000` = do-not-persist,
ring capacity, and delayed-flush batching. The HTML log is a separate consumer fed pre-`say` with the
paren-wrapped name.

---

## 7. Voice and effect coupling

### 7.1 Effect-group lifetime (`cmdMessage` form B, `decomp_say_cmdMessage_fresh.txt` lines 200–255)

`v29 = strings[2].length != 0` (line 165). When set:

```c
group = new UxAsyncEffectGroup(0x2C);            // ctor sub_1018C130
group[+24] = LocalHolder; group[+28] = LocalPosCorrector;
group[+32] = SelectItemManager; group[+36] = RetouchSystem;
sub_101715E0(strings[2]);                        // compile CSV script into the group
RetouchSystem::svdAppendGroup(this, group);
(*(*(this[9814]) + 28))(this + 39256);           // kick (purpose unresolved)
this[987] /*+3948*/ = charId;                    // attribute running voice to character
RetouchAdvCharacter::say(charObj, params[1], lpString, body, params[2]&1, (int)v54,
                         a2[6], a2[7], a2[8], printParam, 2u);   // flags2 base = 2
this[987] = -1;                                  // restored after say returns
RetouchSystem::svdRemoveGroup(this, group);
```

⇒ **the effect group lives exactly as long as the blocking `say` call**; `PE[36]` bit1 (=2) marks
"voice/effect mode" downstream. `sub_101715E0` (the script compiler) was **not decompiled** — flagged (§10).

### 7.2 Script format (corpus evidence, `op28_markup_stats.txt`)

`strings[2]`: records separated by `0C`, fields by `3B` (CSV); voice entries plus animation entries
like `A.15[..].#1(15){2,-5}`; the sentinel `−12345` appears here too (same "keep/default" constant as
`POS`/`MOV`/`CH`, §2.2). These bytes never enter the text pipeline.

### 7.3 Voice start ordering and text coupling (`decomp_say.txt` line numbers)

1. Voice is fully set up **before** the print engine is called: `playVoice` at line 135 vs the
   `vtbl[+76]` printEngine call at line 213. ⇒ **voice starts when the message starts and runs
   asynchronously while the typewriter reveals text. There is no per-character audio sync and no
   mid-text voice cue — the grammar (§2) contains no voice command.**
2. Previous voice is cut first: `stopVoice(sys, (a6 & 0x10000000) ? −2 : −1)` (line 84; −1/−2
   semantics unresolved, flagged).
3. Lip-sync: `UxPlayVoiceParam[+0] = tmGetAnimationForLS(sys+648, this[61])` (lines 90–92) — a
   mouth-flap animation slaved to the voice channel ("LS" = lip-sync; **inferred**), suppressed when
   name == `"c"`, or `a6 & 0x10`, or `this[61] < 0`.
4. Volume: starts 256/256; `correctVoiceVolume(sys, charId, &vL, &vR)`; plus `correctVoice@0x10054F20`
   while `charMgr->isEnter(-1)` (position-based pan; lines 93–97).
5. Gating when voice started (`v31`): `PE[16] |= 0x20` (lines 136/199) → `printEngine` line 80:
   `v27 |= 0x10` → `messageEngine` computes `autoMessageWait` **only when `!(mode & 0x10)`** ⇒ in
   auto-play mode a voiced message does not get the `max(charWait×len, minWait)` timeout; it waits
   indefinitely (`v16 = −1` → `hitwait`), i.e. **auto-pacing defers to voice + user** (inferred).
   Also `sub_10077630(sys, 256)` when `!waitFlag && voice` (lines 77–79) — a voice-driven wait mode
   (inferred; not decompiled).
6. Ducking spans the whole message: music via `sreg(38)` — bits 0–6 target volume %, 8–15 fade-in
   ×10 ms, 16–23 fade-out ×10 ms, 24–30 restore % — `tmEnterMusicControl(sys[52], 0, 10×BYTE1, curL,
   curR, target)` before the print, `tmLeaveMusicControl` after it returns (lines 159–183, 217–222).
   Loop effects via `volumeLoopEffect(sys, 48, 48, 0, false, 16)` when `this[66] & 0x10` and voice
   active, restored after the print (lines 140–153, 215–216).
7. `leaveEnvVoiceEx(sys, −1)` immediately after the print returns (line 214).

### 7.4 What the VM observes

`cmdMessage` returns only after `say` returns = text revealed + `hitwait` satisfied + ducks restored +
`svdRemoveGroup`. The voice itself may still be playing past the message (async channel); it is
terminated by `stopVoice` at the start of the next voiced message. `this[987] = charId` during the
call lets the sound system attribute the running voice to the speaking character (**inferred**).

---

## 8. Worked examples (real `op28` records)

Source: `op28_examples2.txt` — a full sweep of the 310 shipped `.rld` files
(26,279 `op28` records), plus `op28_markup_stats.txt` and `corpus_bytescan.txt`.

### 8.1 Field distributions (whole corpus)

| field | observed values | reading |
| --- | --- | --- |
| `params[2]` (wait flag) | `1` ×26,244; `3` ×35 | bit0 = wait-for-player; bit1 set in only 35 records (§2.2 `W`) |
| `params[3]` (`a6`) | `0x20000001` ×26,279 | **invariant**: b0=1, b29=1, all other bits 0. Mute(b3), lip-sync-suppress(b4), byte1, nib16, b25, b26, b28 are never used by this title |
| `params[0]` (charId) | 3 ×6,022; 1 ×4,978; 7 ×3,292; 5 ×3,174; 4 ×2,959; 6 ×2,878; 8 ×2,864; then 11 ×36, 13 ×26, 10 ×19, 12 ×13, 14 ×12 | the seven main ids carry 99.6 %; ids ≥ 10 are side characters |
| string count | 2 ×24,762; 3 ×1,517 | a third string means voice/effect script (§7.2) |
| body length | min 1, max 138 bytes | the 1-byte bodies are all `test2.rld` filler (§8.7) |

Two consequences for the port: `a6` can be validated rather than interpreted
(any record with bits outside `0x20000001` is either a different title or a
mis-parse), and the voice path is exercised by 5.8 % of messages — frequent
enough that it cannot be stubbed out.

### 8.2 Typical voiced message (the dominant shape)

```
6_011_01_hinata.rld  rec#13/207  hdr=0x530E001C  op=28  pcount=14  scount=3
PARAMS [7, 16080, 1, 536870913, 0,0,0, 1073741824, -1,-1, 0,0,0, -1]
strings[0] len=1   hex=2a
                   -> "*"  => no override: use the registered name (§1.4)
strings[1] len=58  hex=a1b0 b2bbcbb5d5e2d0a9c1cba3ac ced2d6aec7b0becdbadcbac3c6e6
                       a1ad a1ad c0cfb8e7bacdd0a1cff2 a3ac d3d0d7f6b9fdb0aec2f0 a3bf a1b1
                   -> “不说这些了，我之前就很好奇……老哥和小向，有做过爱吗？”
strings[2] len=23  hex=322c35312c322c302c302c383835362c302c302c302c30
                   -> "2,51,2,0,0,8856,0,0,0,0"   voice script (§7.2)
charId=7  msgId=16080  wait=1  a6=0x20000001
```

What the engine does with it: `cmdMessage` → `rdhCmdMessage` (HTML log, §6.3) →
`playVoice` (§7.3 step 1) → `say` → `printEx` with `a6&1` set, so the body is
recorded in the backlog (§6.1) → typewriter at `charWait = sreg(sreg(15)+5)` ms
per char (§3.2) → `hitwait` blocks until the player advances, because
`params[2]` bit0 is set and the voice suppresses the auto-play timeout (§7.3
step 5). The full-width quotes `a1b0`/`a1b1` and ellipses `a1ad` are ordinary
GB18030 double-byte characters — **not** control codes.

### 8.3 Speaker-name override (175 records)

```
1_001_07_com.rld  rec#192/412  hdr=0x520E001C  op=28  pcount=14  scount=2
PARAMS [4, 503, 1, 536870913, 0,0,0, 1073741824, -1,-1, 0,0,0, -1]
strings[0] len=4  hex=c8abd4b1            -> 全员   ("everybody")
strings[1] len=14 hex=a1b0 ced2bfaab6afc1cba1a3 a1b1
                                          -> “我开动了。”
charId=4  msgId=503
```

`strings[0] != "*"` replaces the registered speaker name in the name area
(§1.4), and only the HTML log wraps it in full-width parens `81 69 … 81 6A`
(§6.3). Other overrides in this class: `d3a4` 樱, `d1f4b4ba` 阳春, `c0edcfe3`
理香 — i.e. the override is used for narration labels and for a character
speaking under a different credit, never for markup.

### 8.4 Multi-entry voice/animation script

```
8_001_01_zakuro.rld  rec#123/195  hdr=0x530E001C  op=28  pcount=14  scount=3
strings[1] len=134 -> “所以，我就开始不断地进行训练，……为了能够再次看到兄长大人高潮时的表情。”
strings[2] len=133 -> "2,37,11,0,2,8569,0,11,8,5,0,-12345,9,-1,-1,-1,-12345,-12345,-12345"
                      0C                                       <- record separator
                      "2,37,11,0,2,7029,0,11,8,6,3,-12345,9,-1,-1,-1,-12345,-12345,-12345"
```

Two `0C`-separated entries in one message: one voice plus one animation cue.
`−12345` is the same "keep/default" sentinel the `POS`/`MOV`/`CH` commands use
(§2.2), which is how we know the script compiler shares the constant pool with
the text grammar. None of these bytes ever reach the print engine (§7.2).

### 8.5 ASCII punctuation inside GB text is literal, never markup

```
6_007_01_hinata.rld  rec#78/178   strings[1] hex=… a1b6 d0a1be abc1e9 3a f3aff2eb a1b7 …
                                  -> 《小精灵:蟑螂》      (ASCII ':' = 0x3a)
8_011_01_zakuro.rld  rec#70/134   strings[1] hex=… 32 25 …
                                  -> 大概有2%的概率吧。   (ASCII '%' = 0x25)
```

Both bytes are inside the argument position of a `<word>:<arg>` grammar that
only starts after `81 74` (§2.2). Because no corpus body contains `81 73` or
`81 74` at all (§2.4), a `:` or `%` in a body is just text. **A parser that
tokenises on ASCII punctuation without first seeing the introducer will corrupt
these lines** — this is the single most likely porting bug in §2.

### 8.6 `test.rld` is cp932 content inside a cp936 title

```
test.rld  rec#4/307  strings[1] len=40
hex=834d 8389 834d 8389 82c6 8b50 82ad 91be 977a 82cc 89ba 8141 8e47 9190 82f0 8ee6 82e8 8f9c 82ad 8142
decoded as cp932 -> マロマロと輝く太陽の下、雑草を取り除く。
decoded as GB18030 -> 僊儔僊儔偲婸偔懢梲偺壓丄嶨憪傪庢傝彍偔丅   (mojibake)
```

139 such records survive in the shipped data. The vendor decodes with the
process ANSI code page, so on this title (936) these lines render as mojibake
**in the original game too**. The port must reproduce that, not repair it: it
is the evidence base for code-page-aware MBCS stepping and for the census result
that 936 yields zero lead-byte/delimiter hazards while 932 yields 91.

### 8.7 Degenerate records

`test2.rld` rec#19..23 (and neighbours) carry `strings[0] = strings[1] = 2a`
("*"): a one-byte body with no override. `say` still runs the whole pipeline —
history entry, typewriter with one character due, `hitwait` — so an
implementation must not special-case empty/1-byte bodies into skipping the
blocking wait. These are the records that make the corpus sweep a useful
crash test.

### 8.8 The definitive negative result

Across 26,279 bodies (and 26,279 name strings): **zero occurrences of any
control byte** — no `81 73`, no `81 74`, no `81 90 82 6d`, and the only
in-text control code that ever appears is `0A` (§2.4, `corpus_bytescan.txt`).
The rich grammar of §2 is therefore real engine capability that this title
never exercises. The `text` component must implement it (other ExHIBIT titles
do use it) but its acceptance cannot come from this corpus: §9 pairs every
grammar rule with a synthetic record instead.


---

## 9. Recommended C++ design (`text` component in `aetherkiri::exhibit`)

### 9.1 Component shape

One component, discovered by name like every other module in the package:
`include/exhibit_text.h`, `src/exhibit_text.cpp`, `tests/text_test.cpp`. The
orchestrator declares `text` in `AETHER_EXHIBIT_COMPONENTS` before the work
starts; the implementing agent must not edit `CMakeLists.txt`. Namespace
`aetherkiri::exhibit`, 4-space indent, 80 columns, `#pragma once`,
trailing-underscore members, no license header.

The component is **pure computation plus one platform backend**. It never
touches the VM, the file system or the host ABI directly: `Game` (the `game`
component) owns it and drives it from `tick`.

### 9.2 Pipeline

```
raw MBCS bytes (name, body)                 <- VmHost::message / backlog (§1, §6)
  -> PlaceholderSub                          81 90 82 6d -> last speaker (§2.1)
  -> MarkupParser                            byte cursor, code-page aware (§2)
  -> std::vector<StyledRun>                  text run + style + command effects
  -> LineBuilder                             kinsoku, push-back, ruby (§4.2, §4.5)
  -> Paginator                               4 directions, page/scroll mode (§4.3)
  -> GlyphSource (FreeType backend)            metrics + bitmap (§5, §9.6)
  -> TextSurface                             RGBA8 tile handed to the compositor
  -> Typewriter                              reveal cursor over the laid-out page (§3)
```

Every stage is a separate type with a narrow interface, so each can be tested
against cached vendor behaviour without the stages above it.

### 9.3 Byte-level rules (must hold, cited)

- Scan with the committed code-page-aware cursor (`ByteCursor` + `MbcsPage`,
  `DefaultMbcsPage`), never with a fixed 932 assumption: §8.6 is the proof case,
  and the census result (932 → 91 hazards, 936 → 0) is exactly what a wrong page
  costs.
- Compare decoded characters, not bytes, for the two control sequences:
  `0x8173` block delimiter and `0x8174` command introducer (§2.1, mirroring
  `cmp eax, 8174h` @ `0x10069732`). Under page 936 those byte pairs decode to
  different characters, which is why the vendor's own MBCS decode
  (`sub_101C0890`) sits in front of the compare.
- `0A` is the only in-text control byte (§2.4). Everything else is text: an
  ASCII `:` or `%` outside an introducer is literal (§8.5).
- Keep bytes raw end to end. Transcode to UTF-8 only where a string leaves the
  core (logs, host API), via `exhibit_encoding`.

### 9.4 Style and command state

A single `TextStyle` value object carried across runs: font id, height, colour,
alignment bits (`0x200`/`0x2000`, §4.4), kinsoku enable (§4.5), ruby pending
(§4.7). Commands mutate a copy that becomes the run's style, so a run list is
replayable and diffable in tests. Command coverage: `C P L U I W S T E V CH POS
MOV`, unknown word → the type-1 link path (§2.2) — implemented as
"log once, count, treat as no-op", because its semantics are inferred (§10).

### 9.5 Layout

- Line builder reproduces `sub_10233E20`: token loop, per-char advance, kinsoku
  push-back at line end with the pending count re-committed on the next line
  (`+400` field, §4.1).
- Paginator reproduces `sub_10231980` for all four direction cases and the two
  overflow modes: page mode `0x1000` → clear + beep + log (**no page-break
  control code exists**, §4.3), scroll mode → `sub_10230640`.
- Integer arithmetic only. The vendor's stored cell is `gmCellIncX + 4` and the
  layout step adds nothing on top of it (§5.2); a float accumulation here shifts
  line breaks and is the classic silent divergence.

### 9.6 Glyph backend

`GlyphSource` is an abstract interface with two members — `metrics(codepoint,
style)` and `rasterize(codepoint, style, surface, x, y)` — plus one shipped
backend, `FtGlyphSource`, built on **FreeType** (vcpkg port `freetype`, CMake
package `freetype`, target `Freetype::Freetype`).

**GDI is not used, and must not be.** The vendor measures and rasterizes through
GDI (§5), but GDI is Windows-only and the port has to stay cross-platform.
FreeType is not a new kind of dependency for this product either: Godot's text
server uses it, and the ONScripter runtime already pulls it in through SDL2_ttf.

- Font source: the title's own `res/font/imopara3.ttf`. Verified from its sfnt
  table directory: 21 tables including `glyf`, `loca`, `hmtx`, `cmap`, `kern`,
  `GSUB`, and **no `CFF `**. Load it with `FT_New_Face` (path, or a memory buffer
  if the host already read the bytes) and size it with `FT_Set_Pixel_Sizes` at the
  style's em size. This is arguably *better* fidelity than the vendor's own path:
  `RESIDENT.CNS` asks GDI for `SimHei`/`SimSun` **by name**, so the original's
  metrics depend on whichever system font happens to match, while ours are fixed
  by the file the title ships.
- Fallback when a title ships no font: a host-configured font path. FreeType reads
  CFF/OTF as well as TTF/TTC, so the bundled `aetherkiri-runtime-cjk.otf` **is** a
  usable fallback — worth having, because a TTF-only rasterizer would leave such a
  title with no glyphs at all (§10 R9).
- Metrics: `face->glyph->metrics.horiAdvance` in 26.6 fixed point, converted with
  `>> 6` after rounding, or `FT_Get_Advance` for the unscaled value scaled by
  `size->metrics.x_scale`. Integer only (§9.5). The backend reports raw
  advances: the vendor's cell padding lives inside the stored cell (§5.2), so
  neither the backend nor the layout stage may add a second margin.
- Rasterization: `FT_Render_Glyph` with `FT_RENDER_MODE_NORMAL` (8-bit
  anti-aliased coverage), blitted as alpha using `glyph->bitmap_left` /
  `bitmap_top` for the pen offset. Load flags: start from `FT_LOAD_DEFAULT` and
  record the choice — the vendor's GDI output was hinted, so if small CJK sizes
  read soft, compare `FT_LOAD_DEFAULT` against `FT_LOAD_NO_HINTING` in the visual
  acceptance step rather than tuning silently.
- Codepoints: `FT_Get_Char_Index` on the *decoded* character. Bodies are MBCS
  (§9.3), so decode with `exhibit_encoding` first; the vendor's ANSI GDI calls did
  the same conversion inside the API.
- A per-`(face, size, codepoint)` cache of advance plus bitmap: the message window
  re-draws every frame, and the vendor likewise rasterizes each character once per
  style change.
- The `FT_Library` handle is created once per process and owned by the backend;
  FreeType is not thread-safe across a shared face, so the backend is documented
  single-threaded — which matches §9.7, where all text work happens on the host
  tick thread.

Consequence to accept, stated plainly: our advances come from the shipped font
through FreeType, the vendor's came from GDI's `gmCellIncX` on a system font, so a
line break can land one character earlier or later than in the original. That is a
deliberate trade — portability over pixel identity — and it is why the golden
layout tests (§9.8 item 3) assert against metrics captured once from *our* backend
into a fixture, never against numbers measured from the vendor.

### 9.7 Typewriter, blocking and history

- `Typewriter` reproduces `TmAsyncPrint::exec` (§3.2): `charsDue = elapsed /
  charWait`, `charWait = sreg(sreg(15)+5)` ms and first-line-only, instant on
  Ctrl or a decide-key held > 200 ms, instant when skip is active. It takes a
  clock function, so tests drive it deterministically.
- **Blocking belongs to `Game`, not here.** The vendor blocks inside
  `tmExitPrint(INFINITE)`; in this port the VM thread blocks in
  `VmHost::message` and `TextEngine` only reports "reveal complete, waiting for
  advance". This keeps the component free of threads and matches the runtime
  glue design.
- `History` is a fixed-capacity ring of `{msgId, charId, flags, nameBytes,
  bodyBytes}` stored **verbatim with markup** (§6.2); `0x1000` marks
  do-not-persist; `$dummy$` messages are never recorded; `0A` separators between
  entries; delayed-flush batching preserved as an explicit `flush()` call.
  Replay re-parses through the same `MarkupParser` (§6.4) — there is no second
  parser.
- The HTML drama log (`rdhCmdMessage`, §6.3) is a separate optional consumer fed
  before `say`, with the paren-wrapped name. Phase 3.

### 9.8 Testing

1. **Corpus sweep** (gated on `AETHERKIRI_EXHIBIT_GAME`): parse all 26,279
   bodies and names from the 310 `.rld` files, assert zero parse failures, zero
   control bytes seen, and that every body round-trips byte-identically through
   parse → run list → re-emit. This is the crash test §8.7 asks for.
2. **Synthetic grammar records**: because the corpus never uses the rich grammar
   (§8.8), each command in §2.2 gets a hand-built record asserting the run list
   and style deltas, including the unknown-word/type-1 path and the
   `81 90 82 6d` placeholder substitution.
3. **Golden layout**: fixed style + fixed fake glyph metrics (advance = N) →
   assert exact line break offsets, push-back behaviour, kinsoku cases for both
   pages, and both overflow modes. Fake metrics keep these tests
   backend-independent and machine-independent.
4. **Font and metrics fixture** (needs the title's font, so gated on
   `AETHERKIRI_EXHIBIT_GAME` like the corpus sweep): load
   `res/font/imopara3.ttf` through `FtGlyphSource`, assert it initializes, then
   assert a captured fixture of advances for a fixed character set at a fixed
   size — including that the stored cell carries the vendor's `+4` padding (§5.2)
   exactly once while the layout step adds nothing. The fixture is what catches
   a font substitution or a rasterizer
   upgrade silently moving every line break.
5. **Typewriter timing** with a fake clock: reveal schedule, first-line-only
   charWait, instant-on-Ctrl, skip.
6. **History semantics**: ring eviction, `0x1000` exclusion, `$dummy$`, `0A`
   separators, delayed flush, replay re-parse.
7. **Visual acceptance**: render one real message (with its registered speaker
   name) into an RGBA surface, write a PNG with the dependency-free writer
   `scene_test.cpp` ships, and **read the image** — upright, correct channels,
   correct colour, name area not double-recorded (§6.2).

`EXHIBIT_CHECK_EQ` is integer-only; strings need `EXHIBIT_CHECK_STR_EQ`. Zero
`/W4` warnings; style gate `FMT=0` on the component's own files only (never run
clang-format over `.py` or generated tables).

### 9.9 Phasing

- **Phase 1** (needed for the first playable acceptance): parser, run list, line
  builder, paginator, `FtGlyphSource`, `TextSurface`, `Typewriter`, `History`
  record + replay, tests 1–4 and 7.
- **Phase 2**: scroll mode, ruby (§4.7), frame/window selection (§4.6, still
  partially unresolved), kinsoku set extension decision (§10 R8).
- **Phase 3**: HTML drama log, voice/ducking coupling (§7) behind host audio
  seams, lip-sync.

### 9.10 Non-goals

No UTF-8 conversion inside the core, no `std::filesystem` (paths are joined by
byte, as everywhere else in this package), no threads inside the component, no
repair of mojibake (§8.6), and no re-implementation of the print engine's
blocking wait (§9.7). FreeType is the component's one third-party dependency,
declared in the manifest (§9.6); nothing else is vendored or linked, and no
platform text API may be used.


### 9.11 Measured FreeType baseline

Captured on the development machine with FreeType 2.14.3 against the title's own
`res/font/imopara3.ttf`, so the backend has real numbers to assert instead of
guesses. Face: family `imop`, style `Regular`, 1 face, 48145 glyphs,
units_per_em 1000, ascender 880, descender -120, height 1000, kerning present,
charmap present. A coverage probe over ASCII, hiragana, katakana, three kanji,
fullwidth punctuation, ideographic space and ellipsis found **no missing
glyphs** — worth stating, because a hole in the cmap would drop characters
silently instead of failing.

Advances in pixels, `(horiAdvance + 32) >> 6` after `FT_Load_Char(...,
FT_LOAD_DEFAULT)`:

| codepoint | 16px | 20px | 24px |
|---|---|---|---|
| U+0041 `A` | 8 | 10 | 12 |
| U+004D `M` | 8 | 11 | 12 |
| U+0030 `0` | 8 | 10 | 12 |
| U+3042 | 16 | 20 | 24 |
| U+30AB | 16 | 20 | 24 |
| U+6B21 | 16 | 20 | 24 |
| U+59B9 | 16 | 20 | 24 |
| U+50D5 | 16 | 20 | 24 |
| U+FF01 | 16 | 20 | 24 |
| U+3000 | 16 | 20 | 24 |
| U+2026 | 16 | 19 | 23 |

Size metrics (`face->size->metrics`, `>> 6`): at 16px ascent 15, descent -2,
height 16, max_advance 48; at 20px 18, -3, 20, 60; at 24px 22, -3, 24, 72.
Rendering was verified as well: U+59B9 at 24px gave a 24x22 8-bit bitmap,
`pixel_mode` 2, `bitmap_left` 0, `bitmap_top` 20.

Two facts here shape the layout code. Every CJK advance equals the pixel size
exactly, so columns stay aligned with no correction factor, and the vendor's cell
padding (§5.2) is a property of the stored cell rather than of the metrics: the
backend reports raw advances and the padding is applied once, at store time. And
the rounded advances are already integers, so the integer-only rule of §9.5 costs
no precision.

These numbers are a reference, not the fixture. The fixture is written by the
component's own test (§9.8 item 4), so a FreeType upgrade or a different font
surfaces as a diff rather than as broken layout.

---

## 10. Risk register

Status key: **open** = needs more evidence before the port can trust it;
**decision** = evidence is complete but the port must choose a behaviour;
**closed** = settled by decompilation and/or corpus.

| id | risk | what we know | impact if wrong | status |
| --- | --- | --- | --- | --- |
| R1 | Unknown command word → "type-1 link" | §2.2: an unrecognised `<word>` after `81 74` takes a distinct path that stores a link-like entry; body not decompiled | A title using links renders garbage or crashes | open — decompile the type-1 branch of `printEx@0x100693E0` |
| R2 | `W` / `S` style-bit mapping | Both commands set style bits, but which bit maps to which visual attribute is not resolved (§2.2) | Bold/size/colour emphasis wrong; layout width changes → different line breaks | open — read `sub_1022C680` (`styleset`) against `printEx`'s W/S cases |
| R3 | `params[3]` bits 0 and 29 | Invariant `0x20000001` in all 26,279 records (§8.1). **b0 resolved**: consumed in `printEngine@0x101B12E0` lines 57–78 as the area-driven name-display gate (`(MessageArea[26]>>20)&3` → always / on-speaker-change / name+clear; see §1 `a6` table). **b29 still open**: not read by `say`/`printEngine`/`messageEngine` | Silent behaviour difference on other titles | partially closed — trace remaining `a6` consumers (save/seen systems) for b29 |
| R4 | `GetGlyphOutlineA` `fuFormat {1,5}` | Verified at instruction level (§5.2) but does not match the documented `GGO_*` combination | Advance/bitmap interpretation off by a constant → every line break shifts | open — confirm against the metrics consumer, not the call site |
| R5 | `L` command argument split | Partially decoded (§2.2): the argument list split is incomplete | Line-spacing/position command mis-parsed | open |
| R6 | `stopVoice(−1)` vs `stopVoice(−2)` | Selected by `a6 & 0x10000000` (§7.3 step 2); semantics of the two codes unresolved | Voice cut too early/late; overlapping voices | open — cheap: decompile `stopVoice` |
| R7 | Effect-group kick + script compiler | `(*(*(this[9814]) + 28))(this + 39256)` purpose unresolved; `sub_101715E0` (CSV → `UxAsyncEffectGroup`) never decompiled (§7.1) | Animation/lip cues dropped; voice script fields misread | open — highest-value remaining target, 1,517 records use it |
| R8 | Kinsoku set is cp932-only | Default set @ `0x104253A0`, membership by `_mbschr`; GB punctuation (`a1xx`) is **not** in it (§4.5) | A GB-aware implementation breaks lines where the vendor does not (or vice versa) | **decision** — reproduce the cp932 set verbatim; do not "improve" it for GB. Record the divergence in the component README |
| R9 | Font and metric dependence | The vendor measured through GDI against a *system* font named in `RESIDENT.CNS` (`SimHei`/`SimSun`); we rasterize the title's own `res/font/imopara3.ttf` with FreeType (§5.4, §9.6) | Advances differ from the original, so a line break can move by a character; and a title that ships no font at all needs a host-configured fallback path | **decision** — cross-platform beats pixel identity: `FtGlyphSource` behind `GlyphSource`, layout golden tests use fake metrics, and a captured advance fixture (§9.8 item 4) pins the real backend. FreeType reads CFF/OTF as well as TTF, so the bundled `aetherkiri-runtime-cjk.otf` is a valid fallback; a host-TextServer backend could replace it later without touching layout |
| R10 | Rich grammar never exercised by this title | Zero control bytes in 26,279 bodies (§8.8, §2.4) | Parser bugs in `81 73`/`81 74` handling would ship undetected | **closed as a method** — grammar correctness rests on decompilation plus synthetic records (§9.8 item 2); do not claim corpus validation for it |
| R11 | Auto-play pacing on voiced messages | `autoMessageWait` is computed only when `!(mode & 0x10)`, so a voiced message in auto mode waits indefinitely (§7.3 step 5) | Auto-play stalls forever, or races ahead of the voice | open (inferred) — confirm `sub_10077630(sys, 256)` |
| R12 | Lip-sync attribution | `tmGetAnimationForLS(sys+648, this[61])` and `this[987] = charId` around `say` (§7.3 step 3, §7.4) | Mouth flaps on the wrong character or not at all | open (inferred) |
| R13 | History ring capacity | Ring lives at manager+116, node = 11 dwords copied by `sub_1004E9F0`; capacity value never extracted (§6.2) | Backlog truncates at the wrong point; save-block size differs | open — one read of the ring constructor |
| R14 | Frame / window selection | **Largely resolved** (`printEngine@0x101B12E0` lines 39–47, 95–120): the print area comes from `findMessageArea(this, sreg(14)==255 ? 255 : sreg(14), false)` — i.e. **system register 14 selects the message area**, not `params[1]` (which is the msgId/voice key). When `printParam[5] ≥ 0`: `MessageArea[117] = printParam[5]`, `[118] = 138`, `[119] = 139`, `[120] = 141` — **LID_MESSAGE = 138 confirmed in-binary**, with the intelligent-name area drawn/cleared on layer 138 (`sub_10226910(138)`, `sub_10215D50(138, 255)`). Remaining open: the `RetouchMessageParam` table contents (per-area rect/pitch/flags setup in `messageFrame@0x101730C0`) | Text drawn into the wrong window/layer | partially closed — dump the message-area table via `messageFrame` if per-area geometry is needed |
| R15 | Ruby | §4.7: the mechanism is identified, the metrics path is not | Ruby text mis-positioned (rare in this corpus) | open, low priority (phase 2) |
| R16 | cp932 leftovers in a cp936 title | `test.rld`'s 139 records are cp932 and render as mojibake in the original game (§8.6) | A "helpful" implementation auto-detects and fixes the page, diverging from the vendor and breaking the 932/936 hazard census | **decision** — decode with the title page only; never auto-detect per record |
| R17 | Save-persistence flag `0x1000` | Inferred from the serialization gate `isValidSaveBuffer() && !(flags & 0x1000)` (§6.2) | Volatile/system messages leak into saves, or real messages are dropped | open (inferred) — cross-check with the save spec's `saveEngine` chain |
| R18 | Name area double-recording | `messageEngine` prints the name through `printEx` **without** the history bit, so only the body container carries name+body (§6.2) | Speaker name appears twice in the backlog | **closed** — asserted by §9.8 item 7 |

### 10.1 Suggested order for the next IDA session

Cheapest closures first, all by address (see `ida_status.md`): R6 `stopVoice`,
R13 ring ctor, R2 `sub_1022C680`, R4 metrics consumer, then R7 `sub_101715E0`
(the largest and the only one that blocks phase 3).

### 10.2 Errata corrected during implementation (2026-10-03)

The phase-1 implementation cross-checked every number it consumed and found five
places where this document was wrong. All five are corrected inline above; they
are listed here with their evidence so a future reader can see what changed and
why, and so the corrections survive a rewrite of any single section.

1. **Stored cell and layout step** (§5.2 item 2, §9.5, §9.6, §9.8 item 4). The
   stored cell is `gmCellIncX + 4` and the line builder's step adds nothing on
   top. The earlier "+2 applied at layout" reading double-counted the padding,
   which would have drifted every line break. Verified in `sub_10230960` and
   `sub_10233E20`.
2. **Height source** (§5.2 item 2). The height dword reads `*(otm + 4)` =
   `otmTextMetrics.tmHeight`, not `otmAscent`: OUTLINETEXTMETRIC's first member
   is `otmSize`, so the TEXTMETRIC — and with it `tmHeight` — begins at byte 4.
3. **Default kinsoku set** (§4.5). The byte range is `0x104253A0–0x1042546C`; the
   first dump stopped one byte early and thereby dropped the closing `81 F4`
   pair.
4. **The greedy swallow** (§2.1). Because everything after `81 74` up to the next
   `81 73`/`81 74`/end is `<word>[:<arg>]*`, plain text immediately following a
   command is consumed as that command's last argument. The corpus cannot show
   this (zero control bytes in 26,279 bodies), so it is pinned by a synthetic
   assertion instead (§9.8 item 2).
5. **Where the MBCS helpers live.** `ByteCursor` and `MbcsPage` are owned by
   `exhibit_vm_str.h`, not `exhibit_encoding.h`; the component follows the header
   that actually owns them.

Two behaviours remain **inferred** and are named as such so nobody mistakes them
for reversed fact: `clear2`'s pen reset on overflow, and `sub_10231DE0`'s extent
being the pen travel. Both are implemented as documented and both carry comments
naming the inference.

---

**Document status: §1–§10 complete, with the §10.2 errata applied.** Sections 1–7
were produced by the reverse-engineering agent from ~100 cached decompilations
against the rebuilt database; sections 8–10 were written by the orchestrator from
the same caches plus the full-corpus sweep `op28_examples2.txt` after the agent's
session was lost to upstream provider faults; §10.2 records the corrections the
phase-1 implementation forced. Evidence files are named inline throughout.
