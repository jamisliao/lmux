<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
    <img src="assets/logo.svg" alt="lmux" width="240">
  </picture>
</p>

<h3 align="center">light mux.</h3>

<p align="center">
  轻量的原生 macOS 终端，给整天泡在 Claude Code 和 Codex 里的人用。
</p>

<p align="center">
  <a href="https://github.com/sooftware/lmux/releases/latest/download/lmux-arm64.dmg">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="assets/download-macos-dark.svg">
      <img src="assets/download-macos.svg" alt="下载 macOS 版应用" width="146" height="60">
    </picture>
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.ko.md">한국어</a> | 简体中文 | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ja.md">日本語</a> | <a href="README.es.md">Español</a> | <a href="README.de.md">Deutsch</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.ru.md">Русский</a> | <a href="README.tr.md">Türkçe</a> | <a href="README.vi.md">Tiếng Việt</a>
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
    <img src="assets/hero/hero-light.webp" alt="lmux：侧边栏五个工作区，状态各不相同（运行中、已完成、等你输入、已失败、等待中）；左右分屏开着 Claude Code 和 Codex，正在输入消息" width="900">
  </picture>
</p>

---

前阵子用终端写代码的时候，脑子里突然冒出一个念头。

*终端什么时候变得这么重了？真有必要这么重吗？*

现在的终端应用，浏览器、SSH 工作区，连 PR 角标都往里塞。功能这么多，重一点也正常。AI 确实让我的工作方式变了不少，但对我来说，终端说到底也就是个收发文字的窗口。浏览器也好，SSH 工作区也好，我自己都不在终端里用。设置我也基本不碰，默认值用到底。真要说有什么变化，就是以前开一个终端就够了，现在是开好几个会话，同时跟一堆 AI agent 边聊边干活。可应用却因为那些我根本用不上的功能越来越重，烦人的小地方也越攒越多。所以我做了 **lmux**：用不上的功能统统砍掉，只留真正需要的，再补上那些我一直觉得缺的。

## 亮点

- **轻。**<br>
  应用本体只有 25 MB；不管开 1 个还是 20 个工作区，空闲 CPU 都接近 0%。原生 Swift + libghostty，不套 Electron，不塞浏览器内核，设置就十来项。

- **退出、更新、重启，现场都还在。**<br>
  工作区、分屏、工作目录原样恢复，每个 Claude Code 和 Codex 会话也会从上次停下的地方接着跑。上周关掉的会话？History（`⇧⌘H`）里搜一下就能找回来。

- **一眼看出哪个 agent 在等你。**<br>
  四种状态（运行中、等你输入、完成、失败）直接从 Claude Code 的 hooks 和 Codex 自己上报的事件里来。窗格边框会亮起来，侧边栏对应条目有角标，一个事件只提醒一次，按 `⇧⌘J` 直接跳到在等你的那个。别的 agent 想接进来，输出一条转义序列就行。lmux 不给 `claude` / `codex` 套壳，只在旁边听着。

- **发错了？撤回。**<br>
  回车一按，才发现发错窗格了，心里一句“卧槽”。鼠标移到那条消息上点 `×`，Claude 就回到这条消息发出前的状态，不用重启，就当没发过。`✎` 也一样会回退，但会把消息放回输入框，让你改完再发。（目前只支持 Claude Code。）

  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/gifs/forget-x-dark.webp">
    <img src="assets/gifs/forget-x-light.webp" alt="在发错的消息上点 ×，这条消息和 Claude 的回复一起消失" width="700">
  </picture>

- **cmux 的配置一键搬过来。**<br>
  主题、字体、快捷键，连开着的工作区和分屏都一起搬，里面的 Claude 和 Codex 会话也接着跑。跟换浏览器时从 Chrome 导入书签一个道理。后悔了？点 Undo Import 全部还原。

- **韩文输入直接能用。**<br>
  我是韩国开发者，这条算私心。打字时不会丢字、乱字，韩文固定占两格宽。日文和中文（拼音、注音）也[做了同样的处理](https://lmux.dev/docs/korean-input/#chinese-and-japanese-input)：光标就显示在正在拼的字里，方向键交给输入法，`⌃C` 也还是 Ctrl+C。[한국어로 보기 →](https://lmux.dev/docs/ko/)

另外还有窗格内标签页、Claude Code 会话标题同步、26 套主题、复制为 Markdown 等，完整列表见 **[全部功能](docs/features.md)**。

## 安装

### 下载

<a href="https://github.com/sooftware/lmux/releases/latest/download/lmux-arm64.dmg">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/download-macos-dark.svg">
    <img src="assets/download-macos.svg" alt="下载 macOS 版应用" width="146" height="60">
  </picture>
</a>

打开 .dmg，把 lmux.app 拖进“应用程序”。zip 和旧版本在 [GitHub Releases](https://github.com/sooftware/lmux/releases)。

### Homebrew

```sh
brew install --cask sooftware/tap/lmux
```

只支持 Apple Silicon（M 系列）的 Mac，系统要 macOS 14 及以上。想自己编译的看 [App/README.md](App/README.md)。

文档：[lmux.dev/docs](https://lmux.dev/docs/)

## 用法

**第一次启动。** 之前用过 cmux？lmux 会先问你要不要把配置和开着的工作区搬过来。然后问要不要装几个 Claude Code hooks，改之前会先给你看 `settings.json` 的 diff。两个都选“是”，随便在哪个窗格里跑一下 `claude`，侧边栏上就能看到哪个 agent 在跑、哪个跑完了、哪个在等你。

**Codex 也一样。** Mac 上装了 Codex CLI 的话，lmux 接着会用同样的方式问要不要装 Codex 的 hooks（这次改的是 `~/.codex/hooks.json`）。Codex 下次启动会问一次要不要信任新 hooks，选 **Trust all and continue** 就行。

**常用快捷键。** 下面是默认快捷键。如果你在 Ghostty 配置里用 `keybind` 改过，以菜单里显示的为准。

| 操作                                          | 快捷键                                           |
|-----------------------------------------------|--------------------------------------------------|
| 新建工作区                                    | `⌘N`                                             |
| 向右 / 向下分屏                               | `⌘D` / `⇧⌘D`                                     |
| 关闭标签页 / 工作区                           | `⌘W` / `⇧⌘W`，或鼠标移到侧边栏条目上点 `×`       |
| 在当前窗格新建标签页                          | `⌘T`                                             |
| 切换标签页                                    | `⇧⌘[` / `⇧⌘]`，`⌃1`–`⌃8`，`⌃9` 跳到最后一个      |
| 切换工作区                                    | `⌘1`–`⌘8`，`⌘9` 跳到最后一个，`⌃⌘[` / `⌃⌘]`     |
| 调整工作区顺序                                | 拖动侧边栏条目                                   |
| 切换窗格                                      | `⌘[` / `⌘]`                                      |
| 最大化当前窗格（隐藏其他）                    | `⇧⌘↩`                                            |
| 跳到在等你的 agent                            | `⇧⌘J`                                            |
| 跳到最新未读 / 查看最近通知                   | `⇧⌘U` / 点铃铛图标                               |
| 手动清除某个工作区的状态                      | 右键 → **Clear Status**                          |
| 搜索历史会话                                  | `⇧⌘H`                                            |
| 复制 / 编辑重发 / 删除某条消息                | 鼠标移到消息上点 `⧉` / `✎` / `×`                 |
| 把最后一条回复复制成 Markdown                 | `⌥⌘C`                                            |
| 撤回刚发出的消息                              | “Sent to …”提示还在时按 `⌘Z`                    |
| 搜索终端输出                                  | `⌘F`                                             |
| 显示 / 隐藏侧边栏                             | `⌃⌘S`                                            |
| 设置（主题、字体等）                          | `⌘,`                                             |

边框状态提示、History、撤回消息、韩文输入的动图演示见[功能演示](docs/tour.md)。

## lmux vs cmux

同一台 Mac 装两个应用，分别开 1、10、20 个工作区（每个工作区 2 个运行中的 shell），然后放着不动。数值越小越好。lmux 切到后台时会释放 GPU 内存，所以测了两遍：一遍前台、一遍后台。测试方法见 [scripts/BENCH.md](scripts/BENCH.md)。

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/bench-scaling-dark.svg">
    <img src="assets/bench-scaling.svg" alt="1、10、20 个工作区下的内存与空闲 CPU：前台 lmux 为 182、207、235 MB，CPU 0.1%；后台 lmux 为 45、71、99 MB，CPU 0.0%；cmux 0.65.2 为 398、548、661 MB，CPU 7.2、7.4、8.1%" width="760">
  </picture>
</p>

|                          | cmux 0.65.2 | lmux（前台）   | lmux（后台）            |
|--------------------------|------------:|---------------:|------------------------:|
| 应用体积                 | 242 MB      | **25 MB**      | **25 MB**               |
| 内存（1 个工作区）       | 398 MB      | **182 MB**     | **45 MB**               |
| 内存（10 个工作区）      | 548 MB      | **207 MB**     | **71 MB**               |
| 内存（20 个工作区）      | 661 MB      | **235 MB**     | **99 MB**               |
| 空闲 CPU（1 个工作区）   | 7.16 %      | **0.07 %**     | **0.00 %**              |
| 空闲 CPU（10 个工作区）  | 7.39 %      | **0.12 %**     | **0.00 %**              |
| 空闲 CPU（20 个工作区）  | 8.10 %      | **0.10 %**     | **0.00 %**              |
| 设置项                   | ~200        | **~10**        | **~10**                 |

<sub>M4 Pro，macOS 26.6.2，lmux 0.0.102 对比 cmux 0.65.2。每个工作区 2 个窗格，所有 shell 都在跑，5 轮交替测量取中位数。内存是应用全部进程的物理内存占用；应用体积是磁盘上 Apple Silicon 版 `.app` 的体积。测的时候屏幕锁着，所以 cmux 也在后台，而它的内存随窗口状态起伏很大，那一列只能算某一刻的快照。窗格里跑的 shell 和 agent 两边一样，没算进去，这里只算终端自己的开销。lmux 在不同工作区数量下 0.07–0.12 % 的差异属于正常波动。</sub>

我最在意的数字是空闲 CPU：二十个 agent 干完活挂在那等你看，这期间耗电的就是它。

**什么情况下别用 lmux？**

- 你在用 cmux 的内置浏览器、SSH 工作区、端口面板、PR 面板、自定义命令，或者写脚本光靠 `lmux send` 和 `lmux new-workspace` 不够用。
- 你要 Linux 或 Windows。
- 你就喜欢选项多。cmux 有两百来个。

那就继续用 cmux，它确实好用，我也一直拿它当参照。

## 参与贡献

每个改动都要过一遍这几条规则：

- **轻量优先。** 一个功能如果带来的主要是负担，再好用也砍。空闲 CPU 超预算的 PR，CI 直接不给过。
- **不给 `claude` 套壳**（`codex` 也一样）。lmux 只通过 hooks 和 agent 本来就会写的文件来监听，所以装不装 lmux，agent 的行为都完全一样。连 `✎`、`×` 和 `⌘Z` 也不改会话文件：它们只是在运行中的 `claude` 里调出 Claude Code 自带的 rewind 菜单来操作，什么都不用重启。
- **界面不吵。** 一个事件一条通知（外加一条可选提醒），每个条目一个状态标记，不是真有事找你，就不会闪。

只要符合上面这几条，改个错别字也好，加个模块也好，都欢迎。怎么构建、怎么测、哪些功能不收，见 [CONTRIBUTING.md](CONTRIBUTING.md)。新功能请先开 issue 聊聊。

## FAQ

**是 cmux 的 fork 吗？**
> 不是。思路一样，但范围小得多，从零写的，MIT 协议。仓库里没有一行 cmux 的代码。具体区别见 [lmux 与 cmux 对比](https://lmux.dev/docs/vs-cmux/)。

**Ghostty + tmux 不够吗？**
> 用 cmux 之前我就是这么用的，挺好。但有几样它做不到：在侧边栏一眼看出哪个 agent 在等你、消息发错能撤回、重启后 Claude 和 Codex 会话自动恢复。lmux 基本就是 libghostty 加这三样。

**支持 Codex 吗？**
> 支持。Codex CLI 同样有状态显示、通知、重启后恢复、会话标题、History 和复制为 Markdown。编辑、删除和撤回目前只支持 Claude Code。Codex 会问一次要不要信任 lmux 的 hooks（“Trust all and continue”），同意之前它照常运行，只是 hooks 不生效。

**其他 agent？Linux？**
> 什么 CLI 都能在里面跑。恢复、History 和消息上的悬停按钮是为 Claude Code 和 Codex 做的，我整天就泡在这两个里。不过任何 agent 只要像 Codex 那样上报自己的状态，也能用上状态显示和通知。上报很简单，让 agent 自己输出一条转义序列（OSC 7501）就行，比如在 `my-agent` 里执行 `printf '\e]7501;state=blocked:app=my-agent\e\\'`（[具体做法](docs/agents.md#any-agent-osc-7501)）。Linux 和 Windows 不做。lmux 是基于 libghostty 的原生 AppKit 应用，移植就等于重写。

**会偷偷联网吗？**
> 不会。lmux 完全不发网络请求：不收集任何数据，没有崩溃上报，连检查更新都没有（那是 Homebrew 的事）。它往磁盘写了什么、怎么删干净，[功能页里一段话就写清楚了](docs/features.md#what-does-lmux-write-to-disk-and-how-do-i-remove-it)。

更多问题见 [FAQ](https://lmux.dev/docs/faq/)。

## 致谢

- [Ghostty](https://github.com/ghostty-org/ghostty) 和 libghostty，最难啃的骨头都是它们啃的
- [cmux](https://github.com/manaflow-ai/cmux)，lmux 的思路和布局都是跟它学的


<p align="center">
  如果你用 lmux 撤回过发错窗格的消息，点个 Star 吧，能让更多人发现这个项目。<br><br>
  <a href="https://github.com/sooftware/lmux"><img src="https://img.shields.io/github/stars/sooftware/lmux?style=social" alt="在 GitHub 上给 lmux 点个 Star"></a>
</p>

<sub>MIT 协议。与 cmux、Ghostty、Anthropic、OpenAI 无关，提及它们仅为说明兼容性。第三方许可见 <a href="App/THIRD_PARTY_NOTICES.md">THIRD_PARTY_NOTICES</a>，lmux.app 里也带了一份。</sub>
