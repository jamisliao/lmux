<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
    <img src="assets/logo.svg" alt="lmux" width="240">
  </picture>
</p>

<h3 align="center">light mux.</h3>

<p align="center">
  Claude Code と Codex に一日中入り浸るための、軽量なネイティブ macOS ターミナル。
</p>

<p align="center">
  <a href="https://github.com/sooftware/lmux/releases/latest/download/lmux-arm64.dmg">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="assets/download-macos-dark.svg">
      <img src="assets/download-macos.svg" alt="macOS 版アプリをダウンロード" width="146" height="60">
    </picture>
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.ko.md">한국어</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | 日本語 | <a href="README.es.md">Español</a> | <a href="README.de.md">Deutsch</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.ru.md">Русский</a> | <a href="README.tr.md">Türkçe</a> | <a href="README.vi.md">Tiếng Việt</a>
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
    <img src="assets/hero/hero-light.webp" alt="lmux：サイドバーに 5 つのワークスペースがあり、それぞれ状態が違う（実行中、完了、入力待ち、失敗、確認待ち）。Claude Code と Codex を左右に並べたスプリットでプロンプトを入力しているところ" width="900">
  </picture>
</p>

---

この前、ターミナルで作業していて、ふとこう思った。

*ターミナルって、いつからこんなに重くなったんだろう？ そもそも、ここまで重い必要ってある？*

最近のターミナルアプリには、ブラウザも SSH ワークスペースも、PR バッジまで入っている。これだけ機能があれば、重くなるのも無理はない。AI のおかげで仕事のやり方はずいぶん変わった。それでも僕にとって、ターミナルは今でもテキストをやりとりするだけの画面だ。少なくとも僕は、ブラウザも SSH ワークスペースも、ターミナルの中で使うことはない。設定もデフォルトのまま、ほとんどいじらない派だ。違うのは、前はターミナルをひとつ開いておけば足りたのに、今はいくつものセッションで AI エージェントと同時に話しながら仕事をしていることくらいだ。なのに、使いもしない機能のせいでアプリはどんどん重くなって、細かいイライラも少しずつ増えていった。だから、使わない機能は削って、本当に必要なものとずっと欲しかったものだけを詰めた **lmux** を作った。

## 特徴

- **軽い。**<br>
  アプリは 25 MB で、ワークスペースが 1 つでも 20 個でもアイドル時の CPU はほぼ 0%。libghostty ベースのネイティブ Swift アプリなので、Electron もブラウザエンジンも積んでいない。設定項目は 10 個くらいしかない。

- **終了しても、アップデートしても、再起動しても元どおり。**<br>
  ワークスペースもスプリットもフォルダもそのまま戻ってきて、Claude Code や Codex のセッションも中断したところから再開する。先週閉じたセッションも、History（`⇧⌘H`）で探せば復活できる。

- **どのエージェントが自分を待っているか分かる。**<br>
  ステータス（実行中、入力待ち、完了、失敗）は Claude Code の hooks と Codex 本体から直接受け取る。ペインにはリング、サイドバーの行にはバッジが付き、通知はイベントごとに 1 回だけ。待たせているエージェントには `⇧⌘J` で飛べる。他のエージェントも、エスケープシーケンスを 1 つ出すようにすれば仲間に入れる。lmux は `claude` も `codex` もラップせず、横で様子を見ているだけだ。

- **送ったプロンプトを取り消せる。**<br>
  Enter を押した瞬間に送り先のペインが目に入って、「うわ、やべぇ」。そんなときはそのターンにカーソルを乗せて `×` を押せば、Claude がその直前まで巻き戻る。再起動もなしで、なかったことにできる。`✎` も同じように巻き戻したうえで、プロンプトを入力欄に戻してくれるので、直してから送り直せる（Claude Code のみ）。

  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/gifs/forget-x-dark.webp">
    <img src="assets/gifs/forget-x-light.webp" alt="うっかり送ったプロンプトの × を押すと、そのプロンプトと Claude の返答が消える" width="700">
  </picture>

- **cmux の環境をそのまま持ってこられる。**<br>
  テーマ、フォント、ショートカットはもちろん、開いているワークスペースやスプリットまでワンクリックで移せて、中の Claude や Codex のセッションもそのまま再開する。新しいブラウザに Chrome のブックマークをインポートするのと同じ感覚だ。やっぱりやめたくなったら、Undo Import で全部元に戻せる。

- **韓国語入力がちゃんと動く。**<br>
  僕は韓国の開発者なので、ここは譲れなかった。入力中に文字が消えたり崩れたりしないし、ハングルはきっちり 2 セル幅で表示される。日本語と中国語（ピンイン、注音）の入力にも[同じように手を入れた](https://lmux.dev/docs/korean-input/#chinese-and-japanese-input)。変換中の文字の中にキャレットが出るし、矢印キーは IME 側で効くし、`⌃C` もちゃんと Ctrl+C として届く。[한국어로 보기 →](https://lmux.dev/docs/ko/)

ほかにもペインごとのタブ、Claude Code のセッションタイトル表示、26 種類のテーマ、Markdown 形式でのコピーなどがある。残りは **[機能一覧](docs/features.md)** にまとめてある。

## インストール

### ダウンロード

<a href="https://github.com/sooftware/lmux/releases/latest/download/lmux-arm64.dmg">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/download-macos-dark.svg">
    <img src="assets/download-macos.svg" alt="macOS 版アプリをダウンロード" width="146" height="60">
  </picture>
</a>

.dmg を開いて、lmux.app を「アプリケーション」フォルダにドラッグする。zip や過去のバージョンは [GitHub Releases](https://github.com/sooftware/lmux/releases) にある。

### Homebrew

```sh
brew install --cask sooftware/tap/lmux
```

macOS 14 以降、Apple silicon の Mac で動く。ソースからビルドする場合は [App/README.md](App/README.md) を参照。

ドキュメント：[lmux.dev/docs](https://lmux.dev/docs/)

## 使い方

**初回起動。** cmux を使っていたなら、まず設定と開いているワークスペースを持ってくるか聞かれる。次に Claude Code の hooks をいくつか入れるか聞かれ、`settings.json` を書き換える前に、どこがどう変わるかを diff で見せてくれる。どちらも yes にして、どこかのペインで `claude` を起動すれば、どのエージェントが実行中で、どれが終わって、どれが自分待ちなのかがサイドバーに出るようになる。

**Codex も。** Codex CLI が入っていれば、続けて Codex の hooks も同じ流れで入れるか聞かれる（今度の diff は `~/.codex/hooks.json` が対象）。Codex は次の起動時に、新しい hooks を信頼するか一度だけ聞いてくるので、**Trust all and continue** を選べばいい。

**普段使い。** 下のキーはデフォルト。Ghostty の設定に `keybind` を書いていればそちらが優先され、メニューには実際に割り当てたキーが表示される。

| やりたいこと                                  | キー                                             |
|-----------------------------------------------|--------------------------------------------------|
| 新しいワークスペース                          | `⌘N`                                             |
| 右 / 下にスプリット                           | `⌘D` / `⇧⌘D`                                     |
| タブ / ワークスペースを閉じる                 | `⌘W` / `⇧⌘W`、またはカーソルを乗せた行の `×`     |
| ペインに新しいタブ                            | `⌘T`                                             |
| タブを切り替え                                | `⇧⌘[` / `⇧⌘]`、`⌃1`–`⌃8`、最後のタブは `⌃9`      |
| ワークスペースを切り替え                      | `⌘1`–`⌘8`、最後は `⌘9`、`⌃⌘[` / `⌃⌘]`           |
| ワークスペースを並べ替え                      | 行をドラッグ                                     |
| ペイン間を移動                                | `⌘[` / `⌘]`                                      |
| フォーカス中のペインをズーム（他を隠す）      | `⇧⌘↩`                                            |
| 自分を待っているエージェントに飛ぶ            | `⇧⌘J`                                            |
| 最新の未読 / 最近の通知                       | `⇧⌘U` / ベルをクリック                           |
| 行のステータスを手動でリセット                | 右クリックして **Clear Status**                  |
| 過去のセッションを検索                        | `⇧⌘H`                                            |
| ターンをコピー / 編集して再送 / 削除          | カーソルを乗せて `⧉` / `✎` / `×`                 |
| 最後の返答を Markdown でコピー                | `⌥⌘C`                                            |
| 送ったばかりのプロンプトを取り消す            | "Sent to …" トーストが出ている間に `⌘Z`         |
| スクロールバック内を検索                      | `⌘F`                                             |
| サイドバーの表示 / 非表示                     | `⌃⌘S`                                            |
| テーマ、フォント、その他                      | `⌘,`                                             |

エージェントのリング、History、ターンの取り消し、韓国語入力の様子は、短い GIF にして [ツアー](docs/tour.md) に置いてある。

## lmux vs cmux

同じ Mac で両方のアプリを起動し、ワークスペースを 1・10・20 個（どれもシェルが 2 つ動いている状態）開いて放置した。数字は小さいほど良い。lmux は前面にいないときに GPU メモリを解放するので、前面にあるときと、別のアプリの裏に回したときの 2 パターンで測った。詳しくは [測定方法](scripts/BENCH.md) を参照。

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/bench-scaling-dark.svg">
    <img src="assets/bench-scaling.svg" alt="ワークスペース 1・10・20 個でのメモリとアイドル時 CPU：前面の lmux は 182、207、235 MB で CPU 0.1%、バックグラウンドの lmux は 45、71、99 MB で CPU 0.0%、cmux 0.65.2 は 398、548、661 MB で CPU 7.2、7.4、8.1%" width="760">
  </picture>
</p>

|                          | cmux 0.65.2 | lmux（前面）   | lmux（バックグラウンド） |
|--------------------------|------------:|---------------:|------------------------:|
| アプリサイズ             | 242 MB      | **25 MB**      | **25 MB**               |
| メモリ（1 ワークスペース）   | 398 MB      | **182 MB**     | **45 MB**               |
| メモリ（10 ワークスペース）  | 548 MB      | **207 MB**     | **71 MB**               |
| メモリ（20 ワークスペース）  | 661 MB      | **235 MB**     | **99 MB**               |
| アイドル CPU（1 ワークスペース）  | 7.16 %      | **0.07 %**     | **0.00 %**              |
| アイドル CPU（10 ワークスペース） | 7.39 %      | **0.12 %**     | **0.00 %**              |
| アイドル CPU（20 ワークスペース） | 8.10 %      | **0.10 %**     | **0.00 %**              |
| 設定項目                 | ~200        | **~10**        | **~10**                 |

<sub>M4 Pro、macOS 26.6.2、lmux 0.0.102 vs cmux 0.65.2。ワークスペースごとにペイン 2 つで、シェルはすべて稼働中。5 回交互に実行した中央値。メモリはアプリの全プロセスの物理フットプリント、アプリサイズはディスク上の Apple silicon 版 `.app` のサイズ。計測中は画面をロックしていたので、cmux もバックグラウンドの状態だった。cmux のメモリはウィンドウの状態でかなり上下するので、その数字はある時点のスナップショットだと思ってほしい。ペイン内のシェルやエージェントはどちらも同じなので計測に含めず、ターミナル自体のコストだけを見ている。ワークスペース数による lmux の 0.07–0.12 % の差は、実行ごとの誤差の範囲。</sub>

僕がいちばん気にしているのはアイドル時の CPU だ。20 個のエージェントがこっちが読むのを待っているあいだも、じわじわバッテリーを食っていくのはこれだから。

**lmux が向いていない人**

- cmux のアプリ内ブラウザ、SSH ワークスペース、ポートや PR のウィジェット、カスタムコマンドを使っている。または `lmux send` と `lmux new-workspace` だけでは足りないくらいスクリプトを書いている。
- Linux や Windows が必要。
- 設定をとことんいじりたい。cmux なら 200 個くらいある。

そういう人は cmux を使えばいい。いいアプリだし、これからも cmux から学ばせてもらうつもりだ。

## コントリビュート

変更はすべて、次のルールに沿っているかを見ている：

- **軽さが最優先。** 得るものより重さのほうが大きい機能は、あったら便利でも入れない。アイドル時の CPU が予算を超える PR は CI で落ちる。
- **`claude`（と `codex`）は絶対にラップしない。** lmux が見ているのは hooks と、エージェントがもともと書き出しているファイルだけ。なので lmux があってもなくても、エージェントの動きはまったく変わらない。`✎`、`×`、`⌘Z` もセッションを書き換えているわけではなく、動いている `claude` の中で Claude Code 自身の rewind メニューを操作しているだけ。だから何も再起動しない。
- **静かな UI。** 通知はイベントごとに 1 回（リマインダーはオプション）、インジケーターは行ごとに 1 つ。本当に対応が必要なとき以外、何も点滅しない。

上のルールに合っていれば、typo の修正からモジュール丸ごとまで何でも歓迎。ビルド方法、テスト、スコープのルールは [CONTRIBUTING.md](CONTRIBUTING.md) にまとめてある。新機能を提案するなら、先に issue を立ててもらえると助かる。

## FAQ

**cmux のフォーク？**
> 違う。アイデアは同じで、スコープを絞ってゼロから書いたもの。ライセンスは MIT。このリポジトリには cmux のコードは一切入っていない。どう違うかは [lmux と cmux の違い](https://lmux.dev/docs/vs-cmux/) にまとめてある。

**Ghostty + tmux じゃだめなの？**
> cmux の前はその組み合わせを使っていたし、いい構成だと思う。ただ、どのエージェントが自分待ちか分かるサイドバーも、取り消せるプロンプトも、再起動しても自動で戻ってくる Claude と Codex のセッションもない。lmux はざっくり言えば、libghostty にこの 3 つを足したものだ。

**Codex でも使える？**
> 使える。Codex CLI でも、ステータス、通知、再起動後の再開、Codex 自身のセッションタイトル、History、Markdown 形式でのコピーが使える。編集、削除、送信の取り消しは Claude Code だけ。Codex は lmux の hooks を信頼するか一度だけ聞いてくる（"Trust all and continue"）。信頼するまでは hooks なしで普通に動く。

**他のエージェントは？ Linux は？**
> CLI なら何でも動く。再開、History、ホバー時のアクションは僕が一日中使っている Claude Code と Codex 向けに作ったものだけど、ステータスと通知はどのエージェントでも使える。Codex と同じように、エスケープシーケンス 1 つ（OSC 7501）で状態を知らせればいい。`my-agent` 自身に `printf '\e]7501;state=blocked:app=my-agent\e\\'` を出力させる形だ（[やり方](docs/agents.md#any-agent-osc-7501)）。Linux と Windows は対応予定なし。lmux は libghostty ベースのネイティブ AppKit アプリなので、移植したらもう別のアプリになる。

**裏で外部と通信してない？**
> していない。lmux はネットワーク通信を一切しない。テレメトリーもクラッシュレポートもないし、アップデートチェックすらしない（それは Homebrew がやる）。ディスクに何を書き込むか、どう消すかは [機能ページ](docs/features.md#what-does-lmux-write-to-disk-and-how-do-i-remove-it) の 1 段落に全部まとめてある。

そのほかの質問は [FAQ](https://lmux.dev/docs/faq/) へ。

## 謝辞

- [Ghostty](https://github.com/ghostty-org/ghostty) と libghostty。いちばん大変な部分を引き受けてくれている
- [cmux](https://github.com/manaflow-ai/cmux)。アイデアもレイアウトもここから借りている


<sub>MIT。cmux、Ghostty、Anthropic、OpenAI とは関係なく、名前は lmux の連携先を説明するためだけに使っている。サードパーティのライセンスは <a href="App/THIRD_PARTY_NOTICES.md">THIRD_PARTY_NOTICES</a> にあり、lmux.app にも同梱している。</sub>
