# Caption Island

Caption Island 是可注入 uYouEnhanced／YouTube 的 Theos tweak。它使用原生
ActivityKit Live Activity，把目前字幕顯示在支援機型的系統 Dynamic Island，
並同時提供鎖定畫面版面。

## 字幕來源

影片啟用後依序選擇：

1. LRCLIB `syncedLyrics`，依歌曲名稱、歌手與影片長度選擇時間最接近的版本。
2. LRCLIB `plainLyrics`，優先使用現有人工 CC／ASR cue 對齊，否則依影片長度估算。
3. 使用者偏好語言的原始人工 CC（`zh-Hant`、`en` 或 `ja`）。
4. YouTube 原始 ASR 自動字幕。
5. 全部沒有結果時，以 YouTube 內建 HUD 顯示「沒有相符的結果」。

含 `tlang` 的字幕 URL 會被拒絕，因此不會把 YouTube 自動翻譯誤認成人工字幕。
支援的字幕 payload 包含 YouTube JSON3、WebVTT、timedtext XML／SRV3，以及
LRCLIB 標準 LRC 時間碼。

## Live Activity

主 tweak 取得影片與播放時間，ActivityKit bridge 更新同一張 Live Activity；
Widget extension 負責 Dynamic Island 的 compact、minimal、expanded 版面與鎖定畫面。
換片時會沿用現有 Activity，避免反覆收合與展開。只有字幕 cue 改變時才送出更新。

Live Activity 需要 iOS 16.1 以上。沒有 Dynamic Island 的裝置仍可在鎖定畫面看到
Live Activity。YouTube 在背景播放且程序仍有執行時間時可以繼續更新；若 App 被強制
關閉或被系統完全暫停，畫面會停在最後狀態。完全不依賴 App 程序的更新需要額外的
ActivityKit push server。

## 設定

安裝後前往「YouTube 設定 → Tweaks → Caption Island」：

- 啟用或停用原生 Live Activity；
- 選擇中文（繁體）、英文或日文人工字幕；
- 啟用或停用 LRCLIB 查詢；
- 選擇是否顯示 `CC`／`ASR` 來源標記；LRCLIB 來源固定標示；
- 開啟詳細 Log；
- 進入 Log 預覽，篩選全部／警告／錯誤、分享或清除記錄。

## Log 與隱私

Log 使用一條 serial queue 維護最多 500 筆記錄，並寫入：

```text
Library/Caches/CaptionIsland/CaptionIsland.log
```

檔案上限為 128 KB，超過時只保留最新內容。Info、Warning 與 Error 固定記錄；
Debug 只有在「詳細記錄」開啟時才會加入。預覽頁會在新事件出現時即時更新。

Log 僅供診斷來源選擇、下載與 ActivityKit 狀態；不保存完整歌詞、字幕 URL、
Cookie、API key、token 或 Authorization 內容，且會在寫入前再次遮蔽這些資料。

## LRCLIB 匹配

Provider 使用 LRCLIB `GET /api/search`。先以歌曲名稱與歌手搜尋，沒有可信候選時
再做一次較寬鬆搜尋。搜尋最多評估 20 筆資料，排除 instrumental、無歌詞、歌手或
文字相似度過低，以及與影片版本／長度明顯不符的候選。

在安全的長度差距內優先使用同步歌詞；同步時間軸不合理時，會退回同筆純文字歌詞。
LRCLIB 內容不跨影片寫入磁碟快取。若要公開發行，仍應自行確認歌詞內容的顯示權利。

## 資源使用

- 一條 utility QoS serial queue 管理字幕狀態；
- 同時間最多一個字幕下載與一個 LRCLIB request，換片會取消舊工作；
- YouTube 字幕使用最多 8 筆的記憶體快取，LRCLIB 歌詞不做磁碟快取；
- 播放時間最多每秒取樣約 5 次，只有 cue 改變才更新 ActivityKit；
- 不擷取音訊、不使用 CoreML，也不進行裝置端語音辨識或永久輪詢。

## 建置與驗證

專案由根 Makefile 編譯 tweak、嵌入 `CaptionIsland.bundle`，並封裝
`CaptionIslandWidget.appex`。在 Theos、theos-jailed、iOS SDK 與合法取得的
decrypted YouTube IPA 都已準備好時，可沿用專案原本的建置方式：

```sh
make package THEOS_PACKAGE_SCHEME=rootless IPA=Payload/YouTube.app FINALPACKAGE=1
```

純 Foundation fixtures 位於 `Tweaks/CaptionIslandTests`：

```sh
swift test --package-path Tweaks/CaptionIslandTests
```

YouTube 的私有 class／selector 可能隨版本改動；更新 YouTube 後，應在真機重新測試
一般影片、Shorts、廣告切換、seek、PiP、鎖定畫面與背景播放。安裝前也必須遞迴簽署
主 App 與所有 `.appex`，否則系統不會載入 Live Activity extension。
