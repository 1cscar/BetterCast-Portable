# BetterCast Portable G2-A · Mac 擷取與編碼效能

**G2-A FAIL，尚未達到 4K 持續 60 個唯一影格／秒。** 4K H.264 的編碼延遲已改善，Mac 回歸及故障測試通過。

## 基準與測試環境

Mac16,13（Apple M4），macOS 26.7.2（25G320），Xcode 27.2。工作從 `portable` 的 `4edd108` 開始。G0 PASS，G1 BLOCKED，等待實體 Windows 的解碼、呈現和桌面恢復驗收。

G1 的 Mac 本機 TCP 回環基準如下。G2 的單參數比較以本輪重新量測的對照組為準，因為兩輪的觀測事件與系統負載不同。

| 模式 | G1 擷取／編碼／接收 FPS | G1 擷取至編碼 P95 |
| --- | ---: | ---: |
| 1080p H.264 | 43.62 | 13.19 ms |
| 1440p H.264 | 44.13 | 19.38 ms |
| 4K HEVC | 46.48 | 23.15 ms |
| 4K H.264 | 42.10 | 75.61 ms |

## 如何量測

每組在第一個動態畫面事件後暖機 5 秒，分析接著 60 秒內擷取的 PTS，並追蹤這批影格直到本機接收。AppKit 在每個更新重新填滿視窗並繪製遞增編號。Metal 診斷另外以整個 drawable 的移動圖案與編號標記產生影格。Metal 與 AppKit 的內容不同，兩者用於定位合成與呈現階段，各項擷取及編碼設定的對照維持相同 AppKit 工作負載。原始記錄及本機 bitstream 位於 Git 忽略的建置目錄。

- **畫面產生與刷新。** 記錄 AppKit 更新觸發、繪製完成和繪製耗時。`CGDisplayCopyDisplayMode` 確認獨立虛擬顯示器的實際解析度及 60 Hz 模式。`NSScreen.displayLink` 記錄刷新時間和主執行緒收到回呼的時間。Metal 診斷以 `MTLDrawable.presentedTime` 記錄測試 drawable 的呈現，並另記未呈現的 drawable。公開 API 沒有提供所有 AppKit 交易被 WindowServer 合成的逐幀計數器，AppKit 完成重繪和顯示連結回呼也無法證明每次都有新合成畫面。[Metal 呈現時間](https://developer.apple.com/documentation/metal/mtldrawable/presentedtime)
- **ScreenCaptureKit。** 記錄實際配置、完整樣本、idle、blank、其他狀態、dirty rect 數量和首張 buffer 的格式、尺寸、平面與 IOSurface。以 `CMClockMakeHostTimeFromSystemUnits` 轉換 `displayTime`，計算可觀測樣本的畫面節奏。回呼時間減去 `displayTime` 保留正負號，虛擬顯示器的實測值有些早於該顯示時間，不能當成純擷取排隊時間。[SCFrameStatus](https://developer.apple.com/documentation/screencapturekit/scframestatus) · [displayTime](https://developer.apple.com/documentation/screencapturekit/scstreamframeinfo/displaytime)
- **VideoToolbox。** 在同一個 PTS 記錄提交、API 返回、輸出回呼、access unit 完成、keyframe 和錯誤。以已提交且未回呼的影格估算在途數，這是應用程式可觀測的上限，無法區分硬體內部的轉換、排隊和壓縮時間。Session 建立時要求硬體加速，再讀回 encoder ID 和硬體旗標。屬性 `set` 的 OSStatus 與讀回值均保留在日誌。[VideoToolbox 壓縮屬性](https://developer.apple.com/documentation/videotoolbox/compression-properties)
- **傳輸與唯一性。** 記錄 AES-GCM、TCP 提交及本機完成，並以接收端驗證的 PTS 比對。另將驗證過的 access unit 在量測後離線解碼，以逐幀像素雜湊數出唯一畫面。接收 FPS、唯一 PTS 與唯一畫面各自列出。未改寫來源 PTS，也未使用補幀。
- **資源。** 每兩秒採樣 Mac Host 和本機接收器的 `ps` CPU、RSS，並採樣 IORegistry 的 GPU 使用率及顯示記憶體。CPU 和 RSS 分屬程序，GPU 為整機採樣，涵蓋其他視窗與程式，且無法拆出 VideoToolbox 媒體引擎的獨立忙碌率。

```sh
PORTABLE_BUILD_DIR=.build/g2/matrix PORTABLE_RECORD_BITSTREAM=1 ./scripts/build-portable-host.sh --matrix
PORTABLE_BUILD_DIR=.build/g2/matrix PORTABLE_RECORD_BITSTREAM=1 PORTABLE_MATRIX_RESUME=1 ./scripts/build-portable-host.sh --matrix
python3 -B scripts/portable-smoke/verify_pixels.py .build/g2/matrix/<case-directory>
```

第一條執行整個矩陣，第二條跳過已有成功摘要的案例。選配位元流記錄與 FFmpeg 離線驗證不影響接收協議。對照組及單參數案例的原始 `host-*.csv`、`loopback.csv`、`summary.txt`、`*-loopback.log` 和 `matrix.tsv` 位於 `.build/g2/matrix/`。

## 單參數矩陣

對照使用 60 Hz 獨立顯示器、`minimumFrameInterval=1/60`、`queueDepth=3`、8-bit video-range NV12 IOSurface、20 Mb/s VideoToolbox 目標位元率、`RealTime=true`、禁止重排序、請求 `MaxFrameDelayCount=1` 及兩秒 keyframe 間隔。每個變體只改該列所列參數。兩組不同 codec 的對照分開列出。表中 FPS 依擷取／編碼／接收排列。

| 模式與改動 | FPS | 擷取至編碼 P50／P95 | VT 在途峰值 | 接收 Mb/s |
| --- | ---: | ---: | ---: | ---: |
| 1080p H.264 對照 | 37.97／37.97／37.97 | 7.88／14.47 ms | 1 | 2.01 |
| 1080p 擷取間隔 `0` | 40.17／40.17／40.17 | 8.25／14.44 ms | 2 | 2.09 |
| 1080p 顯示連結觸發 AppKit 重繪 | 42.40／42.40／42.40 | 11.01／11.89 ms | 1 | 2.17 |
| 1080p 佇列深度 5 | 42.63／42.63／42.63 | 9.76／13.75 ms | 1 | 2.11 |
| 1080p 擷取間隔 `1/120` | 48.90／48.90／48.90 | 11.19／13.81 ms | 2 | 2.44 |
| 1440p H.264 對照 | 46.15／46.15／46.15 | 11.25／18.42 ms | 2 | 1.70 |
| 4K HEVC 對照 | 42.38／42.38／42.38 | 15.65／19.81 ms | 2 | 2.98 |
| 4K H.264 對照 | 43.10／43.10／43.10 | 40.41／69.34 ms | 3 | 2.99 |
| 4K H.264 低延遲率控制 | 48.25／48.23／48.23 | 17.20／22.23 ms | 1 | 6.72 |
| 4K H.264 優先編碼速度 | 46.33／46.33／46.33 | 50.89／73.35 ms | 3 | 3.29 |
| 4K H.264 請求 `MaxFrameDelayCount=0` | 46.23／46.23／46.23 | 51.04／73.28 ms | 3 | 3.29 |
| 4K H.264 佇列深度 5 | 47.10／47.10／47.10 | 50.57／73.88 ms | 4 | 3.36 |
| 4K H.264 BGRA IOSurface | 47.73／47.73／47.73 | 52.15／75.03 ms | 4 | 3.40 |
| 4K H.264 `RealTime=false` | 47.68／47.68／47.68 | 17.71／20.43 ms | 2 | 3.41 |
| 4K H.264 一秒 keyframe | 46.73／46.73／46.73 | 50.72／73.35 ms | 3 | 3.83 |
| 4K H.264 允許重排序 | 重跑 70.26 秒僅收到 1 張，影格數不足 | — | — | — |
| 1080p Metal 診斷（不同測試畫面） | 約 15 秒後傳輸停滯斷線 | — | — | — |

第一批 1080p 四組由 `4edd108` 加上尚未提交的觀測程式建置，執行檔 SHA-256 留在 `.build/g2/matrix/initial-binary-sha256.txt`。後續矩陣由 `052db85` 建置。所有有效案例均保有完整 60 秒資料。基準與調整組各自只代表一次量測，系統 GPU 負載會隨時間改變。例同一套 1080p H.264 擷取和編碼參數，對照與預設重跑分別為 37.97 和 48.37 FPS。因此不能把 FPS 的跨輪差異直接歸因於單一參數。

原始 Metal 診斷共收到 847 個完整擷取樣本，最早至最晚樣本相隔 14.97 秒，送出前背壓略過 653 張。Metal 回報 888 個零 `presentedTime`。完成送出的影格中，編碼至主佇列開始加密最慢 4.28 秒，TCP 提交至本機完成最慢 1.94 ms。該結果定位到主佇列延遲，亦顯示此虛擬顯示器未提供可靠的 Metal 呈現時間，故這組不能用作穩態 FPS。

## 已定位的瓶頸

1080p 對照的 AppKit 重繪和顯示連結都約 60 次／秒，完整樣本只有 37.97 FPS。完整樣本的 `displayTime` 間隔 P50 及 P95 都是 33.33 ms。此組編碼在途峰值為 1，沒有編碼後遺失或傳輸背壓。缺口已定位在 AppKit 重繪完成至 ScreenCaptureKit 完整樣本交付之間。調整擷取間隔及測試重繪節奏會改變結果。公開事件不足以判定 WindowServer 是否合併了部分交易，或是擷取排程跳過了部分更新。這份資料無法把全部缺口歸給其中一方。

4K H.264 則另有明確的編碼延遲。AVE 硬體 encoder 讀回 `RealTime=1`、重排序關閉，卻在本次對照保留最多三張待輸出的影格。提交至輸出 P95 為 69.15 ms，幾乎等於完整擷取至編碼 P95 69.34 ms。改 BGRA 未縮短延遲，增加擷取佇列深度亦未縮短延遲。`MaxFrameDelayCount` 的 1 和 0 均被 encoder 以 `-12900` 拒絕，不能把該列的 FPS 變動解讀成配置生效。BGRA 與 NV12 均實際輸出同尺寸 IOSurface，應用程式沒有額外像素格式轉換，硬體內部的轉換時間不可單獨觀測。

請求低延遲率控制改選 `com.apple.videotoolbox.videoencoder.h264.rtvc`，在途峰值降至一張，P50 由 40.41 降至 17.20 ms，P95 由 69.34 降至 22.23 ms，分別下降約 57.4% 和 67.9%。完整擷取提高約 12.0%，仍少於 60。此模式成功以要求硬體加速的設定建立，硬體旗標讀回不支援，Apple 說明其 H.264 低延遲模式使用硬體 encoder。此組仍觀察到 60 秒 30 張 keyframe。RTVC 產生的接收資料由 2.99 增至 6.72 Mb/s，區網效能仍需驗證。[Apple 低延遲硬體編碼說明](https://developer.apple.com/videos/play/wwdc2021/10158/)

`RealTime=false` 在單次 AVE 比較得到 20.43 ms P95、17.71 ms P50，資料量較少，仍有兩張在途，主程序 CPU 和 RSS 高於 RTVC。Portable 對 4K H.264 優先採用 RTVC，因為它保留即時模式且在途峰值最低。如果低延遲 session 無法建立或準備完成，會重試標準硬體 H.264。非 4K H.264 使用既有 AVE 路徑。接收端仍可選用 HEVC。Mac 上 HEVC 對照的 P95 是 19.81 ms，實體 Windows 的 HEVC 硬體解碼與相對延遲待 G1 驗收。

| 4K 編碼設定 | Host CPU 中位／峰值 | Host RSS 中位／峰值 | 整機 GPU 中位／峰值 |
| --- | ---: | ---: | ---: |
| H.264 AVE | 18.9%／26.6% | 68.3／89.3 MiB | 59%／73% |
| H.264 RTVC | 9.5%／18.4% | 74.4／76.6 MiB | 68%／81% |
| H.264 AVE，`RealTime=false` | 15.9%／19.3% | 95.5／98.3 MiB | 34%／42% |
| HEVC AVE | 13.8%／18.0% | 65.5／67.6 MiB | 71%／76% |

## 預設設定重跑

`2478435` 的 Mac Host 建置與簽章通過，四種預設模式各重跑 5 秒暖機及 60 秒穩態。擷取仍使用 `1/60`、深度 3、NV12，4K H.264 優先用 RTVC。四組從完整擷取到接收均沒有遺失的 PTS。

| 模式 | 擷取／編碼／接收 FPS | 擷取至編碼 P50／P95 | 擷取至本機接收 P50／P95 | 接收 Mb/s | VT 在途峰值 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1080p H.264 | 48.37／48.37／48.37 | 7.33／13.58 ms | 7.66／13.96 ms | 2.24 | 1 |
| 1440p H.264 | 46.05／46.05／46.05 | 12.34／22.78 ms | 12.67／23.34 ms | 1.64 | 2 |
| 4K HEVC | 42.92／42.92／42.92 | 13.95／20.46 ms | 14.34／20.99 ms | 3.07 | 3 |
| 4K H.264 | 44.10／44.10／44.10 | 17.29／23.14 ms | 17.71／23.63 ms | 6.44 | 1 |

4K H.264 預設重跑的 P95 比本輪 AVE 對照低 66.6%，FPS 高約 2.3%。與 G1 舊量測相比，P95 從 75.61 ms 降為 23.14 ms，FPS 從 42.10 增為 44.10。後者為歷史參考，兩輪觀測程式和負載不同。預設重跑的 Host CPU 中位／峰值為 9.1%／16.7%，RSS 為 70.6／72.3 MiB，整機 GPU 為 73%／86%。

```sh
export PORTABLE_BUILD_DIR=.build/g2/final
export PORTABLE_RECORD_BITSTREAM=1
./scripts/build-portable-host.sh
./scripts/build-portable-host.sh --steady
PORTABLE_BUILD_DIR="$PORTABLE_BUILD_DIR/regression" ./scripts/build-portable-host.sh --loopback
PORTABLE_BUILD_DIR="$PORTABLE_BUILD_DIR/faults" ./scripts/build-portable-host.sh --faults
```

FFmpeg 將每組實際收到的位元流解碼成原解析度畫面。先確認整個位元流的解碼畫面數與驗證過的接收 PTS 數相同，再按呈現順序對應至正式 60 秒區間。四組正式區間的解碼畫面數與唯一像素雜湊數分別為 2,902／2,902、2,763／2,763、2,575／2,575、2,646／2,646。四組均沒有重複像素雜湊，唯一畫面 FPS 與表中的接收 FPS 相同。標準 4K H.264 對照也驗證 2,586 張皆唯一，為 43.10 FPS。`ffprobe` 確認預設 4K RTVC 為 3840×2160 H.264 High，`has_b_frames=0`。離線解碼時間不計入 Mac 即時鏈路延遲。

各輪的原始 trace、資源採樣、建立虛擬顯示器及 encoder 屬性讀回皆位於 `.build/g2/final/`。[程式提交的 Windows CI](https://github.com/1cscar/BetterCast-Portable/actions/runs/42496061305)

額外三組在預設編碼設定上只將擷取間隔改成 `1/120`，仍使用相同 60 Hz 顯示模式。以下與預設重跑對比，這個參數未成為預設。

| 模式 | 預設 FPS | `1/120` FPS | `1/120` 擷取至編碼 P50／P95 |
| --- | ---: | ---: | ---: |
| 1080p H.264 | 48.37 | 36.95 | 8.56／11.16 ms |
| 4K HEVC | 42.92 | 36.52 | 15.02／25.11 ms |
| 4K H.264 RTVC | 44.10 | 46.38 | 17.15／23.19 ms |

`1/120` 在先前 1080p 矩陣曾量到 48.90 FPS，此次交叉量測是 36.95。4K H.264 的 46.38 FPS 也在兩次 `1/60` RTVC 量測的 44.10 至 48.25 FPS 之間。系統和畫面交付時序的變動足以覆蓋這個參數的效果，4K HEVC 該次的 FPS 也下降約 14.9%。因此維持 `1/60`、深度 3 與 NV12。原始資料在 `.build/g2/headroom/`。

## 主佇列與獨立畫面來源交叉驗證

將 Metal drawable 取得和提交移到有界的獨立佇列後，以 `e95d013` 重跑 1080p。60 秒內收到 3,600 次顯示連結及 3,557 次 Metal 提交，43 次因 render queue 忙碌而略過。ScreenCaptureKit 有 3,386 張完整樣本、7 次 idle，擷取／編碼／接收均為 56.43 FPS。離線解碼確認 3,386 張皆有不同的像素雜湊。擷取至編碼 P50／P95 為 6.23／11.17 ms，編碼至 TCP 提交 P95 為 0.16 ms。未重現前次主佇列停滯，也沒有擷取後遺失的 PTS。這個動態來源的內容與 AppKit 不同，因此 56.43 FPS 用於確認同一套擷取設定能隨來源提高交付速度，不用於宣稱 AppKit 的 FPS 改善比例。

該次 3,557 個 Metal drawable 回呼仍回傳零 `presentedTime`。可量測的是實際 GPU 提交、刷新回呼、SCK 完整樣本和收到的影格。這些資料仍不足以取得 WindowServer 對每筆提交的獨立合成時間。

重排序也以 `e95d013` 重跑。AVE 讀回重排序開啟與 `MaxFrameDelayCount=3`。只收到 4 張完整擷取樣本，其中 1 張即時輸出並送達，另外 3 張直到約第 70 秒的停止流程才回呼。沒有傳輸背壓事件。此結果與重排序保留輸入、在深度 3 的串流上形成阻塞相符，但 VideoToolbox 未公開 IOSurface 的個別保留時間。重跑的錯誤明確是影格數不足，沒有證據顯示重複 PTS。

同一程式提交完成 macOS Host 建置與簽章、四種模式短回歸，以及六組故障回歸。故障涵蓋錯誤配對碼、配對碼過期、等待核准逾時、Host 停止、TCP reset 與關窗。短回歸第一次編譯和診斷檔修改重疊，已重新建置後全部通過。日誌在 `.build/g2/final/build-current.log`、`regression.log` 及 `faults.log`。

額外以 `e95d013` 執行同樣 Metal 來源的 4K HEVC 診斷。60 秒有 2,592 次 GPU 提交、1,001 次 render queue 忙碌、2,484 張完整擷取。擷取／編碼／接收是 41.40／41.37／41.37 FPS，擷取至編碼 P50／P95 是 13.12／21.19 ms，接收影像資料量為 18.90 Mb/s。這組較重的 4K 畫面在擷取前就未能每次刷新提交。兩張完整樣本未送達，Metal 呈現時間仍全部為零。原始記錄在 `.build/g2/metal-4k/`。

```sh
PORTABLE_BUILD_DIR=.build/g2/headroom PORTABLE_EXPERIMENT=production-headroom PORTABLE_RECORD_BITSTREAM=1 \
  ./scripts/build-portable-host.sh --steady 4k-h264
PORTABLE_BUILD_DIR=.build/g2/metal-4k PORTABLE_EXPERIMENT=metal-motion PORTABLE_RECORD_BITSTREAM=1 \
  ./scripts/build-portable-host.sh --steady 4k-hevc
```

## 尚需硬體驗證

- 實體 Windows 的 H.264 High／HEVC 硬體解碼與實際 DXGI 呈現。Mac 回環的接收時間與離線解碼無法量到遠端顯示延遲。G1 持續 BLOCKED。
- 其他 Mac 型號的 RTVC 可用性與 4K 幀率。測試機能建立 RTVC，標準硬體 H.264 已獨立跑過對照，但本機未觸發 RTVC 不可用後的自動回退。
- 跨 Mac 型號與不同實際桌面負載下的合成／擷取邊界，以及裝置層媒體引擎與 IOSurface 佇列觀測。這些是追查 60 FPS 缺口和判斷 4K HEVC 是否較適合特定 Mac／Windows 組合所需的資料。
