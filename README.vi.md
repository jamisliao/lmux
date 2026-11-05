<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
    <img src="assets/logo.svg" alt="lmux" width="240">
  </picture>
</p>

<h3 align="center">light mux.</h3>

<p align="center">
  Terminal native cho macOS, nhẹ tênh, để cắm mặt cả ngày với Claude Code và Codex.
</p>

<p align="center">
  <a href="https://github.com/sooftware/lmux/releases/latest/download/lmux-arm64.dmg">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="assets/download-macos-dark.svg">
      <img src="assets/download-macos.svg" alt="Tải ứng dụng cho macOS" width="146" height="60">
    </picture>
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.ko.md">한국어</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ja.md">日本語</a> | <a href="README.es.md">Español</a> | <a href="README.de.md">Deutsch</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.ru.md">Русский</a> | <a href="README.tr.md">Türkçe</a> | Tiếng Việt
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
    <img src="assets/hero/hero-light.webp" alt="lmux: năm workspace trên sidebar, mỗi cái một trạng thái (đang chạy, xong, cần nhập, lỗi, đang chờ bạn); một prompt gõ vào split có Claude Code và Codex chạy cạnh nhau" width="900">
  </picture>
</p>

---

Hôm trước mình đang ngồi làm việc trên terminal thì tự dưng nảy ra một suy nghĩ.

*Từ bao giờ terminal lại nặng thế này nhỉ? Mà có cần nặng đến vậy không?*

Mấy app terminal bây giờ có cả trình duyệt, SSH workspace, thậm chí cả badge PR. Nhiều tính năng thế thì nặng là phải. AI thay đổi cách mình làm việc nhiều thật, nhưng với mình terminal vẫn chỉ là chỗ gõ chữ vào, đọc chữ ra. Riêng mình thì chưa bao giờ dùng trình duyệt hay SSH workspace trong terminal. Cài đặt cũng vậy, mình thuộc kiểu để mặc định gần hết, ít khi chỉnh gì. Có khác thì chỉ khác ở chỗ: trước đây mở một terminal là xong, giờ thì vừa làm vừa nói chuyện với mấy agent AI cùng lúc, mỗi cái một session. Vậy mà app cứ nặng dần lên vì những tính năng mình chẳng bao giờ đụng tới, còn mấy chuyện lặt vặt gây khó chịu thì cứ thế nhiều lên. Thế là mình tự làm **lmux**: cái gì không dùng thì bỏ, giữ đúng những thứ thật sự cần, rồi thêm mấy thứ mình muốn có từ lâu.

## Điểm nổi bật

- **Nhẹ.**<br>
  App 25 MB, lúc idle CPU gần 0%, dù bạn mở một workspace hay hai mươi. Viết bằng Swift native, chạy trên libghostty. Không Electron, không browser engine, setting thì tầm mười cái.

- **Thoát app, update, reboot: mở lại là đâu vẫn vào đấy.**<br>
  Workspace, split, thư mục vẫn y như cũ, session Claude Code hay Codex nào cũng chạy tiếp từ chỗ đang dở. Tuần trước lỡ tay đóng mất một cái? Vào History (`⇧⌘H`) tìm là mở lại được ngay.

- **Biết ngay agent nào đang cần bạn.**<br>
  Trạng thái (đang chạy, cần bạn, xong, lỗi) lấy thẳng từ hook của Claude Code và từ chính Codex. Pane hiện viền sáng, dòng trên sidebar có badge, mỗi sự kiện chỉ báo một lần, và `⇧⌘J` nhảy thẳng tới agent đang chờ. Agent khác cũng gắn vào được, chỉ cần một escape sequence. lmux không bao giờ wrap `claude` hay `codex`, nó chỉ đứng ngoài nghe thôi.

- **Rút lại prompt.**<br>
  Vừa nhấn Enter thì thấy gửi nhầm pane, trong đầu chỉ kịp nghĩ "thôi chết mẹ rồi." Rê chuột lên lượt đó, bấm `×`, Claude rewind về ngay trước đó mà không phải khởi động lại, coi như chưa có gì. Bấm `✎` thì cũng rewind y vậy, nhưng prompt được trả lại vào ô nhập để bạn sửa rồi gửi lại. (Chỉ có trên Claude Code.)

  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/gifs/forget-x-dark.webp">
    <img src="assets/gifs/forget-x-light.webp" alt="Bấm × ở prompt gửi nhầm: prompt và câu trả lời của Claude biến mất" width="700">
  </picture>

- **Mang setup cmux sang.**<br>
  Một click là chuyển hết theme, font, phím tắt, cả workspace và split đang mở, session Claude và Codex bên trong cũng chạy tiếp luôn. Kiểu như cài trình duyệt mới rồi import bookmark từ Chrome. Đổi ý thì bấm Undo Import là về như cũ.

- **Gõ tiếng Hàn không lỗi.**<br>
  Mình là dev người Hàn nên cái này mình làm cho chính mình. Gõ không bị mất chữ hay nhảy chữ, Hangul chiếm đúng hai ô. Tiếng Nhật và tiếng Trung (Pinyin, Zhuyin) [cũng được làm kỹ như vậy](https://lmux.dev/docs/korean-input/#chinese-and-japanese-input): con trỏ hiện ngay trong đoạn chữ đang gõ, phím mũi tên vẫn do bộ gõ xử lý, và `⌃C` vẫn là Ctrl+C. [한국어로 보기 →](https://lmux.dev/docs/ko/)

Ngoài ra còn có tab trong mỗi pane, tiêu đề session lấy từ Claude Code, 26 theme và copy dạng markdown. Mấy thứ khác thì xem **[danh sách tính năng đầy đủ](docs/features.md)**.

## Cài đặt

### Tải về

<a href="https://github.com/sooftware/lmux/releases/latest/download/lmux-arm64.dmg">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/download-macos-dark.svg">
    <img src="assets/download-macos.svg" alt="Tải ứng dụng cho macOS" width="146" height="60">
  </picture>
</a>

Mở file .dmg rồi kéo lmux.app vào thư mục Applications. Bản zip và các bản cũ hơn có trên [GitHub Releases](https://github.com/sooftware/lmux/releases).

### Homebrew

```sh
brew install --cask sooftware/tap/lmux
```

Cần macOS 14+ và máy Apple silicon. Muốn tự build từ source thì xem [App/README.md](App/README.md).

Tài liệu: [lmux.dev/docs](https://lmux.dev/docs/)

## Cách dùng

**Lần mở đầu tiên.** Nếu bạn chuyển từ cmux qua, lmux sẽ hỏi có muốn mang setup và các workspace đang mở sang không. Sau đó nó hỏi có muốn cài vài hook cho Claude Code không, và cho bạn xem đúng phần diff sẽ sửa trong `settings.json` trước khi đụng vào. Đồng ý cả hai rồi chạy `claude` ở pane nào cũng được, thế là sidebar bắt đầu báo agent nào đang chạy, cái nào xong, cái nào đang chờ bạn.

**Cả Codex nữa.** Nếu máy có Codex CLI, lmux sẽ hỏi tiếp có cài hook cho Codex không, cũng y như vậy (lần này diff áp vào `~/.codex/hooks.json`). Lần khởi động tiếp theo, Codex sẽ hỏi một lần xem có trust các hook mới không. Chọn **Trust all and continue**.

**Hằng ngày.** Dưới đây là phím tắt mặc định. Nếu config Ghostty có `keybind` thì phím đó được ưu tiên, menu cũng luôn hiện đúng phím đang gán.

| muốn làm gì                                   | bấm                                              |
|-----------------------------------------------|--------------------------------------------------|
| workspace mới                                 | `⌘N`                                             |
| split sang phải / xuống dưới                  | `⌘D` / `⇧⌘D`                                     |
| đóng tab / workspace                          | `⌘W` / `⇧⌘W`, hoặc rê chuột lên dòng rồi bấm `×` |
| tab mới trong pane                            | `⌘T`                                             |
| chuyển tab                                    | `⇧⌘[` / `⇧⌘]`, `⌃1`–`⌃8`, `⌃9` cho tab cuối      |
| chuyển workspace                              | `⌘1`–`⌘8`, `⌘9` cho workspace cuối, `⌃⌘[` / `⌃⌘]`     |
| sắp xếp lại workspace                         | kéo một dòng                                     |
| di chuyển giữa các pane                       | `⌘[` / `⌘]`                                      |
| phóng to pane đang focus (ẩn các pane khác)   | `⇧⌘↩`                                            |
| nhảy tới agent đang cần bạn                   | `⇧⌘J`                                            |
| thông báo chưa đọc mới nhất / gần đây         | `⇧⌘U` / bấm vào biểu tượng chuông                |
| reset trạng thái của một dòng bằng tay        | chuột phải vào dòng đó rồi chọn **Clear Status** |
| tìm các session cũ                            | `⇧⌘H`                                            |
| copy / sửa và gửi lại / xoá một lượt          | rê chuột lên lượt đó rồi bấm `⧉` / `✎` / `×`     |
| copy câu trả lời cuối dưới dạng markdown      | `⌥⌘C`                                            |
| huỷ prompt vừa gửi                            | `⌘Z` khi toast "Sent to …" còn hiện             |
| tìm trong scrollback                          | `⌘F`                                             |
| ẩn/hiện sidebar                               | `⌃⌘S`                                            |
| theme, font và mọi thứ khác                   | `⌘,`                                             |

Muốn xem GIF ngắn về viền sáng báo trạng thái agent, History, rút lại một lượt và gõ tiếng Hàn thì vào [tour nhanh](docs/tour.md).

## lmux vs cmux

Hai app chạy trên cùng một máy Mac, mở 1, 10 và 20 workspace (mỗi workspace 2 shell đang chạy) rồi để yên đó. Số càng thấp càng tốt. Khi bạn không nhìn vào nó, lmux nhả bộ nhớ GPU, nên mình đo hai lần: lúc ở foreground và lúc nằm background sau một app khác. Xem [cách đo](scripts/BENCH.md).

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/bench-scaling-dark.svg">
    <img src="assets/bench-scaling.svg" alt="Bộ nhớ và CPU idle với 1, 10 và 20 workspace: lmux ở foreground 182, 207 và 235 MB, CPU 0.1%; lmux ở background 45, 71 và 99 MB, CPU 0.0%; cmux 0.65.2 398, 548 và 661 MB, CPU 7.2, 7.4 và 8.1%" width="760">
  </picture>
</p>

|                          | cmux 0.65.2 | lmux, foreground | lmux, background |
|--------------------------|------------:|---------------:|------------------------:|
| Dung lượng app           | 242 MB      | **25 MB**      | **25 MB**               |
| Bộ nhớ, 1 workspace      | 398 MB      | **182 MB**     | **45 MB**               |
| Bộ nhớ, 10 workspace     | 548 MB      | **207 MB**     | **71 MB**               |
| Bộ nhớ, 20 workspace     | 661 MB      | **235 MB**     | **99 MB**               |
| CPU idle, 1 workspace    | 7,16%       | **0,07%**      | **0,00%**               |
| CPU idle, 10 workspace   | 7,39%       | **0,12%**      | **0,00%**               |
| CPU idle, 20 workspace   | 8,10%       | **0,10%**      | **0,00%**               |
| Số setting               | ~200        | **~10**        | **~10**                 |

<sub>M4 Pro, macOS 26.6.2, lmux 0.0.102 vs cmux 0.65.2. Mỗi workspace 2 pane, shell nào cũng đang chạy, 5 lượt chạy xen kẽ, lấy trung vị. Bộ nhớ là physical footprint của tất cả process của app; dung lượng app là file `.app` bản Apple silicon trên ổ đĩa. Màn hình bị khoá trong lúc đo, nên cmux cũng đang ở background. Bộ nhớ của cmux thay đổi khá nhiều theo trạng thái cửa sổ, nên số của nó chỉ đúng tại thời điểm đo. Shell và agent trong pane ở hai bên như nhau và không được tính vào; đây là chi phí của riêng terminal. CPU của lmux dao động trong khoảng 0,07–0,12% tuỳ số workspace, mức chênh đó nằm trong sai số giữa các lượt chạy.</sub>

CPU idle là con số mình quan tâm nhất, vì chính nó ngốn pin của bạn trong lúc hai mươi agent ngồi chờ bạn đọc những gì chúng viết.

**Khi nào không nên dùng lmux?**

- Bạn dùng trình duyệt tích hợp, SSH workspace, widget port và PR, custom command của cmux, hoặc cần script nhiều hơn những gì `lmux send` và `lmux new-workspace` làm được.
- Bạn cần Linux hoặc Windows.
- Bạn thích có thật nhiều thứ để vọc. cmux có tầm hai trăm setting.

Vậy thì cứ dùng cmux. Nó xịn thật, và mình sẽ còn học hỏi từ nó dài dài.

## Đóng góp

Mọi thay đổi đều được soi theo mấy nguyên tắc này:

- **Nhẹ là trên hết.** Tính năng nào chủ yếu chỉ làm app nặng thêm thì cắt, kể cả loại có thì tốt. CI sẽ fail bất kỳ PR nào đẩy CPU idle vượt ngưỡng cho phép.
- **Không bao giờ wrap `claude`** (hay `codex`). lmux chỉ nghe qua hook và các file mà agent vốn đã ghi ra, nên có hay không có lmux thì agent vẫn chạy y hệt. Ngay cả `✎`, `×` và `⌘Z` cũng không sửa session: chúng điều khiển chính menu rewind của Claude Code trong `claude` đang chạy, nên không có gì phải khởi động lại.
- **UI không ồn ào.** Mỗi sự kiện chỉ có một thông báo (cộng thêm một lần nhắc nếu bạn bật), mỗi dòng chỉ một chỉ báo, và không có gì nhấp nháy trừ khi có chuyện thật sự cần đến bạn.

Từ sửa lỗi chính tả đến viết cả một module, cái gì mình cũng nhận, miễn là hợp với các nguyên tắc trên. Xem [CONTRIBUTING.md](CONTRIBUTING.md) để biết cách build, chạy test và nguyên tắc về phạm vi. Nếu là tính năng mới thì mở issue trước nhé.

## FAQ

**Đây có phải fork của cmux không?**
> Không. Cùng ý tưởng nhưng phạm vi nhỏ hơn, tự viết từ đầu và dùng license MIT. Repo này không có dòng code nào của cmux. Xem thêm [lmux và cmux khác nhau thế nào](https://lmux.dev/docs/vs-cmux/).

**Sao không dùng Ghostty với tmux?**
> Trước khi chuyển sang cmux, mình dùng đúng combo đó, và nó ổn mà. Có điều nó không có sidebar biết agent nào đang chờ bạn, không rút lại prompt được, và session Claude với Codex không tự chạy tiếp sau khi mở lại app. lmux về cơ bản là libghostty cộng thêm đúng ba thứ đó.

**Có dùng được với Codex không?**
> Được. Với Codex CLI bạn có trạng thái, thông báo, chạy tiếp sau khi khởi động lại, tiêu đề session riêng, History và copy dạng markdown. Sửa, xoá và huỷ gửi thì chỉ có ở Claude Code. Codex sẽ hỏi một lần có trust các hook của lmux không ("Trust all and continue"); chưa đồng ý thì Codex vẫn chạy, chỉ là không có hook.

**Agent khác thì sao? Linux thì sao?**
> CLI nào cũng chạy được trong lmux. Resume, History và các thao tác khi rê chuột được làm cho Claude Code và Codex, hai thứ mình dùng suốt ngày. Còn trạng thái và thông báo thì agent nào cũng có được, chỉ cần tự báo trạng thái giống Codex bằng một escape sequence (OSC 7501): `printf '\e]7501;state=blocked:app=my-agent\e\\'`, do chính `my-agent` in ra ([cách làm](docs/agents.md#any-agent-osc-7501)). Linux và Windows thì không. lmux là AppKit native trên libghostty, port sang đó thì thành một app khác rồi.

**Nó có âm thầm gửi dữ liệu về đâu không?**
> Không. lmux không gửi request mạng nào hết. Không telemetry, không gửi crash report, đến kiểm tra cập nhật cũng không (việc đó Homebrew lo). Nó ghi gì xuống ổ đĩa và xoá thế nào đều nằm gọn trong [một đoạn ở trang tính năng](docs/features.md#what-does-lmux-write-to-disk-and-how-do-i-remove-it).

Xem thêm các câu hỏi khác tại [FAQ](https://lmux.dev/docs/faq/).

## Cảm ơn

- [Ghostty](https://github.com/ghostty-org/ghostty) và libghostty, vì đã gánh phần khó
- [cmux](https://github.com/manaflow-ai/cmux), vì ý tưởng và bố cục mà lmux mượn lại


<sub>MIT. Không liên kết với cmux, Ghostty, Anthropic hay OpenAI; tên của họ chỉ được nhắc đến để cho biết lmux dùng được với những gì. License của bên thứ ba nằm trong <a href="App/THIRD_PARTY_NOTICES.md">THIRD_PARTY_NOTICES</a>, và cũng được đóng gói kèm trong lmux.app.</sub>
