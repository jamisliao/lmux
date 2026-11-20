# 手動驗證紀錄：Apple Liquid Glass 雙欄工作台與 Agent 遙測管線 (preview-liquid-glass)

- **日期**：2026-11-19
- **分支**：`feat/preview-liquid-glass`
- **正式 release bundle**：`App/build/lmux.app`（SDK 27.2，macOS 14.0+，`otool -l` 驗證 `sdk 27.2 minos 14.0`）
- **對照設計原型**：`preview-mockup.html`（淺色 High-Key Crystal 與深色 Obsidian Midnight）
- **自動化驗證矩陣**：
  - `swift test --package-path Core`：通過（125/125 案例，10 個測試套件）
  - `./beat/changes/preview-liquid-glass/dev.sh check`：通過（包含 Token 常數、WCAG AA 對比、App 測試與 Mockup 斷言）
  - `./App/scripts/apptest.sh --liquid-glass`：通過（68/68 Liquid Glass + 27/27 Workbench + 5/5 Restore）
  - `./App/scripts/bundle.sh`：通過（產出 `App/build/lmux.app`）

<!-- @feature: liquid-glass-app.feature -->
<!-- @scenario: 淺色與深色外觀具備 1:1 液態玻璃設計 Token 與無障礙對比 -->
<!-- @scenario: 玻璃背景顯示毛玻璃與高光邊緣，開啟減少透明度時切換為不透明實底 -->
<!-- @scenario: 系統開啟減少動態效果時縮短過渡並停止呼吸動畫 -->
<!-- @scenario: 標題列置中顯示目前 workspace 資訊膠囊與快速操作按鈕 -->
<!-- @scenario: 左側 workspace 卡片顯示彩色識別條與狀態藥丸並保留多選與排序 -->
<!-- @scenario: 中央終端窗格顯示圓角卡片、焦點光環與 Pane Tab Strip -->
<!-- @scenario: 透過快捷鍵與標題列／狀態列控制右側 Inspector 展開、收合與分頁切換 -->
<!-- @scenario: 右側 Inspector 即時預覽支援檔案切換、重整與雙軌開啟 -->
<!-- @scenario: 切換不同 workspace 時右側 Inspector 與底部狀態列同步切換上下文 -->
<!-- @scenario: 拖曳調整左右側邊欄、分割線、通知 bar 或視窗縮放期間啟動拖曳降級 -->
<!-- @scenario: 拖曳途中視窗或應用程式失去焦點時自動清除拖曳降級 -->
<!-- @feature: open-menu.feature -->
<!-- @scenario: ⌘-click 可預覽檔案的路徑跳出開啟選單 -->
<!-- @scenario: 選「在右側欄即時預覽」載入檔案至右側 Inspector -->
<!-- @scenario: 按住 ⌃⌘ 點擊可預覽檔案直接開成預覽 tab -->
<!-- @scenario: 不選任何項目就關掉選單 -->

---

## 逐項驗收與 1:1 原型對比表

| # | 驗收項目 | 對應功能與場景 | 檢核步驟 | 原型對齊與預期結果 | 檢核狀態 |
|---|---|---|---|---|---|
| 1 | **雙主題液態玻璃外觀與 WCAG AA 對比** | `liquid-glass-app.feature`<br>淺色與深色外觀具備 1:1 液態玻璃設計 Token 與無障礙對比 | 切換系統深色／淺色外觀（或設定 `LMUX_APPEARANCE=light`/`dark`）檢查整體介面色階 | 淺色 High-Key Crystal 通透高光、深色 Obsidian Midnight 沉穩透光；狀態藥丸文字對比 >= 4.5:1（run: 7.3/4.8、needs: 8.0/5.7、done: 5.5/5.4、idle: 7.9/5.0）；Diff 增刪色對比 >= 4.5:1；Footer 階層文字全數通過 AA | **通過** |
| 2 | **毛玻璃材質與減少透明度實底降級** | `liquid-glass-app.feature`<br>玻璃背景顯示毛玻璃與高光邊緣，開啟減少透明度時切換為不透明實底 | 1. 正常模式檢視 4 個面板背景<br>2. 系統偏好設定開啟「減少透明度」或觸發 `forceOpaque` | 正常模式下左側欄、標題列、右側欄、Footer 呈現 `NSVisualEffectView` 毛玻璃混合與 1pt 頂部高光亮邊；開啟減少透明度時即時切換為對應主題之不透明實底，材質圖層隱藏 | **通過** |
| 3 | **減少動態效果 (Reduce Motion) 降級** | `liquid-glass-app.feature`<br>系統開啟減少動態效果時縮短過渡並停止呼吸動畫 | 開啟系統「減少動態效果」或設 `c.reduceMotionOverride = true` | 呼吸動畫（Attention 綠色光環、Titlebar 狀態燈脈動、Footer 狀態點）全部停止靜態化；過渡動畫時長歸零 | **通過** |
| 4 | **統一玻璃標題列 (44pt) 與置中膠囊** | `liquid-glass-app.feature`<br>標題列置中顯示目前 workspace 資訊膠囊與快速操作按鈕 | 檢視標題列左右按鈕叢集與中央區域 | 左側包含紅黃綠燈、側邊欄切換鈕、鈴鐺（帶未讀紅點）、新增 workspace 鈕；中央懸浮置中資訊膠囊（含狀態燈、工作區名稱、Git 分支、短路徑）；右側包含分割按鈕與右側 Inspector 切換鈕 | **通過** |
| 5 | **左側工作區卡片、狀態藥丸、搜尋與通知列** | `liquid-glass-app.feature`<br>左側 workspace 卡片顯示彩色識別條與狀態藥丸並保留多選與排序 | 檢視左側邊欄各區塊渲染與滑鼠操作 | 工作區卡片左側垂直彩色識別條、右側狀態藥丸、最近訊息摘要與時間；支援 ⌘/⇧ 多選與拖曳排序；搜尋列呈微透膠囊；通知 bar 具備未讀紅點、收合切換與玻璃通知卡片（顯示分支） | **通過** |
| 6 | **中央分塊 10pt 圓角卡片與 Pane Tab Strip** | `liquid-glass-app.feature`<br>中央終端窗格顯示圓角卡片、焦點光環與 Pane Tab Strip | 建立水平／垂直分割，切換焦點與分頁 | 分割格具備 `10pt` 圓角卡片；當前聚焦格顯示藍色 `activePaneRing`（1.5pt），非聚焦格維持細邊框；頂部整合式 `30pt` 膠囊 Tab Strip（含狀態圓點、關閉、新增按鈕與右側向右／向下／關閉分塊按鈕） | **通過** |
| 7 | **右側 Inspector 三分頁導覽與寬度調整** | `liquid-glass-app.feature`<br>透過快捷鍵與標題列／狀態列控制右側 Inspector 展開、收合與分頁切換 | 1. 按 `⌥⌘B` 或點擊標題列/Footer 按鈕<br>2. 切換「即時預覽」、「變更 (Diff)」、「執行記錄」分頁<br>3. 拖曳手把調整寬度 | 展開收合順暢，寬度鉗製於 `240...500pt`；三分頁切換正常；切換離開預覽分頁時透過 `onLeavePreview()` 安全交還鍵盤焦點至終端機 | **通過** |
| 8 | **Inspector 即時預覽 (WKWebView) 與安全外開** | `liquid-glass-app.feature`<br>右側 Inspector 即時預覽支援檔案切換、重整與雙軌開啟 | 1. 點擊候選檔案 chip 或 ⌘-click<br>2. 點擊 `‹`、`›`、`↻`<br>3. 點擊 `↗` 外開 | 預覽位址列顯示目前檔名與 `LIVE` 徽章，瀏覽歷史可上一頁／下一頁／重整；點擊 `↗` 外開經 `GhosttyRuntime.openTerminalURL` 與 `UntrustedURLAlert` 規則嚴格保護，阻擋 `.sh`、`/dev/zero` 與不安全字元 | **通過** |
| 9 | **雙軌 OpenMenu、⌃⌘-click 與關閉還原焦點** | `open-menu.feature`<br>⌘-click 可預覽檔案的路徑跳出開啟選單<br>選「在右側欄即時預覽」載入檔案至右側 Inspector<br>按住 ⌃⌘ 點擊可預覽檔案直接開成預覽 tab<br>不選任何項目就關掉選單 | 1. ⌘-click 可預覽檔案路徑<br>2. 選擇「在右側欄即時預覽」<br>3. 按住 ⌃⌘-click 可預覽路徑<br>4. Esc / 點擊選單外取消 | 彈出 5 項選單首項為「在右側欄即時預覽」，選擇後展開右側 Inspector 預覽該檔案且中央分割維持不變；⌃⌘-click 直接於中央建立預覽 tab，stale pane 不誤觸發；Esc / 外點關閉選單且不開啟預覽、鍵盤焦點回到終端機 | **通過** |
| 10 | **Core Agent 遙測與背景 Git Diff 串流** | `liquid-glass-app.feature`<br>增量解析 Claude 與 Codex 對話紀錄取得模型、Turn 與 Token 用量<br>Hook 即時工具事件更新串流<br>Git Diff 服務讀取工作區統計 | 檢視「執行記錄」與「變更 (Diff)」分頁內容 | Context Window 儀表呈現已用/上限比例條與真實 4 項 API 統計；Tool Calls 串流分類圖示、參數摘要與耗時；Git Diff 呈現 Working Tree 分支統計、逐檔 Diff hunks，非 Git 目錄或乾淨工作樹呈現清楚空狀態 | **通過** |
| 11 | **全寬玻璃 WindowFooterView (32pt) 交互** | `liquid-glass-app.feature`<br>切換不同 workspace 時右側 Inspector 與底部狀態列同步切換上下文 | 點擊 Footer 各統計按鈕並切換 workspace | 左側顯示模型名、最新 Tool、Turn 數與 Metal 渲染器；中央顯示 Context 進度條與 `%`；右側顯示 Git 分支與加減行統計；點擊各區塊自動展開 Inspector 並跳轉對應分頁；切換 workspace 遙測與 Diff 同步重置/切換 | **通過** |
| 12 | **全面板拖曳降級 (isResizing) 與失焦安全復原** | `liquid-glass-app.feature`<br>拖曳調整左右側邊欄、分割線、通知 bar 或視窗縮放期間啟動拖曳降級<br>拖曳途中視窗或應用程式失去焦點時自動清除拖曳降級 | 拖曳左側欄、右側欄、通知 bar、分割線或視窗縮放，並在拖曳中按下 ⌘Tab 切換視窗或切離應用 | 拖曳啟動時 4 個 Backdrop（側欄、標題列、Inspector、Footer）同步進入 `isResizing` 不透明實底降級，完全消除 GPU 模糊負載維持 60fps；放開滑鼠或遇 `didResignKey`、`didResignActive` 自動清除降級並復原毛玻璃 | **通過** |
| 13 | **狀態持久化與重開還原** | `liquid-glass-app.feature` (E2E restore) | 調整右側欄寬度至 360pt、切換至 Diff 分頁、通知 bar 設為收合，重啟應用 | 經 `--liquid-glass-restore` 驗證：`inspectorVisible == true`、`inspectorWidth == 360`、`inspectorTab == .diff`、`BarLayout.isCollapsed == true`、`BarLayout.extra == 45` 100% 準確還原 | **通過** |
