<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
    <img src="assets/logo.svg" alt="lmux" width="240">
  </picture>
</p>

<h3 align="center">light mux.</h3>

<p align="center">
  輕巧的原生 macOS 終端機，讓你整天泡在 Claude Code 和 Codex 裡。
</p>

<p align="center">
  <a href="https://github.com/sooftware/lmux/releases/latest/download/lmux-arm64.dmg">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="assets/download-macos-dark.svg">
      <img src="assets/download-macos.svg" alt="下載 macOS 版 App" width="146" height="60">
    </picture>
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.ko.md">한국어</a> | <a href="README.zh-CN.md">简体中文</a> | 繁體中文 | <a href="README.ja.md">日本語</a> | <a href="README.es.md">Español</a> | <a href="README.de.md">Deutsch</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.ru.md">Русский</a> | <a href="README.tr.md">Türkçe</a> | <a href="README.vi.md">Tiếng Việt</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-2E3440?logo=apple&logoColor=white" alt="macOS 14+">
  <img src="https://img.shields.io/badge/built%20on-libghostty-5E81AC" alt="built on libghostty">
  <a href="https://github.com/sooftware/lmux/releases/latest"><img src="https://img.shields.io/github/v/release/sooftware/lmux?label=release&color=88C0D0" alt="latest release"></a>
  <img src="https://img.shields.io/badge/license-MIT-A3BE8C" alt="MIT">
</p>

<p align="center">
  <code>brew install --cask sooftware/tap/lmux</code> · macOS 14+, Apple silicon
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/hero/hero-dark.webp">
    <img src="assets/hero/hero-light.webp" alt="lmux：側邊欄有五個工作區，各自處在不同狀態（執行中、完成、需要輸入、失敗、等你處理）；在分割畫面裡輸入 prompt，Claude Code 和 Codex 左右並排在跑" width="900">
  </picture>
</p>

---

最近用終端機工作的時候，腦中突然冒出一個念頭。

*終端機什麼時候變得這麼重了？真的有必要這麼重嗎？*

現在的終端機 app 動不動就內建瀏覽器、SSH 工作區，連 PR 徽章都有。功能這麼多，會變重也很正常。AI 讓我的工作方式變了很多，但對我來說，終端機就只是一個讓文字一來一往的畫面。我個人不會在裡面開瀏覽器，也不用 SSH 工作區。設定我也很少動，幾乎都用預設。真要說哪裡不一樣，就是以前我只開一個終端機，現在則是同時開很多個 session，跟好幾個 AI agent 邊聊邊做事。可是 app 卻為了那些我根本用不到的功能越變越重，讓人心煩的小事也越積越多。所以我做了 **lmux**：把用不到的功能拿掉，只留下真正需要的，再補上幾個我一直想要的東西。

## 特色

- **輕。**<br>
  整個 app 25 MB，不管開一個工作區還是二十個，閒置 CPU 都接近 0%。用原生 Swift 寫，底層是 libghostty，沒有 Electron、沒有瀏覽器引擎，設定也只有十個左右。

- **關掉、更新、重開機，全部都會回來。**<br>
  工作區、分割畫面、資料夾都會原樣還原，每個 Claude Code 或 Codex session 也會從上次停下的地方繼續。上禮拜關掉的？在 History（`⇧⌘H`）找到就能叫回來。

- **一眼看出哪個 agent 在等你。**<br>
  狀態直接來自 Claude Code 的 hooks 和 Codex 本身，分成執行中、需要你、完成、失敗。窗格外框會亮一圈、側邊欄那一列會出現徽章，每個事件只通知一次；按 `⇧⌘J` 就跳到在等你的那個。其他 agent 只要輸出一個 escape sequence 也能接進來。lmux 不會把 `claude` 或 `codex` 包一層，只在旁邊聽。

- **把 prompt 收回來。**<br>
  Enter 按下去才看到送進了哪個窗格，心裡只有一句：「靠北。」這時把滑鼠移到那一輪對話上按 `×`，Claude 就會倒回送出之前，不用重開，就當沒發生過。按 `✎` 也一樣會倒回，只是會把 prompt 放回輸入框，讓你改好再送。（僅限 Claude Code。）

  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/gifs/forget-x-dark.webp">
    <img src="assets/gifs/forget-x-light.webp" alt="在送錯的 prompt 上按 ×，prompt 和 Claude 的回覆一起消失" width="700">
  </picture>

- **把 cmux 的設定帶過來。**<br>
  主題、字型、快捷鍵，連開著的工作區和分割畫面，點一下就全部搬過來，裡面的 Claude 和 Codex session 也會接著跑。就跟換新瀏覽器時從 Chrome 匯入書籤一樣。後悔了就按 Undo Import，全部還原。

- **韓文輸入直接就能用。**<br>
  我自己是韓國開發者，這項算是私心。打字時不會掉字、也不會組錯字，韓文剛好佔兩格寬。日文和中文（注音、拼音）也[做了一樣的處理](https://lmux.dev/docs/korean-input/#chinese-and-japanese-input)：組字時游標會顯示在正在組的字裡面，方向鍵交給輸入法處理，`⌃C` 照樣是 Ctrl+C。[한국어로 보기 →](https://lmux.dev/docs/ko/)

另外還有每個窗格都能開分頁、沿用 Claude Code 的 session 標題、26 種主題、複製成 Markdown 等等，其他的請看 **[全部功能](docs/features.md)**。

## 安裝

### 下載

<a href="https://github.com/sooftware/lmux/releases/latest/download/lmux-arm64.dmg">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/download-macos-dark.svg">
    <img src="assets/download-macos.svg" alt="下載 macOS 版 App" width="146" height="60">
  </picture>
</a>

打開 .dmg，把 lmux.app 拖進「應用程式」。zip 和舊版本都在 [GitHub Releases](https://github.com/sooftware/lmux/releases)。

### Homebrew

```sh
brew install --cask sooftware/tap/lmux
```

需要 Apple silicon 的 Mac、macOS 14 以上。想自己從原始碼編譯，請看 [App/README.md](App/README.md)。

文件：[lmux.dev/docs](https://lmux.dev/docs/)

## 使用方式

**第一次啟動。** 如果你之前用過 cmux，lmux 會先問要不要把設定和開著的工作區搬過來。接著問要不要裝幾個 Claude Code hooks，而且在動 `settings.json` 之前，會先把完整的 diff 給你看。兩個都同意之後，隨便在一個窗格執行 `claude`，側邊欄就會開始顯示哪個 agent 在跑、哪個跑完了、哪個在等你。

**Codex 也一樣。** 有裝 Codex CLI 的話，lmux 接著會用同樣的方式問你要不要裝 Codex hooks（這次改的是 `~/.codex/hooks.json`，一樣會先給你看 diff）。Codex 下次啟動時會問一次要不要信任新的 hooks，選 **Trust all and continue** 就好。

**日常操作。** 下面是預設快捷鍵。Ghostty 設定檔裡的 `keybind` 會蓋過這些設定，選單上顯示的一律是實際綁定的鍵。

| 要做的事                                      | 按鍵                                             |
|-----------------------------------------------|--------------------------------------------------|
| 新增工作區                                    | `⌘N`                                             |
| 向右 / 向下分割                               | `⌘D` / `⇧⌘D`                                     |
| 關閉分頁 / 工作區                             | `⌘W` / `⇧⌘W`，或滑鼠移到那一列上按 `×`          |
| 在窗格裡開新分頁                              | `⌘T`                                             |
| 切換分頁                                      | `⇧⌘[` / `⇧⌘]`，`⌃1`–`⌃8`，`⌃9` 跳到最後一個      |
| 切換工作區                                    | `⌘1`–`⌘8`，`⌘9` 跳到最後一個，`⌃⌘[` / `⌃⌘]`     |
| 調整工作區順序                                | 拖曳那一列                                       |
| 在窗格之間移動                                | `⌘[` / `⌘]`                                      |
| 放大目前的窗格（隱藏其他）                    | `⇧⌘↩`                                            |
| 跳到需要你的 agent                            | `⇧⌘J`                                            |
| 最新未讀 / 最近的通知                         | `⇧⌘U` / 點鈴鐺                                   |
| 手動重設某一列的狀態                          | 按右鍵，再選 **Clear Status**                    |
| 搜尋過去的 session                            | `⇧⌘H`                                            |
| 複製 / 編輯後重送 / 移除某一輪對話            | 滑鼠移上去，再按 `⧉` / `✎` / `×`                 |
| 把最後一則回覆複製成 Markdown                 | `⌥⌘C`                                            |
| 收回剛送出的 prompt                           | 「Sent to …」提示還在時按 `⌘Z`                  |
| 搜尋終端機的歷史輸出                          | `⌘F`                                             |
| 顯示 / 隱藏側邊欄                             | `⌃⌘S`                                            |
| 主題、字型等其他設定                          | `⌘,`                                             |

Agent 外框提示、History、收回對話和韓文輸入的 GIF 短片，都在[導覽](docs/tour.md)裡。

## lmux vs cmux

兩個 app 裝在同一台 Mac 上，各開 1、10、20 個工作區（每個工作區 2 個執行中的 shell），然後放著不動。數字越低越好。lmux 不在最前面時會釋放 GPU 記憶體，所以分兩種情況量：在前景，以及被其他 app 蓋住、待在背景。詳細的測量方法寫在 [BENCH.md](scripts/BENCH.md)。

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/bench-scaling-dark.svg">
    <img src="assets/bench-scaling.svg" alt="1、10、20 個工作區下的記憶體與閒置 CPU：lmux 在前景時為 182、207、235 MB，CPU 0.1%；lmux 在背景時為 45、71、99 MB，CPU 0.0%；cmux 0.65.2 為 398、548、661 MB，CPU 7.2、7.4、8.1%" width="760">
  </picture>
</p>

|                          | cmux 0.65.2 | lmux（前景）   | lmux（背景）            |
|--------------------------|------------:|---------------:|------------------------:|
| App 大小                 | 242 MB      | **25 MB**      | **25 MB**               |
| 記憶體（1 個工作區）     | 398 MB      | **182 MB**     | **45 MB**               |
| 記憶體（10 個工作區）    | 548 MB      | **207 MB**     | **71 MB**               |
| 記憶體（20 個工作區）    | 661 MB      | **235 MB**     | **99 MB**               |
| 閒置 CPU（1 個工作區）   | 7.16 %      | **0.07 %**     | **0.00 %**              |
| 閒置 CPU（10 個工作區）  | 7.39 %      | **0.12 %**     | **0.00 %**              |
| 閒置 CPU（20 個工作區）  | 8.10 %      | **0.10 %**     | **0.00 %**              |
| 設定選項                 | ~200        | **~10**        | **~10**                 |

<sub>M4 Pro，macOS 26.6.2，lmux 0.0.102 vs. cmux 0.65.2。每個工作區 2 個窗格，所有 shell 都在執行，交錯跑 5 輪取中位數。記憶體是 app 所有處理程序的實體記憶體用量（physical footprint）；app 大小是 Apple silicon 版 `.app` 在磁碟上的大小。測試期間螢幕是鎖定的，所以 cmux 也在背景。它的記憶體會隨視窗狀態大幅變動，數字請當成單次快照參考就好。窗格裡跑的 shell 和 agent 兩邊都一樣，沒有算進去，這裡量的只有終端機本身吃掉的資源。lmux 在不同工作區數量下 0.07–0.12 % 的差距，落在每次測量的正常誤差範圍內。</sub>

我最在意的是閒置 CPU。二十個 agent 停在那邊等你看它們寫了什麼的時候，耗你電池的就是這個。

**什麼情況下不適合用 lmux？**

- 你會用到 cmux 的內建瀏覽器、SSH 工作區、port 和 PR 小工具、自訂指令，或是需要比 `lmux send` 和 `lmux new-workspace` 更多的腳本功能。
- 你需要 Linux 或 Windows。
- 你就是想要一堆可以調的選項。cmux 大概有兩百個。

那就用 cmux 吧。它很棒，我也會繼續跟它學。

## 參與貢獻

每個改動都要符合下面這幾條：

- **輕量優先。** 如果一個功能主要只是讓 app 變重，就算「有也不錯」，還是會砍掉。讓閒置 CPU 超出預算的 PR，CI 會直接擋下來。
- **絕不把 `claude` 包一層**（`codex` 也是）。lmux 透過 hooks 和 agent 本來就會寫的檔案來監聽，所以不管有沒有 lmux，它們的行為都一模一樣。就連 `✎`、`×` 和 `⌘Z` 也不會去改 session：它們是在執行中的 `claude` 裡操作 Claude Code 自己的 rewind 選單，所以什麼都不用重開。
- **介面要安靜。** 一個事件只發一則通知（可以再加一次提醒），每一列只有一個狀態標示；除非真的需要你處理，不然什麼都不會閃。

從修錯字到整個模組都歡迎，只要符合上面的規則就好。怎麼建置、怎麼跑測試、哪些功能不收，請看 [CONTRIBUTING.md](CONTRIBUTING.md)。想加新功能的話，請先開 issue。

## FAQ

**這是 cmux 的 fork 嗎？**
> 不是。想法一樣、範圍比較小，從零開始寫，MIT 授權，repo 裡沒有任何 cmux 的程式碼。詳細可以看 [lmux 和 cmux 的差異](https://lmux.dev/docs/vs-cmux/)。

**為什麼不用 Ghostty 加 tmux 就好？**
> 用 cmux 之前我就是這樣用，這個組合也不錯。但有三件事它做不到：側邊欄看得出哪個 agent 在等你、送出去的 prompt 能收回來、重開後 Claude 和 Codex 的 session 會自己接回來。lmux 基本上就是 libghostty 再加這三樣。

**支援 Codex 嗎？**
> 支援。Codex CLI 一樣有狀態、通知、重開後恢復、它自己的 session 標題、History 和複製成 Markdown。編輯、移除和收回剛送出的 prompt，只有 Claude Code 能用。Codex 會問一次要不要信任 lmux 的 hooks（「Trust all and continue」），在你同意之前，它就照常跑，只是沒有 hooks。

**其他 agent 呢？Linux 呢？**
> 什麼 CLI 都能在裡面跑。恢復 session、History 和滑鼠移上去才會出現的那些按鈕，是針對我每天泡在裡面的 Claude Code 和 Codex 做的；其他 agent 只要像 Codex 一樣，用一個 escape sequence（OSC 7501）回報狀態，就能有狀態顯示和通知：由 `my-agent` 自己輸出 `printf '\e]7501;state=blocked:app=my-agent\e\\'` 就行（[作法](docs/agents.md#any-agent-osc-7501)）。Linux 和 Windows 不會支援。lmux 是建在 libghostty 上的原生 AppKit app，要移植的話等於是另一個 app。

**會偷偷連網嗎？**
> 不會。lmux 完全不連網路：沒有遙測、沒有當機回報，連檢查更新都沒有（那是 Homebrew 的事）。它在磁碟上寫了哪些東西、要怎麼刪乾淨，都寫在[功能頁的其中一段](docs/features.md#what-does-lmux-write-to-disk-and-how-do-i-remove-it)。

更多問題請見 [FAQ](https://lmux.dev/docs/faq/)。

## 致謝

- [Ghostty](https://github.com/ghostty-org/ghostty) 和 libghostty，最難的部分都是它們做的
- [cmux](https://github.com/manaflow-ai/cmux)，lmux 借用的概念和版面配置都來自它


<p align="center">
  如果你曾用 lmux 把送錯窗格的 prompt 收回來，按個 Star 吧，讓更多人能找到這個專案。<br><br>
  <a href="https://github.com/sooftware/lmux"><img src="https://img.shields.io/github/stars/sooftware/lmux?style=social" alt="在 GitHub 上幫 lmux 按個 Star"></a>
</p>

<sub>MIT 授權。與 cmux、Ghostty、Anthropic 或 OpenAI 沒有任何關係，提到它們的名字只是為了說明 lmux 能搭配什麼使用。第三方授權條款在 <a href="App/THIRD_PARTY_NOTICES.md">THIRD_PARTY_NOTICES</a>，lmux.app 裡也附了一份。</sub>
