# Phase3 Chinese Normal — completed actual Godot review

PASS for this completed route and the recorded60visual samples. Generated a new contact-sheet set retaining everyPNG, then opened all10sheets at1280×1224with read_image and inspected every tile. Expanded9sources at1280×720to check Chinese glyphs, quotes, long options, read badges, stable save/load composition and final title. No square missing-glyph placeholder, mojibake, overflowing body/option text, leaked script control text, or option/read-badge overlap was found in the inspected samples. This is sampled visual acceptance, not a proof that every line/animation in all183overlay scripts was viewed.

## Durable execution result

Read the full [report](../phase3-cn-normal/report.json), [run log](../phase3-cn-normal.log), [final snapshot](../phase3-cn-normal/final.json), all60capture JSONs, and comparison evidence. The parent collected Godot exit0; reportpass=true,34/34checks pass,9757fixed16msframes,35543commandsDispatched,15/15strict-plan entries consumed. Runtime ends attitle,script2025PC36688,flag20=1,choicePending=false,SKIP=false,waitLatch=none,error/scriptError/providerError empty. GoTitle completes17fade ticks per log.17choicesAccepted includes the extra reference/wrong answers used by the save/load test; the main ordered plan still consumes exactly15entries.

This run begins at explicit chapter2001; it does not independently establish title NEW GAME input. That is covered by the separate [Chinese smoke review](smoke.md). Save/profile options, generatedpatch path andfont path are retained in report.engineOptions. Parent identifies the tested frozen engine source asa81e2bc; this review audits outputs rather than rebuilding.

All60metadata files havecaptureSource=engineRGBA,renderBackend=DebugCPU,textEncoding=utf-8,textSource=patch-overlay,audioSilent=true. All60have empty runtime/provider/script error fields and zero pendingPLAY events. FinalpendingAudio=[];audioAcks=1096. OverlayHits78andOverlayLookups10696are recorded. The19305textEncodingChecks count health-check invocations during active body/choice states; more than one invocation can occur per driver tick, so it must not be described as19305unique ticks.

## Complete visual coverage

[New manifest](../phase3-sheets-v2/normal/index.json) maps all60images:19periodic frames,29regularchoice-labelled captures,9pending-roundtrip captures,chapter-start,movie-pendingandfinal. No source was sampled away. Regular choice labels include15first preselection views and14additional select-before views; the second choice uses the expanded roundtrip instead.

| Sheet | Global tiles | Actual inspected observations |
|---|---:|---|
| [01](../phase3-sheets-v2/normal/sheet-01.png) |1–6|2001chapter start is near-black particle frame; later street/character and movie-pending frames are crossfades.2002restaurant has complete scene figures.2003first choice has dim disabled row versus bright enabled second row, legible two-line Chinese body. Character/background remains in a transition; not presented as a stable native-reference frame.|
| [02](../phase3-sheets-v2/normal/sheet-02.png) |7–12|Night street periodic sample, then2003group1choice. Initial choice is blended; after59save-ready ticks,room/curtains/lamp/TV/guitar and both Chinese options/body are clear. Save-before/save-after/reference-load remain the same room composition; read badges stay outside cards.|
| [03](../phase3-sheets-v2/normal/sheet-03.png) |13–18|Loaded,wrong-answer and reanswer evidence retains clear room/body/option images. Immediate post-answer frames may still show old cards until another render tick; their metadata records the actual changed VM state.2004three-character office choice has clear Chinese labels and two-line body.|
| [04](../phase3-sheets-v2/normal/sheet-04.png) |19–24|2004office choice repeated before answer;2005back-office character fade then stable coat/scarf character choice. Body speaker「小春」and「…嗯？」are rendered quote characters, not missing-glyph boxes; verified at full resolution.2007apartment standing pose and next choice visible.|
| [05](../phase3-sheets-v2/normal/sheet-05.png) |25–30|2007pose fade, office three-person group, night street fades and2009choice.2009has complete three-line Chinese body and two distinct options with read annotation outside the second card. Street/coat character stage is clear in expanded view.|
| [06](../phase3-sheets-v2/normal/sheet-06.png) |31–36|2011long option pair fully fits:「这不是那么简单的事情」and「这已经是结束的事情了」; read badge has a clear gutter. Body readable over vending-machine office setting.2012pose blend and2013classroom choice/body readable; no option clipping.|
| [07](../phase3-sheets-v2/normal/sheet-07.png) |37–42|2013bar CG visible;2014apartment choice readable, phone overlay captured midfade;2015back-office uniform choice/body clear. Phone UI content is scene imagery and not used as an overlay-text translation claim.|
| [08](../phase3-sheets-v2/normal/sheet-08.png) |43–48|2016restaurant choices distinguish bright enabled first row from dark disabled second. Chinese two-line body visible.2017three-person office choice has complete labels/body and distinct expressions, suitable highlight.2018phone/character frame is a mixed transition.|
| [09](../phase3-sheets-v2/normal/sheet-09.png) |49–54|2018event/group blend with choice and two-line body;brightfade sample;2019clear night waterfront and hotel-room poses;2019three-row choice is legible over station/character fade. No full-glyph-box substitution observed.|
| [10](../phase3-sheets-v2/normal/sheet-10.png) |55–60|Expanded2019three-row choice confirms longest enabled text「那种事情，怎么能够去考虑」fits completely. Next group has disabled first row versus bright second.2022apartment fade and2023restaurant two-character sample lead to complete Chinese title menu/background/logo,with story window removed.|

## Full-resolution expansions actually opened

1. [2005choice](../phase3-cn-normal/choice-0004-select-before.png): labels「送她回去」/「目送她离去」,speaker小春 and quoted short body; small corner marks are punctuation. Second rowreadbadge at right does not overlap text.
2. [2009night choice/body](../phase3-cn-normal/choice-0006-select-before.png): complete three-line Chinese body, character and street; both options and separate badge readable.
3. [2011long choices](../phase3-cn-normal/choice-0007-select-before.png): both long Chinese labels fit cards, body readable, no badge overlap.
4. [2019three-row choice](../phase3-cn-normal/choice-0014-select-before.png): all enabled long labels complete, dim first row distinguished,body readable; underlay remains in a station/character blend.
5. [Pending save before](../phase3-cn-normal/pending-save-before.png): stable room, body「所以，我必须要回应她的这份请求。」andtwooptions「给她打电话」/「给她发短信」fully readable.
6. [Pending load after](../phase3-cn-normal/pending-load-after.png): same full composition/text as saved, independently opened.
7. [2017office highlight](../phase3-cn-normal/choice-0012-select-before.png): three distinct characters, two option rows and two complete Chinese body lines; no tofu, clipping or badge collision.
8. [2003first choice](../phase3-cn-normal/choice-0001-select-before.png): disabled/bright row distinction and body confirmed; underlying pose/background is visibly crossfading.
9. [Final title](../phase3-cn-normal/final.png): complete title/logo/menu/footer, no residual story/choice overlay.

## Pending-choice save/load and native-ready evidence

The save test parks2003PC125488group1with exact globals/page/choices. It waits59tickswithSKIPoff fornative saveReady=true, verifying that VM/global/choice checkpoint remains unchanged on each tick. It does not demand saving during a busyfade.

[Whole-frame save comparison](../phase3-cn-normal/frame-pending-save-preserves-frame-comparison.json) immediately reads3,686,400RGBAbytes before and afterSaveSlot,without a tick/input/awaitbetween. BothSHA256=4d5e00ca359a85572497cb3a32b6297a85cb459c131701a206a7e34a7fbbf102. No mutation of the captured stage by saving is observed.

[Reference-load stage comparison](../phase3-cn-normal/frame-pending-reference-load-stage-comparison.json) and [wrong-branch load comparison](../phase3-cn-normal/frame-pending-load-stage-comparison.json) both compare2,127,996bytes with identicalSHA256=42177cccf7a3cf618009655437908729afa2dd880ae06d757e7e692b6a1f0cdf. Mask excludes message windowy>=480andchoice/historyrectx330..1010,y290..410inclusive; it is not an assertion over those excluded pixels. In this run, the loaded fullRGBAhash also happens to equal the saved full hash. Save-before/load-afterPNGhas identicalSHA25693251bc464a4d996b030746b3b17e18641692db07fe27b1481a21c952a5535cf.

Strict pending-reference-load and pending-exact-load VM comparisons pass,including script/PC/wait/page/global/visible original rows. Correct reference answer,wrong answer,load,reanswer evidence passespending-affection-once: resulting globals/page match one clean correct answer. System flag preservation and file checksum/bit tests pass;persistedhistory flag901bits=3. Both saved rows already hadchosen=true/historybits3in the captured baseline,so this particular replay proves retention of existing history,not new history acquisition fromzero.

## Suggested final images and limits

Use [2017office Chinese choice/body](../phase3-cn-normal/choice-0012-select-before.png) as the main scene highlight. Use [2009night choice/body](../phase3-cn-normal/choice-0006-select-before.png) for a second distinct pose/background and three-line Chinese paragraph. [Saved pending choice](../phase3-cn-normal/pending-save-before.png) is useful evidence of stable Chinese choices and body afternative readiness; [final title](../phase3-cn-normal/final.png) demonstrates completion. All suggested images were opened atfullresolution above.

No tofu/garble/overflow/control leakage was found in the inspected readabletext, but empty-body periodicSKIPcaptures cannot establish everyline correct. Many four-tick preselection captures still contain crossfades; only the save-readypoint is explicitly settled. Rasterized signs/posters/logo include Japanese/English scene artwork and are not all-Chinese text claims. No retail-frame-by-frame animation/position parity is established. The run is silent;resource/logsuccess and1096lifecycleacks do not establish audible sound quality. One native movie was acknowledged headlessly; its pending screenshot does not prove decoded video playback.

All60capture JSONs were audited for actualengineRGBA/DebugCPU/utf-8patch-overlay/error/silentstate. The whole48794-line runlog search forFAIL|ERROR|MISS found no matching failure/resource-miss record;the successful tests/ending records were separately inspected. No engine/GD edits,builds or game reruns were performed during this review; only new contact sheets and this report were written.
