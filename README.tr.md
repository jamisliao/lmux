<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
    <img src="assets/logo.svg" alt="lmux" width="240">
  </picture>
</p>

<h3 align="center">light mux.</h3>

<p align="center">
  Bütün gün Claude Code ve Codex'le çalışmak için hafif, native bir macOS terminali.
</p>

<p align="center">
  <a href="https://github.com/sooftware/lmux/releases/latest/download/lmux-arm64.dmg">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="assets/download-macos-dark.svg">
      <img src="assets/download-macos.svg" alt="macOS uygulamasını indir" width="146" height="60">
    </picture>
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.ko.md">한국어</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ja.md">日本語</a> | <a href="README.es.md">Español</a> | <a href="README.de.md">Deutsch</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.ru.md">Русский</a> | Türkçe | <a href="README.vi.md">Tiếng Việt</a>
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
    <img src="assets/hero/hero-light.webp" alt="lmux: sidebar'da her biri farklı durumda beş workspace (çalışıyor, bitti, girdi bekliyor, hata verdi, seni bekliyor); Claude Code ile Codex'in yan yana çalıştığı bir split'e yazılmış bir prompt" width="900">
  </picture>
</p>

---

Geçenlerde terminalde çalışırken aklıma bir şey takıldı.

*Terminaller ne zaman bu kadar ağırlaştı? Bu kadarına gerçekten gerek var mı?*

Artık terminal uygulamalarının içinde tarayıcı da var, SSH workspace'leri de, hatta PR rozetleri bile. Bu kadar özellik olunca ağır olmaları da normal. AI sayesinde çalışma şeklim epey değişti ama benim için terminal hâlâ metin yazıp okuduğum bir ekrandan ibaret. Ben şahsen terminalin içinde ne tarayıcı açıyorum ne de SSH workspace'i kullanıyorum. Ayarlara da pek dokunmam, çoğunu varsayılan haliyle bırakırım. Değişen bir şey varsa o da şu: eskiden tek bir terminal açıp işimi görürdüm, şimdi birkaç session'da aynı anda AI agent'larla konuşarak çalışıyorum. Ama kullandığım uygulama, hiç dokunmadığım özellikler yüzünden ağırlaştıkça ağırlaştı; can sıkan ufak tefek şeyler de birikip durdu. Ben de **lmux**'ı yazdım. Kullanmadığım özellikleri çıkardım; geriye sadece gerçekten ihtiyacım olanlar ve hep keşke olsa dediğim birkaç şey kaldı.

## Öne çıkanlar

- **Hafif.**<br>
  Uygulama 25 MB; ister bir workspace açık olsun ister yirmi, boştayken CPU neredeyse %0. libghostty üzerine native Swift ile yazıldı. Electron yok, tarayıcı motoru yok, ayar sayısı on civarı.

- **Kapat, güncelle, yeniden başlat. Hepsi geri geliyor.**<br>
  Workspace'ler, split'ler ve klasörler aynen yerinde; her Claude Code ya da Codex session'ı kaldığı yerden devam ediyor. Geçen hafta birini mi kapattın? History (`⇧⌘H`) bulup açıyor.

- **Seni bekleyen agent'ı hemen gör.**<br>
  Durum bilgisi doğrudan Claude Code'un hook'larından ve Codex'in kendisinden geliyor: çalışıyor, seni bekliyor, bitti ya da hata verdi. Pane'de bir halka, satırda bir rozet ve her olay için tek bir bildirim çıkıyor; `⇧⌘J` ise seni bekleyen agent'a direkt götürüyor. Başka agent'lar da tek bir escape sequence ile aynı şekilde bağlanabiliyor. lmux `claude`'u ya da `codex`'i asla sarmalamıyor, sadece dinliyor.

- **Prompt'u geri al.**<br>
  Enter'a basıyorsun, prompt'un hangi pane'e gittiğini görünce içinden "hassiktir." diyorsun. Mesajın üstüne gelip `×` butonuna bas; Claude yeniden başlamadan tam o mesajdan önceki ana geri sarıyor, sanki hiç olmamış gibi. `✎` de aynısını yapıyor ama prompt'u düzeltip yeniden göndermen için sana geri veriyor. (Sadece Claude Code'da.)

  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/gifs/forget-x-dark.webp">
    <img src="assets/gifs/forget-x-light.webp" alt="Yanlışlıkla gönderilen prompt'un × butonuna basınca prompt da Claude'un cevabı da kayboluyor" width="700">
  </picture>

- **cmux ayarlarını taşı.**<br>
  Tek tıkla temanı, fontlarını, kısayollarını, hatta açık workspace'lerini ve split'lerini taşıyorsun; içlerindeki Claude ve Codex session'ları da devam ediyor. Yeni bir tarayıcıya geçince yer imlerini Chrome'dan içe aktarmak gibi. Fikrini değiştirirsen Undo Import her şeyi eski haline getiriyor.

- **Korece yazmak dert değil.**<br>
  Koreli bir geliştiriciyim, o yüzden bu iş benim için biraz kişisel. Yazarken heceler kaybolmuyor ya da bozulmuyor, Hangul da tam iki hücre kaplıyor. Japonca ve Çince (Pinyin, Zhuyin) de [aynı ilgiyi gördü](https://lmux.dev/docs/korean-input/#chinese-and-japanese-input): imleç yazmakta olduğun metnin içinde duruyor, ok tuşları IME'ye gidiyor, `⌃C` de yine Ctrl+C olarak çalışıyor. [한국어로 보기 →](https://lmux.dev/docs/ko/)

Bunların yanında her pane'de sekmeler, Claude Code'dan gelen session başlıkları, 26 tema ve markdown olarak kopyalama da var. Geri kalanı için **[tüm özelliklere](docs/features.md)** bak.

## Kurulum

### İndir

<a href="https://github.com/sooftware/lmux/releases/latest/download/lmux-arm64.dmg">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/download-macos-dark.svg">
    <img src="assets/download-macos.svg" alt="macOS uygulamasını indir" width="146" height="60">
  </picture>
</a>

.dmg'yi aç ve lmux.app'i Applications klasörüne sürükle. Zip ve eski sürümler [GitHub Releases](https://github.com/sooftware/lmux/releases) sayfasında.

### Homebrew

```sh
brew install --cask sooftware/tap/lmux
```

Apple silicon'da macOS 14+ gerekiyor. Kaynaktan derlemek için [App/README.md](App/README.md)'ye bak.

Dokümantasyon: [lmux.dev/docs](https://lmux.dev/docs/)

## Kullanım

**İlk açılış.** cmux'tan geliyorsan lmux ayarlarını ve açık workspace'lerini taşımayı teklif ediyor. Ardından birkaç Claude Code hook'u kurmayı öneriyor ve hiçbir şeye dokunmadan önce `settings.json` dosyanda ne değişeceğini diff olarak gösteriyor. İkisine de evet deyip herhangi bir pane'de `claude` çalıştırınca sidebar hangi agent'ın çalıştığını, hangisinin bittiğini, hangisinin seni beklediğini göstermeye başlıyor.

**Codex için de aynısı.** Codex CLI kuruluysa lmux ardından Codex hook'larını kurmayı da öneriyor (bu sefer diff `~/.codex/hooks.json` üzerinde). Codex bir sonraki açılışında yeni hook'lara güvenip güvenmeyeceğini bir kere soruyor. **Trust all and continue**'yu seç.

**Günlük kullanım.** Aşağıdakiler varsayılanlar. Ghostty config'indeki bir `keybind` bunları ezer; menüler de o an neye atanmışsa onu gösterir.

| işlem                                         | kısayol                                          |
|-----------------------------------------------|--------------------------------------------------|
| yeni workspace                                | `⌘N`                                             |
| sağa / aşağı split                            | `⌘D` / `⇧⌘D`                                     |
| sekmeyi / workspace'i kapat                   | `⌘W` / `⇧⌘W` ya da üstüne gelinen satırda `×`    |
| pane'de yeni sekme                            | `⌘T`                                             |
| sekme değiştir                                | `⇧⌘[` / `⇧⌘]`, `⌃1`–`⌃8`, sonuncusu için `⌃9`    |
| workspace değiştir                            | `⌘1`–`⌘8`, sonuncusu için `⌘9`, `⌃⌘[` / `⌃⌘]`   |
| workspace'leri yeniden sırala                 | satırı sürükle                                   |
| pane'ler arasında geç                         | `⌘[` / `⌘]`                                      |
| odaktaki pane'i büyüt (diğerlerini gizle)     | `⇧⌘↩`                                            |
| seni bekleyen agent'a atla                    | `⇧⌘J`                                            |
| en yeni okunmamış bildirim / son bildirimler  | `⇧⌘U` / zil simgesine tıkla                      |
| bir satırın durumunu elle sıfırla             | sağ tıkla, sonra **Clear Status**                |
| eski session'larda ara                        | `⇧⌘H`                                            |
| mesajı kopyala / düzenle ve yeniden gönder / sil | üstüne gel, sonra `⧉` / `✎` / `×`            |
| son yanıtı markdown olarak kopyala            | `⌥⌘C`                                            |
| az önce gönderdiğin prompt'u geri al          | "Sent to …" toast'ı ekrandayken `⌘Z`          |
| scrollback'te ara                             | `⌘F`                                             |
| sidebar'ı aç / kapat                          | `⌃⌘S`                                            |
| tema, font ve diğer ayarlar                   | `⌘,`                                             |

Agent halkası, History, bir mesajı geri alma ve Korece yazmanın kısa GIF'lerini [tanıtım turunda](docs/tour.md) bulabilirsin.

## lmux vs cmux

İki uygulamayı aynı Mac'te 1, 10 ve 20 workspace ile (her birinde 2 canlı shell) açıp boşta bıraktım. Ne kadar düşükse o kadar iyi. lmux, o an baktığın uygulama değilse GPU belleğini bırakıyor. O yüzden onu iki kez ölçtüm: bir kez önde, bir kez de başka bir uygulamanın arkasında, yani arka planda. [Ölçüm yöntemini](scripts/BENCH.md) ayrıca anlattım.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/bench-scaling-dark.svg">
    <img src="assets/bench-scaling.svg" alt="1, 10 ve 20 workspace'te bellek ve boştaki CPU: önde lmux 182, 207 ve 235 MB, CPU %0.1; arka planda lmux 45, 71 ve 99 MB, CPU %0.0; cmux 0.65.2 398, 548 ve 661 MB, CPU %7.2, %7.4 ve %8.1" width="760">
  </picture>
</p>

|                          | cmux 0.65.2 | lmux, önde     | lmux, arka planda       |
|--------------------------|------------:|---------------:|------------------------:|
| Uygulama boyutu          | 242 MB      | **25 MB**      | **25 MB**               |
| Bellek, 1 workspace      | 398 MB      | **182 MB**     | **45 MB**               |
| Bellek, 10 workspace     | 548 MB      | **207 MB**     | **71 MB**               |
| Bellek, 20 workspace     | 661 MB      | **235 MB**     | **99 MB**               |
| Boştaki CPU, 1 workspace | %7,16       | **%0,07**      | **%0,00**               |
| Boştaki CPU, 10 workspace | %7,39       | **%0,12**      | **%0,00**               |
| Boştaki CPU, 20 workspace | %8,10       | **%0,10**      | **%0,00**               |
| Ayar sayısı              | ~200        | **~10**        | **~10**                 |

<sub>M4 Pro, macOS 26.6.2, lmux 0.0.102 vs cmux 0.65.2. Workspace başına 2 pane, tüm shell'ler canlı, dönüşümlü 5 ölçümün medyanı. Bellek, uygulamanın tüm process'lerinin physical footprint toplamı; uygulama boyutu ise Apple silicon `.app` paketinin diskteki boyutu. Ölçüm sırasında ekran kilitliydi, yani cmux da arka plandaydı. cmux'ın bellek kullanımı pencere durumuna göre epey oynuyor, o yüzden sayılarını tek bir anlık görüntü olarak değerlendir. Pane'lerin içindeki shell'ler ve agent'lar iki tarafta da aynı ve hesaba katılmadı; ölçülen sadece terminalin kendi yükü. lmux'ta workspace sayısına göre değişen %0,07–0,12 aralığı, ölçümden ölçüme olan normal dalgalanmanın içinde kalıyor.</sub>

En çok önemsediğim sayı boştaki CPU. Yirmi agent yazdıklarını okumanı beklerken pilini bitiren şey o.

**lmux kimlere göre değil?**

- cmux'ın uygulama içi tarayıcısını, SSH workspace'lerini, port ve PR widget'larını, özel komutlarını kullanıyorsan ya da `lmux send` ve `lmux new-workspace`'in verdiğinden fazla script desteğine ihtiyacın varsa.
- Linux ya da Windows lazımsa.
- Kurcalayacak bol ayar istiyorsan. cmux'ta bunlardan iki yüz civarı var.

O zaman cmux kullan. Harika bir uygulama; ben de ondan öğrenmeyi bırakmayacağım.

## Katkıda bulunma

Her değişiklik şu kurallara göre değerlendiriliyor:

- **Önce hafiflik.** Faydasından çok yük getiren bir özellik, ne kadar hoş olursa olsun girmiyor. Boştaki CPU'yu bütçenin üstüne çıkaran her PR CI'da patlıyor.
- **`claude`'u asla sarmalama** (`codex`'i de). lmux, hook'lar ve agent'ların zaten yazdığı dosyalar üzerinden dinliyor; yani agent'lar lmux'la da onsuz da birebir aynı çalışıyor. `✎`, `×` ve `⌘Z` bile session'ı düzenlemiyor: çalışan `claude` içinde Claude Code'un kendi rewind menüsünü tetikliyorlar, o yüzden hiçbir şey yeniden başlamıyor.
- **Sakin arayüz.** Her olay için tek bildirim (artı isteğe bağlı bir hatırlatma) ve her satırda tek gösterge var. Gerçekten sana iş düşmedikçe hiçbir şey yanıp sönmüyor.

Yazım hatası düzeltmesinden koca modüllere kadar her şeye açığım, yeter ki yukarıdaki kurallara uysun. Build, testler ve kapsam kuralı için [CONTRIBUTING.md](CONTRIBUTING.md)'ye bak. Yeni bir özellik için önce issue aç.

## SSS

**Bu bir cmux fork'u mu?**
> Hayır. Fikir aynı ama kapsam daha dar; sıfırdan yazıldı ve MIT lisanslı. Bu repoda hiç cmux kodu yok. [lmux ile cmux'ın farkları](https://lmux.dev/docs/vs-cmux/) burada.

**Neden Ghostty ve tmux değil?**
> cmux'tan önce ben de bu ikiliyi kullanıyordum, gayet iyi bir kombinasyon. Ama hangi agent'ın seni beklediğini bilen bir sidebar, geri alınabilen bir prompt ya da yeniden açılışta kendiliğinden devam eden Claude ve Codex session'ları sunamıyor. lmux aşağı yukarı libghostty artı bu üç şey.

**Codex'le çalışıyor mu?**
> Evet. Codex CLI'da durum, bildirimler, yeniden başlatınca devam etme, kendi session başlıkları, History ve markdown olarak kopyalama var. Düzenleme, silme ve gönderimi geri alma sadece Claude Code'da. Codex, lmux'ın hook'larına güvenip güvenmeyeceğini bir kere soruyor ("Trust all and continue"); onaylayana kadar hook'lar olmadan çalışıyor.

**Başka agent'lar? Linux?**
> İçinde her CLI çalışır. Kaldığı yerden devam etme, History ve üstüne gelince çıkan butonlar, bütün günümü geçirdiğim Claude Code ve Codex için yapıldı. Ama durumunu Codex gibi tek bir escape sequence (OSC 7501) ile bildiren her agent için de durum ve bildirim çıkıyor. Bunun için `my-agent`'ın kendisinin şunu basması yeterli: `printf '\e]7501;state=blocked:app=my-agent\e\\'` ([nasıl](docs/agents.md#any-agent-osc-7501)). Linux ve Windows desteği yok. lmux, libghostty üzerine native AppKit ile yazıldı; port etmek başka bir uygulama yazmak demek.

**Bir yerlere veri gönderiyor mu?**
> Hayır. lmux hiçbir ağ isteği yapmıyor. Telemetri yok, crash raporu yok, güncelleme kontrolü bile yok (onu Homebrew yapıyor). Diske yazdığı her şey ve nasıl silineceği [özellikler sayfasında tek bir paragrafta](docs/features.md#what-does-lmux-write-to-disk-and-how-do-i-remove-it) listeleniyor.

Diğer sorular için [SSS](https://lmux.dev/docs/faq/) sayfasına göz atın.

## Teşekkürler

- [Ghostty](https://github.com/ghostty-org/ghostty) ve libghostty, işin zor kısmını yaptıkları için
- [cmux](https://github.com/manaflow-ai/cmux), lmux'ın ödünç aldığı fikir ve yerleşim için


<sub>MIT. lmux'ın cmux, Ghostty, Anthropic veya OpenAI ile hiçbir bağı yok; bu isimler sadece lmux'ın neyle çalıştığını anlatmak için kullanılıyor. Üçüncü taraf lisansları <a href="App/THIRD_PARTY_NOTICES.md">THIRD_PARTY_NOTICES</a> dosyasında; aynı dosya lmux.app'in içinde de var.</sub>
