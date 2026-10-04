# ExHIBIT Script VM — Implementation Specification

Target: `resident.dll` (imopara3 / ExHIBIT engine), image base `0x10000000`. All addresses below are EAs in that image.
Status legend: **[SETTLED]** = verified from decompilation/disassembly/bytes this analysis; **[INFERRED]** = reasoned, evidence given; **[GAP]** = unresolved, see Risk Register (§10).

Companion on-disk evidence (temp dir `C:\Users\wolfp\AppData\Local\Temp\opencode\`): `decomp_*.txt` / `decomp_h_*.txt` / `decomp_x_*.txt` (cached decompilations), `disasm_liteExec.txt`, `disasm_liteSetReg.txt`, `disasm_liteCalcReg.txt`, `disasm_cmdBillboard.txt`, `disasm_cmdExHIBITMain.txt`, `disasm_calcExpression.txt`, `disasm_calcFunction.txt`, `disasm_liteStr2Value.txt` (disassembly dumps), `corpus_census.json` + `samples_out.txt` (per-opcode stats + real samples), `method_table_ea.json`, `gen_op_table.txt` (merged §2 source), `gen_exhibitmain_cases.txt` (op11 sub-case map), `vm_spec_notes*.md` (raw lab notebooks).

The `.rld` **container** is already implemented and settled — see `packages/AetherExhibit/include/exhibit_rld.h` in the AetherKiri repo. This spec does not re-derive it; it starts where the container ends: the in-memory record array, the dispatch tables, and the interpreter semantics.

> **READ §11 ERRATA BEFORE IMPLEMENTING ANYTHING.** The body below was written
> from decompilation alone. Four components have since been built from it
> (`vm_str`, `vm_reg`, `vm_expr`, `vm_cond`) plus the `encoding` codec, and
> re-reading the disassembly line by line to make them work corrected 23 claims
> here — including the text encoding of the entire scenario corpus, which is not
> cp932. **§11 supersedes the body wherever the two disagree.**

## 1. Dispatch tables

Three dispatch layers, all resolved per record inside `liteExec` @0x101B6590:

1. **Inline switch** @`jumptable 0x101B688C` — 13 opcodes handled directly in the interpreter loop (no table): **5, 11, 12, 13, 17, 20, 21, 22, 23, 24, 28, 140, 191** (§3.1). These are the ADV-loop control records (labels, message, jumps, gosub/return, scenario change, autosave, question, end, meta/action).
2. **Method table** — 287 function pointers at `this + 35752 (0x8BA8)`, built once by `RetouchSystem::createMethodTable` @0x101A9710 (decomp_createMethodTable.txt): `memset32(this+35752, cmdDummy, 0x11F)` (287 slots, filler `cmdDummy` @0x100E4060 = `retn`), then 221 explicit assignments. Default dispatch: `opcode ≤ 286` → `call [esi+opcode*4+0x8BA8]` with `(CMD_DATA&, LocalHolder&, this+0x9024, SelectItemManager*)`; `opcode > 286` → **silent skip** (`ja` over the call, 0x101B7285). Unassigned slots within 0..286 → cmdDummy no-op.
3. **Action table** — 400 function pointers at `this + 37352`, built by `createActionTable` @0x101B5A40 (decomp_createActionTable.txt), lazily (only when `this[9338] == 0`), filler `actionDummy`. Reached **only via inline op191** (`cmdAction`): action number = `str2int(tok[0])`, remaining tokens = args. Handler symbols are generic (`action000`…`action370`); semantics mostly un-reversed (corpus uses only action 291, ×49 records; `action095` @0x100E5510 previously identified as a select-item/retouch helper).

**Method table — complete assignment map** (opcode → handler; every unlisted opcode 0..286 = `cmdDummy`). EAs for the 86 corpus-used ops are in §2; the full name→EA list is `method_table_ea.json`.

```
1 cmdDirect            6 cmdSetReg(R)       7 cmdCalcReg         8 cmdSetReg(S)
10 cmdSetReg(T)        18 cmdFrameView      19 cmdCtrlView       29 cmdRetMessage
30 cmdClearMessage     32 cmdEnterCharacters 33 cmdLeaveCharacters 34 cmdPrepareMoveCharacters
35 cmdExecMoveCharacters 36 cmdExitMoveCharacters 37 cmdEnterCharacter 38 cmdLeaveCharacter
39 cmdMoveCharacter    40 cmdDefConfig      41 cmdDefSave        42 cmdDefLoad
43 cmdDefLog           44 cmdDefCtrl        45 cmdPreCache       46 cmdDefSelect
48 cmdCreateCharacter  49 cmdDefCharacter   50 cmdPlayMusic      51 cmdStopMusic
52 cmdPlayEnv          53 cmdStopEnv        54 cmdPlayLoop       55 cmdStopLoop
56 cmdPlaySE           57 cmdStopSE         58 cmdPlaySyncSE     59 cmdSetVolume
60 cmdWaitFadeVolume   61 cmdCreateDbInt    62 cmdGetDbInt       63 cmdSetDbInt
64 cmdDefCtrl2         65 cmdUserDialog     66 cmdDefDialog      67 cmdDefHelp
68 cmdDefDebugMessage  69 cmdDbgRegView     70 cmdDefEnv         71 cmdDefDebug
72 cmdSetMessageFrame  73 cmdDefMessageArea 74 cmdDraw           75 cmdDrawLayer
76 cmdDrawZoom         78 cmdFadeOutEvent   79 cmdPrepareClip    80 cmdClip
81 cmdEnterClip        82 cmdLeaveClip      83 cmdReleaseClip    84 cmdEnterHandycam
85 cmdLeaveHandycam    86 cmdCtrlHandycam   87 cmdEnterBlur      88 cmdLeaveBlur
90 cmdCtrlSelectItem   91 cmdPrepareSelectItem 92 cmdExecSelectItem 93 cmdExitSelectItem
94 cmdBillboard        95 cmdRemoveBillboard 97 cmdStill          98 cmdEnterStill
99 cmdLeaveStill       100 cmdEnterMove     101 cmdLeaveMove     102 cmdEnterBlink
103 cmdLeaveBlink      105 cmdEnterFade     106 cmdLeaveFade     107 cmdDefKey
108 cmdLocalPosCorrect 109 cmdDefKey1       110 cmdEnterMask     112 cmdPlayVideo
113 cmdEnterMovie      114 cmdLeaveMovie    115 cmdViewAnimation 116 cmdEnterAnimation
117 cmdLeaveAnimation  118 cmdInitAnimation 119 cmdExecAnimation 120 cmdExitAnimation
121 cmdPrepareAnimations 122 cmdNextAnimation 123 cmdAppendAnimations 125 cmdSpeedAnimation
126 cmdPauseAnimation  127 cmdRestartAnimation 128 cmdInitWeather 129 cmdPrepareWeather
130 cmdExecWeather     131 cmdExitWeather   132 cmdCgMode        134 cmdEnterClipView
135 cmdLeaveClipView   136 cmdQuake         138 cmdCtrlLayer     139 cmdInputLayerControl
141 cmdInitFire        142 cmdPrepareFire   143 cmdCtrlFire      144 cmdExecFire
145 cmdExitFire        147 cmdInitRaster    148 cmdExecRaster    149 cmdExitRaster
150 cmdParamRaster     151 cmdInitParax2    152 cmdPrepareParax2 153 cmdExecParax2
154 cmdExitParax2      155 cmdCtrlParax2    157 cmdPrepareMirror 158 cmdExecMirror
159 cmdExitMirror      160 cmdCreateClipper 161 cmdSetClipper    162 cmdDestroyClipper
163 cmdInitFirefly     164 cmdPrepareFirefly 165 cmdExecFirefly  166 cmdExitFirefly
167 cmdSetColorFilter  168 cmdInitColorFilter 169 cmdPrepareColorFilter 170 cmdExecColorFilter
171 cmdExitColorFilter 172 cmdPrepareEvaporation 173 cmdExecEvaporation 174 cmdExitEvaporation
175 cmdInitFireworks   176 cmdCtrlFireworks 177 cmdExecFireworks 178 cmdExitFireworks
179 cmdCreateCamera    180 cmdPrepareCamera 181 cmdEnterCamera   182 cmdLeaveCamera
183 cmdDestroyCamera   184 cmdEnterMesLink  185 cmdLeaveMesLink  186 cmdSetCamera
187 cmdClearCamera     188 cmdCorrectCharacter 189 cmdSetDoneFlag 190 cmdSetSystemSound
192 cmdTKStart         193 cmdTKCheck       194 cmdTKControl     195 cmdDefCryptKey
196 cmdSnapshot        197 cmdCreateOverlay 198 cmdDestroyOverlay 199 cmdDrawOverlay
200 cmdCtrlOverlay     203 cmdPrepareView   204 cmdShowView      205 cmdSelectView
206 cmdDestroyView     207 cmdRemoveView    208 cmdCreateDB      209 cmdGetDB
210 cmdSetDB           211 cmdSetLoadMask   212 cmdInitTransform 213 cmdPrepareTransform
214 cmdExecTransform   215 cmdExitTransform 216 cmdEnterTransform 217 cmdLeaveTransform
218 cmdDummy (explicit) 219 cmdFrameControl 220 cmdLayout        221 cmdSetHitwaitMark
222 cmdSetCursor       223 cmdEnterTempHideFrame 224 cmdLeaveTempHideFrame 225 cmdCtrlWeather
226 cmdEnterLayout     227 cmdLeaveLayout   230 cmdPlaySound     231 cmdStopSound
234 cmdSetSystemSound1 236 cmdCtrlCharaAnime 237 cmdSetValue     238 cmdCtrlMovie
239 cmdLayerFilter     240 cmdPlayEnvVoice  241 cmdStopEnvVoice  242 cmdFaceUp
243 cmdExitFaceUp      244 cmdPreparePalette 245 cmdExecPalette  246 cmdExitPalette
247 cmdInitPalette     248 cmdCopyLayer     249 cmdEnterSkipBlock 250 cmdLeaveSkipBlock
251 cmdDefDrawCharacter 252 cmdDrawCharacter 253 cmdClearCharacter 254 cmdDestroyCtrl
255 cmdZoomSnap        256 cmdDefNotify     257 cmdManpu         258 cmdClearManpu
263 cmdFocus           265 cmdScreenshot    266 cmdMaskBlur      267 cmdPrepareSelectItems
268 cmdFrame
```

Notable dummy slots: **0, 2-5, 9, 11-17, 20-28, 31, 47, 77, 89, 96, 104, 111, 124, 133, 137, 140, 146, 156, 191, 201-202, 228-229, 232-233, 235, 259-262, 264, 269-286**. The inline opcodes (5, 11-13, 17, 20-24, 28, 140, 191) deliberately have dummy table slots — this is what makes the `execRld` non-interactive path (§7) inert for ADV-only records. **op47 is dummy yet used 72× by `cgMode.rld`** (§3.3.19).

**Action table assignment runs** (action number → `actionNNN`; unlisted = `actionDummy`): 0-15, 31-34, 40-47, 50-73, 79-80, 89-90, 95-108, 110-115, 118-123, 130-137, 142-228, 239-241, 247-283, 285, 289-291, 295-358, 360, 370.

## 2. Opcode → handler map (corpus: 53153 records, 310 files, 86 distinct opcodes)

Source: `corpus_census.json` (307 plaintext `.rld` scenario files + `library.rld` etc.; cipher/container per `exhibit_rld.h`), handler names/EAs from `createMethodTable` (`method_table_ea.json`), inline cases from `disasm_liteExec.txt`. `pc` = paramCount distribution, `sc` = stringCount distribution, `nib` = header flags-nibble (hdr>>28) distribution, all as record counts. Samples are first-seen records (strings are corpus-encoded: cp932, some hex-pair encoded — §10 R-HEXSTR). Skipped by census: `$posit.rld`, `_posit.rld` (1 record each), `def.rld` (81 records, tooling limit).

| op | dispatch | handler @EA | count | % | pc | sc | nib | sample (params / strs) |
|---:|---|---|---:|---:|---|---|---|---|
| 28 | inline | cmdMessage (§3.1) | 26279 | 49.4% | 12×24344,14×1935 | 2×24762,3×1517 | 2×24344,5×1935 | [4,1,1,536870913,0,0,0,1073741824...] [`*` \| `｡ｰｸ邵遑｣｡ｱ`] |
| 37 | method | `cmdEnterCharacter` @0x10123b60 | 4327 | 8.1% | 11×4327 | 0×4327 | 2×4327 | [4,71,3,-12345,9,-1,-1,-1...] [] |
| 22 | inline | gosub (§3.1) | 2788 | 5.2% | 0×2788 | 1×2788 | 1×2257,2×531 | [] [`10300,*,*,0`] |
| 74 | method | `cmdDraw` @0x101043c0 (AMBIG) | 2210 | 4.2% | 16×2210 | 0×2210 | 0×2210 | [9999,9,0,500,0,0,0,0...] [] |
| 100 | method | `cmdEnterMove` @0x1016db80 (AMBIG) | 1785 | 3.4% | 0×1785 | 1×1785 | 2×1566,0×134,1×85 | [] [`0,0,0,1,611,50,0,0,-1,-1,-1,-1,-1,-1,-1,`] |
| 101 | method | `cmdLeaveMove` @0x100e0450 | 1745 | 3.3% | 2×1745 | 0×1745 | 0×1745 | [0,1] [] |
| 95 | method | `cmdRemoveBillboard` @0x10181bf0 (AMBIG) | 1354 | 2.5% | 0×1354 | 1×1354 | 1×886,3×466,2×2 | [] [`600,-1,256,*`] |
| 94 | method | `cmdBillboard` @0x1019cf20 (AMBIG) | 1270 | 2.4% | 0×1270 | 1×1270 | 6×1266,4×4 | [] [`1,600,0,16777215,0,0,1280,720,800,9,16,0`] |
| 5 | inline | blockLabel (§3.1) | 933 | 1.8% | 0×933 | 1×933 | 2×918,1×15 | [] [`-1,33554480,-1,*,0,0,*`] |
| 243 | method | `cmdExitFaceUp` @0x10181ec0 (AMBIG) | 747 | 1.4% | 0×747 | 1×747 | 2×395,3×352 | [] [`1619198211,700,-1.0-700,-1,0,300,409,133`] |
| 19 | method | `cmdCtrlView` @0x100e00c0 | 731 | 1.4% | 1×731 | 0×731 | 0×731 | [0] [] |
| 18 | method | `cmdFrameView` @0x1015bca0 | 729 | 1.4% | 2×729 | 0×729 | 0×729 | [0,400] [] |
| 240 | method | `cmdPlayEnvVoice` @0x100e0860 (AMBIG) | 640 | 1.2% | 0×640 | 1×640 | 1×640 | [] [`0,117,300,256,256,2,7.-1`] |
| 56 | method | `cmdPlaySE` @0x100c33b0 | 573 | 1.1% | 5×367,0×206 | 0×367,1×206 | 1×367,2×206 | [34,256,256,1,0] [] |
| 241 | method | `cmdStopEnvVoice` @0x10101c40 (AMBIG) | 545 | 1.0% | 0×545 | 1×545 | 1×545 | [] [`0,300,-1`] |
| 50 | method | `cmdPlayMusic` @0x10115b40 (AMBIG) | 474 | 0.9% | 0×474 | 1×474 | 3×474 | [] [`24,0,144,144,1,0,0,0,-1`] |
| 49 | method | `cmdDefCharacter` @0x101012e0 (AMBIG) | 446 | 0.8% | 0×446 | 1×446 | 1×446 | [] [`4,0,3,1,31,267,-12345,-12345,1,0,0,NULL,`] |
| 20 | inline | condJump (§3.1) | 428 | 0.8% | 1×418,16×10 | 1×418,5×10 | 1×418,0×10 | [110] [`R1300==4`] |
| 17 | inline | cmdChangeScenario (§3.1) | 414 | 0.8% | 0×414 | 2×244,1×170 | 1×244,3×155,2×15 | [] [`1_001_02_com` \| `*`] |
| 78 | method | `cmdFadeOutEvent` @0x1012a080 (AMBIG) | 321 | 0.6% | 0×321 | 1×321 | 2×321 | [] [`520159103,114687,400,400,16777215,83`] |
| 33 | method | `cmdLeaveCharacters` @0x10171970 (AMBIG) | 297 | 0.6% | 6×297 | 0×297 | 1×297 | [16777216,-1,-1,-1,-1,-1] [] |
| 258 | method | `cmdClearManpu` @0x1016d570 (AMBIG) | 296 | 0.6% | 0×296 | 1×296 | 0×296 | [] [`1,-1,-1`] |
| 257 | method | `cmdManpu` @0x1015cd60 (AMBIG) | 290 | 0.5% | 0×290 | 1×290 | 2×156,3×134 | [] [`4163,1004,75,0,3,3,555,198,12,A.#1(15){4`] |
| 55 | method | `cmdStopLoop` @0x1015d810 | 260 | 0.5% | 3×260 | 0×260 | 1×260 | [300,0,0] [] |
| 54 | method | `cmdPlayLoop` @0x1018bff0 (AMBIG) | 242 | 0.5% | 0×242 | 1×242 | 1×242 | [] [`703,0,256,256,0`] |
| 189 | method | `cmdSetDoneFlag` @0x100e1e80 (AMBIG) | 232 | 0.4% | 0×232 | 1×232 | 0×232 | [] [`2,1,46`] |
| 193 | method | `cmdTKCheck` @0x100e3c80 | 192 | 0.4% | 5×192 | 0×192 | 0×192 | [0,4000,-1,-1,1] [] |
| 58 | method | `cmdPlaySyncSE` @0x100c33d0 | 178 | 0.3% | 5×176,0×2 | 0×176,1×2 | 1×176,2×2 | [332,144,144,0,0] [] |
| 114 | method | `cmdLeaveMovie` @0x10102480 (AMBIG) | 171 | 0.3% | 0×171 | 1×171 | 1×171 | [] [`0,6,-1`] |
| 105 | method | `cmdEnterFade` @0x1016e750 (AMBIG) | 169 | 0.3% | 0×169 | 1×169 | 0×169 | [] [`0,0,611,16,300,0,-1,0,0,0,-1,0,0,0,-1,0,`] |
| 113 | method | `cmdEnterMovie` @0x101240f0 (AMBIG) | 161 | 0.3% | 0×161 | 1×161 | 2×161 | [] [`0,1150,-1,-1,1,0,0,1280,720,wmv,NULL`] |
| 238 | method | `cmdCtrlMovie` @0x10115ef0 (AMBIG) | 161 | 0.3% | 0×161 | 1×161 | 1×161 | [] [`0,0,0.0.0.0,0.5.999.0,0.0.0.0,0.5.999.0,`] |
| 116 | method | `cmdEnterAnimation` @0x1016f710 (AMBIG) | 146 | 0.3% | 0×146 | 1×146 | 4×146 | [] [`0,0,9623,300,10,0,0,0,-1,-1,-2,-1,0,NULL`] |
| 117 | method | `cmdLeaveAnimation` @0x100e0530 | 137 | 0.3% | 3×137 | 0×137 | 0×137 | [0,300,0] [] |
| 38 | method | `cmdLeaveCharacter` @0x10101fd0 (AMBIG) | 126 | 0.2% | 0×126 | 1×126 | 2×126 | [] [`4,31,3,-1,-1,0,*`] |
| 13 | inline | wait (§3.1) | 107 | 0.2% | 2×107 | 0×107 | 0×107 | [1000,0] [] |
| 6 | method | `cmdSetReg` @0x100c3370 | 98 | 0.2% | 0×98 | 1×98 | 1×98 | [] [`0,1001,0,1,*,0`] |
| 106 | method | `cmdLeaveFade` @0x100e0470 | 92 | 0.2% | 3×92 | 0×92 | 1×92 | [0,1,0] [] |
| 81 | method | `cmdEnterClip` @0x100e34e0 | 89 | 0.2% | 8×89 | 0×89 | 0×89 | [385,308,512,288,800,0,0,1] [] |
| 82 | method | `cmdLeaveClip` @0x10104830 (AMBIG) | 89 | 0.2% | 10×89 | 0×89 | 0×89 | [0,1,0,0,0,0,300,0...] [] |
| 12 | inline | autosave (§3.1) | 84 | 0.2% | 0×84 | 1×84 | 1×84 | [] [`0,*,*`] |
| 23 | inline | return (§3.1) | 74 | 0.1% | 0×74 | 1×74 | 1×74 | [] [`0,true`] |
| 134 | method | `cmdEnterClipView` @0x101249e0 (AMBIG) | 72 | 0.1% | 0×72 | 1×72 | 1×72 | [] [`0,250,608,0,2,265,128,750,439,-12345,-12`] |
| 47 | method | **cmdDummy (no-op)** — §3.3.19 | 72 | 0.1% | 2×72 | 0×72 | 1×72 | [2000,1] [] |
| 21 | inline | cmdQuestion (§3.1) | 62 | 0.1% | 0×62 | 1×62 | 5×36,6×26 | [] [`1010\t0\t0\t1\t2\t-1\t-1\t-1\t-1\t-1\t-1\t-1\t-12345`] |
| 32 | method | `cmdEnterCharacters` @0x10149d90 (AMBIG) | 61 | 0.1% | 0×61 | 1×61 | 3×61 | [] [`1,6,2,5,16843072,-1,-12345,0,0,4,2,5,169`] |
| 51 | method | `cmdStopMusic` @0x10101bb0 | 58 | 0.1% | 2×58 | 0×58 | 0×58 | [300,0] [] |
| 191 | inline | cmdAction (§3.1) | 49 | 0.1% | 0×49 | 1×49 | 0×49 | [] [`291,-1,1,0,2,0,*`] |
| 57 | method | `cmdStopSE` @0x10101d50 | 40 | 0.1% | 3×40 | 0×40 | 1×40 | [-1,1,0] [] |
| 11 | inline | cmdExHIBIT (§3.1) | 37 | 0.1% | 0×37 | 1×37 | 0×37 | [] [`27,-1,0,`] |
| 80 | method | `cmdClip` @0x101047c0 | 33 | 0.1% | 8×33 | 0×33 | 0×33 | [346,135,512,288,1000,8,0,0] [] |
| 192 | method | `cmdTKStart` @0x100e3bb0 (AMBIG) | 24 | 0.0% | 0×24 | 1×24 | 0×24 | [] [`0,1,4_013_01_sakura`] |
| 8 | method | `cmdSetReg` @0x100c3370 | 24 | 0.0% | 0×24 | 1×24 | 1×24 | [] [`1,1000010,0,1,*,`] |
| 90 | method | `cmdCtrlSelectItem` @0x1016eac0 (AMBIG) | 19 | 0.0% | 0×19 | 1×19 | 0×19 | [] [`6,610,2,*`] |
| 242 | method | `cmdFaceUp` @0x1016ffd0 (AMBIG) | 16 | 0.0% | 0×16 | 1×16 | 3×16 | [] [`537931776,-2,0,0,*,0,0,-1,-1,0,-1,*,655,`] |
| 52 | method | `cmdPlayEnv` @0x100c4800 | 16 | 0.0% | 4×16 | 0×16 | 0×16 | [23,0,-1,-1] [] |
| 39 | method | `cmdMoveCharacter` @0x10102250 | 14 | 0.0% | 8×14 | 0×14 | 0×14 | [5,300,0,0,0,0,16842912,0] [] |
| 216 | method | `cmdEnterTransform` @0x101483f0 (AMBIG) | 14 | 0.0% | 0×14 | 1×14 | 0×14 | [] [`0,700,1200,0,0,33282,0,0,0,0,0,0,0,0,0,0`] |
| 48 | method | `cmdCreateCharacter` @0x100e00f0 (AMBIG) | 12 | 0.0% | 0×12 | 1×12 | 0×12 | [] [`3,1,0,ｵvﾒｻ,,,,,,,,,,`] |
| 263 | method | `cmdFocus` @0x1019b3e0 (AMBIG) | 10 | 0.0% | 0×10 | 1×10 | 0×10 | [] [`50178,600,400,5,-1,5,-1,-1,-1`] |
| 167 | method | `cmdSetColorFilter` @0x100e26f0 (AMBIG) | 8 | 0.0% | 0×8 | 1×8 | 0×8 | [] [`0,0,0`] |
| 267 | method | `cmdPrepareSelectItems` @0x10197670 | 8 | 0.0% | 2×8 | 1×8 | 0×8 | [0,1] [`layer.610.create=-1 / layer.610.item.6.act`] |
| 62 | method | `cmdGetDbInt` @0x1017f2c0 (AMBIG) | 7 | 0.0% | 0×7 | 1×7 | 0×7 | [] [`2,R1293,0,1297,-1,-1,-1,-1,-1,-1,-1,-1,-`] |
| 217 | method | `cmdLeaveTransform` @0x101004f0 (AMBIG) | 6 | 0.0% | 0×6 | 1×6 | 0×6 | [] [`0,0,1,0,0`] |
| 139 | method | `cmdInputLayerControl` @0x101226e0 | 6 | 0.0% | 4×6 | 0×6 | 0×6 | [605,610,0,1] [] |
| 132 | method | `cmdCgMode` @0x101976d0 (AMBIG) | 5 | 0.0% | 0×5 | 1×5 | 1×5 | [] [`0,0,NUMBER.92@0\t1\t1000\t9\t300\t0\t1\t1001\t9\t`] |
| 160 | method | `cmdCreateClipper` @0x101253c0 (AMBIG) | 4 | 0.0% | 0×4 | 1×4 | 0×4 | [] [`0,0,650,652,res\g\gn\m\0266.gyu`] |
| 162 | method | `cmdDestroyClipper` @0x100e2560 | 4 | 0.0% | 2×4 | 0×4 | 0×4 | [-1,0] [] |
| 206 | method | `cmdDestroyView` @0x10173000 (AMBIG) | 4 | 0.0% | 0×4 | 1×4 | 0×4 | [] [`0,400`] |
| 207 | method | `cmdRemoveView` @0x1014b5a0 | 4 | 0.0% | 1×4 | 0×4 | 0×4 | [0] [] |
| 112 | method | `cmdPlayVideo` @0x101246b0 (AMBIG) | 3 | 0.0% | 0×3 | 1×3 | 1×3 | [] [`-1,-2130706433,2000,-1,0,0,0,0,-1,res\g\`] |
| 136 | method | `cmdQuake` @0x101294a0 | 3 | 0.0% | 15×3 | 0×3 | 0×3 | [0,0,100,2,8,8,0,-1...] [] |
| 76 | method | `cmdDrawZoom` @0x10129c70 (AMBIG) | 3 | 0.0% | 0×3 | 1×3 | 2×3 | [] [`610,500,660,371,40,22,0,1,300,16777215,5`] |
| 92 | method | `cmdExecSelectItem` @0x1019f730 (AMBIG) | 3 | 0.0% | 10×3 | 0×3 | 2×3 | [0,-1,1300,-1,-1,-1,-1,604...] [] |
| 93 | method | `cmdExitSelectItem` @0x10121e70 | 3 | 0.0% | 1×3 | 0×3 | 0×3 | [0] [] |
| 203 | method | `cmdPrepareView` @0x10197f40 (AMBIG) | 3 | 0.0% | 2×3 | 1×3 | 1×3 | [0,1] [`layer.606.create=1, 18,143,res\g\sy\00\0`] |
| 204 | method | `cmdShowView` @0x10198070 (AMBIG) | 3 | 0.0% | 0×3 | 1×3 | 0×3 | [] [`0,400,0`] |
| 205 | method | `cmdSelectView` @0x101a95c0 (AMBIG) | 3 | 0.0% | 0×3 | 1×3 | 0×3 | [] [`0,9479,-1,1300,-1,-1,-1,-1`] |
| 35 | method | `cmdExecMoveCharacters` @0x101023e0 | 2 | 0.0% | 17×2 | 0×2 | 1×2 | [0,7,33620288,0,500,8,16842752,0...] [] |
| 59 | method | `cmdSetVolume` @0x10103570 | 2 | 0.0% | 6×2 | 0×2 | 0×2 | [2,48,48,0,0,-1] [] |
| 53 | method | `cmdStopEnv` @0x100c4850 | 1 | 0.0% | 1×1 | 0×1 | 0×1 | [0] [] |
| 239 | method | `cmdLayerFilter` @0x1014a760 (AMBIG) | 1 | 0.0% | 0×1 | 1×1 | 0×1 | [] [`2,-1;0;0;0;0;0,1007;0;0;0;0;0`] |
| 248 | method | `cmdCopyLayer` @0x1015da70 (AMBIG) | 1 | 0.0% | 0×1 | 1×1 | 2×1 | [] [`0,65,-3,res\g\sy\02\02_180.gyu,0,0,-1,-1`] |
| 138 | method | `cmdCtrlLayer` @0x101221e0 (AMBIG) | 1 | 0.0% | 0×1 | 1×1 | 3×1 | [] [`661,128,-1,0,NULL,0,0,R1040,R1041`] |
| 223 | method | `cmdEnterTempHideFrame` @0x101496b0 (AMBIG) | 1 | 0.0% | 0×1 | 1×1 | 0×1 | [] [`2,400`] |
| 224 | method | `cmdLeaveTempHideFrame` @0x10120830 | 1 | 0.0% | 1×1 | 0×1 | 1×1 | [300] [] |

Coverage check: inline ops in corpus = 5, 11, 12, 13, 17, 20, 21, 22, 23, 28, 191 (24/140 unused); op47 is the only corpus op with a **dummy** slot; method-table ops **7 (cmdCalcReg) and 10 (cmdSetReg-T) have zero corpus records** (op6 ×98 and op8 ×24 cover the register writes). Every other corpus op maps to exactly one assigned method-table slot.

## 3. Opcode semantics — deep dives

### 3.0 The interpreter: `liteExec` @0x101B6590

`int RetouchSystem::liteExec(const char* scenarioName, DWORD entryBlockId, int loadResume)` — the interactive scenario interpreter (its non-interactive sibling is `execRld` @0x101B7F40, §8). Evidence: 1970-line disassembly `disasm_liteExec.txt` + notebook `vm_spec_notes_liteExec.md`.

- Loads the scenario via `liteLoad(scenarioName, …)` (same loader as §7; record array at `this[1941]`, count `this[1940]`), lazily builds the method/action tables, constructs a `SelectItemManager` (16 B, ctors 0x101515B0/0x10151610) and the 12-byte-frame callstack object (vtbl `off_1042B6FC`; push = vtbl+0x1C, pop = vtbl+0x28).
- `entryBlockId != 0` → `pc = blockId2Index(entryBlockId)`; failure → `MessageBeep` + `OutputDebugStringA` + `liteRuntimeError`.
- Main loop: while `pc < count`: `cmd = base + 216*pc`; `cmd->execIndex(+212) = pc`; `pc++`; dispatch `switch ((uint16)cmd->header)` — jump table `jpt_101B688C`, cases 5..191; **default**: if `op ≤ 286` call `methodTable[op]` (`this+35752`, 287 slots, §1).
- Handler contract: `int __thiscall cmd(RetouchSystem* this, CMD_DATA* rec, LocalHolder* lh, LocalPosCorrector* corr /*= this+0x9024, embedded*/, SelectItemManager* sim)`.
- Per-record tail: timer/sound GC; if not skipping → pump the view vcall.
- Load-resume mode: when `loadResume` matches the current record index (`reg(5)` is republished each step; marker `[this+0x8B24]`) → `exitLoadMode(500)`; billboard layer 205 (0xCD) initialized with sentinel 0xFFFFFFFE.
- Scenario switch (op17): mutates `treg(2)` = next scenario name and `treg(207)` = entry label, sets the quit flag; the OUTER loop then: restores cursor from `treg(32)`, `loadLayer()`, reads entry label from `treg(207)` (`loadEntryName`), applies `reg(4)` window flags (bit0 → `enterMessage(-1,0,6)` if `[+0x4478] ≤ 0`; bit1 → `UxLocalCtrl(+0x44DC)::enter(-1,0,1)`; bit7 → `[+0xF68] |= 4` else `&= ~4`), `loadViewClip(false)`, `liteLoad(treg(2), 0)`, `pc = blockId2Index(entry)` (999999 = 0xF423F sentinel = "top of scenario"), pushes callstack frame `{entryBlockId, idx+1, 1}`, `exitLoadMode(350)`. Preserved across the switch (disasm outer loop; notes L43/L54-55): **treg(201) = current scenario name, treg(207) = entry label/block title, treg(2) = next-scenario-name carrier** (consumed by `liteLoad`), treg(32) = cursor name; `clearLoad()`; `reg(3)` reset. NB: the integer "current block id" lives in **holder R2** (`LocalHolder::setReg(2,·)` at op5 entry), not in treg(2).
- Debug entry point: `ExHIBIT.ini [exec] entry=1_007_01_com` is fed to liteExec as `scenario!label` in debug builds; release uses `[release] scenario=sc00.dll entry=start`.
- `start.rld` special: if flags byte `[esi+0x4C]` bit7 → nested liteExec-style call with action 114 (0x72).

### 3.1 Inline (non-table) opcodes — switch cases in liteExec

| op | name | semantics (evidence: disasm_liteExec.txt line ranges) |
|---|---|---|
| 5 | block header / label | Two forms. **String form** (stringCount ≥ 1): `splitParam(str0, tok[7], 7, ",", …)` when stringCount ≥ 2 else 5-token form with defaults ("-1","0"). tok[0]=blockId (−1 → auto-number: `var_8` counter, see below), tok[1]=flags, tok[2]=end-block id for skip, tok[3]=message-frame id, tok[4]=enterMessage id, tok[5]=**condition**, tok[6]=**block title**. Flags: bit0=history/backlog enter + state `[+0xF68] |= 4`, bit1=`setTempDisableLoadSkip`, bit4=switch msg frame if `[+0x4478] ≤ 0` (`cmdSetMessageFrame2(tok[3],-1,0,…)` then `enterMessage(tok[4],0,6)`), bit5=`UxLocalCtrl(+0x44DC)::enter(-1,0,1)` if `[+0x44E4] > 0`, bit25 seen in corpus (0x2000030). Condition TRUE → enter: log, `LocalHolder::setReg(2, blockId)` (holder **R2** = current block id; disasm 0x101B6D50), `treg(1, title)` (string reg 1 = block title; 0x101B6D60) + `setBlockMessage(title)`, `blockEntry(holder,false)`. FALSE → skip: `endId = tok[2] != -1 ? tok[2] : ++autoCounter + 1`; `pc = blockId2Index(endId)`. **Param form** (no strings): params[0]=blockId (−1=auto) — plain label/terminator marker (no condition); this is what `blockId2Index` matches for jump targets. Auto-numbering: counter starts 0; auto labels get ids 1,2,3,… in record order; increment suppressed when jump-origin flag (set by op23 bit1) is active; explicit ids SET the counter. `blockId2Index` re-simulates the counter from record 0 on every lookup (deterministic). |
| 11 | cmdExHIBIT | `initActionBranch`; `cmdExHIBIT(cmd, lh, corr, sim, &PC_ExHIBIT)` → system meta-commands; sub-dispatch inside `cmdExHIBITMain` @0x101A9FD0 (68 dense cases, `jpt_101AA05A`; case 0 = `liteLoadUserDefinedEntry`, cases 4-7/9/11-22 = no-op; subcase parsed from str0 tok[0] via `sub_101C28C0`). Then branch check `[+0x4494]`/`[+17556]&1`: mode&2 → `pc = blockId2Index([+0x4490])`, else gosub-push `{blockCtx,pc,0}` then jump; missing target → `liteRuntimeError(-10/-11)`. |
| 12 | autosave point | If `reg(3) == pc` → skip (don't re-autosave right after loading this point). Else `splitParam(str0, tok, "…", ",")`, tok[0]=slot; builds AutoSaveParams{type=186 (0xBA)}; `autoSave()`; then `reg(3, -1)`. Corpus: `"0,*,*"`. |
| 13 | wait | `paramCount ≥ 2 ? UxAdvSystem::wait(params[0], true, params[1]!=0) : wait(params[0], true, false)`. Corpus: `[1000, 0]` = wait 1000 ms, not skippable-flag false. |
| 17 | cmdChangeScenario | `cmdChangeScenario(cmd, lh, corr, sim, &PC_ExHIBIT)`; strs = [next scenario name, entry label (`"*"` = default)]. Sets the outer-loop reload path (§3.0). Then `clearLoad`, callstack reset (`sub_1011E5D0`), `reg(3, pc)`. |
| 20 | conditional jump | Condition: numeric form → `liteCheckCondition(CMD_DATA&)` precompiled slots (§5.6); string form → `liteCheckCondition(FCString&)` on str0 (corpus `"R1300==4"`, `"L14==1"`). TRUE → `pc = blockId2Index(params[0])` (corpus target 110 etc.); FALSE → fall through. |
| 22 | gosub | String form: `splitParam(str0, tok[3], 3, ",")` — tok[0]=target block, tok[1]=wildcard, tok[2]=condition; special: tok[0]=="*" → register-assign from tok[2] instead of call. Numeric form: precompiled condition. TRUE → push 12-byte frame `{blockCtx, pc, 0}` (vtbl+0x1C), `pc = blockId2Index(target)`. Corpus: `"10300,*,*,0"`, `"30009,*,*"`. |
| 21 | cmdQuestion | `initActionBranch`; `cmdQuestion(cmd, lh, corr, sim)` — choice/select question (SelectItemManager machinery, `rsv_*` family). Then the standard branch post-processing: `[+0x4494]&1` → mode&2 → `pc = blockId2Index([+0x4490])` (negative → `liteRuntimeError` path), else gosub-push `{pc, blockCtx, 0}` (vtbl+0x1C) then jump. (Evidence: disasm_liteExec.txt lines 954-992.) |
| 23 | return | `cmdReturn(cmd, holder)` @0x1018C730 returns **bool "do return"**: param form (nibble 0) → `liteCheckCondition(CMD_DATA&)` (precompiled condition, §5.6); string form → `splitParam(str0, tok[2], 2, ",")`: tok[0] bit0 set → return `liteCheckConditionEngine(tok[1], holder)`, else unconditional true. So corpus `"0,true"` = unconditional return (flag 0, condition text unused). If true: pop 12-byte frame `{blockCtx, pc, flags}` (`sub_1011E7A0`); stack non-empty → log `"<=== RET : "` via `directCommandInfoN`, restore `blockCtx`/`pc`; empty → `liteRuntimeError(cmd, 0, pc)`. Then **popped frame flags**: bit0 set and vtbl+0x3C predicate false → `[+0x8B24] = -1` (load-resume marker cleared), `exitLoadMode(350)`; bit1 → `var_9` = jump-origin marker (suppresses op5 auto-number increment on the landing header). (Evidence: decomp_x_h_cmdReturn.txt; disasm_liteExec.txt lines 901-953.) |
| 24 / 140 | end | `rdhExitScene(true)`; result = 0; `pc = [esi+0x1E50]` (record count) → loop exit; `UxAdvSystem::reg(6, 0)`; `[+0x8B24] = -1`. **No corpus records use 24/140** (census) — scenarios end via op17 scenario-switch instead. |
| 28 | cmdMessage | THE text record (49.4% of corpus) — see §3.2. |
| 191 | cmdAction | `initActionBranch`; `cmdAction(cmd, …)` → action table dispatch (§1, 400 slots @this+37352); same branch/gosub post-processing as op11. Corpus str: `"291,-1,1,0,2,0,*"` → action 291 + args. |

### 3.2 op28 `cmdMessage` @0x1018C1B0 (`decomp_cmdMessage.txt`) — character dialogue

Record fields (params = int32 @+8…, strings = FCString @+92…):

| field | meaning |
|---|---|
| params[0] | speaker character id (`0x80000000` bit = narrator/system voice); must be < `this[659]` (char count); char array `this[660]`, stride **268** (`RetouchAdvCharacter`) |
| params[1] | message frame/window id |
| params[2] | bit0 → say "wait/first-page" arg; bit1 → text/audio lock guard (`sub_1022D1D0`) |
| params[3] | display-mode bitfield: bit3 `|= 8` when liteExec skip-arg true; bit7 = invert camera follow; low 7 bits passed to `say` |
| params[4..6] | extra `say` args (speed/position class) |
| hdr flags nibble ≥ 2 | extended print params: params[7] = socket flags (**bit30 0x40000000 = don't serialize**), params[8..11] = print rect/socket (`getLoadPrintSocketParam` for load replay), params[12] (nibble ≥ 3), params[13] (nibble ≥ 4) |
| strings[0] | speaker-name override; `"*"` = character's default name (charIds 1/2 always default) |
| strings[1] | **message body** (markup parsed inside `RetouchAdvCharacter::say` — see GAP below) |
| strings[2] | optional voice/effect command string: compiled by `sub_101715E0`, executed as async effect group (`svdAppendGroup`); when present, `say` runs in mode 2 and `this[987] (+3948) = charId` |

Flow in liteExec (lines ~190-330): `initActionBranch` → vtbl-bool → `cmdMessage(cmd, bool, LocalHolder, this+0x9024, sim)` — **blocks until the message completes** (player click / auto-mode). Inside: `say(charObj, params[1], name, body, params[2]&1, params[3]&0x7F, params[4..6], printParam, mode?2:0)`; history via `rdhCmdMessage(params[1], charName, body)` — name wrapped in SJIS `（`/`）` (0x8169/0x816A bytes @0x10430A6C/0x10430A68) when overridden; camera follow: if camera active and `camera[13]` flags 0x40/0x20/0x80 → `followCharacter(charId)`, inverted by params[3] bit7. After return: branch check `[+0x4494]` → jump/gosub to `[+0x4490]` (`blockId2Index`, error −11 if missing), then delayed history flush (`RetouchPrintManager`).

Corpus sample: `params [4,1,1,0x20000001,0,0,0,0x40000000,-1,-1,0,0] strs ["*", "こんにちは"]` → char 4, frame 1, wait-flag, mode bits 0+29, socket no-serialize, empty rect.

**GAP**: `RetouchAdvCharacter::say` (inline text markup: page breaks, color/ruby tags, inline waits) not yet reversed — §10 risk R-SAY.

### 3.3 Method-table handlers — top-20 deep dives

**Handler contract** — every method-table slot holds a pointer to:

```cpp
typedef void (__thiscall RetouchSystem::*CmdHandler)(
    CMD_DATA& cmd,                  // the 216-byte record (§7)
    LocalHolder& holder,            // per-run register overlay (§6)
    LocalPosCorrector& posCorr,     // this + 0x9024
    SelectItemManager* sim);        // this + local var (choice UI manager)
```

Dispatch site (disasm_liteExec.txt @0x101B7280): `mov edx,[esi+eax*4+8BA8h]; call edx` — table base **0x8BA8 = 35752**, index = opcode (≤ 286; above 286 → silent skip). After the handler: `isValidRDH()` → `rdhCmdSnap(cmd)` (history snapshot), then the common per-record tail `UxAsyncSubsystem::gcTm()` (this+0x288), `UxAdvSystem::gcSE()`, skip-update check (`isSkipUpdate`/`isDoSkip`, VK_CONTROL 0x11 polling).

**Shared conventions** (recurring in nearly every handler below; evidence = the cached `decomp_h_*.txt` / `disasm_cmdBillboard.txt` files named per handler):

| convention | detail |
|---|---|
| Form select | `nibble = hdr >> 28` (hdr = dword @cmd+4). nibble 0/1 → integer **param form** (nibble 1 often = one attached string or extra param group); nibble ≥ 2 → **string form**: `splitParam(strings[0], tok, cap, ",", keepEmpty, NULL)`, cap grows with nibble (per-handler: e.g. 26/27/31 for op94, 35/40/52/54 for op243). |
| paramCount byte | `byte @cmd+6` (= paramCount field of the header, §7) is re-read by several handlers as a *format selector* (op37: ==9 / ==11; op74: ==15 / ==16; op18: ==2). |
| Token numerics | `str2int` @0x101C28C0 (`0x`→hex, `0b`→binary, else decimal atoi) for plain ints; `calcExpression` @0x1016D1E0 (full §5 expression language: R/S/T/Q/L operands, functions, operators) for expression slots. `sub_101BE6C0` parses a token as a 2-byte packed word (lo/hi). |
| Layer ids | `cmdLid2lid(scriptLid)` maps script layer ids → engine LIDs (vendor constants LID_EFFECT=92, LID_MESSAGE=138, LID_MASK=203). Character layers: `cmdLid2lid(charId + 1000)`. |
| Char/CG ids | `cgchCorrectChara(id)`, `cgchCorrectCg(this,&id,holder)` — gallery/correction remap hooks (mutate by reference). |
| Register indirection | int param/token ≥ **1000000** → actual value = `holder.getReg(param − 1000000)`; op74 CG variant: mode ≥ 0x8000 → `mode −= 0x8010`, cgId = `holder.getReg(cgId)`. |
| "silent trio" | `vtbl[15](this)` (vtable slot @+60, skip/mode predicate) ‖ `this[1158]` (+0x1218 dword flags) ‖ `byte[+4836]` (+0x12E4): while any is set (skip / fast-forward / mute), audio volumes and transition times are forced to 0/instant. |
| Sentinels | `-12345` (0xFFFFCFC7) = "param unused"; `-1` = none/default; `-2` = special per-handler mode; `"*"` = wildcard (conditions: TRUE); `"NULL"` = null string slot. |
| Layer geometry | Engine layer record: base `[this+0xB60]+0x14`, stride **2456 (0x998)**: surface obj @+0x150, x @+0x160 (352), y @+0x164 (356), default fade time @+0x170, state word @+0x5A4. Layer-exists check `sub_101F4260`; valid lid range 0..0xDF. |
| Async subsystem | `this+648` (0x288) = `UxAsyncSubsystem`: `tmExitMove`, `tmMoveEngine`, `tmInitFade`, `tmFadeEngine(engine, type, lid, time, …)`, `showLayer`, `gcTm`. |
| Audio channels | music handles `this[702+k]`, SE/voice channels `this[698..700]`, generic sound handles `this[684+k]`, env `this[688+k]`, loop `this[696+k]`; channel stop = `sub_101F8830(handle)`; count words `this[704]`/`this[705]`. |
| Char storage | char count `this[659]`, array `this[660]`, stride **268** (`RetouchAdvCharacter`); last speaker `this[987]` (+0xF6C… +3948); msg-frame depth `this[4382]` (+0x4478). |

#### 3.3.1 op6 / op8 / op10 `cmdSetReg` @0x100C3370 → `liteSetReg` @0x1017FA20 — register assignment (evidence: disasm_liteSetReg.txt, 872 lines)

One function implements all three opcodes; the **opcode word** (`hdr & 0xFFFF`) selects the register class: **6 = R** (script int regs, via the LocalHolder overlay), **8 = S** (system sreg, global bank), **10 = T** (string regs treg).

**String form** (nibble == 1): `splitParam(strings[0], tok[6], 6, ",", false, NULL)`:

| tok | meaning |
|---|---|
| 0 | parsed with str2int but **discarded** (placeholder/subtype) |
| 1 | destination id (for op8: passed through `correctSregExpression`, §6.4) |
| 2 | flags word: low byte = **operation code**; for op8 bit8 = flush flag |
| 3 | value: op6/op8 → `calcExpression(tok[3], holder)`; op10 → string template (below) |
| 4 | **condition**: `liteCheckCondition(tok[4], holder)` (§5) — FALSE → whole record no-op (`"*"` → TRUE) |
| 5 | op6 only: bit0 → after the local write, also push to the GLOBAL bank: `UxAdvSystem::reg(id, holder.getReg(id))` |

Operation codes (op6 R / op8 S): `0` assign, `1` add, `2` mul, `3` div (signed idiv; divisor == 0 → `debugMessage("CMD_SETREG "/"CMD_SETSREG ")`, **no write**), `4` mod (divisor ≤ 0 → no write), `5` and, `6` or, `7` xor, `8/9` reserved (no-op), `10` zero (R only). op8 writes go to `UxAdvSystem::sreg(id,v)` (global, NOT the holder); op8 flush flag → `flushSysreg()` (persist sysreg bank).

op10 (T) value template — switch on the **first character of tok[3]** (CharNextA advance; table byte_10180508):
- `'R'` → int n = str2int(rest); n > 0 → append decimal of `UxAdvSystem::reg(n)` (**global**, not holder) via `sub_101C1120`; else append raw token text.
- `'S'` → same with `UxAdvSystem::sreg(n)`.
- `'T'` → append current text of `treg(n)` (cell accessor `sub_101F6C10` on `[this+0xB40]+0x24`).
- `'"'` → re-tokenize tok[3] with `"` as delimiter (`sub_101C12D0`) = quoted-literal extraction.
- default → raw tok[3] text.

Then op10 operation switch: `0` `treg(id, built)` assign; `1`/`2` concatenations of built with the existing cell text (`sub_101BE320` / `sub_101BE0A0`-append) **[INFERRED order: 1 = existing+built, 2 = built+existing]**; `3` string edit `sub_101C2BB0(copyOfExisting, built, tok[4])` **[semantics not fully reversed — replace/substring; risk R-TREG3]**; `4..9` set treg **cell flag bits** via `sub_101C3110(cell(id), bit)`: 4→0x800000, 5→0x400000, 6→0x200, 7→0x100, 8→0x100000, 9→0x200000 **[INFERRED: persistence/serialization markers — consistent with treg201/207 surviving scenario switch, §6.3]**; `10` `treg(id, NULL)` clear.

**Param form** (nibble ≠ 1): op = `params[2] & 0xFF`, dest id = `params[1]`, value source = `strings[0]` with the same first-char template, but class-specific:
- op6: `'R'`→`holder.getReg(n)` (**overlay**), `'S'`→`sreg(n)`, `'T'`→`str2int(treg text)`, default `str2int(strings[0])`; op switch has only **5 cases** (0..4 = assign/add/mul/div/mod — bitwise & zero are string-form-only); writes via `holder.setReg`.
- op8: `'R'`→`UxAdvSystem::reg(n)` (**global**), `'S'`→`sreg(n)`, `'T'` forbidden (literal fallback); dest = `correctSregExpression(params[1])`; flush flag = bit8 of params[2] → `flushSysreg()`.
- op10: template as above; op switch 10 cases (0 assign, 1/2 concat, 3 edit with `strings[1]` as second arg, 4-9 flag sets).
- Any register reference with n ≤ 0 → op forced to −1 → **no write**.

Corpus: op6 ×98 `"0,1001,0,1,*,0"` = *R1001 := 1, unconditionally, no global flush*; op8 ×24 `"1,1000010,0,1,*,"` = *S(correctSreg(1000010)) := 1, flush* (1000010 ≥ 1000000 → relocated sreg, §6.4); op10 ×0 (T-writes ride inside other records' templates).

#### 3.3.2 op7 `cmdCalcReg` @0x100C3390 → `liteCalcReg` @0x100DF8F0 — precompiled ternary arithmetic (evidence: disasm_liteCalcReg.txt, complete)

Param-only (no string form). All int32, signed:

| field | meaning |
|---|---|
| params[3], params[4] | LHS: type `1` → `holder.getReg(id)`, `2` → `UxAdvSystem::sreg(id)`, else → literal id |
| params[5], params[6] | RHS: same encoding |
| params[2] | op: `0` add, `1` sub (LHS−RHS), `2` mul, `3` div (`idiv`; RHS == 0 → no write), `4` mod (RHS == 0 → no write); >4 → result 0 |
| params[0], params[1] | dest: type `1` → `holder.setReg(id, result)`, `2` → `UxAdvSystem::sreg(id, result)`, else → no write |

**Not used by this corpus** (census: 0 records) but must exist for other titles.

#### 3.3.3 op11 `cmdExHIBITMain` @0x101A9FD0 — system meta-command sub-dispatch (evidence: disasm_cmdExHIBITMain.txt 6512 lines; gen_exhibitmain_cases.txt)

Sub-case = `str2int(tok[0])` of `strings[0]`; jump table `jpt_101AFA90`, **68 dense cases (0..67), lowcase 0**; remaining tokens are ","-split per case. Cases 4, 7, 9, 11-22 → default no-op. Notable cases:

| case | action |
|---|---|
| 0, 1 | `liteLoadUserDefinedEntry(int)` — run a user-defined entry script |
| 3 | `UxAdvSystem::restart()` — engine restart (to title) |
| 8 | `RetouchSystem::config(int, char*, LocalHolder*)` — config dialog |
| 23, 44 | `UxAdvSystem::setSystemFlag(int, bool)` |
| 24 | `UxAdvSystem::execLoad()` — execute pending load |
| 25 | `openURL(char*, char*)` |
| 27 | `skipCancel()` — **the only sub-case used by this corpus** (op11 ×37, `"27,-1,0,"`) |
| 28 | `autoCancel()` |
| 29, 34, 41, 49, 50, 58, 63 | layer ops (`cmdLid2lid` + calcExpression positioning) |
| 33 | `RetouchResManager::experienceCg(int)` — mark CG as seen (gallery unlock) |
| 36 | `defLoadPageOverride(FCString)` |
| 37 | `reg(id, isExistSaveData(slot))` — save-slot probe into a register |
| 38 | `setLocalFlag(id, calcExpression(tok)!=0, bool)` |
| 45 | `initDvdInfo(char*)` |
| 48 | `loc_sreg(int,int)` — local sreg write |
| 51, 52 | flag ← `liteCheckCondition(FCString, holder)` |
| 53, 66 | treg cell read/write (`sub_101F6C10`) |
| 62 | `RetouchPrintManager::clearShadow(int, uint)` |

Full per-case token parsing is mechanical (splitParam + str2int/calcExpression); the extract `gen_exhibitmain_cases.txt` lists the first calls of every case.

#### 3.3.4 op37 `cmdEnterCharacter` @0x10123B60 — 4327× (pc=11, nib=2) — evidence: decomp_h_cmdEnterCharacter.txt

Param form only. `cgchCorrectChara` remaps the character id first. Param map (decompiler extraction order):

| field | role |
|---|---|
| params[0] | charId (must be < `this[659]`; char object = `this[660] + 268*charId`) |
| params[1] | enter **mode/position word** — ordinary values = position slot; special paths for 528, 251, 252, 253 |
| params[2] | pose/def id (sample: 3) |
| params[3], params[4] | x / y (or, per mode, position-inheritance/swap source controls; `-12345` = unused) |
| params[5], params[6] | move time / alpha (`-1` = layer defaults) |
| paramCount(byte+6) == 9 | short form (no extended slots) |
| paramCount == 11 | extended: params[7..10] = per-slot move/fade params (`-12345` = unused) |

Body: `RetouchAdvCharacter::enter(...)` with 12 args (charObj, pose, x, y, times, alpha, mode-derived flags); the character's display layer (lid = `cmdLid2lid(charId+1000)`) is driven through `tmMoveEngine`/`tmInitFade` on `this+648`. Position inheritance: when params[3] references another on-stage character, its layer x/y (stride-2456 table, +0x160/+0x164) are copied/swapped. Sample: `[4,71,3,-12345,9,-1,-1,-1,-12345,-12345,-12345]` = char 4, mode/pos 71, pose 3, no inheritance, 9 = y-slot, defaults elsewhere.

#### 3.3.5 op49 `cmdDefCharacter` @0x101012E0 — 446× (all in `defChara.rld`, nib=1) — evidence: decomp_h_cmdDefCharacter.txt

Character **definition** record: one flat CSV string of **357 or 431 tokens** (","-split): `charId, defId, body block, hair block, another block, faceCount`, then `faceCount` × **8-token face blocks** (expression id, image spec, offsets…). `-12345` = unused slot, `"NULL"` = null filename. Builds the `RetouchAdvCharacter` def entries consumed by op37. Sample head: `"4,0,3,1,31,267,-12345,-12345,1,0,0,NULL,0,0,0,NULL,…"`. Token-block boundaries per the decompile; exact per-slot meanings of the body/hair blocks are **[partially inferred]** — def data is static, so a reimplementer can treat this as an opaque table keyed by (charId, pose).

#### 3.3.6 op74 `cmdDraw` @0x101043C0 — 2210× (pc=16, nib=0) — evidence: decomp_h_cmdDraw.txt

CG background draw, param form only (16 int32):

| field | role |
|---|---|
| params[0] | cgId → `cgchCorrectCg(this, &cgId, holder)` (gallery remap, by reference) |
| params[1] | **mode**: `-3` → `UxAdvSystem::flashback2` (with clip rect `sub_10017350(x,y,x+w,y+h)` when w>0; silent-trio → immediate), `-2` → flashback, `-1` → mask draw, `≥0` → `UxAdvSystem::draw` transition-style mode. **Register indirection**: if mode ≥ 0x8000 → `mode -= 0x8010` and `cgId = holder.getReg(cgId)` |
| params[7..10] | x, y, w, h of the draw rect. If w ≤ 0 and params[13] has 0x10000 but not 0x40000 → fullscreen rect `(0, 0, this[721], this[722])` (screen w/h) |
| params[13] | flags word (0x10000 = fullscreen bit, 0x40000 = variant bit) |
| paramCount == 15 | extra = params[14] (and `mode<0 ? 0 : params[14]` as second extra) |
| paramCount == 16 | extras = params[14], params[15] |
| params[2..6] | transition/time/blend args passed to `draw` (sample: `[0,500,0,0,0]` — 500 = transition time) **[slot-exact roles: see decomp; partially inferred]** |

Sample: `[9999,9,0,500,0,0,0,0,0,1280,720,-1,-1,65536,0,0]` = CG 9999 (corrected), mode 9, 500 ms, fullscreen 1280×720.

#### 3.3.7 op94 `cmdBillboard` @0x1019CF20 — 1270× (sc=1, nib 4/6) — evidence: disasm_cmdBillboard.txt (1153 lines; Hex-Rays refused)

General **billboard layer primitive** (color rect / image / layer-copy-snapshot, plus delayed variants). `kind` selects the engine overload.

**Param form** (nibble 0; unused by this corpus but implemented): `stringCount == 3` → extra = params[18]. `lid = cmdLid2lid(params[1])`, `maskLid = cmdLid2lid(params[17])`, `x = cmdValue2Value(params[4])`, `y = cmdValue2Value(params[5])` (cmdValue2Value @0x101… resolves special position encodings); if maskLid valid & exists → `x += layer[maskLid].x; y += layer[maskLid].y` (align to mask layer). kind = params[0]: `0` color billboard (color = params[2], plus params[8..10], params[12]); `1` image billboard (alpha = low byte params[13]; params[3,6..10,12]; name = NULL); `2` image billboard with filename = strings[0]; `10` `delayBillboard` (params[2], x, y, params[8], params[14..16], params[10]); `12` delayed image w/ strings[0]; `3-9,11` no-op.

**String form** (nibble ≥ 2): token capacity by nibble: `≥4 → 31`, `==2 → 27`, else `26`; `splitParam(strings[0], tok, cap, ",", keepEmpty=1, NULL)`:

| tok | role |
|---|---|
| 0 | kind (str2int) |
| 1 | lid = `cmdLid2lid(calcExpression(tok))` |
| 2, 3 | x0 (calcExpression), y0 (str2int) |
| 4, 5 | x, y — nibble < 6: `cmdValue2Value(str2int(tok))`; nibble ≥ 6: `calcExpression(tok)` |
| 6..17 | 12 int slots (color, times, alpha, blend, mode…) consumed per kind |
| 18 | maskLid = `cmdLid2lid(str2int(tok))` → same align-to-mask as param form |
| 19 | flags2 word (nibble ≥ 2). If bit 0x10000 set and lid already exists → **early return (suppress re-create)**; then `flags2 &= 0xFF00F7FF` |
| 20..23 | extra ints (nibble ≥ 4; defaults −1) |
| 24 | **name/snap spec** — empty or `"-1"` → none; else drives kind-3 source parsing below |
| 25..29 | when named: rect slots (25..28) + surface property name (29 → `sub_100BFFA0`), sets internal flag 0x8000 |

Silent-trio → time slot forced to 0 (instant). Kind switch (13 cases):
- `0` color billboard; `1` image by id; `2` image file = tok[24] text.
- `3` **layer copy / snapshot**:
  - tok[24] starts with `'@'` → `createSnapList(rest, set<UxPosInt>)`; if it returns 3 → set surface from first element via `sub_10221680(layerMgr, lid, cmdLid2lid(src), mode, flags, -1)` + `setSurfaceProperty(surface(lid), flags2, tok19, -1)`; mode word (tok[9] slot): `9` → clamped time (≤16 else layer default @+0x170), `253/255` → −2 (instant show/hide), else −1 (plain show). Then: −2 → hide (`sub_10226210(lid, 0xFF)`); −1 → `showLayer(this+0x288, lid, -1,-1,-1,-1)`; ≥0 → `tmFadeEngine(this+0x288, 8, lid, time, …)` fade-in.
  - else split tok[24] by `";"` → srcSpec; if srcSpec contains `'.'`/`'-'` → multi-region snapshot list (`createSnapList(FCNList<UxPairInt>)` → region-wise billboard); else srcLid = `cmdLid2lid(str2int(tok24b))`, flags = (flags2 0x10000000 → 0x1) | (flags2 0x20000000 → 0x80) | (src layer state `[+0x5A4]==2` → 0x80) → `sub_10221680` copy + same show/hide/fade logic.
- `10` delayed color; `12` delayed image (tok[24] filename).
- Post-image: when named → `sub_102054F0` writes rect/clip from tok[25..28]; flag 0x8000 → `sub_10226910(lid)`; two RGB triples from the tail tokens → color-key/blend via `sub_102000C0(surface, 0xRRGGBB, …, index 1/2)`.

Sample (nib=6): `"1,600,0,16777215,0,0,1280,720,800,9,16,0,-2,0,0,0,0,-1,16,0,"` = image billboard on lid 600 at (0,0), 1280×720, time 800, mode 9. **Note**: a minority of op94 records store strings[0] hex-encoded (ASCII hex pairs) — decode before splitting (§10 risk R-HEXSTR).

#### 3.3.8 op95 `cmdRemoveBillboard` @0x10181BF0 — 1354× (sc=1, nib 1/3) — evidence: decomp_h_cmdRemoveBillboard.txt

String form: tok[0] = **attr word**: `mode = (word >> 8) & 0xF`; bit `0x800000` = region-split removal; low bits identify the target lid (via `cmdLid2lid`) **[low-bit split partially inferred]**. Remaining tokens: tok[1] = mask/time (−1 = all), tok[2] = fade/alpha (sample 256), tok[3] = `"*"` wildcard. Engine call: `removeBillboardEx(lid, mode, time, …)`. Sample: `"600,-1,256,*"` = remove billboard 600 (mode 2) with 256-step fade.

#### 3.3.9 op100 `cmdEnterMove` @0x1016DB80 — 1785× (sc=1, nib 0/1/2) — evidence: decomp_h_cmdEnterMove.txt

The **AsyncSeq keyframe mini-VM** (scripted layer motion). strings[0] = `"time,mode,payload…"`:
- tok[0] = total time, tok[1] = **mode**:
- **mode ≥ 0 → simple path** (26-token capacity): payload = 6 × `(layerLid, y, x, extra)` groups; relative-mode extras resolved by `calcExtraPos` (LocalPosCorrector, the handler's 4th arg @this+0x9024 — this is what the position-corrector object exists for). Sample: `"0,0,0,1,611,50,0,0,-1,…"` = group (lid 1 → y 611?? x 50) **[group order (layer,y,x,extra) per decompile; axis order risk R-MOVEAXIS]**, `-1` groups = unused.
- **mode < 0 → script path** (12-token capacity): payload = 6 × `(layerLid, script)`; script = `'.'`-separated step list, each step = opcode + args:
  | step | meaning |
  |---|---|
  | 0 | create layer track |
  | 1 | show (type 7) |
  | 2 | abs move to (x, y); arg −12345 → keep current coord from layer table (+0x160/+0x164) |
  | 3 | relative move (4 args) |
  | 4 | eased move (4 args) |
  | 5, 6, 8 | wait / delay variants |
  | 7 | sync SE: channel arg 0-2 → `this[698..700]`; soundId → `createSoundFilenameEngine(id)` + `".wav"` |
  | 9 | additive abs move (4 args) |
  | 255 | close track |
  - Special lid `−2` → `MoveWindow` **screen-shake** loop instead of a layer track.
- Execution: steps are queued on `UxAsyncSubsystem` (this+648) via `tmMoveEngine`/`tmInitFade`; op101 tears the sequence down. Per-step arg counts for 3/4/9 **[inferred from call sites; risk R-ASYNCARGS]**.

#### 3.3.10 op101 `cmdLeaveMove` @0x100E0450 — 1745× (pc=2, nib=0) — evidence: decomp_h_cmdLeaveMove.txt

`tmExitMove(this+648, params[0], params[1] != 0, false)` — stop the move sequence for group/track params[0]; params[1] ≠ 0 → immediate/forced teardown. Sample `[0,1]`.

#### 3.3.11 op243 `cmdExitFaceUp` @0x10181EC0 — 747× (sc=1, nib 2/3) — evidence: decomp_h_cmdExitFaceUp.txt (650 lines)

The **scene-restore mega-transition** used when returning from a face-up/CG cut-in to normal play. Token capacity by nibble: `0 → 35` (10 head + 5×5 char entries), `1 → 40` (10 + 6×5), `2 → 52` (10 + 6×7), `≥3 → 54` (12 + 6×7); missing trailing tokens default (keepEmpty split).

Head tokens:
| tok | role |
|---|---|
| 0 | **flag word**: bit31 = snap mode (capture screen) else solid-color cover; 0x40000000 = character array present; 0x20000000 = CG draw; 0x10000000 = remove extra billboard after; 0x800000 = clear all characters; bit8 = CG clip rect present; bit1 = auto-probe CG size; bit0 = clip; audio stops: 0x400 music, 0x800 env, 0x1000 loop, 0x2000 env-voice(×4); 0x200 = clear print; `HIWORD & 7` = transition style index → table `{1,3,5,7,9,1,1,1}` |
| 1 | cover billboard lid (calcExpression → cmdLid2lid) |
| 2 | color spec: non-empty & ≠ `"*"` → as-is; else lid ≤ 0 → `"-1"`; else `"-1.0-(lid−1)"`; parsed via `rgggbb2colorref` on '.'-split |
| 3 | fade time (silent-trio → 0) |
| 4 | extra billboard lid to remove (0x10000000): `removeBillboardEx(cmdLid2lid(calcExpression(tok)), 0, 0)` |
| 5 | CG id (0x20000000) → `cgchCorrectCg`; tok 6..9 = x,y,w,h clip (bit8); bit1 & missing w/h → probe from `createCgResFilename(id) + ".gyu"` header; → `UxAdvSystem::draw(cg, 255, …, flags |= bit1 ? 0x10000 : 0, transition = styleTable[HIWORD&7])` |

Character array (0x40000000): 5 or 6 entries × 7 tokens starting at tok[12] (nib<2… per capacity above): `{charId (cgchCorrectChara), pose, position, time, [nib≥2: 2 extras], else −12345}`. charId −1 → skip; pose −1 → `RetouchAdvCharacter::leave(255,…)`; else re-`enter` if not on stage → **restores the pre-cut-in character layout**.

nibble ≥ 3 tail: message-frame control word (`sub_101BE6C0`): `&3 == 1` → `cmdSetMessageFrame2(frame)` + `enterMessage(0,1,6)` if depth `this[4382]` ≤ 0; `== 2` → `leaveMessage`; `&0x30 == 0x10` → `UxLocalCtrl(this+0x44DC)::enter(0,0,1)`; `== 0x20` → leave.

Audio (per flag bits): stop via channel-handle tables — music `this[702+k]`, env `this[688+k]` (count `this[704]`), loop `this[696+k]` (count `this[705]`), env-voice 4 channels `this+2736[128..143]` window; each stop = volume→0 then `sub_101F8830(handle)`; then `UxAdvSystem::stopMusic/stopEnv/stopLoopEffect(this, 0, -1…)`.

Finale: snap mode → `createSnapList` + `billboard(snapList, mode 255, flags 0x30000000)` (screen capture as cover); else solid-color `billboard(lid, 0, colorref, …, time, mode 9|1, 16, -2, …)`. Then `removeBillboardEx(lid, 1, fadeTime)` (snap: time+200) = fade back to the restored scene; talk-mark restore when `this[987] ≥ 0` (`ctrlTalkMark(false)`/`execTalkMark`). Sample: `"1619198211,700,-1.0-700,-1,0,300,409,133,624,351,0,-1,4,71,0"` → flag word 0x60830103 = char array + CG draw + style 1(→3) + clip + bit0/bit8; cover lid 700; CG 300 at (409,133) 624×351; char entry (4, pose 71, pos 0).

**op242 `cmdFaceUp` @0x1016FFD0** (16×) — the entering counterpart (CG cut-in start; sample `"537931776,-2,0,0,*,0,0,-1,-1,0,-1,*,655,…,res\\g\\e…"` = flag word 0x20100000, lid −2, CG file path token). **Hex-Rays returned None; disasm not yet walked — shallow entry, §10 risk R-FACEUP.**

#### 3.3.12 op18 `cmdFrameView` @0x1015BCA0 — 729× (pc=2, nib=0) — evidence: decomp_h_cmdFrameView.txt

Message-frame window control: `params[0] ≥ 0` → `enterMessage(params[0], …, params[1])` (show frame id with time params[1]); `< 0` → `leaveMessage`. The `paramCount(byte+6) == 2` variant passes the time; other counts use defaults. Sample `[0,400]` = show frame 0 with 400 ms.

#### 3.3.13 op19 `cmdCtrlView` @0x100E00C0 — 731× (pc=1, nib=0) — evidence: decomp_h_cmdCtrlView.txt

`UxLocalCtrl` (embedded at `this+17628` = 0x44DC) enter/leave: `params[0] ≥ 0` → `UxLocalCtrl::enter(params[0], …)` (show local control UI — click/wait surface); `< 0` → leave. Sample `[0]`.

#### 3.3.14 op50 `cmdPlayMusic` @0x10115B40 — 474× (sc=1, nib=3) — evidence: decomp_h_cmdPlayMusic.txt

nibble < 3 → param form; nibble ≥ 3 → 9-token string: `tok[0]` music id (**≥ 1000000 → `getReg(id−1000000)` indirection**; `0x20000000` = "none" sentinel), `tok[1]` mode/restart, `tok[2]/tok[3]` volume L/R (**×4 internal fade scaling** applied to fade args), `tok[4]` loop flag, `tok[5..7]` fade-in/out times, `tok[8]` stream/ext selector (−1 default). Silent-trio suppresses start during skip. Error paths log `cmd.execIndex` (dword @+212). Sample `"24,0,144,144,1,0,0,0,-1"` = track 24, vol 144/144, loop.

#### 3.3.15 op56 `cmdPlaySE` @0x100C33B0 / op58 `cmdPlaySyncSE` @0x100C33D0 → `cmdPlaySEEngine` @0x1016FD20 — 573× / 178× — evidence: decomp_x_cmdPlaySEEngine.txt (complete)

Thunks: op56 → `cmdPlaySEEngine(cmd, async=true, holder)`; op58 → `async=false` (blocking).

Suppression gate: vtbl[15] true → return; else if `this[1158]`: value 2 (bit1) → play only when `async==true`; any other non-zero, or `byte[+4836]` set → return.

Args — param form (nibble < 2): `params[0]` sound id, `params[1]/[2]` vol L/R, `params[3]` channel, nibble == 1 adds `params[4]` packed word (low byte = **type**, BYTE1 = **voice group**); nibble 0 → type 0. String form (nibble ≥ 2): 5 tokens `id(calcExpression), volL, volR, channel (str2int), packed word (sub_101BE6C0)`.

Type dispatch:
- `0` → `playEffect(channel, id, async, ".wav", volL, volR, 16, false)`
- `2` → same with `".ogg"`
- `1` → **voice**: channel `−2` → auto-assign free voice channel (`sub_1001B3B0(this+2736)+1`); volume correction: group > 0 → `correctVoiceVolume(group)` / `isMuteVoice(group)`, else `correctVolume(33)` / `isMuteEffect(16)`; `playVoice2(...)`; if `!async` (op58) → `waitVoice` + `stopVoice` (blocking playback); id ≥ 0 → `experienceMessage(id)` (gallery voice-mark).

Sample (param, nib 1): `[34,256,256,1,0]` = SE 34, full volume, channel 1, type 0 (.wav).

#### 3.3.16 op240 `cmdPlayEnvVoice` @0x100E0860 — 640× (sc=1, nib=1) / op241 `cmdStopEnvVoice` @0x10101C40 — 545× — evidence: decomp_h_cmdPlayEnvVoice.txt, decomp_h_cmdStopEnvVoice.txt

Ambient voice bed. op240 extended string: 6/7 tokens (nibble-dependent): `tok[0]` channel slot (4 env-voice channels, handle table @this+2736 window 128..143), `tok[1]` sound id, `tok[2]` fade time, `tok[3]/[4]` vol L/R, `tok[5]` loop/mode, `tok[6]` optional filename-or-spec (`"-1"`/absent → derive from id). Sample `"0,117,300,256,256,2,7.-1"`. op241: 2/3 tokens `channel, fadeTime, [mask]`; sample `"0,300,-1"`.

#### 3.3.17 op78 `cmdFadeOutEvent` @0x1012A080 — 321× (sc=1, nib=2) — evidence: decomp_h_cmdFadeOutEvent.txt

6-token string (or param form at lower nibbles): `tok[0]` attr/event word, `tok[1]` layer/event mask word, `tok[2]/[3]` fade times, `tok[4]` color (0xFFFFFF = white), `tok[5]` mode → `cmdLid2lid` resolution + `sceneFadeOut(...)` on the async subsystem. Sample `"520159103,114687,400,400,16777215,83"`.

#### 3.3.18 Remaining top-20 members — family-level notes (shallow; names/EAs authoritative, bodies not walked)

| op | handler @EA | count | corpus form / sample | family notes |
|---|---|---|---|---|
| 33 | `cmdLeaveCharacters` @0x10171970 | 297 | pc=6 `[16777216,-1,-1,-1,-1,-1]` | plural leave: params[0] = char selector word (0x01000000 — byte3 = charId or per-slot bitmask **[INFERRED]**), −1 = all positions/times |
| 38 | `cmdLeaveCharacter` @0x10101FD0 | 126 | `"4,31,3,-1,-1,0,*"` | singular leave: charId, pose, mode, times; inverse of op37 |
| 257 | `cmdManpu` @0x1015CD60 | 290 | `"4163,1004,75,0,3,3,555,198,12,A.#1(15){4,-10}…"` | emotion-mark/effect overlay: id, x, y, timing, then an embedded `'.'`/`{}`-step effect script (same step grammar family as op100) |
| 258 | `cmdClearManpu` @0x1016D570 | 296 | `"1,-1,-1"` | remove manpu marks |
| 54 | `cmdPlayLoop` @0x1018BFF0 | 242 | `"703,0,256,256,0"` | looping SE: id, channel, volL, volR, mode — same playEffect plumbing as op56 (type = loop) |
| 55 | `cmdStopLoop` @0x1015D810 | 260 | pc=3 `[300,0,0]` | stop loop with 300 ms fade |

#### 3.3.19 Anomaly: op47 — no handler, but 72 corpus records

Census: op47 ×72 (all `cgMode.rld`, pc=2, sample `[2000,1]`). `createMethodTable` never assigns slot 47 → it stays `cmdDummy` @0x100E4060 = **genuine engine no-op** (the shipped game also ignores these records; the shape `[2000,1]` suggests a disabled wait). A reimplementer MUST keep op47 inert for parity — do not "helpfully" implement it as wait. (§10 risk R-OP47.)

## 4. `splitParam` — the parameter grammar **[SETTLED]**

### 4.1 Call chain and signature

```
RetouchSystem::splitParam @0x100dfd10 (thiscall)
  (FCString& src, FCString* out, int maxTokens, char* delimSet, char keepEmpty, char* restOut)
  → copies src into a temp 12-byte handle (sub_101BE000, COW — the caller's cursor is NOT consumed)
  → sub_101C1860 @0x101c1860: flags = (delimSet!=0 ? 2:0) | (restOut!=0 ? 1:0); forwards
  → sub_101C16D0 @0x101c16d0 "splitterCore": loop, one 12-byte FCString slot per token,
      per-token call to the tokenizer sub_101C12D0; LAST slot (index maxTokens-1) receives the
      ENTIRE REMAINDER of the string (not re-split); flags&4 / flags&8 save/restore the source
      cursor around the split; returns token count (capped at maxTokens).
  → tokenizer sub_101C12D0 @0x101c12d0 (this = source FCString handle, ecx):
```

Evidence: `decomp_splitParam.txt`, `decomp_splitter_101C1860.txt`, `decomp_splitterCore_101C16D0.txt`, `decomp_tokenizer_101C12D0.txt`, `decomp_fcMark_101BEC40.txt`, `decomp_fcScan_101C0890.txt`, `decomp_fcAdvance_101BF010.txt`, `decomp_sub_101C0050.txt`.

### 4.2 FCString runtime representation (needed to read the tokenizer)

12-byte **handle**: `{ +0: (aux/vtable-ish, unused by VM), +4: Cell*, +8: char* cursor }`.
**Cell**: `{ +4: int refcount, +8: int length, +16: int capacity, +20: char* text }`; end-of-string for scanning = `text + length` (NOT necessarily NUL at text[length] until assigned; `sub_101BDF20` NUL-terminates).
Helpers: `sub_101BE000` copy-ctor (shares cell, COW via refcount), `sub_101BDFF0` dtor, `sub_101BDF20(slot, initialCap, cstr)` assign-from-C-string (`nullptr` → empty), `sub_101BE570` clear (if refcount>1 detach-and-reassign-empty, else `text[0]=0; length=0`), `sub_101BE0A0` append C-string, `sub_101BFA50` append formatted int.

### 4.3 Tokenizer algorithm (exact)

`sub_101C12D0(outSlot, delimSet, keepEmpty, &outCursor)` — returns 0 = end-of-source, 1 = token produced, 2 = token produced AND source exhausted by a trailing delimiter (only when keepEmpty):

1. **Token start**:
   - keepEmpty != 0: start = cursor; if `*cursor == 0` → return 0.
   - keepEmpty == 0: `cursor = _mbsspnp(cursor, delimSet)` (MBCS-aware skip of ALL leading delimiter chars); if the whole remainder is delimiters → cursor = text-end and return 0.
2. **Token end**: `sub_101BEC40` = `cursor = _mbspbrk(cursor, delimSet)` — first occurrence of ANY character of delimSet at/after cursor, or `text+length` if none. (`_mbspbrk`/`_mbsspnp` are MBCS-aware: a Shift-JIS lead byte swallows its trail byte, so a trail byte equal to `','` inside a 2-byte char is NOT a delimiter.) Optional out-param receives this position via `sub_101C0890(0,1)`.
3. **Copy**: len = end − start. len < 1 → `sub_101BE570(outSlot)` (empty string). len < 2048 → `_mbsnbcpy` into a 2052-byte stack buffer, NUL-terminate, `sub_101BDF20(outSlot, 256, buf)`. len ≥ 2048 → `malloc(len+2)` (throws `"FCString"` / `"メモリが足りません！"` @0x104240E8 on OOM), copy, assign, free.
4. **Advance**: if `*end != 0` (cursor sits on a delimiter): `sub_101BF010` = `cursor = CharNextA(cursor)` (one MBCS char past the delimiter). If now at NUL and keepEmpty → return 2.
5. Return 1.

### 4.4 Grammar summary (what an implementer must reproduce)

- **Delimiter is a CHARACTER SET, applied per-byte-position with MBCS awareness.** No quoting. No escaping. No whitespace trimming (unless the caller passes a delimSet containing space). Empty tokens: preserved iff keepEmpty (flags&1), else collapsed.
- Token cap = `maxTokens`; **the last slot always gets the raw remainder** including any further delimiters (so callers use `max = N+1` when they want "N fields + tail", e.g. op22 gosub `"10300,*,*,0"` split with max 3 → tokens `10300`, `*`, `*,0`... — verified against splitterCore: on the final iteration the tokenizer is called with the unsplit remainder / the remainder is copied wholesale).
- Return value = number of slots filled.
- Delimiters actually used by the VM: `","` (@0x10423EA8, bytes `2C 00`) for op5/op12/op22/op94/op100... string forms; `";"` for the condition OR-chain in `liteCheckConditionEngine` @0x1018b850 (`splitParam(text,out,24,";",0,NULL)`); `"."` and `";"` appear INSIDE token payloads as secondary mini-languages parsed by handlers themselves (e.g. op100 keyframes `"2.-12345.-12345.3.100.0.-16..."`, op240 `"7.-1"`), not by splitParam.
- `"*"` is the universal wildcard token ("default/none"), and `"-12345"` (0xFFFFCFC7) is the universal "parameter unused" sentinel — both appear throughout the corpus (e.g. op37 params, op95/op22/op5 strings).
- Numeric conversion of tokens goes through `sub_101C28C0` @0x101c28c0: `"0x…"` → hex (`sub_101C1150`), `"0b…"` → binary (`sub_101C11D0`), else `atoi`. Boolean-ish tokens like `"true"` in op23 are handled by handler-specific parsing (§5, liteStr2Value).

### 4.5 Worked examples (real corpus strings → parse trees)

| Record | Raw string | Call | Tokens |
|---|---|---|---|
| op5 block header | `"-1,33554480,-1,*,0,0,*"` | split(max 7, `,`) | `[-1][33554480][-1][*][0][0][*]` → blockId=auto, flags=0x2000030, msgFrame=-1, …, condition token (§3.2) |
| op22 gosub | `"10300,*,*,0"` | split(max 3, `,`) | `[10300][*][*,0]` → target block 10300, cond `*` (true), tail unused |
| op20 jump | `"R1300==4"` + params[0]=110 | condition parsed by liteCheckConditionStr | sreg/`R1300` == 4 → pc = blockId2Index(110) |
| op95 | `"700,800,769,res\\g\\gn\\m\\0139.gyu"` | split(max 4, `,`) | billboard id 700, time 800, flags 769, image path |
| op17 | strs = `["1_001_02_com", "*"]` | no split (2 string slots) | next scenario name + entry block (`*` = default entry) |
| op94 | `"1,600,0,16777215,0,0,1280,720,800,9,16,0,-2,0,0,0,0,-1,16,0,*,0,0,-1,-1,-1,0,0,0,0,ＭＳ Ｐゴシック,0"` | split(max 31, `,`) | text billboard: layer, ids, RGB 0xFFFFFF, rect 1280×720, time 800, …, font name (full-width SJIS, MBCS-safe because `_mbspbrk` skips trail bytes) |

Note: some op94 records store the SAME string ASCII-hex-encoded (`"332c3730302c..."` = hex of `"3,700,..."`) — a tool-side obfuscation; see Risk Register (§10) for the decode location question.

## 5. `liteCheckCondition` — the condition language **[SETTLED]**

### 5.1 Entry points and evaluation chain

| Entry | EA | Signature / behavior |
|---|---|---|
| String form | `?liteCheckCondition@RetouchSystem@@QAE_NABVFCString@@AAVLocalHolder@@@Z` (called from liteExec @0x101B6C0F, 0x101B6F46) | `bool(const FCString& text, LocalHolder&)`: **TRUE if text is empty, or text == `"*"`, else `Engine(text.c_str())`** (`decomp_liteCheckConditionStr.txt`: `len==0 || lstrcmpA(text,"*")==0 || Engine(...)`) |
| Engine (OR level) | 0x1018B850 | `splitParam(text, out[24], 24, ";", keepEmpty=0, NULL)` → **returns TRUE if ANY segment satisfies `Sub`** (short-circuits on first true) (`decomp_liteCheckConditionEngine.txt`) |
| Sub (AND level + comparison) | 0x10180920 | `bool(const FCString& seg, LocalHolder&)` — `&`-separated conjunct chain via `sub_101C18A0(src,"&",outSeg)` (returns non-zero while more segments follow); short-circuits FALSE. Each conjunct is one predicate (below). 858-line disasm: `disasm_liteCheckConditionSub.txt` |
| Precompiled form | 0x10120860 | `bool(CMD_DATA&, LocalHolder&)` — reads 5 condition slots straight out of the record (§5.6); used by numeric-form op20/op22 (called from liteExec @0x101B6F35) |

```
condition  := orTerm { ";" orTerm }            ; TRUE if any orTerm is true
orTerm     := predicate { "&" predicate }      ; TRUE if all predicates true (short-circuit)
predicate  := "true" | "false" | comparison    ; lstrcmpA exact match, case-SENSITIVE ("true"@0x104305F4, "false"@0x104305EC)
comparison := LHS operator RHS
```

Whitespace `" \t"` (@0x10425374) is trimmed around LHS (via `sub_101C0050`) and around/inside the operator (delim set `"=<>! \t"` @0x104305BC).

### 5.2 Operator recognition and cmpOp codes (STRING form)

LHS is split off with `splitterCore(out[2], max=2, delim="=<>!" @0x104305C4, trim=" \t", ...)` — token[0] = LHS, token[1] = operator+RHS remainder; the cursor then skips `"=<>! \t"` leaving the RHS text.

Operator → 3-bit code `esi` (evidence: 0x1018102D-0x1018106E):
- single-char path: `'>'` → `esi = c − 0x3C` = **2**; `'<'` → `esi = c − 0x38` = **4**
- two-char path (byte table `byte_101815E4`, 30 entries indexed `c − 0x21`, jump `jpt_10181050`): `"=="`→**0**, `"!="`→**1**, `"<="`→**5**, `">="`→**3** (IDA case annotations: case 61→esi=0, case 33→esi=1, case 60→esi=5, case 62→esi=3)
- unrecognized → default block with esi = 0 (EQ) — this is why a bare `"0"` predicate is TRUE: LHS="0", no operator, RHS="" → `calcExpression("0")==calcExpression("")` → `0==0` ✓ (the op5 block-header corpus condition `"0"` = always-true)

**cmpOp code semantics (STRING form), proven by the final numeric switch `jpt_101814C5` (0x101814CC-0x101814F4: `cmp edi,eax` then set-flag):**

| code | x86 | meaning | string-compare helper |
|---|---|---|---|
| 0 | `setz` | EQ | `sub_1005F6B0` |
| 1 | `setnz` | NE | `sub_1005F6F0` |
| 2 | `setnle` (signed >) | GT | `sub_100CD150` |
| 3 | `setnl` (signed >=) | GE | `sub_100CD180` |
| 4 | `setl` (signed <) | LT | `sub_1005CEE0` |
| 5 | `setle` (signed <=) | LE | `sub_100CD1B0` |

(Helper↔code binding cross-verified: every switch — `jpt_10181183`, `jpt_10181291`, `jpt_10181408`, cp932 `jpt_10180B6F` — dispatches the same code to the same helper.)

⚠️ **The PRECOMPILED (CMD_DATA) form uses a DIFFERENT code table for 4/5** — see §5.6. Do not share one enum between the two evaluators.

### 5.3 Codepage branch: cp932 full-width operators

`Sub` begins with `cmp CodePage, 3A4h (932); jnz generic` (0x10180975). On cp932 it FIRST scans for full-width operators (delim set @0x104305DC, bytes `81 81 / 81 82 / 81 86 / 81 84 / 81 83 / 81 85`); the operator word (SJIS code read big-endian) is switched via `esi = word − 0x8181` (`jpt_10180B6F` for string compares, `jpt_10180EC7` for numeric). If no full-width operator is present it falls into the same generic ASCII path (0x10180FBC+). Verified identities (Python cp932 decode):

| SJIS | char | case value | helper | semantics |
|---|---|---|---|---|
| 0x8181 | ＝ | 33153 | F6B0 | EQ |
| 0x8182 | ≠ | 33154 | F6F0 | NE |
| 0x8183 | ＜ | 33155 | 5CEE0 | LT |
| 0x8184 | ＞ | 33156 | CD150 | GT |
| 0x8185 | ≦ | 33157 | CD1B0 | LE |
| 0x8186 | ≧ | 33158 | CD180 | GE |

Non-cp932 codepages get ASCII-only operators. (AetherKiri targets cp932 content; implement the full-width set too.)

### 5.4 LHS/RHS type resolution (generic path, 0x10181069-0x101814F4)

1. **LHS starts with `'T'`** (string-register reference): advance, `n = str2int(rest)` (`sub_101C28C0`), LHS value = treg cell `sub_101F6C10(n)` on the string-reg manager (`[RetouchSystem+0xB40] + 0x24`), copied into an FCString. Then by RHS form:
   - RHS starts with `'"'`: extract quoted literal (tokenizer with delim `"\""` @0x1042D1CC, keepEmpty) → **string compare** LHS-cell vs literal via helper[esi] (`jpt_10181183`).
   - RHS starts with `'T'`: parse m → treg(m) cell → **string compare** cell vs cell (`jpt_10181291`).
   - otherwise: `v = calcExpression(RHS)` → format `v` as signed decimal (`sub_101BFA50(..., radix 10, ...)`) → **string compare** LHS-cell vs decimal text (`jpt_10181408`). (So `T3==5` compares treg3's TEXT against `"5"` lexicographically via the helper, not numerically!)
2. **LHS not `'T'`** (0x10181496): `lhsVal = calcExpression(LHS)`, `rhsVal = calcExpression(RHS)` → **signed integer compare** via `jpt_101814C5` (§5.2 table). Both sides support the full expression grammar, so `R1+R2 > Q4` is legal.

String compares on cells ultimately reduce to `lstrcmpA`-style ordering inside the six helpers (each helper = one predicate direction; all take `(cellOrFCString this in ecx, other FCString pushed)`).

### 5.5 calcExpression — whitespace-separated RPN @0x1016D1E0 (267 insns, `disasm_calcExpression.txt`)

```
expr    := '@' funcCall            ; first char '@' → calcFunction(expr, holder)  (§5.7)
         | '-' literal             ; first char '-' → whole string via liteStr2Value (negative literal)
         | operand
         | rpn
rpn     := token { token }         ; tokens split on ' ' (keepEmpty=0)
token   := '+' | '-' | '*' | '/' | operand
```
- Evaluation: operand stack (object @var_4C; push = `sub_1011E8A0`, pop = vtbl+0x1C). Operand → `liteStr2Value(token, holder)` → push int. Operator → pop a (top), pop b: `+`→b+a, `-`→b−a, `*`→b*a (imul), `/`→b/a (`cdq; idiv` **signed**); divisor 0 → error log (OutputDebugString chain) and result 0.
- Single operand (no `*+-/` found by `_mbspbrk` scan, delim `" *+-/"` @0x1042FE24): rewind cursor, return `liteStr2Value(whole expr)`.
- Result = final pop. All arithmetic is 32-bit signed int.
- Note: because tokens are space-split, `R1+1` (no spaces) is ONE operand handed to liteStr2Value, not addition; scripts must write `R1 1 +`. Corpus conditions are overwhelmingly simple `LHS op RHS` forms.

### 5.6 Precompiled CMD_DATA form @0x10120860 (`decomp_liteCheckConditionCmd.txt`)

5 slots, AND-ed, early-out FALSE. Slot i (i=0..4) fields — offsets relative to record base:

| field | offset | meaning |
|---|---|---|
| kind | `+12+12i` (= params[1+3i]) | `<0` → slot unused (skip); 0/1/2 below |
| regId | `+16+12i` (= params[2+3i]) | register index |
| cmpOp | `+20+12i` (= params[3+3i]) | comparison code |
| value | `+92+12i` (= strings[i]) | FCString; RHS text (run through liteStr2Value for kinds 0/1) or string literal for kind 2 |

- **kind 0**: `LocalHolder::getReg(holder, regId) CMP liteStr2Value(strings[i])` — signed int compare.
- **kind 1**: `UxAdvSystem::sreg(correctSregExpression(regId)) CMP liteStr2Value(strings[i])`.
- **kind 2**: string compare of treg cell `sub_101F6C10(regId)` vs `strings[i]`: cmpOp 0 → `sub_1005F6B0` (EQ), cmpOp 1 → `sub_1005F6F0` (NE); any other cmpOp → slot is a no-op pass.
- **cmpOp codes HERE: 0 EQ, 1 NE, 2 GT(`>`), 3 GE(`>=`), 4 LE(`<=`), 5 LT(`<`)** — codes 4/5 are SWAPPED relative to the string form (§5.2). Evidence: Hex-Rays cases 4/5 emit `<=`/`<` (lines 51-56, 106-111) while `jpt_101814C5` cases 4/5 emit `setl`/`setle`. Both readings are direct; the divergence is real. The scenario compiler that emits precompiled slots uses the CMD table, so records are self-consistent — but a re-implemented toolchain must not mix the two tables. (In the imopara3 corpus, conditions appear overwhelmingly in string form; the precompiled path is exercised by numeric-form op20/op22 records — see §10 risk R-COND.)

### 5.7 calcFunction @0x1016BEA0 (1438 insns, `disasm_calcFunction.txt`) — PARTIAL

Reached when an expression/operand starts with `'@'`. Parses `@name` then argument list using delims `"("`, `"( \t"`, `"' \t)"`, `")"`, `"'"` (single-quoted string args supported). Builtins identified so far from string refs: **`random`** (@0x1042FE00) and **`randomSet`** (@0x1042FE08); `"NULL"` (@0x104275CC) and path prefix `"res\dob"` (@0x1042D314) appear in argument handling. The full builtin table is NOT yet enumerated — **GAP** (see §10). For story-mode replay fidelity, `random`/`randomSet` semantics matter (RNG seed persistence across save/load); flag for the implementer.

### 5.8 liteStr2Value — operand resolver @0x10114EE0 (707-line disasm, `disasm_liteStr2Value.txt`) **[SETTLED]**

Switch on first char (case-insensitive; jump via byte table @0x10115A48). Cursor restored on return. Values are 32-bit ints.

| prefix | grammar | value |
|---|---|---|
| (digit/other) | `num` | `str2int` = `sub_101C28C0`: `0x…` hex, `0b…` binary, else `atoi` |
| `R`/`r` | `R<n>` | `LocalHolder::getReg(n)` — user register file |
| `L`/`l` | `L<n>` | `sreg(correctSregExpression(n + 1000000))` — local register (N_LOCREG=100 in ini) |
| `S`/`s` | `S<n>` | identical to `L<n>` (alias; same +1000000 → correct → sreg path) |
| `F`/`f` | `F<n>` | bit `n&31` of `sreg(correct(1000004))` → 0/1 (32-bit system flag word) |
| `B`/`b` | `BR<reg>.<bit>` | bit `bit&31` of `getReg(reg)` → 0/1 (delim between fields = charset @0x10424588; bit must be ≤ 0x1F) |
| `C`/`c` | `C<n>` | `UxAdvSystem::checkSystemFlag(n&31)` → 0/1 |
| `Q`/`q` | `Q<n>` | system query — inner switch, 21 cases (§5.9) |
| `M`/`m` | `MM<x>` / `MG<x>` / `MS<x>` / `MV<x>` | gallery-experience booleans: `RetouchResManager::isExperienceSound/Cg/Scene/Message(n)` where `<x>` is a number or a nested liteStr2Value operand |

`correctSregExpression(id)` (0x10072D00-family, `decomp_correctSregExpression.txt`): `id < 1000000 ? id : sreg(15) + id − 1000000` — **sreg 15 is the relocation base for the whole local/system block ≥ 1000000**. `sreg` get = `*(dword*)sub_1025F910(id)`; set = `sub_1023BCF0(id, val, 0)` (global system-register array, N_SYSREG=13000 per ini).

### 5.9 Q-system queries (inner switch of liteStr2Value, `jpt_10115369`)

| Q | value |
|---|---|
| Q0 | `isExistSaveData(273)` → 0/1 (system slot 0x111) |
| Q1 | `isExistSaveData(17)` → 0/1 (slot 0x11) |
| Q2 | dword `[RetouchSystem+0x4498]` (branch/state field adjacent to +0x4490/+0x4494, §8) |
| Q3 | date/time code: localtime (`sub_10264AE0`) packed (month/day fields) → small enum (era/season-style code) — **partially decoded** |
| Q4 | aspect-ratio class from current W/H at `[+0xB44]`/`[+0xB48]`: ratio = W*256/H mapped through thresholds (0x100→1, <0x12C→0xB, <0x172→0x2B, 0x140→0x36, 0x155→0x2B, 0x199→0x64A, 0x1C7→0x649, ≥0x1D6→0x650/0x656) — **inferred purpose: display-mode selector** |
| Q5 | user "expression" setting: if `[+0x4488] >= 0` → load from settings path @0x104254C0 → non-zero test |
| Q6 | `(sreg(30) >> 16) & 1` |
| Q7 | flags byte `[+0x4C] & 1` (same byte whose bit7 gates the start.rld special in liteExec) |
| Q8 | reads a 4-byte little-endian counter from a file under `res\dob` (@0x1042D314); missing file → 0 — **inferred: play-through statistics** |
| Q10 | vcall on `[+0x8418]` then `word[+0x842C]*100 + word[+0x842E]` — inferred mouse/pointer position encoding |
| Q11..Q18 | raw `word` at `[+0x8424]`, `[+0x8426]`, `[+0x8428]`, `[+0x842A]`, `[+0x842C]`, `[+0x842E]`, `[+0x8430]`, `[+0x8432]` respectively (system value bank) |
| Q20..Q29 | `sub_100C6D40(n − 20)` on manager `[+0x9CF8]` (null → 0) — parameterized manager query |
| Q9, Q19, Q>29 | 0 (default) |

### 5.10 Reference C++ sketch (string form)

```cpp
bool checkCondition(std::string_view text, LocalHolder& lh) {
    if (text.empty() || text == "*") return true;
    for (auto orTerm : splitKeepNone(text, ';'))          // max 24 segments
        if (checkAndChain(orTerm, lh)) return true;
    return false;
}
bool checkAndChain(std::string_view seg, LocalHolder& lh) {
    for (auto pred : splitKeepNone(seg, '&'))             // short-circuit AND
        if (!checkPredicate(pred, lh)) return false;
    return true;
}
bool checkPredicate(std::string_view p, LocalHolder& lh) {
    p = trim(p, " \t");
    if (p == "true")  return true;
    if (p == "false") return false;
    // split LHS at first char of "=<>!" (cp932: also full-width set)
    auto [lhs, op, rhs] = splitAtOperator(p);             // op → code per §5.2/§5.3
    if (lhs.starts_with('T')) {
        FCString a = treg(parseAfterT(lhs));
        if (rhs.starts_with('"'))  return strCmp(op, a, unquote(rhs));
        if (rhs.starts_with('T'))  return strCmp(op, a, treg(parseAfterT(rhs)));
        return strCmp(op, a, toDecimal(calcExpression(rhs, lh)));
    }
    int l = calcExpression(lhs, lh), r = calcExpression(rhs, lh);
    switch (op) {                                          // §5.2 STRING-form codes
    case 0: return l == r; case 1: return l != r;
    case 2: return l >  r; case 3: return l >= r;
    case 4: return l <  r; case 5: return l <= r;
    }
    return l == r;                                          // unrecognized op → EQ
}
```

## 6. Register and state layout

Six script-visible value spaces. Counts from `D:\imopara1\imopara3\ExHIBIT.ini`; all addresses image-base 0x10000000.

### 6.1 Bank overview

| bank | script operand | type | count | storage | primary accessors |
|---|---|---|---|---|---|
| **R** | `R<n>` | int32 | `N_REG=2048` | global cell array in UxAdvSystem + per-run **LocalHolder overlay** | `UxAdvSystem::reg(int[,int])`; `LocalHolder::getReg/setReg` |
| **S** | `S<n>` | int32 | `N_SYSREG=13000` | `FCReg` embedded at `UxAdvSystem+16644` | `UxAdvSystem::sreg(int[,int])`; setter `sub_1023BCF0` |
| **T** | `T<n>` | string cell | `N_STRREG=256` | treg object `RetouchSystem[0xB40]`, cell array @obj+0x24 | `UxAdvSystem::treg(int,char*)`; cell read `sub_101F6C10` |
| **Q** | `Q<n>` | int32 (computed) | — | query object `RetouchSystem+0x9CF8` | `sub_10071100` dispatch (§5.9) |
| **L** | `L<n>` | int32 | `N_LOCREG=100` | loc bank | `loc_sreg(int,int)` (cmdExHIBITMain case 48) |
| **F** | `F<n>` | flag bits | — | **sreg(1000004)** flag word | via S bank |

Expression/condition operand letters are resolved by `liteStr2Value` (§5.8); the engine's own debug introspection (`liteRegInfo`, §6.8) confirms the R/S/T three-bank model.

### 6.2 LocalHolder — the R overlay **[SETTLED]**

Evidence: `decomp_x_lh_ctor.txt`, `decomp_x_lh_getReg.txt`, `decomp_x_lh_setReg.txt`, `decomp_x_lh_searchReg.txt`, `decomp_x_lh_flushReg.txt`, `decomp_x_getRegEngine.txt`, `decomp_x_setRegEngine.txt`.

```cpp
struct LocalHolder {              // 20 bytes; ctor @0x1004E430
    UxAdvSystem* engine;          // +0   back-pointer (RetouchSystem derives from UxAdvSystem)
    RegNode*     locals;          // +4   sorted list of {int id; int value;} overrides
    uint8_t      csMode;          // +16  bit0 = thread-safe (critical-section) mode
};
```

- **`getReg(id)` @0x1004E5E0** — csMode → CS-wrapped; core = **`getRegEngine` @0x1004E2C0**: `searchReg` @0x1004DD80 linear-scans the sorted list; node found → local value, else → `engine->reg(id)` (global bank).
- **`setReg(id, v)` @0x1004E510** — `id < 0` → **no-op**; core = **`setRegEngine` @0x1004E220**: update existing node else insert in sorted order. Never touches the global bank.
- **`flushReg()` @0x1004E170** (engine-side twin `flushRegEngine` @0x1004DCE0) — writes **every** local override back with `engine->reg(id, value)`, then clears the list (overlay merge + teardown at scope exit).
- **ctor(engine, threadSafe)** — `threadSafe=true` additionally registers `this` at `engine+4644` via `setLocalHolderPtr` @0x1000A500; the CS object lives at `engine+4648`. `execRld` constructs with `false` (§7.4).
- **Engine-side routing**: `setRegEx` @0x100DFBF0 / `getRegEx` @0x100DFC20 — if `engine+4644` ≠ null → route through the registered holder, else direct global `reg()`. Lets engine subsystems respect the active overlay outside the script thread.
- Purpose **[inferred]**: speculative scopes (block-entry condition scans, question previews, nested calls) mutate R-regs locally without polluting the global bank until commit via `flushReg`.

### 6.3 Global R bank — known assignments

`UxAdvSystem::reg(int)` getter / `reg(int,int)` setter (`decomp_ux_reg_reg@UxAdvSystem.txt`). Runtime contract (all disasm-verified in `disasm_liteExec.txt` unless noted):

| reg | meaning | evidence |
|---|---|---|
| reg(2) | entry/resume block id | written at liteExec init 0x101B66E7 and the load-resume path |
| reg(3) | last autosave pc — op12 skips re-saving when `reg(3)==pc`; reset to −1 at scenario switch | 0x101B6EAC |
| reg(4) | message-window flags word (applied at scenario load: bit0 frame enter, bit1 local-ctrl enter, bit7 backlog state `[+0xF68] bit2`) | outer-loop head |
| reg(5) | current record index (per iteration, when not suppressed) | §3.0 loop head |
| reg(6) | cleared at script end (`reg(6,0)`, case 24/140) | 0x101B7205 |
| holder R2 | **current block id** (op5 entry, `LocalHolder::setReg(2,·)`) | 0x101B6D50 |
| R1001+ | script-owned general purpose (corpus op6 writes R1001) | census |

### 6.4 S bank (sreg) — system registers

- Setter `sub_1023BCF0(this, id, value, notify)`: `notify ≠ 0` → change notification `sub_10238680(id)` (engine reacts to watched system regs). Evidence: `decomp_ux_sreg_sreg@UxAdvSystem.txt` + cached setter decompile.
- **FCReg layout** (shared by int banks): `{+0 vtbl/flags, +4 int32 cell array*, +8 count}`; bounds-checked item accessor `sub_1025F910`: **out-of-range → `MessageBoxA("FCReg - item()")` then returns the array base** — an OOB index silently aliases cell[0] after a modal warning (§10 R-FCREGOOB).
- **`UxAdvSystem::correctSregExpression(int id)`** (symbol `?correctSregExpression@UxAdvSystem@@QAEHH@Z`; called from liteSetReg at 0x1017FC2B and 0x1018028D): relocates script-space ids `≥ 1000000` into a title-private window based at **sreg(15)** — `id → sreg(15) + (id − 1000000)` **[relocation-base semantics inferred from call sites]**.
- Known assignments: **sreg(30)** hi-word = Q6 query linkage; **sreg(1000004)** = the **F-flag word** (`F<n>` condition operands read its bits, §5.8).
- `flushSysreg()` — invoked after op8 writes carrying the flush flag (tok[2]/params[2] bit8); persists the S bank to the sysreg save area.

### 6.5 T bank (treg) — string registers

- treg object at `RetouchSystem[0xB40]`; cell array @obj+0x24; 256 cells allocated via `sub_101BDF20(256)`, cleared via `sub_101BE570`, re-init `UxAdvSystem::initTreg` (called at 0x101B73BB).
- Setter `UxAdvSystem::treg(int id, const char* text)` (`decomp_ux_treg_treg@UxAdvSystem.txt` + `_set`); cell reader `sub_101F6C10(id)` → cell `{+4 → inner {+20 char* text}}`; per-cell flag word set via `sub_101C3110(cell, bits)`.
- Cell flags (op10 ops 4-9 set 0x800000 / 0x400000 / 0x200 / 0x100 / 0x100000 / 0x200000): **[INFERRED]** persistence/serialization markers — consistent with treg(201)/(207) surviving scenario switch while other cells are re-initialized.
- Known assignments (disasm-verified): **treg(1)** = current block title (op5, 0x101B6D60; cleared to `""` @0x104254C0 at liteExec init 0x101B66F5); **treg(2)** = next scenario name (op17 mutates; outer loop `liteLoad(treg(2).text, 0)`); **treg(32)** = mouse-cursor name (outer-loop restore); **treg(201)** = current scenario name; **treg(207)** = entry label (`loadEntryName`). 201/207/2/32 are the set preserved across scenario switch (§3.0).

### 6.6 Q bank — computed queries

Query object at `RetouchSystem+0x9CF8` (corpus conditions use Q20). `Q<n>` operands dispatch through the inner switch of `liteStr2Value` (`jpt_10115369`, decoded sub-cases in §5.9) via `sub_10071100`. Q values are **computed on read** (window/layout/system state), not stored cells.

### 6.7 L bank and F flags

`N_LOCREG=100` local registers (`L<n>` operand, §5.8), written via `loc_sreg(int,int)` (cmdExHIBITMain sub-case 48). `F<n>` = bit tests against the sreg(1000004) flag word (§6.4).

### 6.8 Introspection: `liteRegInfo` @0x100E42E0

Debug watch-dump (`decomp_x_liteRegInfo.txt`): reads an 8-entry table at `this+33748` of `{kind, id}` pairs — kind 0 = R (getReg), 1 = S (sreg), 2 = T (cell text via `sub_101F6C10`); gated by debug-flag word `this[1938]` bits 0x80 / 0x800000. Independent confirmation of the R/S/T model from the engine's own diagnostics.

### 6.9 Operand → bank resolution matrix (fidelity-critical)

| context | `'R'` resolves to | `'S'` | `'T'` |
|---|---|---|---|
| expressions & conditions (§5.8) | **holder** `getReg` (overlay) | sreg | treg text |
| op6 **param**-form value template | **holder** `getReg` | sreg | `str2int(treg)` |
| op6 **string**-form value template | **global** `UxAdvSystem::reg` | sreg | treg text |
| op8 param/string template | **global** `UxAdvSystem::reg` | sreg | (literal fallback) |

The R asymmetry between op6's param and string forms is genuine engine behavior (`disasm_liteSetReg.txt`: string form calls `UxAdvSystem::reg` @0x1017FFEC; param form calls `LocalHolder::getReg`) — reproduce verbatim, do not "fix" (§10 R-REGASYM).

## 7. `CMD_DATA` and `LocalHolder` — **[SETTLED]**

### 7.1 The 216-byte stride question — resolved

**216 (0xD8) is the in-memory `CMD_DATA` struct size, not an on-disk quantity.** On-disk `.rld` records are variable length (settled by `exhibit_rld.h`, which parses 309/310 corpus files byte-exactly). Two independent analyses agree:

Evidence A — the loader `sub_10120250` (called from `execRld` as `sub_10120250(lpString, 0)`; decompilation cached in `decomp_sub_10120250.txt`):

```c
v14 = *(_DWORD *)(this + 8);                        // total record count (main file + includes)
v15 = (216 * (unsigned __int64)(unsigned int)v14) >> 32 != 0 ? -1 : 216 * v14;
v16 = (char *)malloc(v15 + 4);                      // MEMORY[0x101BD5AA] = operator new/malloc
*(_DWORD *)v16 = v14;                               // array[-1] = record count
MEMORY[0x102F2F25](v16 + 4, 0xD8u, v14, sub_100ADB70, sub_100CFDA0);   // construct v14 elements of size 0xD8=216
...
sub_100B0800(v21, v18++, v27, (int)&v33);           // fill element i from on-disk cursor
v20 += 216;                                         // destination advances by FIXED 216
```

The destination pointer advances by a **fixed 216** while the source cursor `v33` advances by **whatever each variable-length record occupies** (`sub_100B0800` walks params then NUL-terminated strings). That is the stride's only role.

Evidence B — the exec loop `execRld` @ `0x101b7f40`: `v5 = v13 + 216 * v24;` indexes record `v24` of the same array.

### 7.2 Field-by-field `CMD_DATA` (216 bytes) **[SETTLED]**

Built from: ctor `sub_100ADB70`, filler `sub_100B0800` → `sub_100ADC50` (params) / `sub_100ADCA0` (strings), and readers in `execRld` / `blockId2Index` / `liteCheckCondition`.

| Offset | Size | Field | Evidence |
|---|---|---|---|
| +0 | 4 | `int index` — record index; ctor sets `-1`, loader overwrites with the running index (`*this = a2` in `sub_100B0800`; `*(_DWORD *)(v5 + 212) = v24` in `execRld` writes +212 — see below; ctor `*this = -1`) | `decomp_cmdDataCtor.txt`, `decomp_cmdDataFill.txt` |
| +4 | 4 | `uint32 header` — the **raw on-disk header dword**, verbatim (`*(this + 1) = a3`). Readers re-extract fields: opcode = `(uint16)hdr` (`execRld`: `(unsigned __int16)*(_DWORD *)(v5 + 4)`), paramCount = `BYTE2(hdr)` = `(hdr>>16)&0xFF`, stringCount = `*(BYTE*)(cmd+7) & 0xF` = `(hdr>>24)&0xF`, flags = `hdr>>28` (`blockId2Index`: `(v7 & 0xF0000000) != 0`) | `decomp_cmdDataFill.txt`, `decomp_execRld.txt`, `decomp_blockId2Index.txt` |
| +8 | 84 | `int32 params[21]` — filled by `sub_100ADC50`: `v5 = this + 4*a4 + 8` with `a4`=0 base slot; copies while `(v4 + a4) <= 0x14` (21). **Caps at 21 but keeps consuming the on-disk stream** (cursor always advances `paramCount` dwords) | `decomp_cmdDataFillParams.txt` |
| +92 | 120 | `FCString strings[10]` — 10 × 12-byte string handles, filled by `sub_100ADCA0`: `v6 = (int)this + 12*a4 + 92`, copies while `(v4 + v5) <= 9`; each string is assigned via `sub_101BDF20(slot, 256, src)` = "assign C string, initial capacity 256", so each is truncated at the FCString's own limit; source cursor walks NUL terminators | `decomp_cmdDataFillStrings.txt` |
| +212 | 4 | `int execIndex` — written **every dispatch** by `execRld` (`*(_DWORD *)(v5 + 212) = v24`), i.e. the current program counter stamped into the record (used for error reporting / save-game position — inferred). Ctor zeroes it. | `decomp_execRld.txt` |

Total: 4 + 4 + 84 + 120 + 4 = **216 = 0xD8**. ✓

`FCString` (12-byte handle) observed layout: `{ char* body /*+0*/; int cap? /*+4*/; int len /*+8*/ }` — `liteCheckConditionStr` tests `*(cell+8) == 0` for emptiness and reads text at `*(cell+20)` when the handle points into a 24+-byte cell variant; the 12-byte array elements store the body pointer at +0 (the filler passes the slot directly to `sub_101BDF20(slot, 256, cstr)`). **[INFERRED]** detail: helper set is `sub_101BE000` (copy-ctor), `sub_101BDFF0` (dtor), `sub_101BDF20` (assign-from-C-string, arg1 = initial capacity), `sub_101BE570` (clear), `sub_101BEC40`/`sub_101C0890`/`sub_101BF010` (tokenizer internals, §4).

### 7.3 Scenario container object (loader `this`) **[SETTLED fields, name GAP]**

`sub_10120250`'s `this` (16-byte object constructed in `execRld` with ctor `sub_101515B0`):

| Offset | Field |
|---|---|
| +4 | header/version field (assigned from parsed header dword[1]) |
| +8 | total record count (main + all includes) |
| +12 | `CMD_DATA*` array base (malloc'd block + 4; block[-1] = count) |

The `RetouchSystem` object also keeps a live copy: `this[1940]` (dword idx; byte +7760) = record count, `this[1941]` (byte +7764) = array base — used by `blockId2Index` @ `0x100dfc50`. **[SETTLED]** from `decomp_blockId2Index.txt`.

### 7.4 `LocalHolder` — **[SETTLED — full model in §6.2]**

Constructed per `execRld` invocation on the stack: `_BYTE v18[20]` → `LocalHolder::LocalHolder(v18, this /*RetouchSystem*/, false)`; destroyed via `LocalHolder::~LocalHolder(v18)`. Passed to every handler as arg3 and to `liteStr2Value`/`liteCheckCondition`. The 20 bytes are `{+0 UxAdvSystem* engine, +4 sorted local {id,value} override-list head, +16 byte csMode flag}` (ctor @0x1004E430). The ctor bool = **CS thread-safe mode**: when set, `getReg/setReg` wrap accesses in the critical-section object at `engine+4648`; a `true` ctor also registers the holder as back-pointer at `engine+4644` (`setLocalHolderPtr` @0x1000A500) so engine-side `setRegEx/getRegEx` route through the active holder. `execRld` passes `false` (the script thread owns execution). Semantics: **per-run register overlay** — local R-reg shadows over the global bank; `getReg` = local-if-present else global; `setReg` = insert/update local (id < 0 → no-op); `flushReg` writes every override back to the global bank and clears the list. Full accessor set, EAs and evidence: §6.2.

## 8. Control flow

### 8.1 Load pipeline **[SETTLED]**

`execRld(this, scenarioName)` @ `0x101b7f40` →
1. `sub_10142550(this)` (session begin — GAP, not analyzed).
2. `sub_10120250(name, 0)` = **scenario loader**:
   - `loadRldName(this, name, flag)` @ `0x10114e10` builds path `<gameDir(this[1934]+20)> + "rld\\" + name + ".rld"` and calls `loadRld` @ `0x100fdf50` (CreateFile → memory-map → parse 272-byte header via `sub_100AD910` → if version ≥ 3, XOR-decrypt from offset 16, see §8.6).
   - Header parse: magic `0x524C4400`, version (must be ≤ 3), dword@8 skipped, dword@12 = record count, dword@16 = include-related count, bytes @20..275 = **comma-separated include list** (force-NUL'd at 270/271; parsed by comma-split `sub_100AD9E0`).
   - **Includes**: for each name in the include list, `loadRld("rld\\" + name + ".rld")`, parse its header, and **add its record count to the total**. All records (main file first, then includes in list order) are decoded into ONE flat `CMD_DATA[count]` array (`sub_100B0800` per record). Include records are therefore **renumbered/appended**, not nested — a jump to a block inside an include is an ordinary index jump. **[SETTLED]** from `decomp_sub_10120250.txt` lines: `*(_DWORD *)(this + 8) += *((_DWORD *)v29 + 2);` and the two fill loops (`v20 += 216` main, `v23 += 216` includes with `v23 = 216 * v18` starting where the main file left off).
3. Lazy table init: `if (this[9338]==0) createActionTable(); if (this[8938]==0) createMethodTable();`.
4. Builds a 16-byte `SelectItemManager` (`MEMORY[0x102F2F25](v11, 0x10u, 8, sub_101515B0, sub_10151610)`) and a 20-byte `LocalHolder`, then runs the record loop (§8.2).

### 8.2 The `execRld` record loop **[SETTLED]** — and why opcodes 5, 12, 20, 22, 23, 28 are "skipped"

```c
pc = 0;                                        // v24
while (count /*v12*/ > pc) {
  CMD_DATA* cmd = base + 216*pc;               // v5 = v13 + 216*v24
  cmd->execIndex = pc++;                       // *(_DWORD *)(v5 + 212) = v24++
  this[9743] = pc;                             // publish next-index (byte offset +38972)
  switch ((uint16)cmd->header) {
    case 5: case 12: case 20: case 22: case 23: case 28: break;   // *** NO-OP here ***
    case 11:  cmdExHIBIT(...);  /* + branch post-processing, §8.3 */ break;
    case 13:  if (!isUxMode(this)) UxAdvSystem::wait(this, cmd->params[0], true, paramCount>=2 ? params[1]!=0 : false); break;
    case 17:  cmdChangeScenario(...); break;
    case 21:  cmdQuestion(...); break;
    case 24: case 140: result = 0; pc = count; break;             // *** END OF SCRIPT ***
    case 191: cmdAction(...); /* + gosub/jump post-processing, §8.3 */ break;
    default:  if (op <= 0x11E) methodTable[op](this, cmd, localHolder, this+36900, selectItemMgr);
  }
  if (isSkipUpdate(this) && (UxAdvSystem::isDoSkip(this) || sub_100025E0(17))) /*pump skip-mode update*/;
}
UxAdvSystem::entry(this, nullptr, 1);          // once, after the loop
```

**Why the six opcodes are no-ops in this loop:** `execRld` is the *non-interactive/system* execution path. Opcodes 5, 12, 20, 22, 23, 28 have **no method-table handler at all** (slots 5/12/20/22/23/28 stay `cmdDummy` — verified against `method_table.json`: no entries at those indices) because they are the **interactive ADV-loop opcodes**, handled inline by the real interactive dispatcher `liteExec` @ `0x101b6590` / the `UxAdvSystem::entry` message loop (op5 = label marker is data for `blockId2Index`, not an action; op28 = the message/text record — 49.4% of the corpus — see §3). When a scenario is executed through `execRld` (system scripts, `defChara.rld`-style data scripts), these ADV-only records must be inert, hence the explicit `break`s. **[INFERRED — consistent with all evidence; liteExec confirmation pending in §3]**

Note the loop never *waits* except case 13: `execRld` runs straight through; anything requiring player interaction is routed via `UxAdvSystem::entry` after the loop, or through op11/op191 branch machinery.

### 8.3 Jumps, labels, gosub **[SETTLED]**

- **Labels = op5 records.** `blockId2Index(this, blockId)` @ `0x100dfc50` linearly scans the whole `CMD_DATA` array (via `this[1941]`/`this[1940]`, stride 216):
  - record opcode 5: block id = `params[0]`, **unless** `(header & 0xF0000000) != 0` (flags nibble set), in which case the id comes from `sub_101C28C0(0)` (an obfuscated/alternate id source — cached `decomp_sub_101C28C0.txt`); if the resolved id == `-1`, the label gets the next **auto-number** (running counter `v3`), else the explicit id. Match when resolved id == target.
  - record opcode 47 (`cmdBlock`-class, method-table name for 47 not assigned → op47 handled as *named block* only by this scanner): match when `params[0]` == target. (Note: the decompilation reads `*(_DWORD *)(v8 + 8)` = `params[0]`.)
  - Return: index of the matching record; if target==0 and not found → 0 (jump to start); if target!=0 and not found → -1 (caller raises `liteRuntimeError(this, -10/-11, 0, blockId, nullptr)`).
- **Jump mechanism**: handlers do NOT receive the pc. They signal a jump **through the RetouchSystem object**: `this[4388]` (byte +17552) = target block id, `this[4389]` (byte +17556) = mode flags, `*(BYTE*)(this+17556) & 1` = "branch requested". After `cmdExHIBIT` (op11) and `cmdAction` (op191) return, `execRld` checks `*((_BYTE *)this + 17556) & 1`:
  - mode `this[4389] & 2` clear ⇒ **gosub**: push `{v23 /*current block context*/, pc, 0}` onto the call-stack object `v20` (vtable `off_1042B6FC`, push = vtbl+28), then `pc = blockId2Index(this[4388])`; error -10 if not found.
  - mode `this[4389] & 2` set ⇒ **jump/return-style**: `pc = blockId2Index(this[4388])` directly (error -11), no push. For op11 the "return" path restores `v23`/`pc` from the popped frame (`v17[0]=v23; v17[1]=pc; v17[2]=0;` then `pop` via vtbl+28 — inferred pop from symmetry).
  - `RetouchSystem::initActionBranch(this)` is called before each op11/op191 and after each branch resolution — it resets the branch-request state (this[4388]/[4389]/+17556).
- **PC_ExHIBIT** (`v19` in `execRld`) hands the interactive machinery pointers to the live interpreter state: `{ int* pc /*&v24*/, int* blockCtx /*&v23*/, int* result /*&v21*/, callStack /*v20*/ }` — passed as arg6 to `cmdExHIBIT`/`cmdAction` so *they* can move the pc too. **[SETTLED from decomp_execRld.txt]**

### 8.4 Script end **[SETTLED]**

Opcode **24** or **140** ⇒ `result=0; pc=count` ⇒ loop exits ⇒ `UxAdvSystem::entry(this, nullptr, 1)` runs once ⇒ `execRld` returns `v21` (the result int, 0 on normal end). `exit.rld` (record count 0 in header... actually count field = 0) ends immediately.

### 8.5 Waiting for input **[PARTIAL]**

- Non-interactive path: only op13 waits (`UxAdvSystem::wait(this, ms_or_frames, true, cancellable)` @ `0x1007b550`, `?wait@UxAdvSystem@@QBE_NH_N0@Z`).
- Interactive path (op28 text display, op21 question, key waits): driven by `UxAdvSystem::entry` @ `0x100732b0` (29 bytes — a thunk, cached `decomp_uxEntry.txt`) and `liteExec` @ `0x101b6590`; `keywait` @ `0x1007b710` (`?keywait@UxAdvSystem@@QBEHK_N@Z`). Detailed protocol in §3 (pending liteExec analysis).

### 8.6 Encryption at load (context for the container) **[SETTLED]**

`loadRld`: XOR stream cipher from file offset 16, keystream = `key ^ mt[ i & 0xFF ]` where mt = 256 dwords from a seeded MT-style RNG (`sub_102253D0(seed,0,0xFFFFFFFF)` + `sub_102252C0(seed,key)` + 256 × `sub_10225210`), applied to at most `0x3FF0` dwords (65472 bytes). Key = `this[1937]` (byte +0x1E44, hardcoded `0xAE85A916` in `liteInit` @ `0x100fdb50`) for files whose **basename starts with `$`**, else `this[1936]` (+0x1E40). Key 0 ⇒ no-op ⇒ plaintext. `this[1936]` defaults to 0 for this title (calcIniValue/fingerprint path — confirmed by sibling config agent) and can be set at runtime by `action095` @ `0x100e5510` parsing a `"0x..."` parameter. Corpus: 307 plaintext files, `def.rld` + `$posit.rld` + `_posit.rld` ciphertext. Implemented already in `exhibit_rld.h` (`RldKey::Dollar = 0xAE85A916`, `RldKey::Default = 0x7486F21C`, clamp constant `kRldMaxCryptDwords = 16368`).

### 8.7 `[exec] entry=` in `ExHIBIT.ini` — **[GAP → fill after ini analysis]**

## 9. Recommended C++ design

Target: a standalone, headless-testable VM core that reproduces `liteExec` semantics exactly, with the presentation engine behind an interface.

### 9.1 Module layout

```
exhibit-vm/
  rld_container.{h,cpp}   // .rld parse + decrypt — reuse exhibit_rld.h findings verbatim:
                          // 272-byte header, records @276, hdr fields (op 0-15, paramCount 16-23,
                          // stringCount 24-27, flags 28-31), XOR/MT keystream from offset 16,
                          // $-file key 0xAE85A916
  cmd_data.h              // 216-byte POD record (§7.2)
  fcstring.h              // byte-faithful cp932 string + view types (§4.2); NO UTF-8 inside the VM
  strutil.{h,cpp}         // splitParam (§4 — MBCS delimiter-set split, no quoting, raw-remainder
                          // last slot, return 2 = trailing delim), str2int (0x/0b/dec), CharNext step
  registers.{h,cpp}       // IntBank (FCReg clone), TregBank, LocalHolder overlay, correctSregExpression (§6)
  expr.{h,cpp}            // calcExpression whitespace-RPN evaluator (§5.5) + calcFunction builtin
                          // registry (§5.7 — extensible; only 4 names confirmed)
  condition.{h,cpp}       // liteCheckCondition STRING form (§5.2-5.4, cp932 full-width ops §5.3)
                          // AND precompiled CMD form (§5.6) — TWO separate cmpOp tables
  vm.{h,cpp}              // liteExec loop, 12-byte callstack frames, blockId2Index, auto-label
                          // counter, jump-origin flag, outer scenario-switch loop (§3.0, §8)
  handlers/               // one TU per family; static registration mirroring createMethodTable (§1)
  host/                   // IAdvSystem interface: draw/layer/audio/input/timing + vtbl[15]-style
                          // suppression predicate; the "silent trio" collapses to host->isSuppressed()
```

### 9.2 Core types

```cpp
#pragma pack(push, 1)
struct CmdData {                    // 216 bytes, §7.2
    int32_t  index;                 // +0    record index (loader-assigned)
    uint32_t header;                // +4    op = h & 0xFFFF; paramCount = (h>>16)&0xFF;
                                    //       stringCount = (h>>24)&0xF; flagsNibble = h>>28
    int32_t  params[21];            // +8..91
    FCString strings[10];           // +92..211 (12-byte cells: {char* text, int len, int cap} equiv.)
    int32_t  execIndex;             // +212  pc stamp, written each iteration (§3.0)
};
#pragma pack(pop)
static_assert(sizeof(CmdData) == 216);

struct StackFrame { int32_t blockCtx; int32_t pc; int32_t flags; };  // 12 bytes (§8.3)
// frame.flags bit0 → on return: clear load-resume marker + exitLoadMode(350)
// frame.flags bit1 → jump-origin: suppress op5 auto-number increment at the landing label
```

Handlers use the engine signature: `void handler(Vm&, CmdData&, LocalHolder&, PosCorrector&, SelectMgr*)`. `byte +6` (paramCount) is re-read by several handlers as a **format selector** (op37: 9/11; op74: 15/16) — keep it accessible, don't fold it into `params`.

### 9.3 Dispatch skeleton

```cpp
void Vm::liteExec(const std::string& scenario, int entryBlock) {
    loadScenario(scenario);                              // §8.1
    int pc = (entryBlock == 999999) ? 0 : blockId2Index(entryBlock);
    callStack_.push({entryBlock, pc + 1, 1});
    LocalHolder holder(host_, /*csMode=*/false);         // §7.4
    bool jumpOrigin = false;
    while (pc < recordCount_) {
        CmdData& cmd = record(pc);
        cmd.execIndex = pc;
        if (!host_->isSuppressed()) host_->reg(5, pc);
        ++pc;                                            // default advance
        const int op = cmd.header & 0xFFFF;
        switch (op) {                                    // §3.1 inline set — EXACTLY these 13
            case 5:   pc = opBlockLabel(cmd, holder, pc, jumpOrigin); jumpOrigin = false; break;
            case 11:  opExhibitMain(cmd, holder);        pc = branchPost(pc); break;
            case 12:  opAutosave(cmd, holder, pc);       break;
            case 13:  opWait(cmd);                       break;
            case 17:  opChangeScenario(cmd, holder);     return;   // outer loop reloads (§3.0)
            case 20:  pc = opCondJump(cmd, holder, pc);  break;
            case 21:  opQuestion(cmd, holder);           pc = branchPost(pc); break;
            case 22:  pc = opGosub(cmd, holder, pc);     break;
            case 23:  pc = opReturn(cmd, holder, pc, jumpOrigin); break;  // sets jumpOrigin from frame bit1
            case 24: case 140: opEnd();                  return;
            case 28:  opMessage(cmd, holder);            break;
            case 191: opAction(cmd, holder);             pc = branchPost(pc); break;
            default:
                if (op <= 286)                           // §1: >286 → SILENT SKIP (fidelity)
                    (this->*methodTable_[op])(cmd, holder, posCorr_, &selectMgr_);
                break;
        }
        gcAsync(); gcSound(); updateSkip();              // per-record tail (§3.3 contract)
    }
}
```

`methodTable_` = `std::array<CmdHandler,287>` initialized to `cmdDummy` (no-op) then assigned per the §1 map — **including the gaps** (op47 stays inert). `actionTable_` = 400 slots, `actionDummy` fill (§1).

### 9.4 Registers (§6)

```cpp
class IntBank {                                   // FCReg clone
    std::vector<int32_t> cells_;
public:
    int32_t& item(size_t i) {                     // original OOB: MessageBox + return cells_[0]
        if (i >= cells_.size()) { host_->bankError("FCReg - item()"); return cells_[0]; }
        return cells_[i];                         // keep the aliasing in release; assert in debug builds
    }
};
class LocalHolder {
    IAdvSystem* eng_; std::map<int32_t,int32_t> locals_; bool cs_;
public:
    int32_t getReg(int32_t id) const { auto it = locals_.find(id);
        return it != locals_.end() ? it->second : eng_->reg(id); }
    void setReg(int32_t id, int32_t v) { if (id < 0) return; locals_[id] = v; }   // id<0 no-op!
    void flushReg() { for (auto& [k,v] : locals_) eng_->reg(k, v); locals_.clear(); }
};
```

`sreg` writes take a `notify` flag (→ engine reaction hook); `correctSregExpression` applies the ≥1000000 relocation before every S-bank script access. treg cells carry a flag word (persistence bits, §6.5) — serialize flagged cells into save data.

### 9.5 Expressions and conditions (§5)

- Parse condition strings **once per record load** into `{LhsKind, Lhs, CmpOp, Rhs}`; keep the STRING-form cmpOp table `0=EQ,1=NE,2=GT,3=GE,4=LT,5=LE` and the precompiled-CMD table `4=LE,5=LT` **as two distinct constants** (§5.6, R-CMPOPSWAP).
- cp932 full-width operators (0x8181-0x8186) must be recognized at the byte level (§5.3); bare `"0"` condition = TRUE (§5.2).
- calcExpression: whitespace-separated RPN over an operand stack; operands via the §6.9 resolution matrix (**R = holder overlay in expressions; global reg in op6 string templates** — encode the asymmetry explicitly, e.g. `resolveOperand(ch, n, ResolveCtx::Expression | SetRegString | SetRegParam)`).
- calcFunction: registry `std::unordered_map<std::string, BuiltinFn>` seeded with the confirmed names (`random`, `randomSet`, `NULL`, `res\dob`); unknown builtin → log + push 0 (matches the engine's tolerant fallthrough) **[verify against §5.7 GAP]**.

### 9.6 Handler implementation rules

1. Token capacity is a per-handler function of the flags nibble — tabulate it next to each handler (§3.3 preamble); never guess capacity from string content.
2. Shared helpers, one implementation each: `resolveParam(v)` (≥1000000 → `holder.getReg(v−1000000)`), `cmdLid2lid`, `cmdValue2Value`, `cgchCorrectChara/Cg`, `isSuppressed()` (silent trio → single host predicate), `splitParam`.
3. All string handling stays in cp932 bytes; convert only at host/UI boundaries (R-ENCODING).
4. Timed operations take their durations through `isSuppressed()` zeroing (skip = instant), exactly like the silent-trio sites in §3.3.

### 9.7 Test strategy (corpus-driven)

1. **Container**: parse all 310 corpus files; assert record counts/fields byte-exact against the `exhibit_rld.h` reference implementation.
2. **Dry-run replay**: run all 53,153 records headless with a null host; assert: no runtime-error path, every op dispatches (inline ≤ 286 or dummy), token counts ≤ capacity, callstack empty at every scenario end.
3. **Golden registers**: capture R/S/T write streams (op6/8/10/7, op5 R2, treg1/2/32/201/207) from an instrumented reference run; diff against the reimplementation.
4. **Jump integrity**: for every corpus label, `blockId2Index` round-trip incl. auto-number re-simulation with jump-origin suppression active (§3.1 op5); gosub/return balance per scenario.
5. **Per-handler units**: the corpus samples cited in §2/§3.3 as fixtures (op28 ×26k gives cheap message-path fuzzing).

### 9.8 Performance notes

- `blockId2Index` in the original re-simulates auto-numbering **from record 0 on every lookup** (deterministic, O(n) per jump). Precompute a label→index map at load — behaviorally identical because numbering is a pure function of record order (§3.1 op5) — but keep the re-simulation available behind a flag for differential debugging.
- Token parsing dominates hot paths (op28 = 49.4% of corpus): parse message records once at load, cache the split.

## 10. Risk register

Fidelity risks for an implementer working from this document. "Severity" = impact on correct playback of `imopara3`; "likelihood" = chance the gap/quirk actually bites.

| ID | risk | sev | lik | evidence / locator | mitigation |
|---|---|---|---|---|---|
| R-CMPOPSWAP | cmpOp codes 4/5 are **swapped** between the STRING condition form (4=LT, 5=LE — `jpt_101814C5`) and the precompiled CMD form (4=LE, 5=LT — §5.6). Genuine engine divergence; unifying the tables silently flips ≦/≧ branches | high | med | §5.2 vs §5.6 | two separate constant tables; differential-test conditions using full-width ≦/≧ in both forms |
| R-HEXSTR | a minority of records (seen in op94, op28 samples) store strings as ASCII-hex pairs; the encode/decode boundary is not fully characterized | med | med | corpus samples (`samples_out.txt` op28) | byte-level detector on load; corpus-wide validation pass before trusting dry-run results |
| R-SAYMARKUP | `say()` inline markup inside cmdMessage text (control/ruby/wait codes) only partially documented | med | high | §3.2 | render-side spec needed before text fidelity sign-off; VM core unaffected (passes bytes through) |
| R-CALCFUNC | `calcFunction` @0x1016BEA0 builtin registry only partially extracted (confirmed: `random`, `randomSet`, `NULL`, `res\dob`) | med | med | §5.7 GAP; `disasm_calcFunction.txt` | finish the string-table walk in the disasm; extensible registry + loud logging of unknown builtins |
| R-SETREGT3 | op10 (treg) op-3 string edit `sub_101C2BB0` semantics not fully reversed (replace vs substring vs splice); string form passes (text, tok[4]), param form passes (strings[1], text) | med | low (op10 unused in corpus) | §3.3.1; `disasm_liteSetReg.txt` | reverse `sub_101C2BB0` before supporting other titles |
| R-TREGFLAGS | treg cell-flag bits (op10 ops 4-9: 0x100/0x200/0x100000/0x200000/0x400000/0x800000) inferred as persistence markers; per-bit meaning unknown | med | low | §6.5 | trace save/load serialization of the treg bank |
| R-OP47 | op47 has **no handler** (cmdDummy) yet 72 corpus records use it (`cgMode.rld`, params `[2000,1]`). The shipped game ignores them | low | high (will be "helpfully" implemented) | §3.3.19; `decomp_createMethodTable.txt` | keep inert; add a corpus-replay assertion that op47 produces zero side effects |
| R-FACEUP | op242 `cmdFaceUp` @0x1016FFD0 not decoded (Hex-Rays returned None; disasm not walked). Only its sample (`"537931776,-2,…"`) and its exit counterpart op243 are known | high | med | §3.3.11; 16 corpus records | walk the disasm; op243's restore logic constrains the entry state |
| R-QQUERY | Q-operand (query register) semantics inferred from a few decoded sub-cases of `jpt_10115369`; corpus conditions use Q20 heavily | med | med | §5.9 | decode remaining query sub-cases; Q reads are side-effect-free, so wrong values corrupt branches only |
| R-JUMPORIGIN | jump-origin frame flag (bit1) suppresses op5 auto-number increment; misimplementing it shifts every auto-numbered label after a return, and `blockId2Index` re-simulates the counter — errors compound silently into wrong jump targets | high | med | §3.1 op5/op23; §8.3 | golden jump-integrity test (§9.7 #4) over all corpus scenarios |
| R-ASYNCARGS / R-MOVEAXIS | op100 step-arg counts for steps 3/4/9 inferred from call sites; simple-path group order `(layer, y, x, extra)` axis order unconfirmed | med | high (1785 records) | §3.3.9 | visual regression on a known move script; dump AsyncSeq structs |
| R-FCREGOOB | FCReg out-of-range access returns **array base** after a MessageBox → silent aliasing to cell[0] instead of a crash; scripts relying on it would behave differently under an assert-on-OOB reimplementation | med | low | §6.4; `sub_1025F910` | mirror semantics in release (log + cell[0]), assert in debug |
| R-REGASYM | `'R'` operand resolves to the **holder overlay** in expressions/op6-param-form but to the **global bank** in op6-string-form and op8 templates — normalizing this changes values whenever a local override exists | high | med | §6.9; `disasm_liteSetReg.txt` 0x1017FFEC vs param-form `LocalHolder::getReg` | encode resolution context explicitly (§9.5); unit-test with active overrides |
| R-ACTIONTABLE | action000…action370 bodies un-reversed (generic symbols); corpus uses only action 291 (×49). Other titles' op191 records would execute unknown logic | high (other titles) | low (this title) | §1; `decomp_createActionTable.txt` | reverse per-title on demand; action291 first |
| R-DEFRRLD | `def.rld` (81 records) skipped by the census tooling; op49 def-character layout (357/431-token CSV) only partially inferred | med | med | §2 header note; §3.3.5 | fix census tooling for def.rld; treat def blocks as opaque keyed tables meanwhile |
| R-AMBIG | `method_table_ea.json` shows two symbols at one EA for cmdDraw/cmdEnterMove (AMBIG2) — thunk/alias artifact | none | — | §2 table | cosmetic; resolve by following thunks when citing EAs |
| R-ENCODING | all corpus text is cp932 (incl. half-width katakana); census output shows mojibake when misdecoded — any UTF-8 round-trip inside the VM corrupts message text and token parsing | high | med | §4.3, samples | byte-faithful strings end-to-end (§9.2); MBCS-aware tokenizer tests |
| R-SKIPMODE | skip/fast-forward suppression (silent trio + VK_CONTROL toggle) touches every timed/audio op; bugs surface as audio desync or stuck skip, not crashes | med | med | §3.3 preamble; disasm tail 0x101B72B8 | single `isSuppressed()` host predicate; replay tests with skip forced on |
| R-CGSHALLOW | cgMode/system-UI ops (90-93, 132, 267, 203-207, 216/217) decoded at family level only | med | low (main script unaffected) | §2 | reverse before implementing title/system menus |

### 10.1 Settled during this research (formerly open questions)

- **216-byte stride** = in-memory `CMD_DATA` size, not an on-disk quantity (§7.1).
- **Container format + cipher** = `exhibit_rld.h` reference (header fields, records @276, MT keystream from offset 16, `$`-key 0xAE85A916).
- **cmpOp tables** (both forms) and cp932 full-width operator codes (§5.2/5.3/5.6).
- **splitParam grammar** — MBCS delimiter-set split, no quoting/escaping, raw-remainder last slot, return 2 = trailing-delim (§4).
- **LocalHolder** = register overlay; full layout/accessors/flush semantics (§6.2); ctor bool = CS mode.
- **Inline opcode set** = exactly {5,11,12,13,17,20,21,22,23,24,28,140,191} — cmdQuestion (21) included; op23 = conditional return with frame-flag post-processing (§3.1).
- **op6/7/8/10 register-op grammar** — fully decoded from disasm this session (§3.3.1/3.3.2), including the R-resolution asymmetry.
- **Dispatch bounds** — op > 286 → silent skip; unassigned ≤ 286 slots → cmdDummy (§1).

### 10.2 Remaining gaps (priority order for follow-up)

1. `cmdFaceUp` (op242) body — R-FACEUP (16 corpus records, gates every face-up sequence).
2. `calcFunction` builtin table completion — R-CALCFUNC.
3. `sub_101C2BB0` (treg edit op) — R-SETREGT3.
4. Q-query sub-case table completion — R-QQUERY.
5. Action-table bodies (per-title, on demand) — R-ACTIONTABLE.
6. def.rld census + op49 slot-exact layout — R-DEFRRLD.

## 11. Errata — corrections found while implementing from this spec

The body above was written from decompilation alone. Building `vm_str`,
`vm_reg`, `vm_expr`, `vm_cond` and `encoding` from it, then re-reading the
disassembly line by line to make them work, corrected everything below.
**Where this section and the body disagree, this section is right.** Each item
carries the evidence that settled it. The implementing components are the
reference: `packages/AetherExhibit/{include,src}/exhibit_vm_{str,reg,expr,cond}.*`
and `exhibit_encoding.*`.

### 11.1 The scenario corpus is not cp932

§10 R-ENCODING states that all corpus text is cp932. It is not. Measured across
all 310 `.rld` files by the `encoding` component: GB18030 decodes 27,833 of
27,833 non-ASCII record strings with zero replacement characters and yields
coherent Chinese text, while cp932 decodes only 18,751 (67%). The same holds for
both `.CNS` containers, consistent with `[setting] I18N=CNS`.

The underlying rule survives and is still load-bearing — **text stays as raw
bytes inside the VM and is transcoded only at a host boundary** — but the
double-byte lead and trail ranges are a function of the *active code page*, not a
cp932 constant. `IsDbcsLeadByte`'s 0x81-0x9F / 0xE0-0xFC is the cp932 answer;
code page 936 leads run to 0xFE. Any MBCS stepper that hardcodes one page will
split a character in half on the other.

This is not academic. The code page is chosen at runtime by the language module
(`sub_1027D9B0`: name `"CNS"` → 936, `lpString2` → 1252, otherwise 932; the
static default is 932 at `0x1050CE3C`, setter `0x100C5470`, getter `0x100C5480`,
pushed by INIT_ENTRY `0x100C55DD` via `SendMessageA(hwnd, 0x8005, 0x205, 0)`).
imopara3 ships `lang_cns.dll`, so it runs at **936**, which is why ASCII
conditions such as `R1300==4` work at all. Measured cost of getting this wrong:
at code page 932 all 542 condition strings in the corpus evaluate TRUE versus
122 at 936 — **420 branches flip**, because the cp932 path has no ASCII fallback
(§11.2 item 4). A wrong code page does not degrade a title, it opens every
branch in it. `CondEnv::code_page` defaulting to 936 is therefore load-bearing,
not cosmetic, and must be set per title from the language module rather than
compiled in.

### 11.2 Corrections to §4 and §5

1. **§4.1 — the flag mapping is inverted.** `splitParam` hardwires `1` as
   `sub_101C1860`'s fifth argument (keep-empty), and its boolean argument is
   bit 1, raw-remainder. There is no keep-empty choice for a caller to make.
2. **§4.3 — `terminal_code` 0 is the ordinary result**, meaning "source ran
   out", not a failure. Test `count == 0` for emptiness. Measured over the
   corpus: code 0 on 65,738 strings, code 1 on 3,767, and **code 2 never occurs
   at all** — it needs a trailing delimiter to land exactly on the last slot, so
   no logic may depend on it.
3. **§5.2 — an unrecognised operator does not default to EQ.** `esi` stays −1
   (`0x10180FCF or esi,-1`) and `bl` is left unchanged; `cmp esi,5; ja default`
   falls through without writing a result. A bare `"0"` is TRUE because the chain
   only ever exits on FALSE, not because anything defaults to equality.
4. **§5.3 — the cp932 branch does not fall through to the generic ASCII path.**
   It is self-contained (`0x10180990`..`0x10180F20`, exiting at `0x10181543`),
   selected by `cmp CodePage,3A4h; jnz loc_10180F25`, and has **no ASCII
   fallback**. See §11.1 for the measured consequence.
5. **§5.4 bullet 3 — the RHS is not evaluated by `calcExpression`.** A
   non-quoted, non-`T` RHS calls `liteStr2Value` (`0x101813DB` / `0x10180DD1`),
   then `sub_101BFA50(out, v, 10, 0, ' ')` — `_ltoa` to signed decimal text —
   and the comparison that follows is a **string** compare.
6. **§5.8 — `S<n>` is not `L<n>`.** The `'S'` case at `0x10114FA4` jumps to
   `0x10114FB4`, skipping the `add eax,0F4240h` at `0x10114F8A` that `L<n>`
   applies. `L<n>` is a window into S; `S<n>` addresses S directly.
7. **There are three comparison tables, not two.** §5.2 and §5.6 give the string
   and precompiled forms; the full-width cp932 operators use a third order again
   (`Lt=2, Gt=3, Le=4, Ge=5`, `jpt_10180EC7`). Evidence: `0x10181025`..
   `0x1018106E`, `jpt_101814C5`, `decomp_liteCheckConditionCmd`.

### 11.3 Condition behaviours absent from §5

Each was found by reading the disassembly while implementing, and each changes a
result.

1. **A lone `=` or `!` is not an operator.** The *second* character decides
   (`0x10181025`..`0x1018103A`): when it is `'='` the two-character table applies
   (`'='`→0, `'!'`→1, `'<'`→5, `'>'`→3), otherwise only `'>'`→2 and `'<'`→4 are
   recognised. So `R1 ==999` compares, but **`R1 = 999` is silently TRUE** — the
   easiest way to write a condition that can never fail. `'<'` and `'>'` carry no
   such restriction.
2. **A leading `@` swallows the whole comparison.** `0x10180F6B` tests for `'@'`
   at the cursor and `0x10180F89` jumps straight to `test bl,bl`, so
   `@mod(2 7 3) == 2` is TRUE and the `== 2` is ignored text. To compare a call
   result it must be the **RHS**: `0 == @mod(2 7 3)`.
3. **`" false"` is TRUE while `"false"` is FALSE.** Keywords are `lstrcmpA`'d
   against the token **cell base** (`0x10180F8E` reads `[var_68]+14h`), whereas
   `'@'` is matched at the **cursor** after a `" "` skip (`0x10180F66`). The
   comparison is case-sensitive, so `"TRUE"` is TRUE. `" true"` is TRUE as an
   operator-less term, but `" @isDi(...)"` is still a call.
4. **A quoted RHS can never contain a quote.** The tokenizer stops at the first
   `"` (`0x10181175`), so `T3 == "a"b"` compares against `a`. Extraction must go
   through the tokenizer, not a token scan:
   `SplitterCore(cursorAfterQuote, 1, "\"", 0u, nullptr).slots[0]`.
5. **RHS `T<m>` always reads `treg(0)`.** It is parsed with `str2int` mode **0**
   (`0x1018127D` / `0x10180C69`) where the LHS correctly uses mode 1
   (`0x101810F3` / `0x10180ADD`). A genuine vendor bug, and latent in this corpus
   (0 occurrences), so it must be reproduced rather than fixed.
6. **A malformed precompiled slot is inert and later slots still run**
   (`LABEL_37` re-test). Stale-`v4` inheritance is therefore unobservable.
7. **`ScanToken` skips leading delimiters** (`_mbsspnp` first), so `"&"` is an
   empty chain and therefore TRUE, `"&false"` is FALSE, and `"true&&false"` is
   FALSE. Empty conjuncts collapse.

### 11.4 Expressions and builtins

1. **R-CALCFUNC is closed: there are 21 builtin names, not 4.** The dispatch key
   is the **first four name bytes read big-endian** (`0x1016BF4B`..`0x1016BF71`),
   or the first two big-endian for a 2- or 3-byte name (`0x1016C340`), or `0` when
   shorter; `"rand"` then falls through to full-name compares against
   `"randomSet"` (`0x1042FE08`) and `"random"` (`0x1042FE00`). Recovered keys:
   `isIn 0x6973496E`, `dist 0x64697374`, `chec 0x63686563`, `bitC 0x62697443`,
   `bitE 0x62697445`, `clip 0x636C6970`, `dir8 0x64697238`, `isCu 0x69734375`,
   `heig 0x68656967`, `isCh 0x69734368`, `isDi 0x69734469`, `isVa 0x69735661`,
   `isPl 0x6973506C`, `isNe 0x69734E65`, `isNo 0x69734E6F`, `isSc 0x69735363`,
   `isSt 0x69735374`, `posX 0x706F7358`, `posY 0x706F7359`, `widt 0x77696474`,
   `rand 0x72616E64`, plus `"mo"` = `0x6D6F`.
   Because the vendor switches on the **id**, the aliases are real: `@mo` behaves
   as `mod`, and `@widtX(0)` behaves as `widt`. `@randfoo` resolves to id 0,
   parses a full argument list, then yields 0.
2. **`chec` is not a modulo.** Its `'d'` path at `0x1016C0AC` calls
   `sub_101BE6C0(slot0)`, then either `calcFunction_sub` when
   `ebx & 0xFF000000` or `action_strAreaSplitter(0, set, ".", slot1.text)`.
3. **Two argument grammars, selected by name before any argument is read.**
   Generic: `@name(<argc> <arg>…)`, count via `str2int` mode 0, then
   `splitParam(rest, slots, argc, "' \t)", false, NULL)` only when `argc > 0`,
   with the array sized `max(1, argc)`. Quoted pair (`chec`, `isDi`, `isIn`
   only): `@isDi(<a>'<b>)` — the count token is skipped entirely, the argument
   text is `ScanToken(")")` then `SplitterCore(argtext, 2, "'", flags=2, " \t")`.
   The apostrophe is a **separator**, not a quote. `isDi` → `r == 0`,
   `isIn` → `r != 0`.
4. **The RNG is not `genrand() % n`, and it is not the Mersenne Twister at all —
   it is a separate generator, `FCRandom`.** `random(uint n)` @`0x10009280` is
   `sub_10234AA0(n-1)`, and `random(int lo, int hi)` @`0x100092A0` is
   `lo + sub_10234AA0(hi-lo)`, **inclusive** (both re-verified by fresh
   decompilation; the mangled exports `?random@UxAdvSystem@@QAEHI@Z` and
   `?random@UxAdvSystem@@QAEHHH@Z` survive even in a from-scratch database).
   `sub_10234AA0(k)` (72 B) computes `v = sub_10234A90()`; `slot = v >> 27`
   (0..31); `out = bitrev32(table[slot])`; **`table[slot] = v`**; then
   `return out % (k+1)`. `sub_10234A90` (16 B) is a plain LCG
   `counter = 0x5D588B65 * counter + 1` — the multiplier is MT19937's
   `init_by_array` constant *reused as an LCG*, not a twist. **`table` is a
   32-word array at object offset +12 and the LCG counter sits at +8.** This is
   `FCRandom`, embedded in `UxAdvSystem` and seeded from `GetTickCount`; it is a
   *different* generator from the 624-word sgenrand MT19937 that `.rld`/`.gyu`
   decryption uses. (An earlier revision of this item wrongly stated the draw
   "mutates the Mersenne Twister state": it mutates the 32-word `FCRandom` table
   indexed by `v >> 27`. Indexing a 624-word MT state by `v >> 27` would only
   ever touch words 0..31 and is not how MT19937 produces output — that
   conflation is corrected here.) The bounded draw still perturbs its generator
   via the `table[slot] = v` writeback, so the stream depends on every previous
   draw and a plain-modulo reimplementation will diverge. Per the save/load spec
   §6, `FCRandom` is **never persisted** — a load reseeds from the tick and
   replay diverges by vendor design — so the port reproduces the draw exactly but
   must not expect RNG state to survive save/load. Measured structure and the
   port's `FcRandom` design: `doc/exhibit_save_spec.md` §6.1.
5. **`@random` is a chooser, not a generator**: the index is `random(argc)` in
   `[0, argc)` and the result is `Str2Value(args[index])` (`0x1016C7B4`).
   `@randomSet(lo[, hi])` is the inclusive `random(int, int)`; with fewer than two
   slots the high bound is the leftover `eax`, i.e. the **low** operand
   (`0x1016C7F0 cmp ebx,2; jl`).
6. **`calcExpression`'s leading-`'-'` rule disables the fold.** `-2 3 +` is a
   *single* `Str2Value` operand (`atoi` hard-stops, giving −2). With no `*+-/`
   anywhere the whole text is one operand, so **`"1 , 2"` evaluates to 1**, not 2
   — `,` (44) and `.` (46) fall inside the switch's `char-'*'` 0..5 range but
   route to `def_1016D2EB`, the operand case.
7. **Divide-by-zero returns 0 from the whole expression**, not from the fold
   (`0x1016D481` jumps to the epilogue). Separately, `a % b` in `isDi`/`isIn`
   uses `cdq; idiv` with **no divisor test** and genuinely faults in the vendor
   (`0x1016D0B1 mov edi,edx`); a reimplementation must guard and report instead.
8. **`str2int`'s radix parses wrap; only `atoi` saturates** (`v = d + 16*v` and
   `v = c + 2*v − 48`). The `>=3` length test is `end − cursor >= 3` where
   `end = base + length`; `"0zzz"` falls through to `atoi`; the hex loop requires
   `(CharValue & 0xFFFFFF00) == 0` and then indexes `dword_10435E70`, where 255
   means break. Both radix paths advance twice unconditionally before testing.

### 11.5 R-QQUERY is closed

All 30 sub-cases of `jpt_10115369` are decoded. Q0 `isExistSaveData(0x111)` ·
Q1 `isExistSaveData(0x11)` · Q2 `[+0x4498]` · Q3 date/era · Q4 aspect class ·
Q5 `[+0x4488] < 0` → 0 else `loadUserSettings("expression")` · **Q6
`(sreg(30) >> 16) & 1`**, evaluated with no hook at all · Q7 `[+0x4C] & 1` ·
Q8 a 4-byte little-endian counter from a file under `res\dob` · Q10..Q18 the
words at `+0x8424`..`+0x8432` · **Q20..Q29 → `sub_100C6D40(n % 10)` on the
object at `RetouchSystem+0x9CF8`** · Q9, Q19 and anything above 29 → 0. The
corpus leans heavily on Q20, so that hook is the one to implement first.

### 11.6 String and cursor helpers, stated precisely

`sub_100F4B10(set)` = `CharNextA` then `fcMark`. `sub_101BEB40` peeks: at the
text base or the text end it returns only the single **sign-extended** byte; on a
trail byte whose predecessor is a lead byte it returns that byte alone; otherwise
`(lead << 8) | trail`. `sub_101BF070(p)` = `_mbccpy`, then `(b0 << 8) | b1` when
`b1 != 0`. `sub_101BFA50(out, value, radix, width, pad)` = `_ltoa`, where width 0
or equal to the length assigns, width less than the length truncates **from the
left**, and width greater left-pads. `sub_101C0890(this, 0, 1)` is
`sub_101BF070(cursor)`. `splitParam` is a thiscall over a copy-on-write string
(`sub_101BE000` / `sub_101BDFF0`), so **the caller's cursor is never consumed**.

Two measured quantities that bound any reimplementation: 3,649 corpus strings
reach the 24-slot capacity, so real scripts depend on truncation being silent;
and 91 corpus strings contain a double-byte character whose trailing byte equals
a VM delimiter, which is exactly where a naive byte-at-a-time scan splits a
string the engine does not.

### 11.7 Status of §10's risk register after implementation

- R-CALCFUNC — **closed** (§11.4 item 1).
- R-QQUERY — **closed** (§11.5).
- R-ENCODING — **premise corrected, rule retained** (§11.1).
- R-CMPOPSWAP — confirmed and **worse than stated**: three tables, not two
  (§11.2 item 7).
- R-FCREGOOB — confirmed at corpus scale: 2,044 out-of-range accesses across
  33,810 precompiled-condition records, all recovered to cell 0, zero runtime
  errors. Mirror the vendor: log, return cell 0, never throw.
- R-REGASYM — confirmed. Implemented as an explicit three-valued `ResolveCtx`
  (`kExpression`, `kSetRegParam`, `kSetRegString`); do not normalise the paths.
- R-HEXSTR, R-SAYMARKUP, R-TREGFLAGS, R-OP47, R-JUMPORIGIN, R-ASYNCARGS,
  R-MOVEAXIS, R-SKIPMODE, R-CGSHALLOW, R-AMBIG — unchanged, still open.
- R-FACEUP, R-SETREGT3, R-ACTIONTABLE, R-DEFRRLD — unchanged, still open.
- **New, open:** the 15 engine-state builtins (`isVa`, `isSt`, `isNo`, `isPl`,
  `isNe`, `dir8`, `dist`, `posX`, `posY`, `widt`, `heig`, `clip`, `isSc`, `isCu`,
  `isCh`, `bitC`, `bitE`, `chec`) are *decoded* but read state the foundation
  components do not own, so they belong to `vm` and `vm_cmd`. Register them
  through `BuiltinRegistry`; no foundation change is needed. `bitE` case 20 is
  `((a1 & a0) == a1)`; `isSt` case 3 is "treg cell length == 0".
- **New, open:** `CompareStrings` is assumed to be a byte-wise `lstrcmpA`
  normalised to −1/0/+1. `lstrcmpA` is not in `resident.dll`'s import snapshot,
  so it could not be disassembled. If Windows compares mismatching 16-bit
  **words** little-endian rather than bytes, two-byte characters order
  trail-byte-first and every cp932 `<`, `>`, `<=`, `>=` on a text register flips.
  **Equality, the overwhelmingly common corpus case, is identical under both
  readings**, so this only affects ordering comparisons.
