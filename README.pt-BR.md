<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
    <img src="assets/logo.svg" alt="lmux" width="240">
  </picture>
</p>

<h3 align="center">light mux.</h3>

<p align="center">
  Um terminal nativo e leve pra macOS, pra passar o dia inteiro no Claude Code e no Codex.
</p>

<p align="center">
  <a href="https://github.com/sooftware/lmux/releases/latest/download/lmux-arm64.dmg">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="assets/download-macos-dark.svg">
      <img src="assets/download-macos.svg" alt="Baixar o app para macOS" width="146" height="60">
    </picture>
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.ko.md">한국어</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ja.md">日本語</a> | <a href="README.es.md">Español</a> | <a href="README.de.md">Deutsch</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | Português (Brasil) | <a href="README.ru.md">Русский</a> | <a href="README.tr.md">Türkçe</a> | <a href="README.vi.md">Tiếng Việt</a>
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
    <img src="assets/hero/hero-light.webp" alt="lmux: cinco workspaces na sidebar, cada um num estado diferente (rodando, pronto, precisa de input, falhou, esperando você); um prompt sendo digitado num split com Claude Code e Codex trabalhando lado a lado" width="900">
  </picture>
</p>

---

Esses dias, trabalhando no terminal, me bateu uma dúvida.

*Desde quando terminal ficou tão pesado? E precisa mesmo ser assim?*

Hoje os apps de terminal vêm com navegador, workspaces via SSH e até badges de PR. Com tanta coisa dentro, claro que ficam pesados. A IA mudou bastante o meu jeito de trabalhar, mas pra mim terminal continua sendo só uma tela onde o texto vai e vem. Eu, pelo menos, não abro navegador nem workspace via SSH dentro dele. Com as configurações é igual: sou do tipo que deixa quase tudo no padrão. O que mudou de verdade é que antes eu usava um terminal só, e agora passo o dia conversando com vários agentes de IA ao mesmo tempo, cada um na sua sessão. Só que o app que eu usava foi ficando mais pesado por causa de feature que eu nunca uso, e os pequenos incômodos foram se acumulando. Então fiz o **lmux**: tirei o que não uso e deixei só o que eu preciso de verdade, mais aquelas coisas que sempre me fizeram falta.

## Destaques

- **Leve.**<br>
  Um app de 25 MB que fica perto de 0% de CPU em idle, com um workspace aberto ou com vinte. É Swift nativo em cima da libghostty: sem Electron, sem engine de navegador e só umas dez configurações.

- **Fechou, atualizou, reiniciou? Volta tudo.**<br>
  Os workspaces, splits e pastas voltam do jeito que estavam, e cada sessão do Claude Code ou do Codex continua de onde parou. Fechou uma sessão na semana passada? O History (`⇧⌘H`) acha e traz de volta.

- **Saiba qual agente precisa de você.**<br>
  O status vem direto dos hooks do Claude Code e do próprio Codex: rodando, precisa de você, pronto ou falhou. Aparece um anel no pane, um badge na linha e uma notificação por evento, e o `⇧⌘J` te leva direto pra quem está esperando. Qualquer outro agente pode entrar na brincadeira com uma escape sequence. O lmux não é um wrapper do `claude` nem do `codex`; ele só escuta.

- **Desfaça um prompt.**<br>
  Você aperta Enter, vê em qual pane o prompt foi parar e pensa: "puta merda." É só passar o mouse na mensagem e clicar no `×` que o Claude volta pra antes dela, sem reiniciar, como se nada tivesse acontecido. O `✎` faz o mesmo, mas te devolve o prompt pra você corrigir e mandar de novo. (Só no Claude Code.)

  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/gifs/forget-x-dark.webp">
    <img src="assets/gifs/forget-x-light.webp" alt="Ao clicar no × de um prompt enviado por engano, o prompt e a resposta do Claude somem" width="700">
  </picture>

- **Traga sua configuração do cmux.**<br>
  Um clique traz seu tema, fontes, atalhos e até os workspaces e splits que estavam abertos, já retomando as sessões do Claude e do Codex. É como um navegador novo importando os favoritos do Chrome. Mudou de ideia? O Undo Import desfaz tudo.

- **Digitação em coreano que funciona de verdade.**<br>
  Sou dev coreano, então essa aqui é questão pessoal. Nenhuma sílaba some nem sai embaralhada enquanto você digita, e o Hangul ocupa exatamente duas células. Japonês e chinês (Pinyin, Zhuyin) [ganharam o mesmo cuidado](https://lmux.dev/docs/korean-input/#chinese-and-japanese-input): o cursor aparece dentro do texto que você ainda está compondo, as setas continuam com o IME e o `⌃C` segue sendo Ctrl+C. [한국어로 보기 →](https://lmux.dev/docs/ko/)

Também tem abas em todo pane, títulos de sessão puxados do Claude Code, 26 temas e a opção de copiar como markdown. O resto está na **[lista completa de features](docs/features.md)**.

## Instalação

### Download

<a href="https://github.com/sooftware/lmux/releases/latest/download/lmux-arm64.dmg">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/download-macos-dark.svg">
    <img src="assets/download-macos.svg" alt="Baixar o app para macOS" width="146" height="60">
  </picture>
</a>

Abra o .dmg e arraste o lmux.app pra pasta Aplicativos. O zip e as versões antigas ficam no [GitHub Releases](https://github.com/sooftware/lmux/releases).

### Homebrew

```sh
brew install --cask sooftware/tap/lmux
```

macOS 14+ em Apple silicon. Pra compilar do código-fonte, veja o [App/README.md](App/README.md).

Docs: [lmux.dev/docs](https://lmux.dev/docs/)

## Uso

**Primeira vez.** Se você vem do cmux, o lmux pergunta se você quer trazer sua configuração e os workspaces abertos. Depois pergunta se pode instalar alguns hooks do Claude Code e, antes de mexer em qualquer coisa, mostra exatamente o diff que vai aplicar no seu `settings.json`. Aceite os dois, rode `claude` em qualquer pane e pronto: a sidebar passa a mostrar qual agente está rodando, qual terminou e qual está esperando por você.

**Codex também.** Se o Codex CLI estiver instalado, logo depois o lmux pergunta se pode instalar os hooks do Codex, do mesmo jeito (dessa vez o diff é no `~/.codex/hooks.json`). Na próxima vez que o Codex abrir, ele vai perguntar uma vez se você confia nos hooks novos. Escolha **Trust all and continue**.

**No dia a dia.** Estes são os atalhos padrão. Um `keybind` na sua config do Ghostty tem prioridade, e os menus sempre mostram o atalho que estiver valendo.

| pra fazer isso                                | aperte                                           |
|-----------------------------------------------|--------------------------------------------------|
| novo workspace                                | `⌘N`                                             |
| split à direita / embaixo                     | `⌘D` / `⇧⌘D`                                     |
| fechar uma aba / um workspace                 | `⌘W` / `⇧⌘W`, ou o `×` ao passar o mouse na linha |
| nova aba no pane                              | `⌘T`                                             |
| trocar de aba                                 | `⇧⌘[` / `⇧⌘]`, `⌃1`–`⌃8`, `⌃9` pra última        |
| trocar de workspace                           | `⌘1`–`⌘8`, `⌘9` pro último, `⌃⌘[` / `⌃⌘]`        |
| reordenar workspaces                          | arraste uma linha                                |
| navegar entre panes                           | `⌘[` / `⌘]`                                      |
| dar zoom no pane em foco (esconde o resto)    | `⇧⌘↩`                                            |
| pular pro agente que precisa de você          | `⇧⌘J`                                            |
| última não lida / notificações recentes       | `⇧⌘U` / clique no sino                           |
| limpar o status de uma linha na mão           | clique com o botão direito nela, depois **Clear Status** |
| buscar sessões antigas                        | `⇧⌘H`                                            |
| copiar / editar e reenviar / remover uma mensagem | passe o mouse nela, depois `⧉` / `✎` / `×`       |
| copiar a última resposta como markdown        | `⌥⌘C`                                            |
| desfazer o prompt que você acabou de mandar   | `⌘Z` enquanto o toast "Sent to …" estiver na tela |
| buscar no scrollback                          | `⌘F`                                             |
| mostrar/esconder a sidebar                    | `⌃⌘S`                                            |
| tema, fonte e o resto                         | `⌘,`                                             |

O [tour](docs/tour.md) tem GIFs curtos do anel do agente, do History, de desfazer uma mensagem e da digitação em coreano.

## lmux vs cmux

Rodei os dois apps no mesmo Mac, com 1, 10 e 20 workspaces abertos (2 shells ativos em cada), e deixei tudo em idle. Quanto menor, melhor. Quando não é o app que você está olhando, o lmux libera a memória da GPU, então ele foi medido duas vezes: em primeiro plano e em segundo plano, atrás de outro app. Veja a [metodologia](scripts/BENCH.md).

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/bench-scaling-dark.svg">
    <img src="assets/bench-scaling.svg" alt="Memória e CPU em idle com 1, 10 e 20 workspaces: lmux em primeiro plano 182, 207 e 235 MB com 0.1% de CPU; lmux em segundo plano 45, 71 e 99 MB com 0.0% de CPU; cmux 0.65.2 398, 548 e 661 MB com 7.2, 7.4 e 8.1% de CPU" width="760">
  </picture>
</p>

|                            | cmux 0.65.2 | lmux, em primeiro plano | lmux, em segundo plano |
|----------------------------|------------:|------------------------:|-----------------------:|
| Tamanho do app             | 242 MB      | **25 MB**               | **25 MB**              |
| Memória, 1 workspace       | 398 MB      | **182 MB**              | **45 MB**              |
| Memória, 10 workspaces     | 548 MB      | **207 MB**              | **71 MB**              |
| Memória, 20 workspaces     | 661 MB      | **235 MB**              | **99 MB**              |
| CPU em idle, 1 workspace   | 7,16%       | **0,07%**               | **0,00%**              |
| CPU em idle, 10 workspaces | 7,39%       | **0,12%**               | **0,00%**              |
| CPU em idle, 20 workspaces | 8,10%       | **0,10%**               | **0,00%**              |
| Configurações              | ~200        | **~10**                 | **~10**                |

<sub>M4 Pro, macOS 26.6.2, lmux 0.0.102 vs cmux 0.65.2. 2 panes por workspace, todos os shells ativos, 5 rodadas intercaladas, medianas. A memória é a soma do physical footprint de todos os processos do app; o tamanho do app é o do `.app` de Apple silicon no disco. A tela ficou bloqueada durante a medição, então o cmux também estava em segundo plano. A memória dele muda bastante dependendo do estado da janela, então considere os números dele uma foto de um momento só. Os shells e agentes dentro dos panes são iguais nos dois lados e não entram na conta: isso é só o custo do terminal em si. A variação de 0,07–0,12% do lmux conforme o número de workspaces está dentro do ruído normal entre rodadas.</sub>

O uso de CPU em idle é o número que mais me importa, porque é ele que come sua bateria enquanto vinte agentes ficam esperando você ler o que escreveram.

**Quando não usar o lmux?**

- Você usa o navegador embutido do cmux, workspaces via SSH, os widgets de portas e de PR, comandos customizados, ou precisa de mais scripting do que o `lmux send` e o `lmux new-workspace` oferecem.
- Você precisa de Linux ou Windows.
- Você quer poder ajustar tudo. O cmux tem umas duzentas opções.

Nesse caso, use o cmux. Ele é ótimo, e eu sigo aprendendo com ele.

## Contribuindo

Toda mudança precisa passar por estas regras:

- **Leveza primeiro.** Feature que mais pesa do que ajuda fica de fora, mesmo que seja legal. O CI reprova qualquer PR que estoure o limite de CPU em idle.
- **Nada de wrapper no `claude`** (nem no `codex`). O lmux escuta pelos hooks e pelos arquivos que os agentes já escrevem, então eles funcionam do mesmo jeito com ou sem ele. Nem o `✎`, nem o `×`, nem o `⌘Z` editam a sessão: eles acionam o próprio menu de rewind do Claude Code no `claude` que já está rodando, e nada reinicia.
- **UI tranquila.** Uma notificação por evento (mais um lembrete opcional), um indicador por linha, e nada pisca se não tiver algo que precise mesmo de você.

Toda contribuição é bem-vinda, de correção de typo a módulos inteiros, desde que respeite essas regras. Build, testes e a regra de escopo estão no [CONTRIBUTING.md](CONTRIBUTING.md). Se for uma feature nova, abra uma issue antes.

## FAQ

**Isso é um fork do cmux?**
> Não. É a mesma ideia, com escopo menor. O lmux foi escrito do zero e tem licença MIT; não tem código do cmux neste repo. Veja [no que o lmux e o cmux são diferentes](https://lmux.dev/docs/vs-cmux/).

**Por que não Ghostty com tmux?**
> Era o que eu usava antes do cmux, e é um bom setup. Só que ele não te dá uma sidebar que sabe qual agente está te esperando, um prompt que dá pra desfazer, nem sessões do Claude e do Codex que voltam sozinhas quando você reabre o app. O lmux é basicamente a libghostty com essas três coisas.

**Funciona com o Codex?**
> Sim. O Codex CLI tem status, notificações, retomada depois de reiniciar, títulos de sessão próprios, History e copiar como markdown. Editar, remover e desfazer envio são exclusivos do Claude Code. O Codex pergunta uma vez se você confia nos hooks do lmux ("Trust all and continue"); enquanto você não aceitar, ele roda sem eles.

**Outros agentes? Linux?**
> Qualquer CLI roda nele. Retomada, History e as ações de hover foram feitos pro Claude Code e pro Codex, os dois que eu uso o dia todo. Mas qualquer agente pode ter status e notificações: basta reportar o próprio estado como o Codex faz, com uma escape sequence (OSC 7501) impressa pelo próprio `my-agent`: `printf '\e]7501;state=blocked:app=my-agent\e\\'` ([como fazer](docs/agents.md#any-agent-osc-7501)). Linux e Windows, não. O lmux é AppKit nativo em cima da libghostty, e portar seria fazer outro app.

**Ele manda dados pra fora?**
> Não. O lmux não faz nenhuma chamada de rede. Sem telemetria, sem crash report, nem checagem de update (quem cuida disso é o Homebrew). Tudo o que ele grava em disco, e como apagar, está listado em [um parágrafo na página de features](docs/features.md#what-does-lmux-write-to-disk-and-how-do-i-remove-it).

Mais dúvidas? Veja o [FAQ](https://lmux.dev/docs/faq/).

## Agradecimentos

- [Ghostty](https://github.com/ghostty-org/ghostty) e libghostty, por fazerem a parte difícil
- [cmux](https://github.com/manaflow-ai/cmux), pela ideia e pelo layout que o lmux pegou emprestado


<sub>MIT. Sem vínculo com cmux, Ghostty, Anthropic ou OpenAI; os nomes só aparecem pra dizer com o que o lmux funciona. As licenças de terceiros estão em <a href="App/THIRD_PARTY_NOTICES.md">THIRD_PARTY_NOTICES</a>, que também vem dentro do lmux.app.</sub>
