# 右側 Inspector 即時預覽與分割預覽 Tab 雙軌並存

在 **右側 Inspector** 加入「即時預覽」分頁並將終端機 `⌘-click` 開啟選單的第一項設為「在右側欄即時預覽」，同時保留 `Pane.Content.preview` 作為中央分割格內的獨立 **預覽 tab**（包含 `⌃⌘`-click 直接開分頁）。之所以不廢除其中一方，是因為日常檢查文件或 UI 產出時停留在右側欄不打斷終端機版面，而並排比對多份文件或全螢幕檢視時仍需獨立分割分頁；兩者共用 `PreviewView`、`PreviewScheme` 與相同的本機存取安全規則。

## Considered Options

- **全數改開在右側 Inspector、移除預覽 tab**：破壞既有 `preview-tab` 分割移動與並排閱讀工作流。
- **只留分割預覽 tab、右側 Inspector 不做預覽**：無法滿足不更動分割版面的即時側欄預覽體驗，與 `preview-mockup.html` 不一致。

來源：`beat/changes/preview-liquid-glass/design.md`（2026-11-18）。
