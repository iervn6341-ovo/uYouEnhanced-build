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
Tweak 會一次提供目前句與下一句，並把下一句開始時間設為一次性的 stale handoff：
若背景更新恰好被延後，WidgetKit 仍可把已送達的下一句提升成目前句。這只能涵蓋一個
cue 邊界，仍不能保證 AOD 長時間逐句即時重畫。Caption Island 可選擇以
`pushType: .token` 建立 Activity，將 token、播放錨點與完整 cue 時間軸交給專用 relay；
之後即使 YouTube 被 iOS 暫停，relay 仍可繼續向 APNs 提交逐句更新或結束 Activity。
內附的 relay 位於 `Services/CaptionIslandPushServer`。
`NSSupportsLiveActivitiesFrequentUpdates` 只會要求較高的遠端更新額度；APNs 接受請求
不等於裝置已即時顯示，實際傳送、節流與 AOD 重畫仍由 iOS 決定，不能保證每一句都
零延遲。

expanded Dynamic Island 會依目前句與下一句的實際高度擴張，並使用三階段
`ViewThatFits`：一般內容顯示影片標題，長歌詞優先隱藏標題，極長歌詞再縮小字級與
行數，避免最底部被系統上限裁切。leading／trailing／bottom region 都保留額外安全
邊距，避免字幕 icon 貼近圓角或 TrueDepth 區域。

## 設定

安裝後前往「YouTube 設定 → Tweaks → Caption Island」：

- 啟用或停用原生 Live Activity；
- 選擇中文（繁體）、英文或日文人工字幕；
- 設定「AOD 遠端更新」與自己的 HTTPS push relay；
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
Cookie、API key、push/device/APNs/relay token 或 Authorization 內容，且會在寫入前
再次遮蔽這些資料。
背景期間每 30 秒會記錄低頻 clock heartbeat，並分別記錄 YouTube 原生 callback、
Live Activity revision 與 Now Playing 同步是否仍在工作，方便區分 App 已被暫停與
ActivityKit 只延後 AOD 畫面刷新。

「AOD 遠端更新」預設關閉，單純儲存 relay 設定不會開啟上傳。使用者明確啟用後，
資料流如下：

1. 選取的字幕／歌詞全文與時間軸、影片 ID、標題、播放狀態／位置及 Live Activity
   push token 會上傳到使用者設定的 HTTPS relay。
2. Relay 會把顯示所需的目前句、下一句、影片資訊、播放狀態與 cue 時間送到 Apple
   APNs；完整時間軸不會直接整批送到 APNs。
3. APNs 將更新交給 ActivityKit。Apple 接受 HTTP 請求仍不保證 iOS 立即傳送或刷新
   AOD。

Relay access token 存在 iOS Keychain
（`AfterFirstUnlockThisDeviceOnly`），不放在 `NSUserDefaults`。連線只接受不含帳密、
query 或 fragment 的 HTTPS URL，且拒絕轉址。內附 relay 的 log 只記錄 push token
雜湊指紋，不記錄原始 token、標題或歌詞；Caption Island 本機 Log 也會在寫入前遮蔽
token、Authorization 與字幕全文。

設定頁會在啟用及儲存時檢查主 App bundle ID。若仍是 Google 擁有的
`com.google.ios.youtube`，relay URL 與 access token 可以先保存，但「AOD 遠端更新」
會保持關閉並顯示錯誤；必須改以自己 Apple Developer Team 擁有的明確 App ID 最終
簽署後才能啟用。

內附 relay 預設將活動資料保留在程序記憶體；若同時設定 `RELAY_STATE_PATH` 與
`RELAY_STATE_KEY`，則會以 AES-256-GCM 加密後短期寫入磁碟，讓排程可跨服務重啟恢復。
正常影片結束會先保留 5 秒、可被自動播放新影片 PUT 取消的寬限期，之後移除；明確
收到 DELETE 時則立即清理。即使客戶端意外消失，每次註冊最多保留八小時，之後會要求
APNs 結束 Activity。此保留規則只適用於內附實作；若把 API 接到其他服務，資料保存
方式與隱私責任由該服務的營運者決定。
自然結束或 DELETE 後另保留 15 分鐘、不含歌詞的 Activity ID tombstone，用來拒絕
較晚才抵達的舊 PUT，避免已結束的字幕排程因網路亂序而復活。

## AOD APNs relay

伺服器的部署方式與 API schema 詳見
`Services/CaptionIslandPushServer/README.md`。它會在播放、暫停、seek、倍速、換片或
token rotation 時重排 cue，對每句送出含目前句、下一句及 `stale-date` 的
`liveactivity` push；影片自然結束或收到 DELETE 時送出 `event: end`。

這項功能有不可省略的 Apple 簽章條件：

1. 使用付費 Apple Developer Team 擁有的明確 App ID；不能沿用 Google 擁有的
   `com.google.ios.youtube`。
2. 該 App ID 必須啟用 Push Notifications，最終主 App 簽章必須含 provisioning
   profile 核發的 `aps-environment`。
3. Widget ID 必須是 `<主 App ID>.CaptionIslandWidget`，並以相同 Team 的對應 profile
   簽署。
4. Relay 使用同一 Team 的 APNs `.p8`，並將 `APNS_BUNDLE_ID` 設成最終主 App ID。

### 部署順序

1. 在 Apple Developer 後台建立自己的明確 App ID，啟用 Push Notifications，並為
   主 App 與 `<主 App ID>.CaptionIslandWidget` 建立同一 Team 的有效 provisioning
   profile。
2. 執行 GitHub Actions 時，把 `bundle_id` 改成上述主 App ID。保留預設
   `com.google.ios.youtube` 只能使用本機 Live Activity，不能使用自己的 APNs key。
3. 以該 Team 的 profile 最終簽署主 App 與 Widget。GitHub Actions 產生的是待後續
   簽署的結構性產物，無法預先保證 sideload signer 保留了 bundle ID、
   `aps-environment` 或 Live Activity metadata。
4. 在 Mac 對「最終簽署完成」的 IPA 執行簽章檢查。腳本會確認主 App／Widget ID、
   Live Activity plist key、Widget extension point、實際簽章 entitlement、
   provisioning 授權、Team 一致性及 profile 到期日：

```sh
Scripts/verify-caption-island-push-signing.sh /path/to/finally-signed.ipa
```

5. 依 `Services/CaptionIslandPushServer/README.md` 部署 Node.js relay。將檢查腳本
   印出的 `APNS_TEAM_ID`、`APNS_BUNDLE_ID`、`APNS_ENVIRONMENT` 與自己的
   `APNS_KEY_ID`、`.p8` 路徑設成伺服器環境變數；`.p8` 不可放入 IPA、Git repository
   或傳給客戶端。正式環境也應設定 `RELAY_STATE_PATH` 與獨立的 32-byte
   `RELAY_STATE_KEY`，否則服務重啟會中斷當時的 AOD 排程。Relay 本身只監聽
   `127.0.0.1`，對外必須放在 HTTPS reverse proxy 後方。
6. 在 Caption Island 設定中先儲存 HTTPS URL 與至少 32 bytes 的 relay access token，
   再明確打開「AOD 遠端更新」。

### 持久化與可用性

未設定 `RELAY_STATE_*` 時，relay 只使用記憶體，重啟後必須等 App 再次送出 snapshot。
正式部署應啟用內建的 AES-256-GCM state store：它以 `0600` 暫存檔、原子 rename
寫入 Activity token、時間軸與播放錨點，啟動時重新投影時間並恢復下一個事件。加密
key 必須和 state file 分開保管，兩者不可提交到 repository 或備份成一般分析資料。
這提供單節點重啟續傳，不等於多節點共識或災難復原；仍應使用 process manager，
並遵守八小時 TTL、token rotation 與 DELETE 清理。

### 驗證

可先在 repository 根目錄驗證 relay 與腳本：

```sh
node --check Services/CaptionIslandPushServer/server.mjs
npm test --prefix Services/CaptionIslandPushServer
sh -n Scripts/verify-caption-island-push-signing.sh
```

安裝前再對最終 IPA 執行前述簽章腳本。安裝後，完整鏈路至少要依序看到：

1. App Log 出現 `Received a …-byte Live Activity push token`；
2. App Log 出現已向 AOD push relay 註冊 Activity；
3. Relay Log 出現該 Activity 的 `apns_accepted` 與 HTTP 200；
4. 裝置的 Live Activities 與「更頻繁更新」權限已允許。

以上只能證明 entitlement、token、relay 與 APNs 接受路徑完整。網路延遲、APNs budget、
使用者權限、低耗電模式及 iOS AOD 政策仍可能延遲或合併畫面更新，因此不能把 APNs
HTTP 200 解讀成逐句零延遲保證。

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
- 前景與 PiP／背景都保留 YouTube callback（Coordinator 最多接受約 5 Hz）；背景
  另外使用單一 0.75 秒 fallback 計時器並提供 0.15 秒系統容差，時間未改變時不提交
  任何字幕工作；
- Now Playing 的一般校正最多每 12 秒一次，播放／暫停或倍速狀態改變則立即更新，
  之後由 iOS 依 playback rate 自行推進時間；
- 不擷取音訊、不使用 CoreML，也不進行裝置端語音辨識或無聲音訊保活。

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
