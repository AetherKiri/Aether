import Foundation

enum ShellLanguage: String, CaseIterable, Identifiable {
    case simplified, traditional, english, japanese, korean
    var id: String { rawValue }
    var name: String {
        ["简体中文", "繁體中文", "English", "日本語", "한국어"][index]
    }
    var locale: Locale { Locale(identifier: ["zh-Hans", "zh-Hant", "en", "ja", "ko"][index]) }
    var index: Int { Self.allCases.firstIndex(of: self)! }
    static var system: Self {
        let preferred = Locale.preferredLanguages.first ?? "en"
        if preferred.hasPrefix("zh") { return preferred.contains("Hant") || preferred.contains("TW") || preferred.contains("HK") ? .traditional : .simplified }
        if preferred.hasPrefix("ja") { return .japanese }
        if preferred.hasPrefix("ko") { return .korean }
        return .english
    }
    func text(_ key: String) -> String { Self.strings[key]?[index] ?? key }
    // Same five languages as the existing product; game text is untouched.
    private static let strings: [String: [String]] = [
        "rename": ["重命名", "重新命名", "Rename", "名前を変更", "이름 변경"],
        "gameTitle": ["游戏名称", "遊戲名稱", "Game Title", "ゲーム名", "게임 이름"],
        "remove": ["从游戏库移除", "從遊戲庫移除", "Remove from Library", "ライブラリから削除", "라이브러리에서 제거"],
        "removeHelp": ["只移除列表记录，游戏文件和存档都会保留。可重新导入或添加目录恢复记录。", "只移除清單記錄，遊戲檔案和存檔均保留。可重新匯入或加入目錄恢復記錄。", "Only the list entry is removed. Game files and saves remain. Import or add the folder again to restore the entry.", "一覧の項目のみ削除します。ゲームとセーブは保持されます。フォルダを再追加できます。", "목록 항목만 제거합니다. 게임과 저장 파일은 유지되며 폴더를 다시 추가할 수 있습니다."],
        "linkGame": ["添加外部游戏目录", "加入外部遊戲目錄", "Add External Game Folder", "外部ゲームフォルダを追加", "외부 게임 폴더 추가"],
        "linkHelp": ["直接使用所选目录，不复制文件。游戏存档与运行文件会写入该目录；移动目录后需重新添加。", "直接使用所選目錄，不複製檔案。遊戲存檔與執行檔案會寫入該目錄；移動後需重新加入。", "Uses the selected folder directly without copying. Saves and runtime files are written there. Add it again if you move it.", "コピーせず選択したフォルダを使用します。セーブと実行時ファイルはそこに保存されます。移動後は再追加してください。", "복사 없이 선택한 폴더를 사용합니다. 저장 및 실행 파일이 해당 폴더에 기록됩니다. 이동하면 다시 추가하세요."],
        "externalStorage": ["外部目录", "外部目錄", "External Folder", "外部フォルダ", "외부 폴더"],
        "managedStorage": ["游戏库副本", "遊戲庫副本", "Library Copy", "ライブラリのコピー", "라이브러리 복사본"],
        "invalidTitle": ["请输入 1–200 字的名称，不包含控制字符。", "請輸入 1–200 字的名稱，不含控制字元。", "Enter a title of 1–200 characters without control characters.", "制御文字を含まない1〜200文字の名前を入力してください。", "제어 문자 없이 1–200자의 이름을 입력하세요."],
        "skipMovie": ["跳过影片", "跳過影片", "Skip Movie", "動画をスキップ", "동영상 건너뛰기"],
        "video": ["视频", "影片", "Video", "動画", "동영상"],
        "openVideo": ["打开视频", "開啟影片", "Open Video", "動画を開く", "동영상 열기"],
        "videoPlay": ["播放", "播放", "Play", "再生", "재생"],
        "pause": ["暂停", "暫停", "Pause", "一時停止", "일시 정지"],
        "replay": ["重新播放", "重新播放", "Replay", "もう一度再生", "다시 재생"],
        "videoPosition": ["播放进度", "播放進度", "Playback Position", "再生位置", "재생 위치"],
        "videoRate": ["速度", "速度", "Speed", "速度", "속도"],
        "volume": ["音量", "音量", "Volume", "音量", "음량"],
        "subtitles": ["字幕", "字幕", "Subtitles", "字幕", "자막"],
        "subtitlesOff": ["关闭", "關閉", "Off", "オフ", "끄기"],
        "backward10": ["后退 10 秒", "後退 10 秒", "Back 10 Seconds", "10秒戻る", "10초 뒤로"],
        "forward10": ["前进 10 秒", "前進 10 秒", "Forward 10 Seconds", "10秒進む", "10초 앞으로"],
        "dialogYes": ["是", "是", "Yes", "はい", "예"],
        "dialogNo": ["否", "否", "No", "いいえ", "아니요"],
        "virtualControls": ["虚拟按键", "虛擬按鍵", "On-Screen Keys", "画面上のキー", "화면 키"],
        "virtualControlsHelp": ["按键的作用由游戏决定。", "按鍵的作用由遊戲決定。", "Key actions depend on the game.", "キーの動作はゲームによって異なります。", "키 동작은 게임에 따라 다릅니다."],
        "enterKey": ["回车", "Enter", "Enter", "Enter", "Enter"],
        "spaceKey": ["空格", "空白", "Space", "Space", "Space"],
        "holdControl": ["保持 Ctrl", "保持 Ctrl", "Hold Ctrl", "Ctrlを保持", "Ctrl 누름 유지"],
        "enterText": ["输入文字", "輸入文字", "Enter Text", "文字入力", "텍스트 입력"],
        "enterTextHelp": ["先在游戏中选中输入框，再输入文字。一次最多发送 2048 个 Unicode 字符；不发送换行。", "先在遊戲中選取輸入框，再輸入文字。一次最多傳送 2048 個 Unicode 字元；不傳送換行。", "Select a text field in the game first. Sends up to 2048 Unicode characters without line breaks.", "先にゲーム内の入力欄を選択してください。改行を除く最大2048文字を送信します。", "먼저 게임 내 입력란을 선택하세요. 줄바꿈을 제외한 최대 2048자를 전송합니다."],
        "sendText": ["发送", "傳送", "Send", "送信", "보내기"],
        "Esc": ["Esc", "Esc", "Esc", "Esc", "Esc"],
        "←": ["←", "←", "←", "←", "←"],
        "↑": ["↑", "↑", "↑", "↑", "↑"],
        "→": ["→", "→", "→", "→", "→"],
        "↓": ["↓", "↓", "↓", "↓", "↓"],
        "PgUp": ["PgUp", "PgUp", "PgUp", "PgUp", "PgUp"],
        "PgDn": ["PgDn", "PgDn", "PgDn", "PgDn", "PgDn"],
        "library": ["游戏库", "遊戲庫", "Library", "ライブラリ", "라이브러리"],
        "import": ["导入游戏", "匯入遊戲", "Import Game", "ゲームを追加", "게임 가져오기"],
        "importing": ["正在导入…", "正在匯入…", "Importing…", "追加中…", "가져오는 중…"],
        "importHelp": ["选择游戏文件夹。游戏将复制到应用游戏库，存档写入副本。", "選擇遊戲資料夾。遊戲將複製到 App 遊戲庫，存檔寫入副本。", "Choose a game folder. A copy is added to the library; saves stay in the copy.", "ゲームのフォルダを選択してください。コピーをライブラリに追加し、セーブもコピーに保存します。", "게임 폴더를 선택하세요. 라이브러리에 복사되며 저장 파일도 복사본에 보관됩니다."],
        "empty": ["你的游戏库", "你的遊戲庫", "Your Game Library", "ゲームライブラリ", "내 게임 라이브러리"],
        "emptyHelp": ["导入一个 KiriKiri、ONScripter 或支持的 Minori 游戏，开始游玩。", "匯入 KiriKiri、ONScripter 或支援的 Minori 遊戲，開始遊玩。", "Import a KiriKiri, ONScripter or supported Minori game to begin.", "KiriKiri、ONScripter または対応 Minori のゲームを追加して始めましょう。", "KiriKiri, ONScripter 또는 지원되는 Minori 게임을 가져와 시작하세요."],
        "choose": ["选择一款游戏", "選擇遊戲", "Choose a Game", "ゲームを選択", "게임 선택"],
        "play": ["开始游玩", "開始遊玩", "Play", "プレイ", "플레이"],
        "back": ["返回游戏库", "返回遊戲庫", "Back to Library", "ライブラリに戻る", "라이브러리로 돌아가기"],
        "backHelp": ["返回后游戏会停止，请先在游戏内保存进度。", "返回後遊戲會停止，請先在遊戲內儲存進度。", "Returning stops the game. Save your progress in the game first.", "戻るとゲームが終了します。先にゲーム内でセーブしてください。", "돌아가면 게임이 종료됩니다. 먼저 게임 내에서 저장하세요."],
        "cancel": ["取消", "取消", "Cancel", "キャンセル", "취소"],
        "continue": ["继续游玩", "繼續遊玩", "Keep Playing", "プレイを続ける", "계속 플레이"],
        "settings": ["设置", "設定", "Settings", "設定", "설정"],
        "language": ["界面语言", "介面語言", "Language", "表示言語", "언어"],
        "renderer": ["绘制方式", "繪製方式", "Rendering", "描画方式", "렌더링"],
        "software": ["软件绘制", "軟體繪製", "Software", "ソフトウェア", "소프트웨어"],
        "metal": ["Metal 绘制（测试中）", "Metal 繪製（測試中）", "Metal (Testing)", "Metal（テスト中）", "Metal (테스트 중)"],
        "rendererHelp": ["更改将在下次启动游戏时生效。", "更改將於下次啟動遊戲時生效。", "Changes apply the next time you start a game.", "変更は次回ゲーム起動時に適用されます。", "변경 사항은 다음 게임 실행 시 적용됩니다."],
        "exportDiagnostics": ["导出诊断日志", "匯出診斷日誌", "Export Diagnostics", "診断ログを書き出す", "진단 로그 내보내기"],
        "logs": ["显示运行日志", "顯示執行日誌", "Show Runtime Log", "実行ログを表示", "실행 로그 표시"],
        "folder": ["在访达中显示", "在 Finder 中顯示", "Show in Finder", "Finder で表示", "Finder에서 보기"],
        "storage": ["游戏库存储位置", "遊戲庫儲存位置", "Library Location", "ライブラリの保存場所", "라이브러리 위치"],
        "imported": ["导入时间", "匯入時間", "Imported", "追加日", "가져온 날짜"],
        "played": ["最近游玩", "最近遊玩", "Last Played", "最終プレイ", "최근 플레이"],
        "never": ["尚未游玩", "尚未遊玩", "Not played yet", "未プレイ", "아직 플레이하지 않음"],
        "starting": ["正在启动…", "正在啟動…", "Starting…", "起動中…", "시작 중…"],
        "error": ["无法完成操作", "無法完成操作", "Unable to Complete", "操作を完了できません", "작업을 완료할 수 없음"],
        "ok": ["好", "好", "OK", "OK", "확인"],
        "game": ["游戏", "遊戲", "Game", "ゲーム", "게임"],
        "unsupported": ["没有找到可识别的游戏入口。请选择包含 startup.tjs、XP3、ONS 脚本或支持的 Minori PAZ 文件的文件夹。", "找不到可識別的遊戲入口。請選擇含 startup.tjs、XP3、ONS 腳本或支援的 Minori PAZ 檔案的資料夾。", "No game entry found. Choose a folder containing startup.tjs, XP3, an ONS script or supported Minori PAZ files.", "ゲームが見つかりません。startup.tjs、XP3、ONS スクリプトまたは対応 Minori PAZのあるフォルダを選択してください。", "게임을 찾을 수 없습니다. startup.tjs, XP3, ONS 스크립트 또는 지원되는 Minori PAZ가 있는 폴더를 선택하세요."],
        "unsafeSource": ["这个文件夹包含应用游戏库，请选择独立的游戏文件夹。", "此資料夾包含 App 遊戲庫，請選擇獨立的遊戲資料夾。", "This folder contains the app library. Choose a separate game folder.", "このフォルダにはアプリのライブラリが含まれます。別のゲームフォルダを選択してください。", "이 폴더에는 앱 라이브러리가 포함되어 있습니다. 별도의 게임 폴더를 선택하세요."],
        "symbolicLink": ["文件夹内有符号链接，请导入包含实际游戏文件的文件夹。", "資料夾含符號連結，請匯入包含實際遊戲檔案的資料夾。", "The folder contains symbolic links. Choose a folder containing the actual game files.", "シンボリックリンクが含まれます。実際のゲームファイルがあるフォルダを選択してください。", "폴더에 심볼릭 링크가 있습니다. 실제 게임 파일이 있는 폴더를 선택하세요."],
        "invalidIndex": ["游戏库索引无法读取，原索引已保留。", "遊戲庫索引無法讀取，原索引已保留。", "The library index cannot be read. The original index has been preserved.", "ライブラリの一覧を読み込めません。元の一覧は保持されています。", "라이브러리 목록을 읽을 수 없습니다. 원본 목록은 보존되었습니다."],
        "startFailed": ["游戏启动失败。", "遊戲啟動失敗。", "Game startup failed.", "ゲームの起動に失敗しました。", "게임 실행에 실패했습니다."],
        "missing": ["游戏目录已移动或丢失，请重新导入或添加原文件夹。", "遊戲目錄已移動或遺失，請重新匯入或加入原資料夾。", "The game folder is missing. Import or add the original folder again.", "ゲームのフォルダが見つかりません。元のフォルダを再度追加してください。", "게임 폴더를 찾을 수 없습니다. 원본 폴더를 다시 가져오거나 추가하세요."],
    ]
}
