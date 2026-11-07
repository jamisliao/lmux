<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
    <img src="assets/logo.svg" alt="lmux" width="240">
  </picture>
</p>

<h3 align="center">light mux.</h3>

<p align="center">
  Claude Code와 Codex용 light & native macOS 터미널
</p>

<p align="center">
  <a href="https://github.com/sooftware/lmux/releases/latest/download/lmux-arm64.dmg">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="assets/download-macos-dark.svg">
      <img src="assets/download-macos.svg" alt="macOS용 앱 다운로드" width="146" height="60">
    </picture>
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | 한국어 | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ja.md">日本語</a> | <a href="README.es.md">Español</a> | <a href="README.de.md">Deutsch</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.ru.md">Русский</a> | <a href="README.tr.md">Türkçe</a> | <a href="README.vi.md">Tiếng Việt</a>
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
    <img src="assets/hero/hero-light.webp" alt="사이드바의 워크스페이스 다섯 개에 실행 중, 완료, 입력 필요, 실패, 확인 대기 상태가 하나씩 표시된 lmux 화면. 분할 화면에서 Claude Code와 Codex가 나란히 돌고, 한쪽 pane에 프롬프트를 입력하는 모습" width="900">
  </picture>
</p>

---

최근에 터미널로 일하다가 문득 그런 생각이 들었습니다.

'*언제부터 터미널이 이렇게 무거워졌지? 그리고 이렇게까지 무거울 이유가 있나?*'

요즘 터미널 앱들은 브라우저, SSH 워크스페이스, PR 배지까지 품고 있습니다. 기능이 많으니 무거워지는 건 당연합니다. 다만 AI 덕분에 일하는 방식은 많이 바뀌었어도, 제게 터미널은 여전히 그저 텍스트를 주고받는 화면입니다. 저는 브라우저도 SSH 워크스페이스도 터미널 안에서는 쓰지 않습니다. 설정도 거의 기본값 그대로 쓰는 순정파입니다. 달라진 게 있다면, 예전엔 터미널 하나를 띄워 놓고 썼는데 이제는 여러 세션에서 AI 에이전트들과 동시에 대화하며 일한다는 점 정도입니다. 그런데 쓰지도 않는 기능 때문에 앱은 점점 무거워지고, 신경에 거슬리는 일도 하나씩 늘었습니다. 그래서 쓰지 않는 기능은 덜어내고, 꼭 필요한 기능과 그동안 아쉬웠던 부분만 담은 **lmux**를 만들었습니다.

## Highlights

- **가벼운 앱**<br>
  앱 크기는 25 MB이고, 워크스페이스를 하나 열든 스무 개 열든 가만히 두면 CPU 사용량이 0%에 가깝습니다. libghostty 위에서 동작하는 native swift 앱입니다. Electron이나 브라우저 엔진은 쓰지 않습니다. 설정은 10개 정도입니다.

- **종료·업데이트·재부팅 후에도 복원**<br>
  워크스페이스, 분할, 폴더가 그대로 복원되고 Claude Code와 Codex 세션도 이어서 실행됩니다. 지난주에 닫은 세션은 History(`⇧⌘H`)에서 찾아 다시 열 수 있습니다.

- **에이전트 상태 표시**<br>
  상태(실행 중, 입력 필요, 완료, 실패)는 Claude Code에서는 hooks로, Codex에서는 Codex가 직접 보내는 신호로 받습니다. 받은 상태는 pane 테두리와 사이드바 배지에 표시하고, 알림은 이벤트마다 한 번 보냅니다. `⇧⌘J`를 누르면 입력을 기다리는 에이전트로 이동합니다. 다른 에이전트도 escape sequence 하나로 연동할 수 있습니다. lmux는 `claude`나 `codex`를 wrapping하지 않고 상태만 받아 옵니다.

- **입력 되돌리기**<br>
  다른 세션에 프롬프트를 잘못 보냈을 때 쓰는 기능입니다. 해당 턴에 마우스를 올리고 `×`를 누르면 Claude가 해당 입력을 보내기 전 상태로 돌아갑니다. `✎`도 같은 방식으로 되돌리지만, 보냈던 프롬프트를 입력창에 다시 넣어 주기 때문에 고쳐서 다시 보낼 수 있습니다. (Claude Code 전용)

  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/gifs/forget-x-dark.webp">
    <img src="assets/gifs/forget-x-light.webp" alt="잘못 보낸 프롬프트에서 ×를 누르면 프롬프트와 Claude의 답변이 사라지는 모습" width="700">
  </picture>

- **cmux 설정 가져오기**<br>
  테마, 폰트, 단축키, 열어 둔 워크스페이스와 분할을 클릭 한 번으로 가져옵니다. 기존 cmux 유저분들이 쉽게 사용 가능하도록 고려한 기능입니다.

- **한글 입력**<br>
  한글 입력에 특히 신경을 썼습니다. 입력 중에 글자가 빠지거나 깨지지 않고, 한글은 정확히 두 칸을 차지합니다. 일본어와 중국어(병음, 주음) 입력도 같은 방식으로 지원합니다([자세히](https://lmux.dev/docs/korean-input/#chinese-and-japanese-input)). [한국어 문서 →](https://lmux.dev/docs/ko/)

나머지는 **[전체 기능](docs/features.md)** 문서에 있습니다.

## Installation

### Download

<a href="https://github.com/sooftware/lmux/releases/latest/download/lmux-arm64.dmg">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/download-macos-dark.svg">
    <img src="assets/download-macos.svg" alt="macOS용 앱 다운로드" width="146" height="60">
  </picture>
</a>

.dmg를 열고 lmux.app을 응용 프로그램 폴더로 옮기면 됩니다. zip 파일과 이전 버전은 [GitHub Releases](https://github.com/sooftware/lmux/releases)에 있습니다.

### Homebrew

```sh
brew install --cask sooftware/tap/lmux
```

macOS 14+, Apple silicon에서 동작합니다. 소스에서 빌드하는 방법은 [App/README.md](App/README.md)에 있습니다.

문서: [lmux.dev/docs](https://lmux.dev/docs/)

## Usage

### 처음 실행할 때

cmux를 쓰고 있었다면 lmux가 먼저 설정과 열어 둔 워크스페이스를 가져올지 묻습니다. 그다음 Claude Code hooks 몇 개를 설치할지 묻는데, 파일을 수정하기 전에 `settings.json`에 적용될 diff를 그대로 보여 줍니다. 둘 다 허용하고 아무 pane에서 `claude`를 실행하면, 사이드바에 에이전트마다 실행 중, 완료, 입력 필요 상태가 표시됩니다.

### Codex

Codex CLI가 설치되어 있으면 이어서 Codex hooks도 같은 방식으로 설치할지 묻습니다. 이때는 `~/.codex/hooks.json`에 적용될 diff를 보여 줍니다. Codex는 다음 실행 때 새 hooks를 신뢰할지 한 번 묻습니다. **Trust all and continue**를 선택하면 됩니다.

### 단축키

아래는 기본값입니다. Ghostty 설정에 `keybind`가 있으면 그 설정이 우선하고, 메뉴에는 실제로 지정된 키가 표시됩니다.

| 기능                                          | 키                                               |
|-----------------------------------------------|--------------------------------------------------|
| 새 워크스페이스                               | `⌘N`                                             |
| 오른쪽 / 아래로 분할                          | `⌘D` / `⇧⌘D`                                     |
| 탭 / 워크스페이스 닫기                        | `⌘W` / `⇧⌘W`, 또는 항목에 마우스를 올리고 `×`    |
| pane에 새 탭 열기                             | `⌘T`                                             |
| 탭 전환                                       | `⇧⌘[` / `⇧⌘]`, `⌃1`–`⌃8`, 마지막 탭은 `⌃9`       |
| 워크스페이스 전환                             | `⌘1`–`⌘8`, 마지막 워크스페이스는 `⌘9`, `⌃⌘[` / `⌃⌘]` |
| 워크스페이스 순서 변경                        | 항목을 드래그                                    |
| pane 간 이동                                  | `⌘[` / `⌘]`                                      |
| 현재 pane 확대 (나머지 숨기기)                | `⇧⌘↩`                                            |
| 입력을 기다리는 에이전트로 이동               | `⇧⌘J`                                            |
| 읽지 않은 최근 알림으로 이동 / 알림 목록      | `⇧⌘U` / 종 아이콘 클릭                           |
| 항목 상태 지우기                              | 우클릭 후 **Clear Status**                       |
| 이전 세션 검색                                | `⇧⌘H`                                            |
| 턴 복사 / 수정 후 다시 보내기 / 삭제          | 마우스를 올리고 `⧉` / `✎` / `×`                  |
| 마지막 답변을 마크다운으로 복사               | `⌥⌘C`                                            |
| 방금 보낸 프롬프트 취소                       | "Sent to …" 토스트가 떠 있는 동안 `⌘Z`          |
| 스크롤백에서 검색                             | `⌘F`                                             |
| 사이드바 보이기 / 숨기기                      | `⌃⌘S`                                            |
| 테마, 폰트 등 설정                            | `⌘,`                                             |

에이전트 상태 표시, History, 프롬프트 되돌리기, 한글 입력을 보여 주는 짧은 GIF는 [둘러보기](docs/tour.md)에 있습니다.

## lmux vs cmux

같은 Mac에서 두 앱에 워크스페이스를 1개, 10개, 20개 열고(워크스페이스마다 셸 2개 실행) 가만히 둔 상태에서 측정했습니다. 수치는 낮을수록 좋습니다. lmux는 백그라운드로 가면 GPU 메모리를 반납하기 때문에 포그라운드와 백그라운드를 따로 측정했습니다. 측정 방법은 [BENCH.md](scripts/BENCH.md)에 정리했습니다.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/bench-scaling-dark.svg">
    <img src="assets/bench-scaling.svg" alt="워크스페이스 1, 10, 20개일 때 메모리와 유휴 CPU: 포그라운드 lmux는 182, 207, 235 MB, CPU 0.1%. 백그라운드 lmux는 45, 71, 99 MB, CPU 0.0%. cmux 0.65.2는 398, 548, 661 MB, CPU 7.2, 7.4, 8.1%" width="760">
  </picture>
</p>

|                              | cmux 0.65.2 | lmux (포그라운드)  | lmux (백그라운드) |
|------------------------------|------------:|-------------------:|------------------:|
| 앱 크기                      | 242 MB      | **25 MB**          | **25 MB**        |
| 메모리 (워크스페이스 1개)    | 398 MB      | **182 MB**         | **45 MB**        |
| 메모리 (워크스페이스 10개)   | 548 MB      | **207 MB**         | **71 MB**        |
| 메모리 (워크스페이스 20개)   | 661 MB      | **235 MB**         | **99 MB**        |
| 유휴 CPU (워크스페이스 1개)  | 7.16%       | **0.07%**          | **0.00%**        |
| 유휴 CPU (워크스페이스 10개) | 7.39%       | **0.12%**          | **0.00%**        |
| 유휴 CPU (워크스페이스 20개) | 8.10%       | **0.10%**          | **0.00%**        |
| 설정 개수                    | ~200        | **~10**            | **~10**          |

<sub>M4 Pro, macOS 26.6.2, lmux 0.0.102 vs cmux 0.65.2. 워크스페이스마다 pane 2개에 각각 셸을 띄웠고, 두 앱을 번갈아 5번씩 실행해 중앙값을 냈습니다. 메모리는 앱 프로세스 전체의 physical footprint이고, 앱 크기는 디스크에 있는 Apple silicon용 `.app` 기준입니다. 측정 중에는 화면이 잠겨 있었기 때문에 cmux도 백그라운드 상태였습니다. cmux의 메모리는 창 상태에 따라 크게 달라지므로 측정 시점의 값으로 봐 주시기 바랍니다. pane 안의 셸과 에이전트는 양쪽이 같아서 수치에 포함하지 않았습니다. 터미널 자체가 쓰는 자원만 측정했습니다. lmux가 워크스페이스 수에 따라 0.07–0.12%로 달라지는 건 실행할 때마다 생기는 노이즈 수준입니다.</sub>

제가 가장 중요하게 보는 수치는 유휴 CPU입니다. 에이전트 스무 개가 작업을 끝내고 제가 확인할 때까지 기다리는 동안에도, 유휴 CPU가 높으면 배터리가 계속 닳기 때문입니다.

**lmux가 맞지 않는 경우**

- cmux의 내장 브라우저, SSH 워크스페이스, 포트·PR 위젯, 커스텀 커맨드를 쓰거나, `lmux send`와 `lmux new-workspace`로는 부족할 만큼 스크립팅이 필요한 경우
- Linux나 Windows가 필요한 경우
- 설정을 세세하게 조정하고 싶은 경우. cmux에는 설정이 200개 정도 있습니다.

이런 경우에는 cmux를 쓰는 게 맞습니다. 저도 계속 참고하는 앱입니다.

## Contributing

모든 변경은 아래 규칙을 기준으로 검토합니다.

- **가벼운 게 우선입니다.** 좋은 기능이라도 앱을 무겁게 만들면 넣지 않습니다. 유휴 CPU 기준치를 넘는 PR은 CI에서 실패합니다.
- **`claude`와 `codex`를 wrapping하지 않습니다.** lmux는 hooks와 에이전트가 원래 쓰는 파일로 상태를 확인하기 때문에, lmux가 있든 없든 에이전트는 똑같이 동작합니다. `✎`, `×`, `⌘Z`도 세션을 직접 수정하지 않습니다. 실행 중인 `claude`에서 Claude Code의 rewind 메뉴를 조작하는 방식이라 재시작할 필요가 없습니다.
- **UI는 기본 스타일을 유지합니다.** 알림은 이벤트마다 한 번만 보내고(원하면 리마인더를 한 번 더 받을 수 있습니다), 사이드바 항목에는 배지를 하나만 표시합니다. 정말 확인이 필요한 일이 아니면 아무것도 깜빡이지 않습니다.

위 규칙에 맞으면 오타 수정이든 모듈 하나를 통째로 만드는 PR이든 환영합니다. 빌드, 테스트, 범위 규칙은 [CONTRIBUTING.md](CONTRIBUTING.md)에 있습니다. 새 기능은 먼저 이슈를 열어 주시기 바랍니다.

## FAQ

**cmux 포크인가요?**
> 아니요. 아이디어는 같지만 범위를 더 좁혔고, 처음부터 새로 작성했습니다. 라이선스는 MIT이고 cmux 코드를 참고하진 않았습니다. 자세한 내용은 [lmux와 cmux의 차이](https://lmux.dev/docs/vs-cmux/)에 정리했습니다.

**Ghostty와 tmux를 쓰면 되지 않나요?**
> cmux 전에는 저도 이 조합을 썼고, 지금도 좋은 조합이라고 생각합니다. 하지만 이 조합으로는 어떤 에이전트가 입력을 기다리는지 사이드바에서 볼 수 없고, 보낸 프롬프트를 되돌릴 수도 없고, 다시 실행했을 때 Claude·Codex 세션이 이어지지도 않습니다. lmux는 libghostty에 이 세 가지를 더한 것에 가깝습니다.

**Codex에서도 되나요?**
> 네. Codex CLI에서도 상태 표시, 알림, 재시작 후 이어하기, Codex 세션 제목, History, 마크다운 복사를 지원합니다. 수정 후 다시 보내기, 삭제, 보내기 취소는 Claude Code 전용입니다. Codex는 lmux의 hooks를 신뢰할지 한 번 묻는데, "Trust all and continue"를 선택하면 됩니다. 그 전까지는 hooks 없이 실행됩니다.

**다른 에이전트나 Linux는요?**
> CLI라면 무엇이든 실행할 수 있습니다. 이어하기, History, hover 버튼은 제가 매일 쓰는 Claude Code와 Codex에 맞춰 만들었습니다. 다른 에이전트도 Codex처럼 escape sequence 하나(OSC 7501)로 상태를 알려 주면 상태 표시와 알림을 쓸 수 있습니다. 예를 들어 `my-agent`가 직접 `printf '\e]7501;state=blocked:app=my-agent\e\\'`를 출력하면 됩니다([연동 방법](docs/agents.md#any-agent-osc-7501)). Linux와 Windows는 지원하지 않습니다. lmux는 libghostty 기반의 네이티브 AppKit 앱이라 다른 OS를 지원하려면 사실상 새로 만들어야 합니다.

**외부로 데이터를 보내나요?**
> 아니요. lmux는 네트워크 요청을 전혀 하지 않습니다. 텔레메트리, 크래시 리포트는 물론 업데이트 확인도 하지 않습니다(업데이트 확인은 Homebrew가 합니다). lmux가 디스크에 쓰는 파일과 지우는 방법은 [기능 문서](docs/features.md#what-does-lmux-write-to-disk-and-how-do-i-remove-it)에 정리했습니다.

다른 질문은 [FAQ](https://lmux.dev/docs/faq/)에 있습니다.

## 감사의 말

- [Ghostty](https://github.com/ghostty-org/ghostty)와 libghostty: lmux의 터미널 기능은 libghostty 위에서 동작합니다.
- [cmux](https://github.com/manaflow-ai/cmux): lmux의 아이디어와 레이아웃을 여기서 빌려 왔습니다.


<p align="center">
  엉뚱한 pane에 보낸 프롬프트를 lmux로 한 번이라도 되돌린 적이 있다면 star를 눌러 주세요. 다른 사람들이 lmux를 찾기 쉬워집니다.<br><br>
  <a href="https://github.com/sooftware/lmux"><img src="https://img.shields.io/github/stars/sooftware/lmux?style=social" alt="GitHub에서 lmux에 star 누르기"></a>
</p>

<sub>MIT. lmux는 cmux, Ghostty, Anthropic, OpenAI와 관계가 없습니다. 이 이름들은 lmux와 함께 쓰는 도구를 설명하려고 적었습니다. 서드파티 라이선스는 <a href="App/THIRD_PARTY_NOTICES.md">THIRD_PARTY_NOTICES</a>에 있으며 lmux.app 안에도 들어 있습니다.</sub>
