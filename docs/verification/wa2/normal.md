# Phase2 Godot Normal: final actual visual/log review

**Outcome: route/plan/VM checkpoint checks PASS; visual save/load presentation mismatch remains OPEN.** Every supplied58PNG was actually inspected via all10 sheets. Five originals were expanded to resolve uncertainty. The review did not run the game,build or edit engine/GDScript code.

## Actual image coverage

[Index](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase2-sheets/normal/index.json>) lists58/58capturePNG/JSON pairs,10pages(6each on1–9,4on10). All10sheets were opened with read_image; no sampling/deduplication excluded hold or checkpoint captures.

| Page read | Tiles | Actual observations |
|---|---:|---|
|[sheet-01.png](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase2-sheets/normal/sheet-01.png>)|1–6|Initial0tick black/particles; campus/street and restaurant; movie wait still shows composited story frame; choice1 shows clear disabled first row/enabled second row and readable narration.|
|[sheet-02.png](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase2-sheets/normal/sheet-02.png>)|7–12|Street/choice2 before and pending-save; after reference/load the same choice/narration is visible in an empty bedroom, unlike the saved street+characters. See OPEN V1.|
|[sheet-03.png](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase2-sheets/normal/sheet-03.png>)|13–18|Wrong/reanswer branch checkpoints keep choices/body readable; office trio/choice3 and Koharu restaurant sprite visible.|
|[sheet-04.png](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase2-sheets/normal/sheet-04.png>)|19–24|Choice4 Koharu,Chiaki bedroom and choice5; Japanese rows/read badges are separate; kitchen duo visible.|
|[sheet-05.png](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase2-sheets/normal/sheet-05.png>)|25–30|Koharu station/night street,choice6,Setsuna park and Mari choice7; narration up to3lines fits.|
|[sheet-06.png](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase2-sheets/normal/sheet-06.png>)|31–36|Chiaki campus transition,Io bedroom,choice8 classroom,bar trio transition and choice9 bedroom; Japanese text clear.|
|[sheet-07.png](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase2-sheets/normal/sheet-07.png>)|37–42|Choice9 hold; restaurant duo,choice10 Koharu; choice11 restaurant with dark disabled row clearly distinguished.|
|[sheet-08.png](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase2-sheets/normal/sheet-08.png>)|43–48|Restaurant blend,office trio choice12,Io/Takeya,choice13 over transition; rows and two-line body text readable.|
|[sheet-09.png](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase2-sheets/normal/sheet-09.png>)|49–54|Night sky/river/station images; choice14 has dark first row and enabled rows2/3; choice15 dark station blend remains legible.|
|[sheet-10.png](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase2-sheets/normal/sheet-10.png>)|55–58|Choice15 hold,Chiaki bedroom,2025 bright transition and complete title screen.|

Expanded originals: [pending save before](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase2-godot-normal/pending-save-before.png>),[pending load after](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase2-godot-normal/pending-load-after.png>),[choice1](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase2-godot-normal/choice-0001-before.png>),[choice14](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase2-godot-normal/choice-0014-before.png>),[final title](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase2-godot-normal/final.png>).

Outside V1 below,no persistent full-frame blank,garbled Japanese/tofu,rawcontrolmarkup,ruby tag leakage,message overflow or option/read-marker collision was observed. Initialblackframe0is startup,not a persistent blank. SKIP captures contain blends/empty body moments; those are annotated as transition captures,not settled-layer proof. All15 choice cards (including paired holds) were visually read. Disabled styling is visible at choice1,11,14,15; Japanese labels/narration are legible. No clearly established ruby-bearing settled sample is independently certified by this set.

## OPEN V1 — presentation differs after loading the same pending choice

Original [pending-save-before PNG](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase2-godot-normal/pending-save-before.png>) at driverframe1687 shows a street/shopping background and two fading characters (male on left,Setsuna on right),with option 電話をかける/メールを送る and body だから俺は、彼女の求めに応じなくちゃならない。

[pending-load-after PNG](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase2-godot-normal/pending-load-after.png>) atframe1695 instead shows an empty bedroom with no characters,while retaining the same options/body. The first reference-load capture atframe1691 already shows that bedroom,so the difference appears on load,not merely after a wrong answer.

The corresponding [saved JSON](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase2-godot-normal/pending-save-before.json>) and [loaded JSON](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase2-godot-normal/pending-load-after.json>) both say script2003,PC125488,choiceGroup1,choicePending=true,same pageText and scriptGlobals. Thus **the VM/choice restore passes while the visual scene is not restored to the saved presentation**. The empty checkpointDifferences list does not compare background/sprites/presentation pixels. A street-to-empty-bedroom change at a parked option is not certified as an ordinary SKIP fade. Parent was notified with the exact original evidence. This remains OPEN until fixed captures or an established intended behavior explain it.

## Route and strict plan state

Read [2025 plan](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/r6-routes/2025.plan>). Each of the15choice-beforeJSONfiles has matching runtime.script,choiceGroup,nextPlan.raw_row for the respective plan row:

~~~text
2003 0 1
2003 1 1
2004 0 1
2005 0 1
2007 0 1
2009 0 1
2011 0 1
2013 0 1
2014 0 1
2015 0 1
2016 0 0
2017 0 1
2018 0 1
2019 0 2
2019 1 1
~~~

Final planConsumed15/planTotal15,planComplete=true,nextPlan=null. Final choicesAccepted17includes the two extra accepted answers exercised by checkpoint testing; it must not be described as only15physical acceptance calls. Driverchecks for each answer,all-plan-consumed,disabled rejection,pending exact VM restore/history/systemflags and affection-once allpass.

## Actual VM checkpoint and disabled-input checks

[Report](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase2-godot-normal/report.json>) reports30/30checksPASS,roundtripDone=true,disabledChecked=true,checkpointDifferences=[]; the original state checkpoints were read and independently confirm:

- Saved state:2003/125488,choicegroup1,pendingtrue,historybits3,global7=0,global15=0.
- Wrong rawrow0 after load advancesPC125880,sets global7=1/global15=1.
- Load returnsPC125488,pendingtrue and restores global7=0/global15=0; livehistorybits3 persists.
- Reanswer rawrow1 advancesPC149808,global7=0/global15=2. Wrong-branch affection increment is removed; answer ordinal is the planned one.
- report disabled-row-rejected explicitly checks original disabled row refuses input without VM/global change. Choice1 original image shows that disabled first row.

These verify logic/VM behavior and avoid repeating the old double-affection issue. They do not close V1's visual presentation mismatch.

## Final route completion

[Final JSON](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase2-godot-normal/final.json>) and report were read/parsed in full:

| Field | Actual value |
|---|---|
|driverFrames/runtime ticks/logicTicks|9698/9698/9698|
|fixedDeltaMs|16|
|commandsDispatched|35543|
|state/script/PC|title/2025/36688|
|gameFlags20|1|
|plan|15/15,complete,nextnull|
|choicesAccepted|17(includes checkpoint probes)|
|roundtripDone/disabledChecked|true/true|
|failure/error/scriptError/providerError|all empty|
|checkpointDifferences|[]|
|audioSilent/audioAcks/pendingAudio|true/1096/[]|
|moviesFinished|1|

The final1280×720PNGshows the complete WHITEALBUM2title background/logo/menu. It independently supports returned title. Runtime began with explicit2001startup override in fresh isolated userdata; this is **Closing Chapter2001→Normal**,not an IC1001fullnewgame or an earned whole-game save. NativeSKIP scheduling/framecounts may differ from standalone hosts; actualdriver/runtime both9698ticks with16ms configured here.

## Complete available log audit and its limit

All11689lines of [runtime.log](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase2-godot-normal/runtime.log>) were read sequentially in500-line chunks. LiteraluppercaseMISS count0;ERROR/exception/WARNING count0. However,thelogcontains141debugbackgroundmessages of the form Wa2Bgloadfailedbg=-2variant0→keepold(silent);these alluse negativebackground-2. They are separate from assetMISS. This review did not establish native sentinel semantics,so it does not claim zero load-failure messages. They need not be an observed visual blocker beyond V1,but they remain a logging qualification.

The availablelogstarts atstartup2001andcontains three provideropen_gamesuccesses during reference/checkpoint restore. It ends while logging script2006voice events,not the final2025endpoint. No GoTitle or Wa2Flag lines are present. Therefore **this availablelogis bounded/truncated relative to the completedrun**,and cannot be cited as the complete later script chain or17tickGoTitle proof. The finalJSON/report/PNGprove completion; a separate runtime log/otherinstrumentation would be needed for17tick evidence here. No endingloglines were invented.

## Additional outer stdout audit

The separate [full outer log](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase2-godot-normal.log>) was subsequently searched for endpoint and error evidence. It supplies the endpoint missing from the bounded embedded runtime log: SLoad2020→2021 atline43612,2021→2022at44495,2022→2023at46002,2023→2025at47790; flag20=1writeat2025PC36620,line48764; GoTitleatPC36688,line48768; **GoTitlecompletefade_ticks17**,line48773. Lines48778–48783record15/15andendingPASSplusfinalresult. LiteralMISS/ERROR/exception/WARNINGsearchmatches0 in this outer log. This targeted search is distinguished from reading every outer-logline. It closes the missing endpoint-log-evidence qualification; the embedded runtime.logprefix limitation remains descriptive, and **V1visualsave/loadremainsOPEN**.

Parent later confirmed via native analysis that SaveSlot itself mutates presentation through flatten/cancel before capturing, while retail Save performs a read-only snapshot. A core fix is being prepared. That diagnosis is parent-provided follow-up; no corrected screenshots have yet been reviewed here.

## Backend and audio limits

CaptureSource=engineRGBA,renderBackend=DebugCPU,textureBackend=none. This reviews the actualCPUcompositor output under Godotruntime/provider,not an on-screen GodotGPUviewport. audioSilent=true with1096acknowledgements and empty finalpendingAudio verifies silentqueuehandling,not audibleplayback. The one movie-finished acknowledgement is not proof a movie was visually decoded/played: movie-before-finishPNGshows the compositedstoryscene while waiting.

## Final disposition

- PASS: all10pages58tilesread;readableJapanesechoices/disabledstyle;strict15/15plan;Normalflag20andtitle;VMcheckpoint/history/affectionanddisabledchecks;silentacknowledgementqueueempty.
- OPEN: saved street+characters becomes empty bedroom atsamependingchoiceafterload;VMstatePASSdoesnotcoverpresentation.
- Qualified:141negativebg=-2keepolddebugmessages;availablelogendsbeforeending;no17tickproofinthislog;CPUcaptureonly,silentonly,directCCentryonly.

## Follow-up — V1 CLOSED after native SAVE gate correction

Earlier OPEN findings remain historical evidence. Parent native analysis established retail40A140→409DC0 rejects background/character busy state before424400Save; mid-fadeSave is unavailable. Parent reports core3cd8427 adds SaveReadygating and removes unconditionalSave-time flatten/cancel. This reviewer did not independently redo the IDA trace.

The focused2003target waited until the same pendingchoice2003/PC125488/group1 had saveReady=true. All four original1280×720 images were actually opened with read_image: [beforeSave](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase2-godot-save/pending-save-before.png>), [afterSave](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase2-godot-save/pending-save-after.png>), [referenceLoad](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase2-godot-save/pending-reference-load-after.png>) and [secondLoad](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase2-godot-save/pending-load-after.png>). All four show the same settledbedroom, readableJapanesebody and bothoptions. No scenejump,missingbackground,controlmarkup,overlaporoverflow is visible. Same fullPNG SHA256: **1b361342e6799076e02050a6c8196e518d3295f5fdbd6dd56237d21fef1ff94a**. JSONs confirm samePC/group/page/globals and saveReady=true; before/afterSaveframe591,loads595/599.

ImmediateSave compares all3686400RGBAbytes withoutmask: expected/actualhash148a3ab6e88ef63573b29289e0801de685784a0b4def067a680c981c537bd261. Bothloadscenecomparisons compare2127996bytes outsideUI/history/messageareas: expected/actual198ad86f8876978027bca993d736175a379af47960955c9f663f4064ae41bdd2. Maskedchecks certifyprotectedscene; in this capturedset fullPNGshashes additionallymatch and body/options were visuallychecked.

The [targetreport](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase2-godot-save/report.json>) passes19/19checks,2/2plan,roundtripDone=true,disabledChecked=true,checkpointDifferences=[],emptyfailure/error/scriptError/providerError. Targetstopsat2003/PC149808after603frames/2013commands; it is afocusedregression,not anotherending.

**Updated disposition: V1 CLOSED.** LegalstableSave no longer changes presentation and bothLoads restore the same scene. This supersedes the earlier illegalmidfadeSavebehavior,while retaining its failureevidence. Combined with the earlier58-imageNormalroute/flag20/titleacceptance,this removes the scopedPhase2visualblocker. CPU/silent/directCC limits remain. See [save-gate.md](<C:/Users/Administrator/Documents/deepseek-harness/default-workspace/probe-out/phase2-reviews/save-gate.md>). No reviewer game/build/productionedit was performed.
