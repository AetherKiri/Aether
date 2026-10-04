# ExHIBIT Save/Load System — Implementation Specification

Status: **COMPLETE** — all 10 sections written (combined fresh-IDB decompilation from instances `2ec70db4de41` + `c5c73c78b37d`; VA authority = header provenance note). Byte-faithful for system.dat; slot-file/DB layouts decompiled-only (no on-disk sample, §10 N1).
Target engine: `resident.dll` (imopara3), image base `0x10000000`. IDA: fresh from-scratch analysis of `D:/imopara1/ida_recover/resident.dll`, instance `2ec70db4de41` (no symbol names — all addresses below were derived from the PE export table, PDB-named caches, or verified call-site rel32 arithmetic, and re-confirmed in the fresh database where noted).
Companion VM spec: `D:\imopara1\AetherKiri-exhibit\doc\exhibit_vm_spec.md` (referred to as "VM spec" below).
All byte values are hex. Claims carry an EA, a quoted disassembly/decompilation, or real file bytes with offsets. Items marked **inferred** are reasoned guesses, not observed facts.

**Address provenance note.** Three address sources were cross-checked (`save_verify.out.txt`, `save_verify2.out.txt`):
- **Call-site verified** (strongest): rel32 targets of annotated call instructions in cached disassembly. `isExistSaveData` body = `0x10073CB0` (three independent call sites 0x10115377/0x1011538B/0x101ABC81 all resolve there), `execLoad` body = `0x10073310` (call @0x101AA22F), Q5 `loadUserSettings` body = `0x10074E50` (call @0x101155D2).
- **PDB-named** (`names_interest.txt`, sibling IDA session with `resident.pdb`): e.g. `save@RetouchSystem` `0x101A40C0`, `load@RetouchSystem` `0x101A52B0`, `exitLoadMode` `0x10104DC0`, `quickSave` `0x100D5490`, `defSave` `0x10127940`, `createSaveTitleCallback` `0x100F7180`, `saveLfp` `0x1018D4E0`.
- **Export-table parse** of the raw PE (`resident_exports.txt`, `save_exports.py`): e.g. `systemSave(int,const char*)` `0x101A8320`, `flushSysreg()` `0x100202D0`, `saveEngine(FCFile&)` `0x1008DA80`, `loadEngine(FCFile&)` `0x100968B0`, `createSaveFilename` `0x10083CF0`, `checkSaveData` `0x1008D0D0`, `getSaveDataVersion` `0x1004EE30`, `time2key` `0x10006ED0`, `key2time` `0x100C8BB0`, `saveNotify` `0x10060030`, `removeSystemSave(int)` `0x100513E0`, `createThumbnailFilename` `0x1000D8F0`, `createSaveThumbnail` `0x10110840`.
  **RESOLVED (fresh IDB)**: the raw-PE export parse had a name↔VA pairing bug — every "export-table parse" VA in the third bullet is **deprecated** (e.g. `0x100202D0` is `TmAsyncFireworks::flushSeq`, `0x101A8320` is `RetouchSystem::systemMenu`, `0x1013E020` is `saveLayer()`, `0x1008DA80` is `saveEngine(int,int,const char*)` not `saveEngine(FCFile&)` = `0x1008D9B0`). The fresh IDB's auto-applied export names agree with **all three** call-site-verified bodies (0x10073CB0/0x10073310/0x10074E50) and with every PDB-named address, so the fresh-IDB names are the single authority (`save_names2.txt` = 3882 relevant name↔VA rows). Every function cited below was decompiled or disassembled in the fresh IDB (caches `decomp_save1/A/B/C/D/E/F/G/H/I.txt`).

---

## 1. File inventory

**Path root rule.** All user-writable persistence lives under `<game dir>\<USER_FOLDER>` where `USER_FOLDER=userdata\` comes from `ExHIBIT.ini [setting]` (measured, `D:\imopara1\imopara3\ExHIBIT.ini` line 10). The default literal `userdata\` and the key name `USER_FOLDER` are strings in `imopara3.exe` at file offsets `0x0D8AA0` / `0x0D8A94` (hexdump `save_exestr.out.txt`). Inside `resident.dll` the placeholder `%UserFolder%` exists at VA `0x1042E444`, referenced from `.text 0x1012C1DD` — the engine substitutes it in config values. No registry keys are involved (none observed).

On this machine `D:\imopara1\imopara3\userdata\` exists but is **empty** (no save ever made here). The only real sample is the shared all-CG-unlock snapshot `D:\imopara1\imopara3\全CG存档\userdata\imopara3.system.dat` (52,022 bytes, mtime 2018-01-27). A full walk of the game root (excluding `res\`, `rld\`) found no other `.dat/.sav/.svd/.sys/.bin`.

| # | File | Path rule | Evidence | Status |
|---|------|-----------|----------|--------|
| 1 | `imopara3.system.dat` | `userdata\<CLASS>.system.dat`, CLASS from ini (`imopara3`) | `.system.dat` literal @VA `0x1043B854` (xref `.text 0x102385F9`); exe copy @file off `0x0D8B34`; measured sample | **measured** |
| 2 | `*.system.dat` (wildcard) | enumeration/removal pattern | literal `2a 2e 73 79 73 74 65 6d 2e 64 61 74 00` @VA `0x104318D0` | measured bytes; use **inferred** (pairs with `removeSystemSave` export VA `0x100513E0`) |
| 3 | `settings.dat` | `<USER_FOLDER>settings.dat` — **confirmed**: `createUserSettings` @`0x10074C20` = `getFolder(10)` + `"settings.dat"` (decompiled); folder id 10 = user folder (ini `USER_FOLDER`, engine default `user\`) | literal @VA `0x10426914`, xref `0x10074C82` inside `createUserSettings`; format = plaintext `key=value` with `rnftype=1` header (§7) | **measured + decompiled** |
| 4 | `qc01.dat`, `qc02.dat` | `<CD drive>:\qc01.dat` / `qc02.dat` — **NOT user data**: read by `checkVirtualDrive` @`0x10074110` (decompiled: 4 MB read-timing loop, elapsed <800 ms → fast/virtual-drive flag stored at `this+12`) | literals @VA `0x104268F4` / `0x104268E8`, xrefs `0x100741EC` / `0x10074208` both inside `checkVirtualDrive` | **decompiled — excluded from the save system** |
| 5 | Thumbnails `<U\|A\|Q><saveId>.gyu` | `<USER_FOLDER>thumbnail\<id>.gyu` (folder from `tn.folder=%thumbnail\`) | `res\c\save.layout.rnf`+`load.layout.rnf` lines 121–134 (`tn.create=1,242,136`, `tn.file=%id%.gyu`, `%id%`=U/A/Q+saveId per rnf comment); engine literals `%saveid%.gyu` @VA `0x10426BE8`, `thumbnail\` @`0x10426BF8`, `%thumbnail` @`0x10426C10`, `tn.file` @`0x10426BE0`, `tn.folder` @`0x10426C04`, all xref'd from one body `.text 0x10093F27–0x10094059` | measured (rnf + strings); exact `%thumbnail` expansion **inferred** |
| 6 | Save-slot data files | `<USER_FOLDER>\<u\|a\|q\|s><idx>` — **unpadded decimal** (corrected this run), no extension (decompiled `createSaveFilename` @`0x1006D520`; formatter `sub_101BFA50(idx,10,0,32)` width=0 ⇒ `_ltoa` as-is, `decomp_save_fmt.txt`; type table + layout in §5) | no sample on disk (`userdata\` empty); layout decoded from `saveEngine`/`loadEngine` decompilation | **decompiled**, bytes unverified (§10 N1) |
| 7 | Slot DB files `udb`/`adb`/`qdb` | `<USER_FOLDER>\<u\|a\|q>db` — decompiled `createDBFilename` @`0x1006D5B0` appends fixed literals @VA `0x10425670/6C/68` (`udb\0`/`adb\0`/`qdb\0`); enum wildcards `u*`,`a*`,`q*`,`s*` @VA `0x1042564C+` (bytes read) | `saveDB`/`loadDB` @`0x1006DAA0`/`0x1006D880` decompiled — format in §5; debug literals `db size: ` @VA `0x10426BD4`, `history size: ` @`0x10426BC4` | **decompiled** |
| 8 | `backlog2.data.` | backlog/history store | literal @VA `0x10427A10` (xref `.text 0x100BD155`); ini `BACKLOG=3`, `N_HISTORY=1024,26576` | measured string |
| 9 | `tw.dat` | Twitter integration (`twSave`/`twLoad`) | literal @VA `0x1042E968` region | out of core-save scope |
| 10 | LFP override files | `saveLfp`/`loadLfp` (PDB-named `0x1018D4E0`/`0x1018D8B0`; export parse says `0x1013E020` — conflict, §10) | font/color/shortcut override persistence | **GAP** |
| 11 | `res\c\settings.user.rnf` | user-editable action-parameter overrides (`A###=`, `F#=`, `@###=` lines) | read verbatim; values match system.dat cells (see §2/§7) | measured |

Thumbnail **content** is JPEG: libjpeg strings `Warning: thumbnail image size does not match data length %u` @VA `0x10510934`, `    with %d x %d thumbnail image` @`0x105109A0`, `JFIF extension marker: JPEG-compressed thumbnail image` @`0x10510C00`; size 242×136 from `tn.create` (rnf).

### 1.1 `imopara3.system.dat` — full measured layout

Real bytes from the 52,022-byte sample (`save_dump1.out.txt`); all integers little-endian:

```
off 0x00: ff ff ff 7f        u32 magic   = 0x7FFFFFFF
off 0x04: 00 00 00 00        u32 word1   = 0            (version/flags — inferred)
off 0x08: 06 00 00 00        u32 tagLen  = 6 (incl. NUL)
off 0x0C: 46 43 52 65 67 00  char[6] tag = "FCReg\0"    (serializer class tag)
off 0x12: c8 32 00 00        u32 count   = 0x32C8 = 13000 (= N_SYSREG, ini line 18)
off 0x16: <13000 × int32>    S-bank cells 0..12999, PLAINTEXT
```

`22 + 13000*4 = 52022` = exact file size → **one record, nothing appended, no checksum, no encryption, no compression**. The tag string `FCReg` lives @VA `0x1043C53C` and is referenced from `.text 0x1025FA78` and `0x1025FB09` (the serializer body). Sibling class tags: `FCStrReg` @VA `0x104399A8` (xrefs `0x101F6D7D`, `0x101F6E2A`), error strings `FCReg - create` @`0x1043C51C`, `FCReg - item()` @`0x1043C52C`. `imopara3.exe` statically links the same framework: RTTI `?AVFCReg@@`, `?AVFCRegistry@@`, `?AVFCStrReg@@`, `?AVFCSaveData@@` and `FCReg - create` at exe file off `0x0E4510`.

Record grammar — **CONFIRMED by decompilation** (`decomp_saveF.txt`): the stream writer `sub_101BE970` emits exactly `u32 0x7FFFFFFF | u32 flags(0) | u32 len | payload[len]`; for FCReg the payload is the `"FCReg\0"` tag followed (via the class serializer) by `u32 count | int32 cells[count]`. The reader `sub_101C2980` mirrors it and has a **legacy fallback**: first dword ≠ `0x7FFFFFFF` → treat it as a plain u32 length prefix. String records use the same envelope with `len = strlen+1` (NUL included). Generalized:

```
RECORD := u32 magic(0x7FFFFFFF) | u32 word1 | u32 tagLen | char tag[tagLen] | PAYLOAD(FCReg)
PAYLOAD(FCReg) := u32 count | int32 cells[count]
```

## 2. The FCReg bank and what persists

### 2.1 Which banks exist and which persist where

| bank | size (ExHIBIT.ini) | class | persists in |
|---|---|---|---|
| S (sysreg) | `N_SYSREG=13000` **[M]** | `FCReg` (int32) | `userdata\imopara3.system.dat` — single measured record, tag `"FCReg"`, count 13000 **[M]** |
| R (reg) | `N_REG=2048` **[M]** | `FCReg` (int32) | save-slot files via `saveEngine(FCFile&)` **[I — record order open, §10]** |
| T (strreg) | `N_STRREG=256` **[M]** | `FCStrReg` (strings; tag string @`0x104399A8` **[B]**) | save-slot files **[I]** |
| LOC | `N_LOCREG=100` **[M]** | unknown class | not observed in system.dat; slot behavior unknown (§10) |

system.dat contains **S only** — the file is exactly 22 + 13000*4 bytes with one record, leaving no room for R/T (§1.1) **[M]**.

### 2.2 Transform: none (plaintext)

No XOR, no checksum, no compression on system.dat **[M]**: cells match known plaintext values —
- `cell[4]=0x8080`, `cell[8]=0x021C01A4` = (540,420) packed screen size, `cell[13]=1500` (= `A312` in `settings.user.rnf`), `cell[15]=89` (relocation base), `cells[17..22] = 250/250/200/250/200/250` (= `A306`–`A311` volume defaults), `cell[24]=224` (= `A330`), `cell[31]=0x00660066`, `cells[32+]=0x00800080` volume pairs **[M — full map in `save_cells.out.txt`/`save_cells2.out.txt`]**;
- `cells[189..192] = 9999/400/100/1500` — mirrors of ini `N_CG`/`N_SCENE`/`N_SOUND`(-ish) and `A312` **[M,I]**.

The `.rld` XOR-keystream cipher (VM spec §9) is a *different* path (script data), **not** applied here **[M by absence]**.

### 2.3 Cell regions of S (measured map of the 52022-byte sample)

- `[1..105]` settings block (see above; overlaps `settings.user.rnf` A-codes).
- `[189..192]` engine-capacity mirrors.
- `[473..6459]` per-50-cell blocks holding values 0..4 — CG/scene/message *seen* counters/flags **[I]**.
- `[7193..7697]` small counters 1..15 **[M]**.
- `[10191..10272]` 75 cells all = 1 **[M]**.
- `[10692..11500]` len-809 run of 32-bit bitmask words: 352 cells = `-1` (all bits set), the rest "all bits except one" negatives — consistent with a 100%-unlock snapshot where bit set = experienced **[M bytes, I semantics]**.
- `[11500..12999]` zero. Whole file: 2424 nonzero cells; value histogram peaks `1 x1198`, `-1 x352` **[M]**.

### 2.4 Write path (when system.dat hits the disk)

- VM: op8 `cmdSetReg` with bit8 in `params[2]` → `flushSysreg()` (VM spec §6.4, settled). Corpus: **24 op8 records, all `params[2]=0`** → the story corpus never flushes; flushes come from the settings UI/system paths **[M census]**.
- `flushSysreg()` **real VA `0x10072C80`** (fresh-IDB export name; the old export-parse VA `0x100202D0` is `TmAsyncFireworks::flushSeq` — decompiled, unrelated). Decompiled: a one-line tail call `sub_1023BCF0(0, 0, 1)` = the engine sreg-setter: `*FCReg::item(S-bank@this+4161*4, 0) = 0; if (flush) sub_10238680();` — i.e. **`sreg(0) = 0` (cell 0 = dirty/flush flag) then commit the S bank to disk via `sub_10238680`**, the same commit call that ends FCReg's serializer. Measured sample has `cell[0]=0` ✓. `FCReg::item()` = `sub_1025F910` (decompiled in the VM-spec run): in-range → `cells+4*idx`; out-of-range → MessageBox `"FCReg - item()"` + returns base pointer = **cell-0 clamp** — the `bank_error` behavior, now measured at source level. The `"FCReg"` tag xref sites `0x1025FA78`/`0x1025FB09` live in `sub_1025FA40`/`sub_1025FAE0` = FCReg vtbl[1]/vtbl[2] (serialize/deserialize, §2.5) **[M decompiled]**.
- `UxAdvSystem::systemSave(int,const char*)` **real VA `0x1008DC90`** (decompiled): `fn==NULL` → default filename from singleton `*(sub_101F6C10(1)+4)+20` (the `<CLASS>.system.dat` path — **inferred**, matches the measured file); then `saveEngine(3, id, fn)` → **engine save-type 3 = system** (type table §5). The old export-parse VA `0x101A8320` is `RetouchSystem::systemMenu` (decompiled) **[M]**.
- `removeSystemSave(int)` **real VA `0x10073950`** (decompiled): `createSaveFilename(out, 3, id)` → if file exists (`sub_101E7920`) delete it (`sub_10263300`).
- `autoSave(AutoSaveParams&)` @`0x1008DCD0` (decompiled): slot cursor = **`sreg(7)`** clamped to `[0, numberOfAsave)`; optional thumbnail (flags `this[986]` bits 8/4 → `createSaveThumbnail(1, slot, params[0], 1289|34057, 0, title)`); `saveEngine(1, slot, title)`; then `sreg(7) = (slot+1) % numberOfAsave` **followed by `flushSysreg()`** — the round-robin cursor persists to system.dat (measured cell map region [1..105]).

### 2.5 Load path and error behavior

- **Serializer and deserializer are now decompiled** (fresh IDB, caches `decomp_saveB/C.txt`). FCReg vtable @VA `0x1043B818` = `{dtor 0x10237770, serialize 0x1025FA40, deserialize 0x1025FAE0}` (3 slots; the adjacent FCStrReg vtable @`0x1043B828` = `{0x10237850, 0x101F6D40, 0x101F6E00}`, same slot order). Object layout: `+4` = `int32* cells`, `+8` = `int32 count`.
  - **serialize** (`sub_1025FA40`): `sub_101CD890("FCReg")` (record-header/tag machinery — emits §1.1's `magic|word1|tagLen|tag` bytes) → `sub_101BE970(stream)` barrier → `write(&count, 4)` → `write(cells, 4*count)` → `sub_10238680()` commit.
  - **deserialize** (`sub_1025FAE0`): `sub_101CD890("FCReg")` → if stream-ok (`sub_101E7A80`, `sub_102AC7F0`): `sub_1025F860(this)` frees the old array → `read(&count, 4)` → `sub_1025F890(count)` **allocates the file's count** → `read(cells, 4*count)`.
- Load is therefore **whole-bank replacement, not merge**: the bank is freed and re-allocated to the file's `count`. A file with smaller `count` *shrinks* the bank **[M decompiled]**. **Short/truncated file** (data past EOF): count still wins the allocation; tail cells get whatever the read leaves (allocator-zeroed or stale) — no truncated sample exists to observe **[I, §10]**. **Missing file**: stream-open fails → guarded out, bank keeps init values **[I from the guard structure]**.
- **Out-of-range access** (the corpus's 2044 hits): VM spec [settled] — clamped/recovered to cell 0 via the `bank_error` hook; never reaches the file because flush always writes exactly `count` cells **[M framing]**. Consequence: cell 0 can be polluted by erroneous writes; measured sample has `cell[0]=0` **[M]**.

### 2.6 Slot-file persistence (what a save slot carries beyond S)

**Superseded by fresh-IDB decompilation** (caches `decomp_saveB/D/E/G/H.txt`). Real addresses: `saveEngine(FCFile&)` = `0x1008D9B0`, `saveEngine(int type,int id,const char* title)` = `0x1008DA80`, `loadEngine(FCFile&)` = `0x100966A0`, `loadEngine(int,int)` = `0x100968B0`. The int overload (decompiled verbatim) writes the **entire slot file**: reg(4) flag update (`reg(4) = reg(4)&0xFFF000FF|0x200`, +bit23 iff `this[80]&1`) → `RetouchCharacterManager::save(this+2624)` (`0x10057ED0`, 53 B — commits live character state into engine fields before serialization **[semantics I]**) → `createSaveFilename` → CreateFile(CREATE_ALWAYS) → 24-byte header (§5) → **engine-state blob** `sub_1023BB20` (91 B) = `Rbank.vtbl[1](file)` + `Tbank.vtbl[1](file)` (banks at engine `+24`/`+36`; vtbl[1] = the same serialize slot as FCReg's) + 2 string records (`sub_101BE970`) + `sub_102D0CC0` (u32 `engine[23]!=0`, u32 `engine[37]&1`, string record from `engine+1944`) → if reg(4) bit23: `saveJumpHistory(file)` @`0x1008B470` → flush/close (`sub_101E7C10`) → if type≠3: reopen read-only, take the file's FILETIME (`sub_101E8230`), `saveNotify(type,id,filetime,title)` @`0x1006E590` (updates the in-memory DB item and rewrites the whole DB file via `saveDB`). **Slot files carry no layer/camera/print-socket state** — visuals are rebuilt at load by scenario reload + VM resume (load-side `sub_10240140` walks the FCSignature list, purges resource caches type 5/6; resume machinery = VM spec op23/24 `[+0x8B24]=-1` marker + `exitLoadMode(350)` @`0x10104DC0`). The old raw-xref callee list attributing saveLayer/savePrintSocket/createSaveList to saveEngine was an artifact of the misparsed function ranges — **deprecated**. Per-feature savers, fresh-IDB-named: `saveJumpHistory`/`loadJumpHistory` `0x1008B470`/`0x100964F0`; `saveReadFlag`/`loadReadFlag` `0x10072E00`/`0x10072E90` — **decompiled: read/seen flags persist through the S bank** (each 32-bit word of an `FCBit` → `sregSetEngine(base+i, word, flush=1)`; single-bit mode writes only word `a4/32`; optional trailing `flushSysreg`) — this is what fills the measured system.dat bitmask regions `[473..6459]`/`[10692..11500]`; `saveGraphicInfo` `0x1007C2E0`; `savePrintSocket` `0x1000A6B0`; `saveLayer()`/`loadLayer()` `0x1013E020`/`0x10157340`; `saveClipper`/`loadClipper` `0x10073510`/`0x100735E0`; `saveViewClip`/`loadViewClip` `0x1007B820`/`0x1007B920`; `saveCamera` `0x10086E70`(FCString)/`0x10087020`(); `loadCamera` `0x1007BA10`/`0x1007BD40`; `checkSystemFlag` `0x10077F00`; `setLoadIndex` `0x100C32F0`; `clearLfp` `0x100C5340`; `loadRld` `0x100FDF50`; `registerClient` `0x10094110`.

**RNG state is NOT persisted anywhere** — settled by disassembly in §6: the generator is an LCG (`x = x*0x5D588B65 + 1`) plus a 32-word bit-reversal table (not MT19937 — VM spec §11.4's "MT state" label is an erratum), seeded from `GetTickCount`, and no save/load path touches its object.

### 2.7 RegHooks mapping for the sibling interpreter

| hook | fed by |
|---|---|
| `system_query` | Q0/Q1 `isExistSaveData` probes (§3); Q5 `loadUserSettings`; Q8 `res\dob` |
| `sreg_notify` | every S write → host marks dirty; bit8-flush requests (op8) → write system.dat (§2.4) |
| `bank_error` | out-of-range R/S/T access → clamp+recover to cell 0 (§2.5); no file impact |
| `manager_query` | ResManager seen/CG/scene/message flag queries — the data behind cells `[473..6459]` and `[10692..11500]` |
| `runtime_error` | invalid/absent save data at load: strings `"invalid save data."` @`0x1043154C` (xref `0x101A6019`), `"no save."` @`0x1042D490` (xrefs `0x10116E4D`, `0x101A6035`) **[B; hook attribution I]** |

## 3. `isExistSaveData(0x111)` vs `isExistSaveData(0x11)`

**Settled by decompilation** (rebuilt IDB `c5c73c78b37d`; caches `decomp_isExistSaveData.txt`, `decomp_isExist_helpers.txt`). The argument is **not a slot id — it is a category bitmask**, and Q0/Q1 differ only in whether the *quick-save* category is included.

### 3.1 `UxAdvSystem::isExistSaveData` @ `0x10073CB0` (71 B, call-site-verified)

```c
bool __thiscall UxAdvSystem::isExistSaveData(UxAdvSystem *this, __int16 a2)
{
  return (a2 & 1) != 0 && UxAdvSystem::isExistUserSaveData(this)
      || (a2 & 0x10) != 0 && UxAdvSystem::isExistAutoSaveData(this)
      || (a2 & 0x100) != 0 && UxAdvSystem::isExistQuickSaveData(this);
}
```

| bit | category | helper (all 224 B, identical bodies but for the category constant) |
|---|---|---|
| `0x001` | user saves (ids 0–89, `save.usave`) | `isExistUserSaveData` @ `0x10073BD0` — `initTitleIterator(ctrl, 0, false)` |
| `0x010` | auto saves (ids 90–98, `save.asave`) | `isExistAutoSaveData` @ `0x10073A10` — cat 1 |
| `0x100` | quick saves (ids 99–107, `save.qsave`) | `isExistQuickSaveData` @ `0x10073AF0` — `initTitleIterator(ctrl, 2, false)` (measured in its decompilation) |

Therefore **Q0 = `isExistSaveData(0x111)` = "any user OR auto OR quick save exists"**; **Q1 = `isExistSaveData(0x11)` = "any user OR auto save exists"** (quick excluded — Q1 is the "can continue?" probe, Q0 the "any save at all?" probe). Call sites confirmed at instruction level: `push 111h` @`0x10115370` → `call` @`0x10115377` (Q0, switch case 0); `push 11h` @`0x10115387` → `call` @`0x1011538B` (Q1, case 1); bool→int marshalling `neg al; sbb eax,eax; neg eax` @`0x1011537C`–`0x10115382`. Third call site: `0x101ABC81` (cmdExHIBITMain case 37).

**Provenance conflict resolved**: the export-table VA `0x10073AF0` is `isExistQuickSaveData` (decompiled), not `isExistSaveData` — the earlier export-parse name↔VA association was wrong for this family; `0x10073CB0` (the address all three engine call sites target) is the real `isExistSaveData`.

### 3.2 What each helper actually consults

`this` = `UxAdvSystem`; the `RetouchSaveDataControl` member lives at **`UxAdvSystem+2980` (`+0xBA4`)** (measured in all three helper bodies). Each helper: construct FCString (`0x101BDB60` ctor, `0x101BDF20` reserve(256), `0x101BDFF0` dtor), then

```c
initTitleIterator(ctrl, cat, false);
do { r = nextTitle(ctrl, &str, &idx, false, false, NULL); } while (r == 0);
return r > 0;   // r < 0 (exhausted/error) -> false
```

- **`initTitleIterator(int cat, bool buildList)` @ `0x1006E850` (408 B, decompiled)**: validates `cat` via `isValid`, stores it at `ctrl+52`, resets position `ctrl+56=0`, stores `buildList` at `ctrl+48`. With `buildList=false` (the isExist* path) nothing else happens — plain sequential scan. With `true` it builds a node list `{elemPtr, index}` (8-byte nodes) from the category's in-memory table: **counts at `ctrl+20/+24/+28` and element arrays (stride 16 B) at `ctrl+36/+40/+44` for cat 0/1/2** (measured in decompilation).
- **`isValid(cat, idx)` @ `0x1006CB30` (73 B, decompiled)**: `cat==3 → true` (special "all" category); else `idx >= 0 && idx < count[cat]` where count = `ctrl+20/+24/+28` for cat 0/1/2; other cats false. So the scan bounds are the loaded per-category slot counts — 90/9/9 per ini `N_USAVE=108` split by the rnf ranges **[I for the split]**.
- **`nextTitle(FCString&, int&, bool, bool, uint*)` @ `0x1006EC00` (194 B, decompiled)**: sequential mode → `pos=ctrl+56`; if `isValid(cat,pos)`: `*idx=pos; r=title(cat,pos,...); ++pos; return r`; else reset and return `-1`. So the loop walks every slot of the category and returns the first `title()` result `>0`.
- **`title(FCString&, cat, idx, bool, uint*)` @ `0x1006E060` (1280 B, callee-level analysis)**: `isValid(cat,idx)` → `getItem(cat,idx)` returning **`UxPairItem<FCString>`** (a `{FCString memo/title, u32 timeKey}` pair) → `key2time(SYSTEMTIME&, u32)` @`0x1006E100` → formats the display title by substituting `%IDX% %ID3% %ID2% %YYYY% %YY% %MM% %DD% %hh% %mm% %ss% \n %memo%` (string pushes at `0x1006E14E`–`0x1006E320`) — the same placeholder grammar as `info.format` in `load.layout.rnf`; empty-slot fallbacks `"--/-- --:-- "` @`0x1042569C` / `"--/--/-- --:--:-- "` @`0x10425674` (pushed `0x1006E3B1`/`0x1006E3C4`). Its int return is >0 for a *used* slot and ≤0 for an unused one **[I — the exact per-slot used-test inside `title()` is §4/§5 work; flagged §10]**.

### 3.3 Field/file summary for implementers

- **Field consulted**: the in-memory per-category slot tables of `RetouchSaveDataControl` (`UxAdvSystem+0xBA4`) — count (`+20/+24/+28`), 16-byte-stride item array (`+36/+40/+44`), each item a `{FCString, u32 timeKey}` pair. **No filesystem stat occurs at query time** — the tables are populated from the slot DB files (`loadDB`/`createDBFilename`, §1 row 7) at init/save-notify time **[I — load point not yet traced]**.
- **Q0** → true iff any of the 108 slots (user∪auto∪quick) is used. **Q1** → true iff any user or auto slot (ids 0–98) is used; quick-only state returns false.
- Category ids: `0`=user, `1`=auto, `2`=quick (measured: helper↔constant pairing above); `3`="all" (isValid always true) **[semantics I]**.
- For the port: route Q0/Q1 through `system_query` with the bitmask as argument; the host answers from its own slot-DB model (§2.7).

## 4. The save/load handlers

All EAs below are from the rebuilt DB's own PDB names (authoritative per §3.1); full pseudocode cached in `decomp_saveengine.txt`, `decomp_save_uicmds.txt`, `decomp_save_slots.txt`.

### 4.1 Opcode inventory (method_table.json + corpus_census.json + VM spec §3.3)

| op | cmd | body EA (DB) | corpus | role |
|---|---|---|---|---|
| 11 | `cmdExHIBIT` → `cmdExHIBITMain` @`0x101A9FD0` | sub-cases | ×37 (all case 27 `skipCancel`) | save-relevant sub-cases: **24** = `execLoad` (call @`0x101AA22F`), **36/37** @`0x101ABC5E`/`0x101ABC6E` (case 37 calls `isExistSaveData` @`0x101ABC81`). Q0/Q1 probes live in the *operand* switch `jpt_10115369` (VM spec §5.9/§11.5, §3 above) |
| 12 | autosave point (inline, VM spec §3.3 **[settled]**) | — | ×84, all `"0,*,*"` | if `reg(3)==pc` skip; else `splitParam(",")`, build `AutoSaveParams{type=186}`, `autoSave()`, then `reg(3,-1)`. Engine side: §4.4 |
| 40 | `cmdDefConfig` | `0x10149C10` (23 B thunk) | 0 | config-screen definer (settings, §7) |
| 41 | `cmdDefSave` | `0x10149C30` (23 B thunk) | 0 | save-screen definer → `defSave` (§4.2) |
| 42 | `cmdDefLoad` | `0x10149C50` (23 B thunk) | 0 | load-screen definer → `defLoad` @`0x10127E10` (mirror of `defSave`, same 1227 B size) |
| 43 | `cmdDefLog` | `0x10149C70` (23 B thunk) | 0 | backlog-screen definer (`backlog2.data.` store, §1) |
| 61 | `cmdCreateDbInt` | `0x1017F2A0` (20 B) | 0 | `createDB(this, CMD_DATA[2]/*dbId*/, str0)` — create/reset an 8-int INTDB record |
| 62 | `cmdGetDbInt` | `0x1017F2C0` (317 B) | **×7** | read INTDB → scatter into R cells (§4.2) |
| 63 | `cmdSetDbInt` | `0x1017F400` (302 B) | 0 | gather 8 values → `setDB(dbId,key,INTDB)` |
| 196 | `cmdSnapshot` | (export parse `0x10198070`, unverified) | 0 | screenshot; not slot persistence |
| 208–210 | `cmdCreateDB`/`cmdGetDB`/`cmdSetDB` | `0x1018B660`/`0x1018B680` (thunks), `cmdSetDB` `0x1017F760` (692 B), `cmdGetDBSub` `0x1017F540` (534 B) | 0 | string-DB variants |
| 211 | `cmdSetLoadMask` | `0x101002D0` (335 B) | 0 | load-time remap table for indices <256 (T-bank string registers **[inferred]**): `str0` = up to 8 `(src,dst)` pairs → `this[8908+2n]`/`this[8909+2n]`, count `this[8907]`; values ≥256 → −1; short form uses `CMD_DATA[2]/[3]` |

Delete/enumerate are **not script opcodes**: deletion = `RetouchSaveDataControl::remove/clearItem` (§5), enumeration = the `title`/`nextTitle` iterators (§3.2) driven by the load UI.

### 4.2 Parameter grammar (via `exhibit_vm_str.h` primitives)

All handlers parse `CMD_DATA.str0` (@`CMD_DATA+0x5C`) with `RetouchSystem::splitParam` @`0x100DFD10` (`SplitParam`: comma delim `vm_delim::kComma` @`0x10423EA8`, keepEmpty hardcoded, no quoting/escaping), ints via `sub_101C28C0` (`Str2Int`: `0x` hex / `0b` binary / atoi), register operands via `calcExpression`. `cmdDefSave/Load` thunks pass `a3 = CMD_DATA[1] >> 28` (top nibble) and use capacity 48 (a3<1) or 49 with raw-remainder (a3≥1).

- **op41 `defSave(str0, a3)` @`0x10127940`** — *defines* the save screen, saves nothing itself. Token stream (decompiled): 2 ints + 4 layer-ids via `cmdLid2lid` + 1 int → `RetouchSaveDataViewParam::create(this+7872,…)`; four `(string,int,int)` groups → `this+1976/7`, `+1981/2`, `+1986/7`, `+1991/2`; `setItemArea(4)`, `setMemoArea(7)`, `setSIItem(str,4)`, `setSIPage(str,4)`, `setSIMemo(str,4)`, `setSIExit(str,2)`. `a3<1` loads built-in defaults (`this+2038..2045` = 256,400,20,16,…,0xFFFFFF,0 from globals `0x1051E3F0/F4/440`); `a3≥1` opens the UI (`sub_100BFFA0(this+8140,…)`). The actual per-slot save fires from the screen's item action (`save.layout.rnf` item action 52 = save-slot, 54 = page) → engine `saveEngine(0, slotIdx, memo)` **[UI-action glue inferred — not decompiled; flagged §10]**. `defLoad` mirrors with action 55 → `loadEngine(0, slotIdx)`.
- **op62 `cmdGetDbInt`**: `str0 = "<dbId>,<keyExpr>,(slot,destRegExpr)×8"` — `dbId=Str2Int(tok0)`, `key=calcExpression(tok1)`, then 8 pairs: `slot=Str2Int` (must be ≤7 else reads 0), `dest=Str2Int(tok)` → `LocalHolder::setReg(dest, INTDB[slot])`. Corpus sample `"2,R1293,0,1297,-1,…"` = dbId 2, key from R1293, INTDB[0]→reg via token `1297`, remaining pairs `-1` = discard. `getDB/setDB` (RetouchSystem) hold INTDB = **8 × int32** keyed `(dbId,key)`; their on-disk backing not traced (§10 N8 — the `qc01/qc02.dat` candidacy is excluded by §7.4).
- **op63 `cmdSetDbInt`**: same head; 8 pairs `(slot, valueExpr)` → `setDB(dbId,key,…)`.
- **op12**: VM-spec grammar **[settled]**; note the engine's `autoSave` ignores `str0` for slot choice — it rotates **S[7]** (§4.4). `AutoSaveParams.type` (=186 per VM spec) is passed to the thumbnail call.

### 4.3 Engine call chains (fully decompiled)

**`UxAdvSystem::saveEngine(int cat, int idx, const char* memo)` @`0x1008DA80`** (protected; cat 0=user/1=auto/2=quick/3=system):
1. Stamp `R[4]`: `R[4] = (R[4] & 0xFFF000FF) | 0x200`; then set bit23 (`0x800000`) iff jump-history enabled (`this+80` bit0), else clear it. (`getSaveDataVersion()` @`0x100737E0` = `(u16)(R[4]>>8)` — version lives in R[4] bits 8..19; bit9 (0x200) = "genuine engine save" marker **[role inferred]**.)
2. `RetouchCharacterManager::save(this+2624)` — character/layer state serialized (target stream not explicit in the decompile; feeds the file opened below or an internal buffer **[inferred]**).
3. `createSaveFilename(ctrl=this+2980, &name, cat, idx)` (§5.2).
4. `FCFile.open(name, write, GENERIC_READ|WRITE(0xC0000000), CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL)` (`sub_101E8AB0`).
5. Write engine header — **7 × u32**: `[0x8000 magic][0 reserved][key = this+56][id0..id3 = this+60..+72]`.
6. `sub_1023BB20(file)` — the bank serializer: virtual `save(file)` (vtbl+4) on the two bank objects at registry+24 and registry+36 (**R `FCReg` + T `FCStrReg`; which offset is which bank [inferred]**), then two name-string records, then `sub_102D0CC0`: `u32(reg+92 != 0)`, `u32(reg+148 & 1)`, one string record (reg+1944), then **`sub_10238680` rewrites `userdata\<CLASS>.system.dat`** (opens CREATE_ALWAYS, S-bank `FCReg` virtual save = preamble+count+13000 cells, closes) — *every engine save also flushes system.dat*.
7. If jump-history enabled: `saveJumpHistory(file)` @`0x1008B470`.
8. `SetEndOfFile` (truncate stale tail when overwriting a longer save — `sub_101E7C10`), close.
9. If `cat != 3`: reopen the same file read-only, take its FILETIME (`sub_101E8230`), `saveNotify(ctrl, cat, idx, ft, memo)` → slot DB item `{time2key(ft), memo}` + immediate `saveDB(cat)` rewrite (§5.4).

**Every serialized record** (banks, strings, memos) starts with the preamble written by `sub_101BE970`: `u32 0x7FFFFFFF | u32 0 | u32 (strlen+1) | tag bytes` — byte-identical to the measured system.dat header (§1.1), confirming the grammar generalizes.

**`UxAdvSystem::loadEngine(int cat, int idx)` @`0x100968B0`** (protected):
1. `createSaveFilename`; open read-only (`GENERIC_READ 0x80000000`, OPEN_EXISTING). Missing file → `FCFile` throws (retry MessageBox "FCFile - write"-class handler in `sub_101E8690`/reader twin) **[exception path inferred]**; `quickLoad` pre-checks `isUsed` to avoid this.
2. Read magic: must be `0x8000` (or `0` = legacy, only while `this+56 == 0`); anything else → `seek(-4)`, **"system warning" dialog** (cp932 message string @`0x10426C88`, `MessageBox`-style `sub_101BCC00` with caption `"system warning"`), return 0 — *no state touched*.
3. Read reserved word, `key`, `id[4]`; `checkSaveData` @`0x100737F0`: file `key` must equal current `this+56`; if key ≠ 0 also `id[0..3] == this+60..+72`. Mismatch → same warning dialog, return 0. (**Save-compatibility identity** — title/scenario GUID-like, set at boot; setter not traced, §10 **[semantics inferred]**.)
4. `sub_10240140(file,…)` — bank deserializer: virtual `load(file)` (vtbl+8) on registry+24/+36; scenario-name record handling (file name vs current string @reg+16976, mismatch → conversion path `sub_10017A70`); `FCSignature` list at reg+16632 refreshed (entries with `id()==110` get vtbl+84(1)); all under critical section reg+16604.
5. `RetouchCharacterManager::load(this+2624)`.
6. Jump history: if enabled, `R[4] & 0x800000` ? `loadJumpHistory(file)` @`0x100964F0` : `clearJumpHistory`.
7. `vtbl+18` = `postLoadEngine` (`UxAdvSystem` @`0x100737D0` = bare `ret`; `RetouchSystem` override @`0x100D5620`, 54 B); `setLoad`; `loadRequest`; return 1.

`saveEngine(FCFile&)` @`0x1008D9B0` / `loadEngine(FCFile&)` @`0x100966A0` are the same bodies on a caller-provided open file (used by `snapshot`-style flows); the int-overloads wrap them with filename+open+notify.

### 4.4 Quick/auto/system/execLoad (all decompiled in full)

- **`quickSave(int idx)` @`0x100D5490`**: if save not inhibited (`this+76` bit0 == 0): `saveEngine(this, 2, idx, defaultMemo)` where defaultMemo = global config string (`sub_101F6C10(1)`→`+4`→`+20`; the cp932 default-memo string @`0x104256AC` region). Slot idx is the caller's (UI hotkey) parameter.
- **`quickLoad(int idx, bool confirm)` @`0x10157410`**: mode guard `this[19]&2` → return 0; `confirm` → `system_dialog(2,6,7,6)` must return 6 (Yes); `isUsed(ctrl,2,idx)` false → return −1; prep (`sub_100A6490(1)` — *itself draws RNG*, §6 — and `sub_1008C4D0`); `loadEngine(this,2,idx)`; returns 1/0.
- **`autoSave(AutoSaveParams&)` @`0x1008DCD0`** (op12's engine half): `slot = S[7]`, clamped to `[0, numberOfAsave)`; if `this+3944 & 8` and `params.type >= 0`: `createSaveThumbnail(this, 1, slot, params.type, this+3944&4 ? 0x8509 : 0x509, 0, memoFromParams)`; `saveEngine(this, 1, slot, memo)` (memo = `params+8` string or global default); then **`S[7] = (slot+1) % numberOfAsave`** and **`flushSysreg()`** — the rotation index is itself persisted in system.dat, so autosaves round-robin across reboots.
- **`autoSave(const char* memo, int type)` @`0x10090420`**: wrapper building `AutoSaveParams` → the above.
- **`systemSave(int i, const char* name)` @`0x1008DC90`**: `saveEngine(this, 3, i, name ?: globalDefault)` → file `<saveFolder>s<i>`, **no DB item** (saveDB/saveNotify skip cat 3).
- **`execLoad()` @`0x10073310`** (op11 sub-case 24): if pending-load flag `this+4628` set: clear it, set `this+4629=1`, build and **throw `LoadException`** (`CxxThrowException`, `_TI2_AVLoadException__`) — the load executes via C++ unwinding to the VM-loop catcher **[catcher site inferred]**. This is how "load from the menu mid-scene" restarts the script.

### 4.5 Side effects summary (for the port)

A slot save touches: the slot file (rewritten, CREATE_ALWAYS + SetEndOfFile), `<u|a|q>db` (rewritten via saveNotify), `userdata\<CLASS>.system.dat` (rewritten twice: bank-serializer tail + autoSave's flushSysreg), S[7] (autosave rotation), R[4] (version/save/jump-history bits), the thumbnail file (autosave with flag, UI saves per rnf `tn.create=1`), and the RNG state (only incidentally — `quickLoad`'s prep draw, §6). A load touches: R/T banks, character manager, jump history, `postLoadEngine`, and throws into the VM loop; it never writes files.

## 5. Slot layout

### 5.1 Categories, counts, and setup

`RetouchSaveDataControl` (RSDC, embedded at `UxAdvSystem+2980`/`+0xBA4`) owns four slot categories: **0=user (`u`), 1=auto (`a`), 2=quick (`q`), 3=system (`s`)**. `RSDC::create(const char* folder, nUser, nAuto, nQuick)` @`0x1006EA30` (451 B, decompiled): stores counts at ctrl+20/+24/+28, allocates three item arrays (`new u32[1 + 16*n]`, first word = n; 16-byte items `{u32 timeKey; FCString memo}`) at ctrl+36/+40/+44, stores the base folder (ensuring trailing `\`), then `createDB(cat)` for each of cats 0..2 (load-or-init each DB file). **Sole caller: `initScenario@RetouchSystem` @`0x101B3849`** — counts flow from `ExHIBIT.ini` `N_USAVE=108 / N_ASAVE=9 / N_QSAVE=9` **[ini→create wiring inferred]**. Accessors `numberOfUsave/Asave/Qsave` @`0x1006CB80/90/A0` return ctrl+20/+24/+28 (disasm: `mov eax,[ecx+14h]; retn` etc.).

Slot indices passed to `saveEngine/loadEngine/isValid/isUsed` are **per-category, 0-based** (autoSave's `S[7]` is bounds-checked against `numberOfAsave`). The rnf UI slot-ids 0–89/90–98/99–107 (`save.layout.rnf`, §1) are a shared 108-id space for the screens; the UI→engine conversion glue was not decompiled **[inferred: subtract range base; §10]**. Cat 3 has no DB, no count bound (`isValid(cat=3,…)` always true, §3.2), and exists for `systemSave` files `<folder>s<i>`.

### 5.2 On-disk names (all builders decompiled; suffix bytes measured)

| kind | rule | evidence |
|---|---|---|
| slot data file | `<saveFolder> + {"u","a","q","s"}[cat] + ltoa(idx,10)` — **no padding, no extension** (e.g. `u0`, `u89`, `a3`, `q8`, `s0`) | `createSaveFilename` @`0x1006D520`; formatter `sub_101BFA50(idx,10,width=0,pad=32)` → width 0 = as-is |
| slot DB file | `<saveFolder> + {"udb","adb","qdb"}[cat]` | `createDBFilename` @`0x1006D5B0`; measured bytes `71 64 62 00 61 64 62 00 75 64 62 00` @`0x10425668` (`qdb`/`adb`/`udb`) |
| thumbnail | template `tn.file=%id%.gyu` with `%id%` = `{"U","A","Q"}[cat] + idx` **5-digit zero-padded** (e.g. `U00007.gyu`, `A00000.gyu`), folder from `tn.folder=%thumbnail\` | `createThumbnailFilename` @`0x10073840` (`sub_101BFA50(idx,10,5,'0')` then `sub_101C2BB0("%id%", id)` substitution) |
| system bank | `[prefix] + <CLASS> + ".system.dat"` → `userdata\imopara3.system.dat` | `sub_10238580` name builder + writer `sub_10238680`; CLASS member = registry+4 string |

`saveFolder` = the FCString at ctrl+12 (distinct from the ctrl+4 base-folder member used by the system.dat name build); its setter wasn't traced — expected `USER_FOLDER=userdata\` from the ini **[inferred; §10]**. `isSaveFilename(name,&cat)` @`0x1006CC70` parses back: first char `u/a/q/s` (any case) → cat; remainder must `lstrcmpA`-match the canonical `ltoa` form — so enumeration over directory listings must canonicalize exactly (no zero-pad tolerance).

### 5.3 Slot-file record layout (from §4.3 chains)

```
[u32 0x8000 magic][u32 0 reserved][u32 key = UxAdvSystem+56][4×u32 id = +60..+72]
<character-manager record(s)>                     ; internal layout NOT decoded (§10)
<bank record @registry+24> <bank record @registry+36>   ; R FCReg / T FCStrReg (which offset = which bank [inferred])
<string record> <string record>                   ; scenario/module name tags
[u32 (reg+92!=0)][u32 (reg+148&1)]<string record @reg+1944>   ; sub_102D0CC0
[ jump-history records ]                          ; iff R[4] bit23 (0x800000)
EOF (SetEndOfFile truncates any stale tail)
```
Every tagged record = preamble `u32 0x7FFFFFFF | u32 0 | u32 (strlen+1) | bytes` (`sub_101BE970`) + payload; for an `FCReg` bank the payload is `count + count×i32` (byte-identical to measured system.dat, §1.1). `FCStrReg` (T) payload per-string framing not decoded **[§10]**.

### 5.4 DB-file layout and metadata

Per category, `saveDB(cat)` @`0x1006DAA0` writes `CREATE_ALWAYS`: for each slot `i < count[cat]`: `[u32 timeKey][preamble+memo string]`, then `SetEndOfFile`. `loadDB(cat)` @`0x1006D880` mirrors (returns false if file missing → `createDB` @`0x1006E710` then `initItems(cat)` (all slots → `{0, ""}`) + `saveDB` to materialize a fresh DB). **`timeKey = 0` ⇔ slot empty**; `isUsed(cat,idx)` @`0x1006DCA0` = `isValid && getItem(cat,idx).timeKey != 0` — the used-test behind every existence check (§3) and the load UI.

`timeKey` codec (both 44–68 B, decompiled): `time2key(SYSTEMTIME&)` @`0x1006CBE0` = `FileTimeToDosDateTime` → `(dosDate<<16)|dosTime` (FAT stamp: 2-second resolution, 1980–2107 range); `key2time(SYSTEMTIME&,u32)` @`0x1006CBB0` inverts it. So slot metadata = **{FAT-datetime stamp, memo string}** only; the stamp is taken from the slot file's own FILETIME at save time (`saveNotify` reopens the written file, §4.3 step 9), and every `saveNotify` rewrites the whole DB file immediately.

### 5.5 Menu title text and thumbnails

`title(out, cat, idx, rnfMode, u32* keyOut)` @`0x1006E060` (1280 B, decompiled) has two render modes:
- **rnfMode=true** (layout `info.format` path): returns −1 invalid / 0 empty (`out` cleared, `*keyOut=0`) / 1 used (`*keyOut=timeKey`); placeholders `%IDX%`,`%ID3%` (idx 3-digit `'0'`-pad), `%ID2%` (2-digit), `%YYYY%` (4d), `%YY%/%MM%/%DD%/%hh%/%mm%/%ss%` (2d `'0'`-pad), literal `\\n` → newline, `%memo%` = item memo — matching `save.layout.rnf`/`load.layout.rnf` `info.format` templates (§1).
- **rnfMode=false** (C++ list path used by `nextTitle`, §3.2): delegates to a custom proc if `setTitleProc` @`0x10007580` installed one (ctrl+8); else built-in: used → cat0/1 `"YY/MM/DD hh:mm:ss "+memo`, cat2 `"MM/DD hh:mm "+memo`; empty → fallback `asc_10425674` `"--/--/-- --:--:-- "` (cat0/1) or `asc_1042569C` `"--/-- --:-- "` (cat2), return 0.

Default memo when the caller passes none: cp932 string @`0x104256AC` (bytes `83 5a 81 5b 83 75 82 b3 82 ea 82 c4 82 a2 82 dc 82 b9 82 f1`).

Thumbnails are **captured rendered frames**, not recomposed layers: `createSaveThumbnail(cat,idx,type,mode,0,memo)` @`0x1007C210` builds the `%id%` filename, appends the memo, fills `SnapShotParams{type, w=this[1454], h=this[1455], 0, mode}` and calls `snapshot` @`0x10079600` (1726 B) — which grabs the framebuffer into the `.gyu` (JPEG-in-gyu container, §1). Auto-saves take it only when `this+3944 & 8` with mode `0x509`, or `0x8509` when `this+3944 & 4` **[mode-bit semantics inferred]**; the rnf screens' `tn.*` keys (`tn.layer=851`, `tn.create=1`, `tn.file=%id%.gyu`, `tn.folder=%thumbnail\`) drive the UI-side capture/display: the menu *displays* the stored `.gyu` on layer 851, the save *creates* it at capture time.

### 5.6 Deletion, copy, iteration

`remove(cat,idx)` @`0x1006E560` (34 B) and `clearItem(cat,idx)` @`0x1006DE60` (272 B) clear the in-memory item (timeKey→0); `copy(cat,idx,cat2,idx2)` @`0x1006E7E0` clones an item (used by slot-shifting UIs **[callers not traced]**). Enumeration for the menus = `initTitleIterator`/`nextTitle`/`isValid`/`title` chain (§3.2); `getLatest`/`getOldest` @`0x1006CE20`/`0x1006D110`/`0x1006D310` find newest/oldest used slot per category (continue-game logic). No script opcode deletes or copies slots — all mutation is UI/engine-internal.

## 6. RNG and replay

### 6.1 The gameplay RNG: `FCRandom` (not MT19937)

The engine's gameplay RNG is a `FCRandom` object **embedded at `UxAdvSystem+0x1248`** (vftable `??_7FCRandom@@6B@`; constructed inside the `UxAdvSystem` ctors, e.g. `lea ecx,[esi+1248h]` @`0x10095506`). Object layout (all members observed in decompilation):

```
+0   vtable
+4   u32 seed          (caller-supplied init value)
+8   u32 counter       (LCG state; re-seeded from GetTickCount at init)
+12  u32 table[32]     (32-word scratch table)
```

- **Init** `sub_10234B60(this, seed)` (54 B, decompiled): `+4 = seed; +8 = GetTickCount();` then fills all 32 table words by iterating `sub_10234A90`.
- **Step** `sub_10234A90(this)` (16 B): `counter = 1566083941 * counter + 1; return counter;` — multiplier `0x5D588B65` is MT19937's *init_by_array* constant reused as a plain LCG.
- **Draw** `sub_10234AA0(n)` (72 B): `v = step(); slot = v >> 27` (0..31); `out = bitreverse32(table[slot]); table[slot] = v; return out % (n+1);` — each draw consumes exactly one counter step and rewrites exactly one table word.
- **Public API**: `random(uint n)` @`0x10009280` = `add ecx,1248h; jmp sub_10234AA0(n-1)` → uniform `[0,n)`; `random(int lo,int hi)` @`0x100092A0` → `lo + sub_10234AA0(hi-lo)` → `[lo,hi]`. This **confirms and completes the VM spec §11.4 errata** (`sub_10234A90`/`sub_10234AA0` = the bounded-draw mutators).

⚠️ Do **not** confuse this with `exhibit_mt19937.h` in the port: that models the **original-1997 sgenrand (69069) MT used for `.rld`/keytable decryption** — a different generator, different state, different purpose. `FCRandom` is 34 words total, has no 624-word state and no MT twist.

Separate effect-only statics (also never persisted): `UxStaticRandom s_rnd@AsyncFireflyObject` @`0x10515960`, `s_rnd@TmAsyncFireflyObject` @`0x10511EB0`, `m_rnd@TmAsyncHandycam` @`0x10513240` (firefly/handycam particle jitter).

### 6.2 Persistence answer: **no RNG state is saved or restored — anywhere**

Evidence (all [M] unless noted):
1. **Complete record inventory** of a slot file (§5.3): magic/reserved/identity header, character-manager records, two bank records, two name strings, `sub_102D0CC0`'s `{u32(reg+92≠0), u32(reg+148&1), name string @reg+1944}` (registry members — none is `+0x1248`), optional jump history. No RNG record exists in the stream.
2. **system.dat** = single `FCReg` "FCReg" record = S bank only (§1.1 measured, writer decompiled).
3. **Full-image scan for displacement `0x1248`** (byte pattern `48 12 00 00` over the whole loaded image): hits only in `UxAdvSystem` ctor/dtor, the two `random()` thunks, `cmdCtrlFireworks` ×2, `cmdInitFireworks` ×2, and `exceptionEntry`. **Zero hits in `saveEngine`, `loadEngine`, the bank serializers, RSDC, or any DB/thumbnail path.**
4. Cross-references to `sub_10234AA0` likewise never enter a save/load function — with one notable exception: `sub_100A6490` (quickLoad's pre-load prep) *draws* from it, i.e. **the vendor's own load path advances the RNG**, so even a hypothetical RNG-carrying save could not produce a bit-identical post-load stream.

Load restores: R/T banks, character manager, jump history, `postLoadEngine` — and leaves `FCRandom` exactly where the current session's draws put it (seeded from `GetTickCount` at process construction; `seed` member's runtime source not traced **[inferred]**).

### 6.3 Consequences for the port

- **Replay after load diverges by design.** Any script logic depending on `random()` outcomes (fireworks choreography, `exceptionEntry` jitter) is intentionally non-reproducible across save/load; a faithful interpreter must **not** try to persist or restore RNG state to match vendor behavior.
- If intra-session reproducibility is wanted (tooling, TAS-style debugging), implement `FCRandom` verbatim: LCG `x = 0x5D588B65*x + 1`, slot `= x >> 27`, output `= bitreverse32(table[slot]) % (n+1)`, write-back `table[slot] = x`. Draw-count accounting is exact: 1 step + 1 table write per bounded draw.
- Save-format writers must not emit an RNG record (it would break `checkSaveData`-compatible parsing of vendor files and vice versa); readers must tolerate none.
- The `.rld` cipher MT (`exhibit_mt19937.h`) is orthogonal: it is re-seeded per decryption, is stateless across saves, and needs no persistence either.

## 7. System settings vs save data

Three **disjoint** persistence stores back the engine; only the S bank straddles "settings" and "gameplay". All EAs below are fresh-IDB (decompiles cached in `decomp_saveG/H/I.txt`).

### 7.1 Store responsibilities

| store | file | holds | written by | survives load? |
|---|---|---|---|---|
| user settings | `<USER_FOLDER>settings.dat` | named string config (window pos, screenshot template, gesture/volume/text-speed overrides) | `flushUserSettings` | **yes** — never touched by `loadEngine`; it is process-global config |
| system bank (S) | `<USER_FOLDER><CLASS>.system.dat` | 13000 int32: volumes, seen/read bitflags (via `saveReadFlag`), autosave cursor `S[7]`, capacity mirrors `S[189..192]` | `flushSysreg`/`sub_10238680` (also every `saveEngine`, §4.3) | **yes** — a slot load does *not* roll back seen-flags or volumes (correct galge semantics: "seen" stays seen) |
| story state | slot files `u#/a#/q#/s#` | R bank (`FCReg`) + T bank (`FCStrReg`) + scenario path + engine flags | `saveEngine` | **restored** by `loadEngine` (§4.3) |

### 7.2 settings.dat — location, format, API (all decompiled)

- **Location** `createUserSettings()` @`0x10074C20`: `getFolder(10, out, …)` then append `"settings.dat"` (literal @VA `0x10426914`, xref `0x10074C82` inside this function) → `sub_10256030(path)`. **Folder id 10 = the user folder**: `getFolder` @`0x10071C80` (decompiled switch) returns, for id 10, the string at `UxAdvSystem+720 → +16988` if set, else the built-in default `"user\\"`. `ExHIBIT.ini`'s `USER_FOLDER=userdata\` overrides that member → the measured `userdata\settings.dat`. (Other folder ids, for reference: 0=`rld\`, 1=`res\`, 2=`res\g\`, 3=`res\g\ev\` (+CG subdir `Value/100`), 4=`res\g\sy\`, 5=`res\g\ch\`, 6=`res\g\gn\m\`, 7=`res\s\`, 8=`res\s\e\`, 9=`res\s\m\`.)
- **Format** `sub_10256030` (create/upgrade worker, decompiled): if the file exists, read its first line, split on `"="` (trim set `" \t"`), and require the header key **`rnftype=1`**; then walk the `FCIdString` list at store`+8` and substitute `%<id>%` placeholders in values with current table values (`sub_101C2BB0` = string replace). → **settings.dat = plaintext `key=value` lines, first line `rnftype=1`, values may embed `%id%` placeholders resolved at create/upgrade time.**
- **Write** `saveUserSettings(name, value)` @`0x10074CE0`/`D00`/`D20` (three overloads: `(c*,int)`, `(c*,uint)`, `(c*,c*,uint)`) → `sub_10255040(name, value, -1)` updates the in-memory `FCIdString` store. `flushUserSettings()` @`0x10074CD0` → `sub_10254B30(NULL, 0)`: renders the whole store into a 64 KB string (`sub_10254330`) and rewrites the file wholesale; **if the render is empty and the file exists, it deletes the file** (decompiled branch).
- **Read** `loadUserSettings(FCString& out, key, def, bool, uint)` @`0x10074E50` → `sub_10255D10` key lookup with optional numeric conversion (`sub_101C2FB0`); the `(int&,…)`/`(uint&,…)` overloads @`0x10074DF0`/`0x10074E20` write straight into an int. **Q5 in the VM (§11.5) = `loadUserSettings("expression", …)`** — reads a named key from this store, which is why settings.dat is the S-bank-independent config surface.

### 7.3 settings.user.rnf A-codes = boot-time overrides into the store

`settings.user.rnf` lines (`A306`–`A312`, `A330`, `A273`, `A158`, `F0`/`F2`, decoded in §1) are **name/value overrides injected into the settings store at boot**; their values mirror specific S-bank cells (measured match: `A312=1500`↔`S[13]`, `A306–A311`↔`S[17..22]`, `A330=224`↔`S[24]`, §2.3). So the same logical setting lives both as a named string (settings.dat, user-editable) and as an int32 S cell (system.dat, engine fast-path) — the port must keep the two in sync at boot exactly as the vendor does (rnf → store → S cell).

### 7.4 qc01.dat / qc02.dat are NOT settings or save data

Correcting an earlier inference (§1 row 4): the `qc01.dat`/`qc02.dat` literals (@VA `0x104268F4`/`0x104268E8`, xrefs `0x100741EC`/`0x10074208`) both live inside **`checkVirtualDrive` @`0x10074110`** (decompiled): it opens `<CD-drive>:\qc01.dat` and `qc02.dat` and runs a 4 MB read-timing loop, comparing elapsed `GetTickCount` against **800 ms** to flag a fast/virtual drive (result stored at `this+12`). These are **drive-speed probe files read from the game disc**, never written, never part of persistence — excluded from the save system.

### 7.5 Untraced

`DisableSystemSaveRlds=` (empty in the measured ini): no gate observed on any decompiled save/flush path — the flag consumer was not located (§10).

## 8. Worked examples

Byte values little-endian; offsets in hex. Cross-refs: record grammar §1.1/§5.3, chains §4.3, names §5.2.

### Example A — `userdata\imopara3.system.dat`, byte anatomy (measured, exact 52022 B)

```
off      bytes                     field
0x0000   ff ff ff 7f               magic  0x7FFFFFFF
0x0004   00 00 00 00               flags  0
0x0008   06 00 00 00               tagLen 6 (incl NUL)
0x000C   46 43 52 65 67 00         tag    "FCReg\0"
0x0012   c8 32 00 00               count  13000
0x0016   <13000 × int32>           S-bank cells (52000 B)
         0x16 + 52000 = 52022 ✓    (no trailing bytes, no checksum)
```
Cell callouts (measured): `S[0]=0` (dirty/flush flag, cleared by `flushSysreg`), `S[7]` = autosave round-robin cursor, `S[13]=1500`, `S[17..22]`=gesture timings, `S[24]=224`, `S[31]=0x00660066`, `S[32..]`=0x00800080 volume pairs, `S[189..192]`=9999/400/100/1500 (CG/scene/sound/text-speed capacity mirrors), `S[473..6459]`=per-50 seen-flag blocks, `S[10692..11500]`=809-word read bitmasks (`-1`×352 = all-experienced), written via `saveReadFlag` (§2.6).

### Example B — user slot save `saveEngine(0, 5, "メモ")`

1. `R[4] = (R[4] & 0xFFF000FF) | 0x200`; set bit23 (`0x800000`) iff jump-history enabled.
2. `RetouchCharacterManager::save(this+2624)`.
3. `createSaveFilename` → `<folder>u5` (**no padding**, §5.2).
4. `CreateFile(u5, GENERIC_READ|WRITE 0xC0000000, CREATE_ALWAYS)`.
5. Header (28 B): `00 80 00 00 | 00 00 00 00 | key(+56) | id0 id1 id2 id3(+60..+72)`.
6. `sub_1023BB20`: **R-bank record** `ff ff ff 7f|00 00 00 00|06 00 00 00|"FCReg\0"|00 08 00 00 (count=2048)|2048×i32`; **T-bank record** `…"FCStrReg\0"|<strings>`; **2 string records**; `sub_102D0CC0` = `u32(reg+92≠0)|u32(reg+148&1)|string@reg+1944`; then **`sub_10238680` rewrites `imopara3.system.dat`** (every slot save also flushes the S bank).
7. If `R[4]` bit23: `saveJumpHistory(file)` (`u32 count | u32 52 | count×64 B`).
8. `SetEndOfFile` (truncate stale tail), close.
9. cat≠3 → reopen read-only, take FILETIME → `saveNotify(0, 5, ft, "メモ")` → `udb` item[5] = `{time2key(ft), "メモ"}`, `saveDB(0)` rewrites all 108 `udb` entries.
10. Thumbnail `U00005.gyu` (**5-digit pad**, §5.2) written separately by `createSaveThumbnail`→`snapshot` (framebuffer grab).

### Example C — VM op12 autosave (`AutoSaveParams{type=186}`)

`liteExec` op12 (`reg(3)==pc` → skip) → `autoSave(params)`: `slot = S[7]` (say 3, clamped `<numberOfAsave=9`); if `this+3944 & 8` → `createSaveThumbnail(1, 3, 186, this+3944&4 ? 0x8509 : 0x509, 0, memo)`; `saveEngine(1, 3, memo)` → file `a3` + `adb` item; then `S[7] = (3+1)%9 = 4` and **`flushSysreg()`** → `S[0]=0` + `sub_10238680` rewrites `system.dat` (52022 B). The cursor `S[7]` persists, so autosaves round-robin across reboots.

### Example D — load rejection (build mismatch)

`loadEngine(0, 5)`: open `u5` read-only → read word0. `0x8000` → read word1(0), `key`, `id[4]` → **`checkSaveData`**: `key == this+56` and (key≠0) `id[0..3] == this+60..+72`? Mismatch → modal **"system warning"** (caption @VA `0x10426C74`, cp932 body @VA `0x10426C88` = "ロードしようとしたデータは…"), **no state touched**, return 0. UI prints `OutputDebugStringA("invalid save data.")` and stays in the dialog. Missing file → `no save.` @VA `0x1042D490`.

### Example E — `flushSysreg()` byte path

`flushSysreg()` @`0x10072C80` → `sub_1023BCF0(0, 0, 1)`: `*FCReg::item(S-bank@this+4161*4, 0) = 0` (S[0]=0; out-of-range index would hit the `"FCReg - item()"` MessageBox + cell-0 clamp = `bank_error`), then `sub_10238680()`: build path via `sub_10238580` = `[prefix] + <CLASS> + ".system.dat"` → `CreateFile(CREATE_ALWAYS)` → FCReg vtbl[1] serializer emits `ff ff ff 7f|00 00 00 00|06 00 00 00|"FCReg\0"|c8 32 00 00|13000 cells` → close = the exact 52022-byte file of Example A.

## 9. Recommended C++ design (`aetherkiri::exhibit::save`)

Design goal: byte-faithful reader/writer of vendor files + behavioral parity, driven by the same hooks the VM core already exposes (`RegHooks`). Components map 1:1 to the decompiled vendor classes.

### 9.1 Components

| component | mirrors | responsibility |
|---|---|---|
| `RecordStream` | `FCFile`/`FCSaveData` (`sub_101BE970`/`sub_101C2980`) | envelope `u32 0x7FFFFFFF \| u32 flags \| u32 len \| payload[len]`; `writeRecord/readRecord(tag)`; string records (`len=strlen+1`) with **legacy fallback** (first dword ≠ magic ⇒ plain u32 length); raw `u32`/bytes; retry-then-throw IO |
| `RegBank` (int32) | `FCReg` (`sub_1025FA40`/`FAE0`) | `vector<int32>`; serialize = `count + cells`; **deserialize = whole-replace, resize to file `count`** (§2.5) |
| `StrRegBank` | `FCStrReg` (`sub_101F6D40`/`E00`) | string array; per-string framing (decode gap §10) |
| `SystemDatStore` | `sub_10238580`/`sub_10238680` | path `USER_FOLDER/<CLASS>.system.dat`; `load()`/`commit()` (full `CREATE_ALWAYS` rewrite); `S[0]` = dirty flag |
| `SlotDb` | `saveDB`/`loadDB`/`createDB` | per-cat `vector<Item{uint32 timeKey; string memo}>`; `<u\|a\|q>db` fixed-count IO (no header); `time2key`/`key2time` = FAT codec (2-s resolution); `isUsed = timeKey!=0` |
| `SlotFile` | `saveEngine`/`loadEngine` int-overloads | header `{0x8000,0,key,id[4]}` + charmgr + R + T + 2 strings + `{u32,u32,string}` + optional jump history; `checkSaveData` fingerprint gate |
| `SaveControl` | `RetouchSaveDataControl` | `create(base,nU,nA,nQ)`; `isValid` (cat3 always true); `createSaveFilename` = `{u,a,q,s}[cat] + ltoa(idx)` **no pad**; `isSaveFilename` parser (canonical `ltoa` match); `remove/clearItem/copy`; `saveNotify`; `getLatest/getOldest`; `initTitleIterator/nextTitle/title` |
| `ExistsProbe` | `isExistSaveData` | `mask` bit0=user/bit4=auto/bit8=quick → any-used-slot in that cat's `SlotDb` |
| `AutoSave` | `autoSave(AutoSaveParams&)` | `S[7]` round-robin cursor mod `numberOfAsave`; thumbnail; `flushSysreg()` after advance |
| `SettingsStore` | `sub_1025xxxx` settings cluster | `key=value` text, `rnftype=1` header, `%id%` substitution, whole-file flush, delete-if-empty; feeds Q5 |
| `FCRandom` | `sub_10234A90/AA0/B60` | LCG `x=0x5D588B65*x+1`, slot `x>>27`, out `bitreverse32(table[slot])%(n+1)`, writeback; seeded `GetTickCount`; **never serialized** (§6) |
| `LoadFlow` | `execLoad`/`LoadException` | deferred load = set flag + throw-equivalent (a `pending_load` enum consumed by the main loop); VM op23/24 marker `[+0x8B24]=-1`; `exitLoadMode(350)` |

### 9.2 RegHooks feed (mandated mapping)

| RegHooks member | fed by | vendor evidence |
|---|---|---|
| **`bank_error`** | out-of-range R/S/T cell access → clamp to cell 0 + diagnostic | `FCReg::item()` `sub_1025F910`: in-range → `cells+4*idx`; else `"FCReg - item()"` MessageBox + returns base ptr (cell-0 clamp) |
| **`sreg_notify`** | every S-bank write (VM op8) **and the flush bit** → `SystemDatStore::commit()`; also `saveReadFlag`'s per-word `sregSetEngine(base+i,word,flush=1)` and `autoSave`'s `S[7]` advance | `flushSysreg`→`sub_1023BCF0`; `sub_10238680` rewrite; §2.4/§2.6 |
| **`runtime_error`** | fatal file IO — `RecordStream` raw write/read throws `CannotWrite`/`CannotRead` after the retry MessageBox is abandoned | `sub_101E8690`/`sub_101E8430` (decompiled): retry loop → `CxxThrowException` |
| **`manager_query`** | read/seen-flag bitmap lookups (S cells via `saveReadFlag` base) and slot-count queries (`numberOfUsave/Asave/Qsave`) | §2.6 read-flag mirror; `0x1006CB80/90/A0` |
| **`system_query`** | **Q0/Q1** = `isExistSaveData(mask)`; **Q5** = `loadUserSettings("expression")`; other Q-cases per VM spec §11.5 | §3 bitmask; §7.2 settings read |

Note: the "system warning" build-mismatch refusal (`checkSaveData`) is **not** a `runtime_error` — it is a benign, state-preserving rejection surfaced to the UI (§4.4); the port should model it as a load-result code, config-relaxable, not a fatal hook.

### 9.3 Fidelity rules

- Writers must reproduce the exact envelope and header (`0x8000` version word, 28-byte header) so vendor files round-trip; readers must accept legacy word0==0 and the non-magic string fallback.
- Slot filenames are **unpadded** (`u5`, not `u005`); thumbnails are **5-digit padded** (`U00005.gyu`) — do not conflate.
- Do **not** emit or expect an RNG record (§6). Do **not** roll back S-bank seen-flags/volumes on load (§7.1).
- `checkSaveData` binds a save to the engine build fingerprint (`key`+`id[4]` at `+56..+72`); the port replays its own fingerprint and keeps the same gate (relaxable by config).

## 10. Risk register

Sections 1–9 complete. This register triages every gap/inferred item into **RESOLVED** (with resolving evidence) or **OPEN** (residual port risk).

### 10.1 Retired risk: the export-table VA bug

The largest early risk is **retired**. A raw PE export-table parse mis-paired decorated names with VAs; every "export-parse" VA in the working notes is **deprecated**. The fresh-IDB auto-applied export/PDB names agree with all three call-site-verified bodies (`0x10073CB0` isExistSaveData, `0x10073310` execLoad, `0x10074E50` loadUserSettings) and are the sole authority (header note; `save_names2.txt`). Concrete deprecations (wrong VA → real): `0x100202D0`→flushSysreg is `0x10072C80` (`0x100202D0`=TmAsyncFireworks::flushSeq); `0x101A8320`→systemSave is `0x1008DC90` (`0x101A8320`=RetouchSystem::systemMenu); `0x1013E020`→saveLfp is `0x1018D4E0` (`0x1013E020`=saveLayer); `0x10083CF0`→createSaveFilename `0x1006D520`; `0x1017AF70`→createDBFilename `0x1006D5B0`; `0x1018DB40`→loadDB `0x1006D880`; `0x10157410`=quickLoad (quickSave is `0x100D5490`); `0x1006C570`→save@RetouchSystem `0x101A40C0`; `0x1004EE30`→getSaveDataVersion `0x100737E0`.

### 10.2 RESOLVED

| # | item | resolution | where |
|---|---|---|---|
| 1 | slot naming + record layout | `createSaveFilename` = `{u,a,q,s}+ltoa(idx)` **no pad**; full slot layout decoded | §5.2/§5.3 |
| 2 | `title()` used-test | two render modes; returns −1/0/1; `isUsed = timeKey!=0` | §5.4/§5.5 |
| 3 | RSDC table population | `loadDB`@`0x1006D880` at `create()`; `createDB` = load-or-(init+saveDB) | §5.1/§5.4 |
| 4 | qc01/qc02.dat | `checkVirtualDrive`@`0x10074110` CD read-speed probe (800 ms) — **not** persistence | §7.4 |
| 5 | settings.dat schema | `rnftype=1` header + `key=value` lines + `%id%` substitution | §7.2 |
| 8 | system.dat word@0x04; getSaveDataVersion | word@0x04 = flags (0 on write); `getSaveDataVersion` = `(u16)(R[4]>>8)` (the "global 0x10516CF8" claim came from a deprecated VA) | §1.1/§4.3 |
| 10 | DB filenames | `udb`/`adb`/`qdb` (measured bytes @`0x10425668`); "data.txt" was an export-era guess — deprecated | §5.2 |
| 12 | RNG persistence | LCG+32-table `FCRandom`@`UxAdvSystem+0x1248`, GetTickCount seed, **never persisted**; full-image `0x1248` displacement scan | §6 |

### 10.3 OPEN (residual port risk)

| # | item | risk | note |
|---|---|---|---|
| 6 | `backlog2.data.` format undecoded | low | cmdDefLog backlog store; outside core save/load |
| 7 | `.lfp` payload undecoded | med | `saveLfp`@`0x1018D4E0`/`loadLfp`@`0x1018D8B0` named; internal format not reversed |
| 9 | truncated system.dat tail cells | low | deserializer resizes to file `count`; tail-cell content past EOF unobserved (allocator-dependent) |
| 11 | LOC bank (`N_LOCREG=100`) persistence | med | not in system.dat (S-only); whether it rides in the slot blob's R/T or engine state is untraced |
| 13 | per-category counts + ini→`create()` wiring | med | rnf shows a shared 108-id UI space (u0–89/a90–98/q99–107) while `create()` takes separate counts; `N_USAVE=108` vs 90 user slots and the UI→engine index-conversion glue are **inferred**, not decompiled (§5.1) |
| N1 | no on-disk slot/DB sample | med | `userdata\` held only `system.dat`; §5.3/§5.4 layouts are decompiled-only, not byte-verified against a real slot file |
| N2 | `FCStrReg` (T bank) per-string framing | med | T payload structure not decoded → blocks a byte-faithful T writer |
| N3 | `RetouchCharacterManager::save/load` record | med | 53 B each; the bytes they contribute to the slot file are not decoded (§5.3) |
| N4 | engine-blob string #2 + identity fingerprint source | low | string #1 = scenario path (inferred); string #2 unknown; `this+56..+72` fingerprint init not traced |
| N5 | jump-history `52` vs 64-B stride | low | `saveJumpHistory` writes `count, 52, count×64B`; the `52` constant's role is unclear |
| N6 | `DisableSystemSaveRlds=` gate | low | ini flag present but empty; consumer not located (§7.5) |
| N7 | concurrent authorship | info | two IDA instances (`2ec70db4de41`, `c5c73c78b37d`) analyzed the same image; merged via non-clobbering edits; the header provenance note is the VA authority |

### 10.4 Supplementary open items (final-run triage; continues the N-numbering)

Entries for inline §1–§9 flags not yet carried in §10.2/§10.3. This pass also **settled the §1-row-6 padding contradiction**: formatter `sub_101BFA50` @`0x101BFA50` decompiled in full — `width==0 ⇒ append _ltoa as-is` (no pad), `width<len ⇒ keep last width chars`, `width>len ⇒ left-pad`; slot names are unpadded (`u5`), thumbnails 5-pad (`U00005`); `isSaveFilename` enforces the same canonical form via `lstrcmpA`. Evidence: `decomp_save_fmt.txt`; §1 row 6 corrected in place.

| # | item | risk | note |
|---|---|---|---|
| N8 | INTDB (`op61–63`) on-disk backing untraced | **high** | `getDB/setDB/createDB@RetouchSystem` (`0x1017AF70` family) unread; **op62 is corpus-active ×7** (`"2,R1293,0,1297,-1,…"`) — the port must know whether the 8×i32 `(dbId,key)` records survive a session or `getDB` always fails cold (dest regs untouched — the decompiled guard, §4.2). Resolution: decompile the three + xref the storage member |
| N9 | UI action-callback chain unread | med | rnf item actions 52/54/55 → `createSaveTitleCallback` @`0x100F7180`, `save@RetouchSystem` @`0x101A40C0`, `load@RetouchSystem` @`0x101A52B0` (PDB-named only). The slot-id→per-category-idx conversion (row 13) lives inside this chain |
| N10 | exception control flow inferred | med | `execLoad` throws `LoadException` @`0x10073310`; VM-loop catcher unlocated; `FCFile` IO throws after retry dialogs (`sub_101E8690`/`sub_101E8430`). Port substitutes a `pending_load` result code (§9.1) — behavioral parity untested |
| N11 | bank record order (registry `+24` = R vs `+36` = T) inferred | med | write order = vtbl call order in `sub_1023BB20`; a flip breaks vendor-file compatibility both directions. Resolution: vftable identification via the registry ctor |
| N12 | save-folder member (RSDC ctrl+12) setter untraced | low-med | inferred = ini `USER_FOLDER`; both slot and DB filenames derive from it (§5.2) |
| N13 | thumbnail mode bits + snapshot type semantics inferred | low | `0x509`/`0x8509` gated by `this+3944` bits 3/2; `type=186` from op12's `AutoSaveParams` (§4.4/§5.5) — cosmetic impact |
| N14 | `FCRandom` `seed` member source untraced | low | counter seeds from `GetTickCount` (`sub_10234B60` decompiled); `+4 seed` writer unknown; no persistence impact (§6) |
| N15 | `op211` load-mask application site untraced | low | table `this[8907..8909+2n]`; consumer (T-reg remap at load) inferred; corpus ×0 |
| N16 | legacy `magic==0` slot header | low | reader accepts only while `this+56==0`; no observed writer emits it (§4.3) — keep as reader branch (§9.3) |
| N17 | system.dat optional name prefix (`registry+4248`) | low | non-empty case unobserved; measured file carries no prefix (§4.3, Example E) |

**Closure.** With §10.4 merged, every inline `[inferred]`/`(§10)` flag in §1–§9 maps to an N-entry; the document is complete. Highest-value next step remains N1's acceptance test (capture one real vendor save), which simultaneously bounds N2/N3/N5/N8/N11.
