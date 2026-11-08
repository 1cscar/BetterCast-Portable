# BetterCast Portable · G1 實機驗收

G1 需要實體 Windows x64 在標準使用者帳號下，顯示同一個 Mac 的獨立延伸桌面。實機畫面和本機鍵鼠操作需要人工確認，Windows trace 另需提供 Media Foundation 解碼輸出和 DXGI `Present` 回傳值。

## 結論

**G1 BLOCKED，等待實機結果。** 已確認有操作者能接觸實體 Windows 與 Mac，並提供同提交產物及配對步驟。驗收記錄尚未取得該 Windows 的機型、版本、GPU、標準帳號執行結果、目視同一延伸工作階段的確認或實機 trace。實體 Windows 的解碼 FPS、DXGI Present 與桌面恢復尚未取得證據。GitHub Windows runner 僅提供建置和啟動回歸。

## 基準回歸

2026-11-08，Mac16,13（Apple M4），macOS 26.7.2（25G320），Xcode 27.2。開始時本機和遠端皆為 `eee2712b063d0031761e750fa04f8ee4e415e156`，工作目錄乾淨。

- `./scripts/build-portable-host.sh` 建置成功。`./scripts/build-portable-host.sh --loopback` 四組成功。包含啟動的短區間接收結果為 1080p H.264 51.5、1440p H.264 52.6、4K HEVC 39.2、4K H.264 44.3 FPS。每組都驗證核准後才建立 60 Hz 延伸顯示器，TCP 關閉後移除顯示器及恢復普通視窗可見。
- 手動重新觸發的 [基準 Windows CI](https://github.com/1cscar/BetterCast-Portable/actions/runs/42454220915) 通過，`headSha` 與基準 Mac 回歸一致。CI 查驗 x64 建置、`asInvoker`、EXE 啟動、顯示模式查詢、H.264 MFT 啟用及 AES-GCM 篡改拒絕。

## 重現實機驗收

1. 從相同提交建置 Mac Host 和 Windows x64 Portable EXE。Actions 產物附 `SOURCE-COMMIT.txt`。Windows 從標準使用者可寫入的資料夾解壓並執行，保留原有管理及應用程式執行政策。
2. 在 Mac Terminal 從 repository 根目錄啟動記錄版。

   ```sh
   ./scripts/build-portable-host.sh
   open -na '.build/portable-host/BetterCast Portable Host.app' \
     --args --trace-dir "$PWD/.build/g1/physical"
   ```

3. 在 Windows 的解壓資料夾開啟 PowerShell。記錄機型、OS、GPU、螢幕模式和帳號類型。以下查詢和啟動都可以使用標準帳號。

   ```powershell
   Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer,Model,SystemType
   Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber
   Get-CimInstance Win32_VideoController | Select-Object Name,DriverVersion,CurrentHorizontalResolution,CurrentVerticalResolution,CurrentRefreshRate
   Start-Process -FilePath (Resolve-Path .\BetterCastPortableReceiver.exe) -ArgumentList '--trace'
   ```

4. 讓兩台設備在可互通的 LAN 上。Windows 選 H.264 與 `Cap at 1080p`，輸入 Mac 區網 IPv4 和新配對碼。確認 Windows 等待核准時沒有顯示 Mac 畫面，在 Mac 人工按 **Approve extension**。在 Mac 把普通視窗拖到延伸區，操作視窗並確認 Windows 全螢幕顯示同一工作階段。Windows F2 顯示 RX、Decode、Present。
5. 按 Mac Host 的 **Start 72-second test motion**。在這段時間讓測試視窗留在延伸顯示器。72 秒結束後按 Windows Esc，確認恢復 Windows 桌面、Mac 移除虛擬顯示器、原本的普通視窗仍在既有 Mac 顯示器上可見。
6. 每個異常案例產生新的配對碼。分別測試關閉 Windows Receiver、Windows 網路中斷、Mac 按 Stop、錯誤配對碼、等待 Mac 核准逾時及未使用的配對碼逾時。記錄兩端訊息和回收時間。先完成 H.264 1080p，再按實體螢幕及 GPU 支援測試 1440p、4K 和 HEVC。

Windows trace 位於 `%TEMP%\BetterCastPortable-*.csv`，按 Esc 或 Stop 並等待收尾後取用。Mac 的 `host-*.csv` 位於指定資料夾。兩份 CSV 都只記錄狀態、時間和計數，無畫面、位址或配對碼。

```sh
python3 scripts/portable-smoke/analyze.py /path/to/host-session.csv /path/to/windows-session.csv
```

## 量測定義

- 以第一筆實際重繪為起點，排除 5 秒暖機，測量接下來 60 秒內擷取到的影格。以媒體 PTS 配對擷取、編碼、TCP、接收、解碼及呈現。影片資料沒有加入重複影格，只有獨立的加密心跳。
- Mac 記錄完整 ScreenCaptureKit 樣本、idle 通知、編碼前背壓略過、VideoToolbox 實際輸出與本機 TCP 寫入時間。缺少後一階段的 PTS 有獨立計數。60 Hz 為 CoreGraphics 實際啟用的顯示模式。
- Windows `decoded` 來自實際 Media Foundation 輸出 sample。`present` 僅計 `Present(0, 0)` 回傳 `S_OK`，另記其他 HRESULT。成功回傳代表應用程式提交呈現，實機面板是否顯示相同視窗由人工確認。
- 兩台機器的 monotonic clock 沒有共同原點。TCP 跨機延遲只報相對該次最低觀察值的超額，包含 Windows 讀取執行緒排程。P50/P95 的 Windows 接收至解碼、解碼至 Present 和 Mac 擷取至編碼則各自在本機時鐘計算。Mac loopback 可直接量到同一時鐘的擷取至接收，該測試沒有 Windows 解碼或 DXGI 階段。

## 同提交驗證及穩態結果

受測程式提交為 `5b202477513f19aaeff9f0ecf22695f3ffab6c39`。Mac Host 建置及 ad-hoc 簽章檢查成功，Mac trace 的 commit 與 [Windows x64 CI](https://github.com/1cscar/BetterCast-Portable/actions/runs/42455094917) 的 `headSha` 及 [產物](https://github.com/1cscar/BetterCast-Portable/actions/runs/42455094917/artifacts/13607193379) 的 `SOURCE-COMMIT.txt` 相符。EXE SHA-256 為 `b40bb04960fa9a1bfcfbb85ae277701c7bb6bf60b1bc1256c058a246f4e260d4`。

執行指令如下。各案例循序執行，使用臨時 TCP port 跑真實 Mac 顯示器、ScreenCaptureKit、硬體 VideoToolbox 和加密 TCP。

```sh
export PORTABLE_BUILD_DIR=.build/g1/5b20247
./scripts/build-portable-host.sh
./scripts/build-portable-host.sh --steady
PORTABLE_BUILD_DIR="$PORTABLE_BUILD_DIR/regression" ./scripts/build-portable-host.sh --loopback
PORTABLE_BUILD_DIR="$PORTABLE_BUILD_DIR/faults" ./scripts/build-portable-host.sh --faults
```

| 解析度 | 編碼 | 重繪／SCK idle 通知 | 擷取／編碼／接收 FPS | 擷取→編碼 P50／P95 | 擷取→本機接收 P50／P95 | 影像 Mb/s |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 1920 × 1080 | H.264 | 3584／346 | 43.62／43.62／43.62 | 8.43／13.19 ms | 8.81／14.07 ms | 3.44 |
| 2560 × 1440 | H.264 | 3600／460 | 44.13／44.13／44.13 | 12.38／19.38 ms | 12.83／19.99 ms | 2.89 |
| 3840 × 2160 | HEVC | 3600／381 | 46.48／46.48／46.48 | 15.51／23.15 ms | 15.99／23.74 ms | 4.14 |
| 3840 × 2160 | H.264 | 3600／534 | 42.10／42.10／42.10 | 50.05／75.61 ms | 50.68／76.91 ms | 4.64 |

四種模式均為獨立 60 Hz 顯示器。完整擷取樣本分別為 2617、2648、2789、2526 幀，全部可配對至編碼與接收，背壓略過和提交後未收到均為 0。重繪、idle 通知與完整樣本各自是不同事件，差值不能直接當作網路丟幀。Mac 停止擷取及編碼清理在發出停止要求後約 192–389 ms 完成，四份 trace 在完成標記後都沒有擷取回呼。原始 CSV、摘要與完整日誌在本機 `.build/g1/5b20247/`。

早期長測的圖層顏色計時器持續執行，卻出現長段沒有完整樣本；該次約 14.83 FPS 只用於診斷。測試已改成使用 AppKit 逐次實際重繪變色與遞增編號，並在重繪時記錄活動。四組新長測都沒有重現該段停頓，實際擷取仍低於 60 FPS。

### 退出與故障回歸

| 案例 | Mac 回環觀察 | 實體 Windows |
| --- | --- | --- |
| 正常 TCP 關閉 | 四種模式均移除獨立顯示器，普通測試視窗回到既有顯示器且可見 | 待實測 |
| Mac Stop | 有影格後按 Stop，收到 EOF，顯示器移除，測試視窗可見 | 待實測 |
| 接收端 TCP reset | 真實 TCP 以 RST 關閉，Mac 移除顯示器且測試視窗可見 | 待測物理網路中斷或靜默失聯 |
| 關閉 Mac 測試視窗 | 關窗後工作階段仍存活，接收端稍後關閉可正常回收 | 待測 Windows Receiver 關窗與原桌面恢復 |
| 錯誤碼 | AES-GCM 驗證拒絕，無核准請求、無延伸顯示器 | 待實測 |
| 配對碼過期 | 過期後 listener 關閉，舊碼無法建立連線 | 待實測 |
| Mac 核准逾時 | 加密回傳逾時，未建立顯示器 | 待實測 |

自動測試用兩秒時限重現過期和核准逾時，產品預設分別為 300 與 30 秒。RST 是 TCP 層的異常終止，未驗證實體網卡拔除時的靜默黑洞。Mac 四種模式短測與六個故障案例皆通過。

### 修復與邊界

- `7c4c0cd` 使停止流程先等 ScreenCaptureKit 啟動工作結束，再停止串流並序列化清理 encoder。Mac 的 TCP 重傳逾時和 keepalive 探針有明確上限。原 v1 加密封包格式維持相容。
- `7c4c0cd` 新增同 PTS 的 Host 和 Receiver trace，Windows F2 分開顯示接收、解碼和成功 Present。`5b20247` 改善長測的真實畫面重繪並修正 trace 分析的 PTS 交集。
- G2 需要以實體 Windows trace 量測解碼與呈現、定位 4K H.264 編碼延遲、加入跨機時鐘校準與面板延遲驗證。G3 需要在此基線上驗證公開節點配對及 ICE/NAT 直連，並在不同網路重跑相同量測。
