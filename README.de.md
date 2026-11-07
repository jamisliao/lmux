<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
    <img src="assets/logo.svg" alt="lmux" width="240">
  </picture>
</p>

<h3 align="center">light mux.</h3>

<p align="center">
  Ein leichtes, natives macOS-Terminal, in dem man den ganzen Tag mit Claude Code und Codex arbeitet.
</p>

<p align="center">
  <a href="https://github.com/sooftware/lmux/releases/latest/download/lmux-arm64.dmg">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="assets/download-macos-dark.svg">
      <img src="assets/download-macos.svg" alt="App für macOS herunterladen" width="146" height="60">
    </picture>
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.ko.md">한국어</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ja.md">日本語</a> | <a href="README.es.md">Español</a> | Deutsch | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.ru.md">Русский</a> | <a href="README.tr.md">Türkçe</a> | <a href="README.vi.md">Tiếng Việt</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-2E3440?logo=apple&logoColor=white" alt="macOS 14+">
  <img src="https://img.shields.io/badge/built%20on-libghostty-5E81AC" alt="built on libghostty">
  <a href="https://github.com/sooftware/lmux/releases/latest"><img src="https://img.shields.io/github/v/release/sooftware/lmux?label=release&color=88C0D0" alt="latest release"></a>
  <img src="https://img.shields.io/badge/license-MIT-A3BE8C" alt="MIT">
</p>

<p align="center">
  <code>brew install --cask sooftware/tap/lmux</code> · macOS 14+, Apple Silicon
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/hero/hero-dark.webp">
    <img src="assets/hero/hero-light.webp" alt="lmux: fünf Workspaces in der Sidebar, jeder in einem anderen Zustand (läuft, fertig, braucht Input, fehlgeschlagen, wartet auf dich); ein Prompt wird in einen Split getippt, in dem Claude Code und Codex nebeneinander arbeiten" width="900">
  </picture>
</p>

---

Neulich hab ich mal wieder im Terminal gearbeitet, und auf einmal dachte ich mir:

*Seit wann sind Terminals eigentlich so fett geworden? Und muss das überhaupt sein?*

Viele Terminal-Apps bringen inzwischen einen Browser, SSH-Workspaces und sogar PR-Badges mit. Bei so vielen Features ist es kein Wunder, dass sie fett sind. KI hat zwar viel daran geändert, wie ich arbeite, aber für mich ist ein Terminal immer noch ein Fenster, in dem nur Text hin und her geht. Ich persönlich nutze darin weder einen Browser noch SSH-Workspaces. Und bei den Einstellungen bin ich auch eher der Typ, der fast alles auf Standard lässt. Neu ist eigentlich nur eins: Früher hatte ich ein einziges Terminal offen, heute rede ich in vielen Sessions gleichzeitig mit mehreren KI-Agents. Nur wurde meine Terminal-App immer fetter, wegen Features, die ich nie anfasse, und die kleinen Ärgernisse häuften sich. Also hab ich **lmux** gebaut. Alles, was ich nicht nutze, ist rausgeflogen. Geblieben ist, was ich wirklich brauche, plus die paar Sachen, die mir schon immer gefehlt haben.

## Highlights

- **Leicht.**<br>
  Eine 25-MB-App, die im Leerlauf bei fast 0 % CPU liegt, egal ob ein Workspace offen ist oder zwanzig. Natives Swift auf libghostty, kein Electron, keine Browser-Engine und nur etwa zehn Einstellungen.

- **Beenden, updaten, neu starten. Alles ist wieder da.**<br>
  Dieselben Workspaces, Splits und Ordner, und jede Claude-Code- oder Codex-Session macht da weiter, wo sie aufgehört hat. Letzte Woche eine geschlossen? History (`⇧⌘H`) findet sie und holt sie zurück.

- **Welcher Agent braucht dich?**<br>
  Der Status kommt direkt aus den Hooks von Claude Code bzw. von Codex selbst: läuft, braucht dich, fertig oder fehlgeschlagen. Du bekommst einen Ring ums Pane, ein Badge am Eintrag und pro Event eine Benachrichtigung, und mit `⇧⌘J` springst du zu dem Agenten, der gerade wartet. Andere Agents können sich mit einer einzigen Escape-Sequenz einklinken. lmux wrappt weder `claude` noch `codex`, es hört nur mit.

- **Prompt zurückholen.**<br>
  Du drückst Enter, siehst, in welchem Pane der Prompt gelandet ist, und denkst: „Ach du Scheiße.“ Maus über den Turn, `×` drücken, und Claude spult bis kurz davor zurück, ohne Neustart, als wär nichts gewesen. `✎` macht dasselbe, gibt dir den Prompt aber zurück, damit du ihn korrigieren und neu abschicken kannst. (Nur Claude Code.)

  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/gifs/forget-x-dark.webp">
    <img src="assets/gifs/forget-x-light.webp" alt="Klick aufs × bei einem versehentlich abgeschickten Prompt: Prompt und Claudes Antwort verschwinden" width="700">
  </picture>

- **cmux-Setup mitnehmen.**<br>
  Mit einem Klick holst du Theme, Fonts, Shortcuts und sogar deine offenen Workspaces und Splits rüber, und die Claude- und Codex-Sessions darin laufen einfach weiter. Wie bei einem neuen Browser, der deine Lesezeichen aus Chrome übernimmt. Und wenn du es dir anders überlegst, macht Undo Import alles wieder rückgängig.

- **Koreanische Eingabe, die einfach funktioniert.**<br>
  Ich bin koreanischer Entwickler, das hier ist mir also persönlich wichtig. Beim Tippen werden keine Silben verschluckt oder zerhackt, und Hangul belegt genau zwei Zellen. Japanisch und Chinesisch (Pinyin, Zhuyin) [funktionieren genauso](https://lmux.dev/docs/korean-input/#chinese-and-japanese-input): Der Cursor steht im Text, den du gerade eingibst, die Pfeiltasten bleiben bei der IME, und `⌃C` ist weiterhin Ctrl+C. [한국어로 보기 →](https://lmux.dev/docs/ko/)

Dazu kommen Tabs in jedem Pane, Session-Titel aus Claude Code, 26 Themes und Kopieren als Markdown. Den Rest findest du in der **[Feature-Übersicht](docs/features.md)**.

## Installation

### Download

<a href="https://github.com/sooftware/lmux/releases/latest/download/lmux-arm64.dmg">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/download-macos-dark.svg">
    <img src="assets/download-macos.svg" alt="App für macOS herunterladen" width="146" height="60">
  </picture>
</a>

Öffne die .dmg und zieh lmux.app in den Programme-Ordner. Das ZIP und ältere Versionen gibt's unter [GitHub Releases](https://github.com/sooftware/lmux/releases).

### Homebrew

```sh
brew install --cask sooftware/tap/lmux
```

macOS 14+ auf Apple Silicon. Wie du lmux selbst baust, steht in [App/README.md](App/README.md).

Doku: [lmux.dev/docs](https://lmux.dev/docs/)

## Benutzung

**Erster Start.** Wenn du von cmux kommst, bietet lmux an, dein Setup und deine offenen Workspaces zu übernehmen. Danach fragt es, ob es ein paar Claude-Code-Hooks installieren darf, und zeigt dir den genauen Diff für deine `settings.json`, bevor es irgendwas anfasst. Sag zu beidem ja, starte `claude` in einem beliebigen Pane, und schon zeigt dir die Sidebar, welcher Agent läuft, welcher fertig ist und welcher auf dich wartet.

**Codex auch.** Ist die Codex-CLI installiert, bietet lmux danach auf die gleiche Art Codex-Hooks an (diesmal mit Diff für `~/.codex/hooks.json`). Beim nächsten Start fragt Codex einmal, ob es den neuen Hooks vertrauen soll. Wähl dort **Trust all and continue**.

**Im Alltag.** Das hier sind die Defaults. Ein `keybind` in deiner Ghostty-Config überschreibt sie, und die Menüs zeigen immer die aktuelle Belegung.

| was du machen willst                          | Kürzel                                           |
|-----------------------------------------------|--------------------------------------------------|
| neuer Workspace                               | `⌘N`                                             |
| nach rechts / unten splitten                  | `⌘D` / `⇧⌘D`                                     |
| Tab / Workspace schließen                     | `⌘W` / `⇧⌘W`, oder `×` auf dem Eintrag unter der Maus |
| neuer Tab im Pane                             | `⌘T`                                             |
| Tab wechseln                                  | `⇧⌘[` / `⇧⌘]`, `⌃1`–`⌃8`, `⌃9` für den letzten   |
| Workspace wechseln                            | `⌘1`–`⌘8`, `⌘9` für den letzten, `⌃⌘[` / `⌃⌘]`  |
| Workspaces umsortieren                        | Eintrag ziehen                                   |
| zwischen Panes wechseln                       | `⌘[` / `⌘]`                                      |
| fokussiertes Pane zoomen (Rest ausblenden)    | `⇧⌘↩`                                            |
| zum Agenten springen, der dich braucht        | `⇧⌘J`                                            |
| neueste ungelesene / letzte Benachrichtigungen | `⇧⌘U` / Glocke anklicken                         |
| Status eines Eintrags von Hand zurücksetzen   | Rechtsklick drauf, dann **Clear Status**         |
| alte Sessions durchsuchen                     | `⇧⌘H`                                            |
| Turn kopieren / bearbeiten & neu senden / entfernen | Maus drüber, dann `⧉` / `✎` / `×`          |
| letzte Antwort als Markdown kopieren          | `⌥⌘C`                                            |
| gerade gesendeten Prompt rückgängig machen    | `⌘Z`, solange der „Sent to …“-Toast zu sehen ist |
| im Scrollback suchen                          | `⌘F`                                             |
| Sidebar ein-/ausblenden                       | `⌃⌘S`                                            |
| Theme, Font und der Rest                      | `⌘,`                                             |

Kurze GIFs vom Agent-Ring, von History, vom Zurückholen eines Turns und von der koreanischen Eingabe gibt's in [der Tour](docs/tour.md).

## lmux vs cmux

Beide Apps liefen auf demselben Mac, jeweils mit 1, 10 und 20 Workspaces (je 2 laufende Shells) geöffnet und dann in Ruhe gelassen. Niedriger ist besser. lmux gibt seinen GPU-Speicher frei, sobald es nicht die App ist, auf die du gerade schaust. Deshalb gibt es zwei Messungen: im Vordergrund und im Hintergrund hinter einer anderen App. Wie gemessen wurde, steht in der [Methodik](scripts/BENCH.md).

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/bench-scaling-dark.svg">
    <img src="assets/bench-scaling.svg" alt="Speicher und Leerlauf-CPU bei 1, 10 und 20 Workspaces: lmux im Vordergrund 182, 207 und 235 MB bei 0.1 % CPU; lmux im Hintergrund 45, 71 und 99 MB bei 0.0 % CPU; cmux 0.65.2 398, 548 und 661 MB bei 7.2, 7.4 und 8.1 % CPU" width="760">
  </picture>
</p>

|                            | cmux 0.65.2 | lmux, im Vordergrund | lmux, im Hintergrund |
|----------------------------|------------:|---------------------:|---------------------:|
| App-Größe                  | 242 MB      | **25 MB**            | **25 MB**            |
| Speicher, 1 Workspace      | 398 MB      | **182 MB**           | **45 MB**            |
| Speicher, 10 Workspaces    | 548 MB      | **207 MB**           | **71 MB**            |
| Speicher, 20 Workspaces    | 661 MB      | **235 MB**           | **99 MB**            |
| Leerlauf-CPU, 1 Workspace  | 7,16 %      | **0,07 %**           | **0,00 %**           |
| Leerlauf-CPU, 10 Workspaces | 7,39 %     | **0,12 %**           | **0,00 %**           |
| Leerlauf-CPU, 20 Workspaces | 8,10 %     | **0,10 %**           | **0,00 %**           |
| Einstellungen              | ~200        | **~10**              | **~10**              |

<sub>M4 Pro, macOS 26.6.2, lmux 0.0.102 vs. cmux 0.65.2. 2 Panes pro Workspace, alle Shells laufen, 5 abwechselnd ausgeführte Durchläufe, jeweils der Median. Speicher ist der Physical Footprint aller App-Prozesse; die App-Größe ist die `.app` für Apple Silicon auf der Platte. Während der Messung war der Bildschirm gesperrt, cmux lief also auch im Hintergrund. Sein Speicherverbrauch schwankt stark je nach Fensterzustand, seine Werte sind daher nur eine Momentaufnahme. Die Shells und Agents in den Panes sind auf beiden Seiten gleich und nicht mitgezählt; gemessen wird nur, was das Terminal selbst kostet. Dass lmux je nach Workspace-Anzahl zwischen 0,07 und 0,12 % liegt, ist normales Messrauschen zwischen den Durchläufen.</sub>

Am wichtigsten ist mir die Leerlauf-CPU, denn die zieht dir den Akku leer, während zwanzig Agents rumsitzen und darauf warten, dass du liest, was sie geschrieben haben.

**Wann ist lmux nichts für dich?**

- Du nutzt den eingebauten Browser von cmux, SSH-Workspaces, die Ports- und PR-Widgets, Custom Commands oder brauchst mehr Scripting, als `lmux send` und `lmux new-workspace` hergeben.
- Du brauchst Linux oder Windows.
- Du willst an vielen Reglern drehen. cmux hat ungefähr zweihundert davon.

Dann nimm cmux. Es ist großartig, und ich schaue mir weiter viel davon ab.

## Mitmachen

Jede Änderung wird an diesen Regeln gemessen:

- **Leicht geht vor.** Ein Feature, das vor allem Gewicht mitbringt, fliegt raus, auch wenn es nett wäre. Die CI lässt jeden PR durchfallen, der die Leerlauf-CPU übers Budget treibt.
- **`claude` wird nie gewrappt** (`codex` auch nicht). lmux hört nur über Hooks mit und liest die Dateien, die die Agents ohnehin schreiben. Mit und ohne lmux verhalten sie sich also genau gleich. Selbst `✎`, `×` und `⌘Z` fassen keine Session an: Sie bedienen das Rewind-Menü von Claude Code im laufenden `claude`, deshalb startet nichts neu.
- **Ruhige UI.** Pro Event gibt es eine Benachrichtigung (plus optional eine Erinnerung) und pro Eintrag einen Indikator, und nichts blinkt, solange dich nicht wirklich etwas braucht.

Von Tippfehler-Fixes bis zu ganzen Modulen ist alles willkommen, solange es zu diesen Regeln passt. Wie man baut und testet und was in den Scope passt, steht in [CONTRIBUTING.md](CONTRIBUTING.md). Für neue Features mach bitte erst ein Issue auf.

## FAQ

**Ist das ein Fork von cmux?**
> Nein. Gleiche Idee, kleinerer Scope, von Grund auf neu geschrieben und MIT-lizenziert. In diesem Repo steckt kein cmux-Code. Hier steht, [worin sich lmux und cmux unterscheiden](https://lmux.dev/docs/vs-cmux/).

**Warum nicht einfach Ghostty und tmux?**
> Das hab ich vor cmux benutzt, und das ist ein gutes Setup. Nur bekommst du damit keine Sidebar, die weiß, welcher Agent auf dich wartet, keinen Prompt, den du zurückholen kannst, und keine Claude- und Codex-Sessions, die nach einem Neustart von selbst weiterlaufen. lmux ist im Grunde libghostty plus genau diese drei Sachen.

**Geht das mit Codex?**
> Ja. Die Codex-CLI bekommt Status, Benachrichtigungen, Resume nach dem Neustart, ihre eigenen Session-Titel, History und Kopieren als Markdown. Bearbeiten, Entfernen und das Zurücknehmen eines gesendeten Prompts gibt es nur für Claude Code. Codex fragt einmal, ob es den Hooks von lmux vertrauen soll („Trust all and continue“); bis du zustimmst, läuft es ohne sie.

**Andere Agents? Linux?**
> Jede CLI läuft darin. Resume, History und die Hover-Aktionen sind für Claude Code und Codex gebaut, die beiden, mit denen ich den ganzen Tag arbeite. Status und Benachrichtigungen bekommt aber jeder Agent, der seinen Zustand wie Codex über eine einzige Escape-Sequenz (OSC 7501) meldet: `printf '\e]7501;state=blocked:app=my-agent\e\\'`, ausgegeben von `my-agent` selbst ([so geht's](docs/agents.md#any-agent-osc-7501)). Linux und Windows: nein. lmux ist natives AppKit auf libghostty, ein Port wäre eine ganz andere App.

**Telefoniert es nach Hause?**
> Nein. lmux greift überhaupt nicht aufs Netzwerk zu. Keine Telemetrie, keine Crash-Reports, nicht mal einen Update-Check (das macht Homebrew). Alles, was es auf die Platte schreibt, und wie du es wieder loswirst, steht in [einem Absatz auf der Features-Seite](docs/features.md#what-does-lmux-write-to-disk-and-how-do-i-remove-it).

Weitere Fragen: [FAQ](https://lmux.dev/docs/faq/)

## Danksagungen

- [Ghostty](https://github.com/ghostty-org/ghostty) und libghostty, für die eigentliche Knochenarbeit
- [cmux](https://github.com/manaflow-ai/cmux), für die Idee und das Layout, das lmux übernommen hat


<p align="center">
  Falls du mit lmux schon mal einen Prompt zurückgeholt hast, der im falschen Pane gelandet war, hilft ein Stern anderen, das Projekt zu finden.<br><br>
  <a href="https://github.com/sooftware/lmux"><img src="https://img.shields.io/github/stars/sooftware/lmux?style=social" alt="lmux auf GitHub einen Stern geben"></a>
</p>

<sub>MIT. lmux steht in keiner Verbindung zu cmux, Ghostty, Anthropic oder OpenAI; ihre Namen werden nur genannt, um zu beschreiben, womit lmux zusammenarbeitet. Lizenzen von Drittanbietern stehen in <a href="App/THIRD_PARTY_NOTICES.md">THIRD_PARTY_NOTICES</a> und liegen auch in lmux.app bei.</sub>
