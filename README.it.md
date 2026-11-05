<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
    <img src="assets/logo.svg" alt="lmux" width="240">
  </picture>
</p>

<h3 align="center">light mux.</h3>

<p align="center">
  Un terminale per macOS nativo e leggero, per chi passa le giornate dentro Claude Code e Codex.
</p>

<p align="center">
  <a href="https://github.com/sooftware/lmux/releases/latest/download/lmux-arm64.dmg">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="assets/download-macos-dark.svg">
      <img src="assets/download-macos.svg" alt="Scarica l'app per macOS" width="146" height="60">
    </picture>
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.ko.md">한국어</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ja.md">日本語</a> | <a href="README.es.md">Español</a> | <a href="README.de.md">Deutsch</a> | <a href="README.fr.md">Français</a> | Italiano | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.ru.md">Русский</a> | <a href="README.tr.md">Türkçe</a> | <a href="README.vi.md">Tiếng Việt</a>
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
    <img src="assets/hero/hero-light.webp" alt="lmux: cinque workspace nella sidebar, ognuno in uno stato diverso (al lavoro, finito, serve un input, fallito, aspetta te); un prompt scritto in uno split dove Claude Code e Codex lavorano fianco a fianco" width="900">
  </picture>
</p>

---

L'altro giorno, mentre lavoravo nel terminale, mi è venuta in mente una cosa.

*Da quando i terminali sono diventati così pesanti? E c'è davvero bisogno che lo siano?*

Le app da terminale di oggi si portano dentro un browser, i workspace SSH, perfino i badge delle PR. Con tutta quella roba è normale che pesino. L'AI ha cambiato parecchio il mio modo di lavorare, ma per me il terminale resta uno schermo dove passa testo, avanti e indietro. Il browser e i workspace SSH dentro il terminale io non li uso. E con le impostazioni sono uno che lascia quasi tutto di default. L'unica cosa cambiata davvero è che prima tenevo aperto un terminale e basta, mentre adesso parlo con diversi agenti AI in parallelo, su più sessioni. Intanto l'app continuava a ingrassare per feature che non usavo mai, e i piccoli fastidi si accumulavano uno dopo l'altro. Così ho scritto **lmux**: via quello che non mi serve, dentro solo l'essenziale e le poche cose che mi sono sempre mancate.

## In breve

- **Leggero.**<br>
  Un'app da 25 MB che a riposo sta vicino allo 0% di CPU, che tu abbia aperto un workspace o venti. È Swift nativo su libghostty. Niente Electron, niente motore di browser, e le impostazioni sono una decina.

- **Chiudi, aggiorni, riavvii. Torna tutto com'era.**<br>
  Stessi workspace, split e cartelle, e ogni sessione di Claude Code o Codex riparte da dove l'avevi lasciata. Ne hai chiusa una la settimana scorsa? History (`⇧⌘H`) te la ritrova e te la riapre.

- **Sai sempre quale agente ha bisogno di te.**<br>
  Lo stato arriva direttamente dagli hook di Claude Code e da Codex stesso: in esecuzione, ti aspetta, finito o fallito. Hai un anello intorno al pannello, un badge sulla riga e una notifica per ogni evento, e con `⇧⌘J` salti a chi ti sta aspettando. Altri agenti si possono agganciare con una sola escape sequence. lmux non fa mai da wrapper a `claude` o `codex`: si limita ad ascoltare.

- **Rimangiati un prompt.**<br>
  Premi Invio, vedi in quale pannello è finito e pensi: "oh, cazzo." Passa il mouse sul messaggio e premi `×`: Claude riavvolge fino a un attimo prima, senza riavviarsi, come se non fosse mai successo. `✎` fa lo stesso, ma poi ti rimette il prompt nella casella di input, così lo sistemi e lo rimandi. (Solo Claude Code.)

  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/gifs/forget-x-dark.webp">
    <img src="assets/gifs/forget-x-light.webp" alt="Premi × su un prompt inviato per sbaglio e spariscono sia il prompt sia la risposta di Claude" width="700">
  </picture>

- **Porta con te il setup di cmux.**<br>
  Con un clic ti porti dietro tema, font, scorciatoie e perfino i workspace e gli split che avevi aperti, con le sessioni di Claude e Codex che ripartono. È come quando un browser nuovo ti importa i preferiti da Chrome. Se ci ripensi, Undo Import rimette tutto come prima.

- **Input coreano che funziona e basta.**<br>
  Sono uno sviluppatore coreano, quindi questa mi sta a cuore. Mentre scrivi nessuna sillaba si perde o esce storpiata, e l'Hangul occupa esattamente due celle. Giapponese e cinese (Pinyin, Zhuyin) [hanno avuto lo stesso trattamento](https://lmux.dev/docs/korean-input/#chinese-and-japanese-input): il cursore resta dentro il testo che stai componendo, i tasti freccia li gestisce l'IME e `⌃C` è sempre Ctrl+C. [한국어로 보기 →](https://lmux.dev/docs/ko/)

C'è anche altro: le tab in ogni pannello, i titoli delle sessioni presi da Claude Code, 26 temi e la copia in markdown. Per il resto c'è la **[lista completa delle feature](docs/features.md)**.

## Installazione

### Download

<a href="https://github.com/sooftware/lmux/releases/latest/download/lmux-arm64.dmg">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/download-macos-dark.svg">
    <img src="assets/download-macos.svg" alt="Scarica l'app per macOS" width="146" height="60">
  </picture>
</a>

Apri il .dmg e trascina lmux.app in Applicazioni. Lo zip e le versioni precedenti sono su [GitHub Releases](https://github.com/sooftware/lmux/releases).

### Homebrew

```sh
brew install --cask sooftware/tap/lmux
```

macOS 14+ su Apple silicon. Per compilarlo dai sorgenti, vedi [App/README.md](App/README.md).

Documentazione: [lmux.dev/docs](https://lmux.dev/docs/)

## Come si usa

**Primo avvio.** Se arrivi da cmux, lmux ti propone di importare il tuo setup e i workspace aperti. Poi si offre di installare qualche hook di Claude Code e, prima di toccare qualsiasi cosa, ti mostra il diff esatto che applicherà al tuo `settings.json`. Accetta tutte e due, lancia `claude` in un pannello qualsiasi e la sidebar comincia a dirti quale agente sta lavorando, quale ha finito e quale aspetta te.

**Anche Codex.** Se hai la CLI di Codex installata, subito dopo lmux ti propone gli hook di Codex allo stesso modo (stavolta il diff è su `~/.codex/hooks.json`). La prossima volta che lo avvii, Codex ti chiede una volta sola se ti fidi dei nuovi hook: scegli **Trust all and continue**.

**Tutti i giorni.** Queste sono le scorciatoie di default; se metti un `keybind` nella config di Ghostty vince quello, e i menu mostrano sempre i tasti assegnati.

| per fare questo                               | premi                                            |
|-----------------------------------------------|--------------------------------------------------|
| nuovo workspace                               | `⌘N`                                             |
| split a destra / in basso                     | `⌘D` / `⇧⌘D`                                     |
| chiudere una tab / un workspace               | `⌘W` / `⇧⌘W`, oppure `×` sulla riga sotto il mouse |
| nuova tab nel pannello                        | `⌘T`                                             |
| cambiare tab                                  | `⇧⌘[` / `⇧⌘]`, `⌃1`–`⌃8`, `⌃9` per l'ultimo      |
| cambiare workspace                            | `⌘1`–`⌘8`, `⌘9` per l'ultimo, `⌃⌘[` / `⌃⌘]`     |
| riordinare i workspace                        | trascina una riga                                |
| spostarsi tra i pannelli                      | `⌘[` / `⌘]`                                      |
| zoom sul pannello attivo (nasconde gli altri) | `⇧⌘↩`                                            |
| saltare all'agente che ha bisogno di te       | `⇧⌘J`                                            |
| ultima notifica non letta / notifiche recenti | `⇧⌘U` / clic sulla campanella                    |
| azzerare a mano lo stato di una riga          | clic destro sulla riga, poi **Clear Status**     |
| cercare tra le sessioni passate               | `⇧⌘H`                                            |
| copiare / modificare e rimandare / rimuovere un messaggio | passaci sopra col mouse, poi `⧉` / `✎` / `×` |
| copiare l'ultima risposta in markdown         | `⌥⌘C`                                            |
| annullare il prompt appena mandato            | `⌘Z` finché c'è il toast "Sent to …"             |
| cercare nello scrollback                      | `⌘F`                                             |
| mostrare/nascondere la sidebar                | `⌃⌘S`                                            |
| tema, font e tutto il resto                   | `⌘,`                                             |

Nel [tour](docs/tour.md) ci sono delle brevi GIF: l'anello degli agenti, History, come rimangiarsi un prompt e l'input coreano.

## lmux vs cmux

Ho messo le due app sullo stesso Mac, le ho aperte con 1, 10 e 20 workspace (2 shell attive ciascuno) e le ho lasciate a riposo. Più è basso, meglio è. lmux libera la memoria della GPU quando non è l'app che stai guardando, per questo l'ho misurato due volte: in primo piano e in background, dietro un'altra app. I dettagli sono nella [metodologia](scripts/BENCH.md).

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/bench-scaling-dark.svg">
    <img src="assets/bench-scaling.svg" alt="Memoria e CPU a riposo con 1, 10 e 20 workspace: lmux in primo piano 182, 207 e 235 MB allo 0.1% di CPU; lmux in background 45, 71 e 99 MB allo 0.0% di CPU; cmux 0.65.2 398, 548 e 661 MB al 7.2, 7.4 e 8.1% di CPU" width="760">
  </picture>
</p>

|                          | cmux 0.65.2 | lmux, in primo piano | lmux, in background |
|--------------------------|------------:|---------------------:|--------------------:|
| Dimensione app           | 242 MB      | **25 MB**            | **25 MB**           |
| Memoria, 1 workspace     | 398 MB      | **182 MB**           | **45 MB**           |
| Memoria, 10 workspace    | 548 MB      | **207 MB**           | **71 MB**           |
| Memoria, 20 workspace    | 661 MB      | **235 MB**           | **99 MB**           |
| CPU a riposo, 1 workspace   | 7,16%   | **0,07%**           | **0,00%**          |
| CPU a riposo, 10 workspace  | 7,39%   | **0,12%**           | **0,00%**          |
| CPU a riposo, 20 workspace  | 8,10%   | **0,10%**           | **0,00%**          |
| Impostazioni             | ~200        | **~10**              | **~10**             |

<sub>M4 Pro, macOS 26.6.2, lmux 0.0.102 vs cmux 0.65.2. 2 pannelli per workspace, tutte le shell attive, mediana di 5 run alternate. La memoria è il physical footprint di tutti i processi dell'app; la dimensione è quella del `.app` per Apple silicon su disco. Durante la misura lo schermo era bloccato, quindi anche cmux era in background. La sua memoria cambia parecchio a seconda dello stato delle finestre, per cui prendi i suoi numeri come una fotografia del momento. Le shell e gli agenti nei pannelli sono gli stessi da entrambe le parti e non li ho contati: qui c'è solo il costo del terminale. Lo scarto 0,07–0,12% di lmux al variare del numero di workspace rientra nel rumore tra una run e l'altra.</sub>

Il numero a cui tengo di più è la CPU a riposo, perché è quella che ti svuota la batteria mentre venti agenti stanno lì ad aspettare che tu legga quello che hanno scritto.

**Quando lmux non fa per te**

- Usi il browser integrato di cmux, i workspace SSH, i widget delle porte e delle PR, i comandi personalizzati, o ti serve più scripting di quello che ti danno `lmux send` e `lmux new-workspace`.
- Ti serve Linux o Windows.
- Ti piace smanettare con le opzioni. cmux ne ha circa duecento.

Allora usa cmux: è ottimo, e io continuo a imparare da lui.

## Contribuire

Ogni modifica viene valutata in base a queste regole:

- **Prima di tutto leggero.** Una feature che porta più peso che altro si taglia, anche se fa comodo. La CI boccia qualsiasi PR che fa sforare il budget di CPU a riposo.
- **Mai fare da wrapper a `claude`** (né a `codex`). lmux ascolta tramite gli hook e i file che gli agenti scrivono già, quindi gli agenti funzionano esattamente allo stesso modo con o senza lmux. Nemmeno `✎`, `×` e `⌘Z` modificano una sessione: pilotano il menu di rewind di Claude Code nel `claude` in esecuzione, quindi non riparte niente.
- **UI discreta.** Una notifica per evento (più un promemoria opzionale) e un indicatore per riga, e non lampeggia niente a meno che non serva davvero il tuo intervento.

Va bene tutto, dai typo a moduli interi, purché rispetti le regole qui sopra. In [CONTRIBUTING.md](CONTRIBUTING.md) trovi la build, i test e la regola sullo scope. Per una feature nuova, apri prima una issue.

## FAQ

**È un fork di cmux?**
> No. È la stessa idea con uno scope più piccolo, scritta da zero e con licenza MIT. In questo repo non c'è codice di cmux. Qui trovi [le differenze tra lmux e cmux](https://lmux.dev/docs/vs-cmux/).

**Perché non Ghostty e tmux?**
> È quello che usavo prima di cmux, ed è un setup che va benissimo. Però non ti dà una sidebar che sa quale agente ti sta aspettando, un prompt che puoi rimangiarti, o sessioni di Claude e Codex che ripartono da sole dopo un riavvio. lmux in pratica è libghostty più queste tre cose.

**Funziona con Codex?**
> Sì. Con la CLI di Codex hai stato, notifiche, ripresa dopo il riavvio, i suoi titoli di sessione, History e la copia in markdown. Modifica, rimozione e annullamento dell'invio sono solo per Claude Code. Codex ti chiede una volta sola se ti fidi degli hook di lmux ("Trust all and continue"); finché non accetti, gira senza.

**Altri agenti? Linux?**
> Ci gira qualsiasi CLI. Ripresa, History e le azioni al passaggio del mouse sono fatti per Claude Code e Codex, i due su cui passo le giornate, ma qualsiasi agente può avere stato e notifiche: basta che lo segnali come fa Codex, con una sola escape sequence (OSC 7501) stampata da `my-agent` stesso: `printf '\e]7501;state=blocked:app=my-agent\e\\'` ([come](docs/agents.md#any-agent-osc-7501)). Linux e Windows invece no: lmux è AppKit nativo su libghostty, e portarlo vorrebbe dire scrivere un'altra app.

**Manda dati da qualche parte?**
> No. lmux non fa proprio nessuna chiamata di rete. Niente telemetria, niente crash report, nemmeno il controllo degli aggiornamenti (quello lo fa Homebrew). Tutto quello che scrive su disco, e come rimuoverlo, è elencato in [un paragrafo della pagina delle feature](docs/features.md#what-does-lmux-write-to-disk-and-how-do-i-remove-it).

Altre domande? Leggi le [FAQ](https://lmux.dev/docs/faq/).

## Ringraziamenti

- [Ghostty](https://github.com/ghostty-org/ghostty) e libghostty, per aver fatto la parte difficile
- [cmux](https://github.com/manaflow-ai/cmux), per l'idea e il layout che lmux gli ha preso in prestito


<sub>MIT. Non affiliato a cmux, Ghostty, Anthropic o OpenAI; i loro nomi sono usati solo per descrivere con cosa funziona lmux. Le licenze di terze parti sono in <a href="App/THIRD_PARTY_NOTICES.md">THIRD_PARTY_NOTICES</a>, incluse anche dentro lmux.app.</sub>
