# YouTube Diagnostics

YouTube Diagnostics 是獨立注入 uYouEnhanced／YouTube 的 Theos tweak，不依賴
Caption Island。安裝後可由「YouTube 設定 → Tweaks → YouTube 診斷記錄」進入
Universal Log 預覽。

它會即時記錄 YouTube HUD、播放器錯誤、播放器要求重載、Tap-to-Retry、記憶體警告
與前／背景切換，並列出目前載入的第三方 dylib。開啟診斷頁或按「擷取」時，才使用
`OSLogStore` 讀取目前 YouTube 程序的 Unified Logging，不建立常駐輪詢。

診斷記錄獨立存放於：

```text
Library/Caches/YouTubeDiagnostics/YouTubeDiagnostics.log
```

最多保存 2,000 筆／512 KB。寫入前會遮蔽 Cookie、授權資訊、Token、電子郵件、
裝置識別欄位與 URL query。iOS 仍可能依 Unified Logging 的 privacy／rotation
規則省略資料，因此這是「目前程序可讀取的 Log」加上關鍵播放器 hooks，而不是封包
側錄。
