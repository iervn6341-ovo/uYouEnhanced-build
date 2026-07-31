# Caption Island

Caption Island 是可注入 uYouEnhanced／YouTube 的 Theos tweak。它使用原生
ActivityKit Live Activity，把目前字幕顯示在支援機型的系統 Dynamic Island，
並同時提供鎖定畫面版面。

## 字幕來源

預設依序選擇：

1. LRCLIB `syncedLyrics`，依歌曲名稱、歌手與影片長度選擇時間最接近的版本。
2. LRCLIB `plainLyrics`，優先使用現有人工 CC／ASR cue 對齊，否則依影片長度估算。
3. 使用者偏好語言的原始人工 CC（`zh-Hant`、`en` 或 `ja`）。
4. YouTube 原始 ASR 自動字幕。
5. 全部沒有結果時，以 YouTube 內建 HUD 顯示「沒有相符的結果」。

設定也可改成「YouTube 內建字幕優先」，順序會變為人工 CC、YouTube ASR、
LRCLIB 同步／純文字歌詞。字幕軌若晚於影片 metadata 抵達，Coordinator 也會依目前
優先順序重新判斷，不會讓先完成的低優先來源永久蓋過後來抵達的高優先來源。

含 `tlang` 的字幕 URL 會被拒絕，因此不會把 YouTube 自動翻譯誤認成人工字幕。
支援的字幕 payload 包含 YouTube JSON3、WebVTT、timedtext XML／SRV3，以及
LRCLIB 標準 LRC 時間碼。

若播放器回報 `isPlayingAd`，或目前 `YTSingleVideo.videoType` 為廣告／內容插播，
Caption Island 不會建立影片 context 或發出 LRCLIB／字幕請求。廣告在既有查詢期間
開始時會取消該工作，等內容影片恢復後才重新載入。

## Live Activity

主 tweak 取得影片與播放時間，ActivityKit bridge 更新同一張 Live Activity；
Widget extension 負責 Dynamic Island 的 compact、minimal、expanded 版面與鎖定畫面。
expanded 與鎖定畫面會同時顯示目前句和字體較小的下一句；清醒狀態換句時使用
push／淡入淡出過渡。換片時會沿用現有 Activity，避免反覆收合與展開。只有字幕 cue
改變時才送出更新。

本 Tweak 最低需要 iOS 17.5。沒有 Dynamic Island 的裝置仍可在鎖定畫面看到
Live Activity。進入 PiP、背景或鎖定畫面時，仍會優先接受 YouTube 的原生播放時間
callback，並另外以每 0.75 秒一次的低頻計時器作 fallback；兩條路徑最後都由
Coordinator 去重，只有字幕 cue 改變時才更新 Activity。進入背景前會短暫保留目前
播放器，避免 PiP 切換視圖時釋放時間來源；回到 App 完全 active 後才停止 fallback
並釋放引用。AVKit、YouTube 現代與舊版 PiP 啟動入口也會直接觸發同一套準備流程，
避免只靠 `viewDidDisappear` 而錯過自動 PiP。

YouTube 在第二次前景／背景切換後，有時音訊仍播放但私有的 media-time getter 停在
舊值。背景監控器此時會以系統 Now Playing 的 playback rate 延續已確認的時間錨點，
不會只因 getter 三秒未變就誤判為暫停；YouTube rate callback 或 Now Playing 明確
回報 rate 為零時，才會停止換句排程。播放器每次回到前景畫面也會重新綁定監控器，
避免下一次鎖屏仍持有第一輪的播放器 graph。

背景同步也會在 YouTube 已提供的 Now Playing dictionary 上補正 elapsed time、
duration 與 playback rate，不取代標題、封面或 Remote Command，因此鎖定畫面的時間
可由系統持續推進，播放控制仍由 YouTube 處理。

此機制需要 YouTube 的背景音訊仍在播放，讓 App 保有系統核准的背景執行時間。若
使用者從多工畫面關閉 YouTube 時，`UISceneDidDisconnectNotification` 會略過排隊中
的歌詞更新並立即要求 ActivityKit 移除所有 Caption Island Activity；
`UIApplicationWillTerminateNotification` 則作為第二層清理。若 iOS 在沒有 scene
callback 的極端狀況直接終止程序，要讓程序外部仍能可靠結束 Activity，仍需要額外的
ActivityKit push server。本 Tweak 不會播放無聲音訊來規避系統限制。

「螢幕關閉」時面板本身不會發光：iPhone 11 會在喚醒鎖定畫面時看到最新字幕；
支援 Always-On Display 的機型則仍由 iOS 的 AOD 顯示規則決定刷新頻率。iOS 會節流
類似逐句歌詞的本機 Live Activity 更新，而且 AOD 不播放 WidgetKit 動畫；因此本
Tweak 會一次提供目前句與下一句，讓被節流時至少仍看得到下一句預告。ActivityKit 的
`staleDate` 只能標記內容過期，不能在指定時間替 Widget 切換字幕；若 YouTube 程序被
暫停，仍不能保證 AOD 長時間逐句即時重畫。本版本只使用 App 內的本機 ActivityKit
更新，不含 APNs Live Activity push 或外部 relay。

iOS 26 以上另提供預設關閉的「持續背景字幕」實驗模式。它使用公開的
`BGContinuedProcessingTaskRequest`，以影片播放作為由使用者啟動、可完成且具有
進度的背景工作；目前時間會持續回報到 `NSProgress`，目前句與下一句也會更新到
系統提供的背景任務 Live Activity。影片結束、切換為不符合 Shorts／長度政策的
內容、播放器釋放或 App 終止時會完成並清除任務，系統提前收回執行資格時則寫入
`ContinuedTask` Warning。此模式不需要 APNs 或外部伺服器，但系統仍可因資源限制
終止任務，而且系統背景任務 Activity 可能與 Caption Island 自訂 Activity 競爭
Dynamic Island 顯示位置。iOS 17.5～18 不會顯示此設定，仍沿用背景音訊方案。
每次從背景真正回到 YouTube 前景時，上一輪 continued-processing session 會正常完成，
並在 App 尚為 active 時為下一次「回主頁／鎖屏」提交具有唯一動態後綴的新 request；
不會重用先前背景週期已消耗或仍在清理的 identifier。request 使用系統預設 queue
策略，若上一輪剛結束、資源尚未釋放，不會因為無法立即啟動就直接丟棄第三輪工作。
因此從播放器畫面直接鎖屏與先回主畫面再鎖屏，都會使用同一份已在前景提交的工作。

expanded Dynamic Island 會依目前句與下一句的實際高度擴張，並使用三階段
`ViewThatFits`：一般內容顯示影片標題，長歌詞優先隱藏標題，極長歌詞再縮小字級與
行數，避免最底部被系統上限裁切。leading／trailing／bottom region 都保留額外安全
邊距，避免字幕 icon 貼近圓角或 TrueDepth 區域。

## 設定

安裝後前往「YouTube 設定 → Tweaks → Caption Island」：

- 啟用或停用原生 Live Activity；
- 選擇返回主畫面時使用 YouPiP 自動子母畫面，或使用 Caption Island 背景
  字幕模式；背景字幕模式只阻止自動 PiP，播放器內的手動 PiP 按鈕仍可使用；
- 在 iOS 26 選擇是否啟用不需伺服器的持續背景字幕實驗模式；
- 選擇中文（繁體）、英文或日文人工字幕；
- 選擇 LRCLIB 優先或 YouTube 內建字幕優先；
- 啟用或停用 LRCLIB 查詢；
- 為目前影片指定 LRCLIB 搜尋歌名、歌手與字幕提前／延後秒數（正值代表提早，
  範圍為 -30～+30 秒）；設定以 YouTube video ID 個別保存；
- 選擇是否顯示 `CC`／`ASR` 來源標記；LRCLIB 來源固定標示；
- 開啟詳細 Log；
- 進入 Log 預覽，篩選全部／警告／錯誤、分享或清除記錄。

Caption Island 背景字幕模式不會清除 YouTube 的 Now Playing 資料，避免破壞控制
中心與鎖定畫面的播放控制。因此，若 iOS 同時顯示系統 Now Playing Live Activity，
Dynamic Island 仍可能依系統規則把兩張活動縮成 minimal；這個模式只負責可靠地
阻止返回主畫面時自動建立 PiP 浮窗。

手動 PiP 被叉叉關閉時，AVKit 會釋放該 PiP 的 sample-buffer renderer。若使用者
之後從控制中心按播放，Caption Island 會先保存的影片 ID／時間重建 YouTube
背景播放器，再 seek 回原位置；不會把 Play 送回已失效的 PiP renderer。重建後會
觀察播放時鐘 12 秒，時鐘停滯時最多自動重建一次；兩次都失敗時會保留影片與時間，
讓下一次明確的控制中心 Play 再開啟一輪恢復，而不是回到已失效的 renderer。舊 PiP
延遲送到的 teardown pause 在恢復期間會被忽略。回到 App 再次手動觸發 PiP 時，會先
把目前影片重新綁定至 PiP 控制器；影片切換或 PiP 返回 YouTube 則會取消舊恢復，避免
操作到錯誤的影片。

## Log 與隱私

Log 使用一條 serial queue 維護最多 500 筆記錄，並寫入：

```text
Library/Caches/CaptionIsland/CaptionIsland.log
```

檔案上限為 128 KB，超過時只保留最新內容。Info、Warning 與 Error 固定記錄；
Debug 只有在「詳細記錄」開啟時才會加入。預覽頁會在新事件出現時即時更新。

Log 僅供診斷來源選擇、下載與 ActivityKit 狀態；不保存完整歌詞、字幕 URL、
Cookie、API key 或 Authorization 內容，且會在寫入前再次遮蔽這些資料。
背景期間每 30 秒會記錄低頻 clock heartbeat，並分別記錄 YouTube 原生 callback、
Live Activity revision 與 Now Playing 同步是否仍在工作，方便區分 App 已被暫停與
ActivityKit 只延後 AOD 畫面刷新。
PiP 關閉後的控制中心恢復會另外使用 `PlayerGraph` 分類，依序記錄
`Armed`、`Intercepted`、`Rebuilding`、播放時鐘開始前進及 12 秒健康檢查結果。

## LRCLIB 匹配

標題解析器會先辨識 `「歌名」`／`『歌名』`、`歌手 / 歌名`、`歌名 / 虛擬歌手 SV`
及常見的 artist-title 分隔，並移除 Official Video、動畫作品說明、音訊優化等
上傳資訊；未知的中括號不會任意刪除，因此 `SawanoHiroyuki[nZk]` 仍可保留。
一般上傳者頻道不會被當作歌手，只有標題內可辨識的歌手或
Topic／VEVO／Official Artist Channel 才會加入歌手條件。無法可靠推導時會只查
歌名，使用者可用目前影片的專屬設定消除同名歌曲歧義。

Provider 使用 LRCLIB `GET /api/search`。先以歌曲名稱與歌手搜尋，沒有可信候選時
再做一次較寬鬆搜尋。搜尋最多評估 50 筆資料，排除 instrumental、無歌詞、歌手或
文字相似度過低，以及與影片版本／長度明顯不符的候選。

候選先通過歌名／歌手門檻，再以影片總時間選擇最接近的版本。LRCLIB 曲目比影片長
時只容許約 18～35 秒差距，避免 90 秒 TV Size 誤配到較長版本；影片比曲目長時則
容許約 35～60 秒，保留 MV 劇情片頭／片尾的空間。在安全的長度差距內優先使用
同步歌詞；同步時間軸不合理時，會退回同筆純文字歌詞。
LRCLIB 內容不跨影片寫入磁碟快取。若要公開發行，仍應自行確認歌詞內容的顯示權利。

## 資源使用

- 一條 utility QoS serial queue 管理字幕狀態；
- 同時間最多一個字幕下載與一個 LRCLIB request，換片會取消舊工作；
- YouTube 字幕使用最多 8 筆的記憶體快取，LRCLIB 歌詞不做磁碟快取；
- 前景與 PiP／背景都保留 YouTube callback（Coordinator 最多接受約 5 Hz）；背景
  另外使用單一 0.75 秒 fallback 計時器並提供 0.15 秒系統容差，時間未改變時不提交
  任何字幕工作；
- Now Playing 的一般校正最多每 12 秒一次，播放／暫停或倍速狀態改變則立即更新，
  之後由 iOS 依 playback rate 自行推進時間；
- 不擷取音訊、不使用 CoreML，也不進行裝置端語音辨識或無聲音訊保活。

## 建置與驗證

專案由根 Makefile 編譯 tweak、嵌入 `CaptionIsland.bundle`，並封裝
`CaptionIslandWidget.appex`。封裝時也會把
`<主程式 Bundle ID>.captionisland.background-captions.*` 加入主程式的
`BGTaskSchedulerPermittedIdentifiers`。iOS 26 API 以 runtime availability
檢查，因此最低部署版本與建置 SDK 仍可維持 iOS 17.5。在 Theos、theos-jailed、
iOS SDK 與合法取得的
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
