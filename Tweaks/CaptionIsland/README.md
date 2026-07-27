# CaptionIsland

CaptionIsland 是可獨立注入 uYouEnhanced／YouTube 的 Theos tweak。影片啟用時，它會依序選擇：

1. LRCLIB 的逐行同步歌詞，依歌曲名稱、歌手與影片總長度選擇最接近的版本。
2. 若只有 LRCLIB 純文字歌詞，先用人工 CC（若有）或 YouTube ASR cue 對齊；無法對齊時依影片長度估算。
3. 使用者偏好語言的 **原始人工 CC**（`zh-Hant`、`en` 或 `ja`）。
4. YouTube 原始 ASR 自動字幕。
5. 全部沒有結果時，使用 YouTube 內建 HUD 顯示「沒有相符的結果」。

含 `tlang` 的字幕 URL 會直接拒絕，因此不會把 YouTube 自動翻譯當成人工字幕。

## 目前可用的顯示範圍

這個版本提供的是 **YouTube App 內的島狀字幕浮層**：在 YouTube 位於前景時，將目前句子顯示在 Dynamic Island／安全區附近。它不會偽裝成系統 Live Activity。

真正能在系統 Dynamic Island、鎖定畫面與其他 App 上方持續顯示的版本，還需要：

- 一個 Swift `ActivityAttributes`／ActivityKit bridge；
- 一個含 `ActivityConfiguration` 與 `DynamicIsland` 的 WidgetKit extension；
- 主 App 與 extension 一起完成 entitlement、provisioning 與重簽。

`CICaptionPresenting` 已把顯示層和字幕管線分離。未來可用 ActivityKit presenter 取代 `CIOverlayPresenter`，不必重寫選軌、歌詞查詢或時間軸。

## 資料流程

```text
YTPlayerViewController didActivateVideo
  └─ snapshot YTIPlayerResponse
      ├─ LRCLIB line-synced LRC ─────────────┐
      ├─ LRCLIB text + CC/ASR alignment ──────┤
      ├─ LRCLIB estimated timing ─────────────┤→ serial cue timeline → presenter
      ├─ preferred manual CC ─────────────────┤
      └─ YouTube ASR ─────────────────────────┘
```

支援的字幕 payload：YouTube JSON3、WebVTT、timedtext XML／SRV3，以及 LRCLIB 標準 LRC 時間碼。

## 設定

安裝後到 YouTube 的「設定 → Tweaks → Caption Island」：

- 開關整個 tweak 或 App 內浮層；
- 選擇中文（繁體）、英文或日文；
- 啟用或停用 LRCLIB 歌詞查詢；LRCLIB 不需要 API Key；
- 選擇是否顯示 `CC`／`ASR` 標記；LRCLIB 來源會固定顯示；
- 視需要開啟不含任何憑證的除錯記錄。

## LRCLIB 查詢與匹配

Provider 使用 `GET https://lrclib.net/api/search`。第一次以 `track_name` 與 `artist_name` 查詢；若沒有可信候選，再以「歌手＋歌曲名稱」做一次較寬鬆搜尋。所有相鄰 LRCLIB 請求的啟動時間至少間隔 350 ms，上一個請求完成後也至少再等 200 ms，並使用可識別的 `User-Agent`；同時間最多一個連線，收到 `429` 時會完整遵守 `Retry-After`，切換影片則取消舊請求。

搜尋最多檢查 20 筆資料，先排除 instrumental、無歌詞、歌手不符及文字相似度過低的候選，再從 metadata 相近的版本中選影片總長度差距最小者。若同步版本與最接近版本的時長差距只落在小幅容許範圍內，會優先採用同步版本；過短或與影片總長度差異過大的時間軸會降級採用同筆 `plainLyrics`，不會為了取得 `Synced` 而選擇明顯不同的 live／remix 版本。

`syncedLyrics` 會交給既有 LRC parser 轉成 cue，播放時以 YouTube 真實 media time 二分搜尋目前行。若只有 `plainLyrics`，YouTube 的人工 CC／ASR 只作為時間尺，畫面仍顯示 LRCLIB 歌詞。LRCLIB 內容不寫入磁碟或跨影片快取。

LRCLIB 是免費、社群維護的服務；其 server 原始碼授權不等同於歌詞內容的公開再散布授權。這個 Provider 適合個人側載與原型。若要正式公開發行，仍應另行確認歌詞顯示權。

## 資源使用策略

- 一條 utility QoS serial queue 管理狀態，避免多個來源競爭更新畫面；
- 同時間最多一個字幕下載與一個 LRCLIB request；切換影片會取消舊請求；
- YouTube 字幕對同一影片與相同設定使用最多 8 筆的記憶體快取；LRCLIB 歌詞不寫入快取；
- 播放時間最多每秒取樣 5 次，只有 cue 改變才更新 UIKit；
- 沒有常駐輪詢、音訊擷取、CoreML 或裝置端語音辨識；
- 純文字歌詞對齊只在需要時執行，YouTube 字幕只提供既有文字與時間；晚到或更新的字幕軌最多在三次 bounded snapshot 內觸發一次升級。

## 建置

根 Makefile 已完成三項整合：編譯 `Tweaks/CaptionIsland`、注入 `CaptionIsland.dylib`，以及從 `Assets` 嵌入 `CaptionIsland.bundle`。

在已安裝 Theos、theos-jailed、iOS SDK 且持有可合法使用的 decrypted YouTube App 時，沿用專案原本的建置方式，例如：

```sh
make package THEOS_PACKAGE_SCHEME=rootless IPA=Payload/YouTube.app FINALPACKAGE=1
```

目前 hook 已依專案內的 YouTube 21.10.2 binary 驗證資料路徑；YouTube 的私有 class／selector 可能隨版本改動，升級 App 後仍應在真機驗證一般影片、Shorts、廣告切換、seek 與 PiP。

## 驗證

純 Foundation 的格式 fixtures 位於 `../CaptionIslandTests`：

```sh
swift test --package-path Tweaks/CaptionIslandTests
```

正式 Objective-C 核心亦可直接用 iPhoneOS SDK 執行 `clang -fsyntax-only`；完整 dylib／IPA 驗證仍需要 Theos 與 jailed toolchain。
