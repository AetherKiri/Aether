# Phase3 Chinese extra/CODA: actual visual review

**Outcome: UTF-8/data and chapter progression checks PASS; Chinese body-font visual acceptance FAIL/OPEN.** All supplied29PNG images were actually reviewed through6contactsheetpages,with3original1280×720sourcesexpanded. Visiblemissing-glyphsquares are confirmed in bothbonus and CODA bodytext. CorrectJSON/overlayencodingandreportedfontcoveragecannotreplaceactualpixelacceptance. Noengine/build/gameexecutionorproductioneditwasperformed.

## Actual coverage

Generatedallimageswith [genericcontactsheetgenerator](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase2-sheets.py>) (image-onlyPython),withoutmaxsampling/deduplication.

| Set | Available/reviewed PNG | Sheets read | Index |
|---|---:|---:|---|
|Extra5000|9/9|2/2(6+3)|[index](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase3-sheets/extra/index.json>)|
|CODA3013|20/20|4/4(6+6+6+2)|[index](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase3-sheets/coda/index.json>)|
|**Total**|**29/29**|**6/6**|Allactualread_image|

| Sheet opened | Actual observations |
|---|---|
|[extra01](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase3-sheets/extra/sheet-01.png>)|Startupblack0ticks;rain/classroombackgrounds;frame250Chineseparagraphvisiblewithmultiplemissing-glyphsquares.|
|[extra02](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase3-sheets/extra/sheet-02.png>)|Classroomfadeandnight-skyframes;final350duplicatescurrentstoryframe.Noending/title.|
|[coda01](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase3-sheets/coda/sheet-01.png>)|Apartment/office/streetcharactersrecognisable;choice1bodyhasmissing-glyphsquareswhileChineseoptionsarelegible.|
|[coda02](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase3-sheets/coda/sheet-02.png>)|Choice1/2before/holdpairs;bodytofuconfirmed;optionlabelsarecompleteChinese.Music-room/night-streetimagespresent.|
|[coda03](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase3-sheets/coda/sheet-03.png>)|Station,piano/phone/music-roomSKIPtransitions;choice3Chineseoptionsand春希/「…」clear.|
|[coda04](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase3-sheets/coda/sheet-04.png>)|Choice3holdandpost-choicecheckpoint;storycontinues,noending/title.|

Initialblackframeandwhite/dark/blendedstoryframesareexplicitstartup/SKIPtransitioncaptures,notpersistentblankevidence. Noadditionalpersistentblank,rawcontrolmarkuporparagraph/optionoverflowwasobserved,butmanynonchoiceframeshavedim/emptytextduringSKIPanddonotcertifysettledbodytext.

## OPEN V1 — Chinese body text renders missing-glyph squares

Thefollowingoriginal1280×720PNGs wereactuallyopenedafterthesheetreview,so thedefectisnotcontactsheetresizing.

| Original source + JSON | Correct pageText from JSON | Pixel result |
|---|---|---|
|[CODAchoice1selectPNG](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase3-cn-coda/choice-0001-select-before.png>) / [JSON](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase3-cn-coda/choice-0001-select-before.json>)|不单单是雪菜，<br>连和纱的信赖都要剥夺吗，我…|Visible不□□是雪菜 and □和□的信□都要剥□□，我…;multiplebodyglyphsareemptyboxfallbacks.|
|[CODAchoice2selectPNG](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase3-cn-coda/choice-0002-select-before.png>) / [JSON](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase3-cn-coda/choice-0002-select-before.json>)|现在，只是看着的话，我…|现 and 话 positionsshowboxes(plusfadingpreviousbody).CurrenttextisnotfullyreadableChinese.|
|[Extraframe250PNG](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase3-cn-extra/frame-00000250.png>) / [JSON](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase3-cn-extra/frame-00000250.json>)|窗边整列桌子如同多米诺骨牌一般倒下的瞬间所发出的巨大声响，万幸没有传到走廊上北原的耳中。|边/诺/间/发/传positionsshowemptyboxfallbacks.Thesentencewrapsintwovisiblelinesbutcharactersaremissing.|

Choice1options **１．回去 /２．看着和纱的睡脸** renderasrecognisableChinese;choice2options **１．想要，一直留在这里 /２．想要抱紧她** arealsolegible.Thebodytextvisuallyusesadifferentlargeroutlinedstylefromthechoices. This indicates an activebodyglyph/rasterpathproblemisplausible,butthisreviewdidnotdiagnosetheimplementation. Itmustnotbeclaimedthatallfontpathsworkbecauseonefontcmapcovers3720characters.

ThetaskcontextreportsfullUTF8overlaysfor183scriptsandNotoSerifCJKscglyphcoverage3720/3720. Theseareparent-supplieddataset/fontauditfacts,not independentlyrerunhere. JSONtextEncoding=utf-8,textSource=patch-overlay,patchOverlay=trueareindependentlyconfirmedintheactualsnapshots. TheirUnicode stringsdonotcontainreplacementcharacters,butthePNGsdo containmissing-glyphsquares. Thus dataencodingPASS doesnotimplyglyphrenderPASS. Parentwasnotifiedimmediatelywithsources/PCs,andV1remainsOPENpendingcorrectedactualPNGs.

## Runtime/data results and strict chapter limits

| Check | Extra | CODA |
|---|---|---|
|Entry|Direct5000freshisolatedprofile|Direct3013freshisolatedprofile|
|Final|story5003/PC23692|story3013/PC254732|
|Frames/logicTicks|350/350|1261/1261|
|commandsDispatched|1173|4571|
|plan|0/0|3/3|
|Reportchecks|5/5PASS|8/8PASS|
|Textencodingcheck|ActualUTF8verifiedon692body/choiceticks(asdriverreports)|ActualUTF8verifiedon2494body/choiceticks(asdriverreports)|
|Overlay|on,lookups278/hits12|on,lookups575/hits3|
|Error/scriptError/providerError/failure|empty|empty|
|audioSilent/finalpendingAudio|true/[]|true/[]|

Read [extra report](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase3-cn-extra/report.json>) and [CODAreport](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase3-cn-coda/report.json>). Extra350ticksisasmoketraverse5000→5001→5002→5003,notafullbonusending5004. CODA3013stopsafter3rdchoice,notanearnedCodaending. NoGoTitle/endingflagclaimismade.

CODAplanusesgroups0/1/2rawrow1. Before/heldchoicepairPCs103296,109828,250824andframes502→506,542→546,1257→1261retainpendingchoice;driverreportrecords3rawrow1acceptedand3/3complete. ChinesechoiceJSONstringsmatchtheactuallegibleoptionlabels. Finalchoicescleared;state remainsstory/wait-frames. No save/load,earnedprofile,fullending,audiblemovieorGPUviewportparityclaim.

Logsearchesof [extraruntime.log](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase3-cn-extra/runtime.log>) (850lines) and [CODAruntime.log](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase3-cn-coda/runtime.log>) (1372lines) foundzeroMISS/ERROR/exception/WARNING/loadfailedmatches. Thiswas a whole-filesearch,notaclaimthateveryloglinewasmanuallyread. CaptureSourceengineRGBA/renderBackendDebugCPU andsilentmodeboundvisualverificationtoCPUcompositorpixelsunderGodotprovider,noton-screenVulkanoraudibleplayback.

## Disposition

- PASS:29/29imagesactuallyread;UTF8Chineseoverlaystringsverified;chapterprogressionand3CODArawchoicesclean;nocontrolmarkuporoverflowobservedinsamples.
- **OPEN/BLOCKER:** actualChineseBODYglyphsrenderasemptyboxesinbothsets despitecorrectJSONandlegiblechoicefont. NewactualcapturesafterfontpathfixmustbereviewedbeforeclosingPhase3visualacceptance.
- Scope:directchapters only,noending/title/earnedfullsave/audiblemovieparityclaims.

## Follow-up — V1 CLOSED after actual body-font fix and full corrected review

The preceding OPEN findings describe the original output. Parent identified a separate Wa2MessageBox-owned Wa2TextRenderer that still used MSGothic while choice rendering used Noto; parent commit1e04066 selects the Chinese font for both renderers. That implementation diagnosis is parent-provided; this reviewer independently verifies the corrected pixels below. Original failure contact sheets remain under [old extra sheet01](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase3-sheets/extra/sheet-01.png>) and [old CODA sheet02](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase3-sheets/coda/sheet-02.png>). Source capture directories were rerun by the parent,so original source links above now resolve to corrected images; the preserved original contact sheets and recorded image hashes in the session are the historical pixel evidence.

Generated new sheets without overwriting old sheets and **actually opened every corrected page/29tiles again with read_image**:

- Extra9/9: [v2page1](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase3-sheets-v2/extra/sheet-01.png>), [v2page2](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase3-sheets-v2/extra/sheet-02.png>); [index](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase3-sheets-v2/extra/index.json>).
- CODA20/20: [v2page1](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase3-sheets-v2/coda/sheet-01.png>), [v2page2](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase3-sheets-v2/coda/sheet-02.png>), [v2page3](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase3-sheets-v2/coda/sheet-03.png>), [v2page4](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase3-sheets-v2/coda/sheet-04.png>); [index](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase3-sheets-v2/coda/index.json>).

The same three problem original1280×720PNGs were additionally reopened and compared against their current JSON text:

| Corrected original | Exact body comparison | Result |
|---|---|---|
|[CODAchoice1select](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase3-cn-coda/choice-0001-select-before.png>)|不单单是雪菜， /连和纱的信赖都要剥夺吗，我…|All formerly missing单/连/纱/赖/夺/吗 glyphs now readable; no squares. PNGSHA256d1ba1838b4ef319a794ac001f7d7ab74c42d59ca8d2b8e08b59d776bbad0cbd3.|
|[CODAchoice2select](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase3-cn-coda/choice-0002-select-before.png>)|现在，只是看着的话，我…|现/话 now present; older fading line is a SKIP transition,not a new glyph failure. PNGSHA2563495755cf9a3d1dba450d0bcb70c3cd4bb6e3e5886eaba59b7a54603609a5a21.|
|[Extraframe250](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase3-cn-extra/frame-00000250.png>)|窗边整列桌子如同多米诺骨牌一般倒下的瞬间所发出的巨大声响，万幸没有传到走廊上北原的耳中。|Previously missing边/诺/间/发/传 render correctly; entire two-line sentence agrees with JSON. PNGSHA2563ba2706c3318b5c098c354793db8e4866d3072ae070396ff4c108c8e337aa9ba.|

**V1 CLOSED / corrected scoped visual PASS.** Corrected body and choice Chinese glyphs are readable in the available fully revealed samples. No tofu/replacement-glyph square,mojibake,literalcontrolmarkup,optioncollision or body overflow was observed in the corrected29images. Text uses fixed-spaced outlined serif glyphs and remains within the message region. SKIP non-choice snapshots still have empty/fading text; this review does not invent settled glyph verification for those moments. Basic scene/character transitions remain as before and no new persistent blank is established.

Fresh reports were read and agree with the original chapter bounds: Extra5/5checksPASS,350frames,1173commands,story5003/PC23692,0/0plan; CODA8/8checksPASS,1261frames,4571commands,story3013/PC254732,3/3plan. Error/scriptError/providerError/failure remain empty. The corrected JSONs at the expanded points still say textEncoding=utf-8,textSource=patch-overlay. Choice1/2labels match visibleChinese exactly and choice history/read markers now appear separately to the right without overlap.

This closes the observed body-font blocker for these corrected direct-entry extra/CODA samples. It does not claim a complete extra5004 ending,earnedCodaending,ICfullsave,all183scriptpagesvisuallyinspected,audibleplayback,moviedecodingparity or GPUviewportpresentation. All chapter/silent/CPU scope limits above remain. Only image-processing Python was run by this reviewer; no engine/build/core/GDScript changes or game runs.
