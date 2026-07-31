# CaptionIsland parser 測試

這是一個只依賴 macOS `Foundation`／`FoundationXML` 的獨立 Swift Package，不會連結
UIKit、Theos 或 YouTube 私有 framework，也不會被正式 tweak 的 Makefile 編譯。用途是先固定字幕
輸入的解析行為，再將相同規則移植或抽回 CaptionIsland 正式來源。

## 執行

從本目錄執行：

```sh
swift test
```

或從 repository 根目錄執行：

```sh
swift test --package-path uYouEnhanced-build/Tweaks/CaptionIslandTests
```

## 已覆蓋格式

| 格式 | 已測行為 | 明確邊界 |
|---|---|---|
| YouTube JSON3 | `events`、`tStartMs`、`dDurationMs`、多個 `segs.utf8`、字串型數字、無文字 window event | 以 event 為一個 cue；`tOffsetMs` 不拆成逐字 cue；`aAppend` rolling window 尚未重建 |
| WebVTT | UTF-8 BOM、CRLF、cue id、settings、多行 cue、`NOTE`／`STYLE`、標籤與 named/numeric entity | 忽略 `REGION`／CSS；移除 voice/class/timestamp tag；不套用 `X-TIMESTAMP-MAP`；容錯接受逗號小數 |
| YouTube timedtext XML | `<text start dur>` 秒制、SRV3 `<p t d>` 毫秒制、子 `<s>`、`<br/>`、XML entity、缺 duration | 忽略 pen/window/style；只認定 `text` 與 `p` 為 cue；`p` 的 `t/d` 固定視為毫秒 |
| LRC | metadata、正負 `[offset]`、多 timestamp、空 timestamp 間奏、百分／毫秒精度、legacy `[mm:ss:xx]`、`[h:mm:ss.xxx]`、enhanced word tag | 無時間文字忽略；逐字 tag 只移除不建立 word cue；最後一句預設 4 秒；沒有全域歌曲長度可供收尾 |

## 共同規則

- 所有結果轉成秒制 `CaptionCue(startTime:endTime:text:)` 並依時間排序。
- 缺少 duration 時使用下一個「更晚」cue 的開始時間；JSON/XML 最後一句預設 2 秒，LRC 預設 4 秒。
- 換行保留，但每行的連續空白會合併；LRC 純空白 cue 不輸出文字，但會截斷上一句形成顯示空檔。
- 負時間（例如負 offset）會 clamp 到 0。
- 無法解碼的 UTF-8、錯誤 JSON root、malformed XML 會拋錯；單一 malformed VTT/LRC cue 則略過，避免整軌失效。

## 尚未放進 parser 的責任

以下應由 CaptionIsland 的 provider/coordinator 做，而不是 payload parser：

- 依 `captionTrack.kind == "asr"` 區分人工字幕與自動字幕。
- 依 BCP-47 語言碼選軌及排除 `tlang` 自動翻譯。
- ASR rolling caption 的去重、正式歌詞模糊比對與播放時間 offset 校正。
- 網路請求取消、快取、來源可信度和 Dynamic Island 更新節流。

## LRCLIB provider smoke test

`ObjC/LRCLIBProviderSmoke.m` 會直接連結正式的 `CILRCLIBProvider.m`，以虛構搜尋結果驗證：

- 時長相近時優先選擇有效 `syncedLyrics`；
- 有可信歌手時建立單一 `/api/get` 精確查詢，沒有可信歌手時才使用 `/api/search`；
- `/api/get` 的單筆物件會套用與搜尋候選相同的歌手、時長及時間軸安全檢查；
- HTTP 403／封鎖頁可被辨識，供 provider 啟動跨重啟冷卻；
- 成功結果與短期「查無結果」都會寫入測試專用暫存快取，並可由新的 provider 實例讀回；
- 只使用清理後的影片標題查詢時，不送出 YouTube 頻道名稱，並依時長選擇候選；
- 移除影片標題內所有 `[…]`／`【…】` 區塊及已知版本、歌詞、字幕 suffix；
- 同步版本的時長明顯較差時，保留最接近的 `plainLyrics`；
- 排除錯歌手、未知時長、過短、裁切後不完整及 placeholder-only 的候選；
- LRC 會轉成可跟隨 media time 的 cue；
- LRC 空 timestamp 會正確形成間奏空檔；
- instrumental、低可信候選與錯誤 JSON root 都會安全拒絕。

測試不會呼叫網路或寫入歌詞快取。

YouTube inspector smoke test 也會驗證字幕 URL 依序採用原始簽名 URL、JSON3、
WebVTT fallback，阻止自動翻譯 `tlang` URL 進入下載流程，並確認一般直式影片不會
被誤認為 Shorts、Shorts 容器標記可保留到後續 metadata refresh。

`ObjC/VideoEligibilitySmoke.m` 會驗證 Caption Island 的播放資格規則：

- Shorts 預設可獨立排除，且關閉該偏好後可立即恢復；
- 5 分鐘閾值允許 5:00，從 5:01 起排除；
- `0` 代表不限制長度；
- 未知、零或非數字時長不會造成誤判。
