<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
    <img src="assets/logo.svg" alt="lmux" width="240">
  </picture>
</p>

<h3 align="center">light mux.</h3>

<p align="center">
  Un terminal macOS natif et léger, pour passer ses journées dans Claude Code et Codex.
</p>

<p align="center">
  <a href="https://github.com/sooftware/lmux/releases/latest/download/lmux-arm64.dmg">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="assets/download-macos-dark.svg">
      <img src="assets/download-macos.svg" alt="Télécharger l'app pour macOS" width="146" height="60">
    </picture>
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.ko.md">한국어</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ja.md">日本語</a> | <a href="README.es.md">Español</a> | <a href="README.de.md">Deutsch</a> | Français | <a href="README.it.md">Italiano</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.ru.md">Русский</a> | <a href="README.tr.md">Türkçe</a> | <a href="README.vi.md">Tiếng Việt</a>
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
    <img src="assets/hero/hero-light.webp" alt="lmux : cinq workspaces dans la barre latérale, chacun dans un état différent (en cours, terminé, attend une saisie, en échec, t'attend) ; un prompt tapé dans un split où Claude Code et Codex bossent côte à côte" width="900">
  </picture>
</p>

---

Récemment, en bossant dans mon terminal, je me suis fait une réflexion.

*Depuis quand un terminal, c'est aussi lourd ? Et est-ce que ça doit vraiment l'être ?*

Les terminaux d'aujourd'hui embarquent un navigateur, des workspaces SSH et même des badges de PR. Avec autant de fonctionnalités, forcément, c'est lourd. L'IA a beaucoup changé ma façon de travailler, mais pour moi, un terminal, ça reste juste un écran où on échange du texte. Perso, le navigateur intégré ou les workspaces SSH, je ne m'en sers pas. Pareil pour les réglages : je suis du genre à tout laisser par défaut. La seule vraie différence, c'est qu'avant je gardais un seul terminal ouvert, alors que maintenant je discute avec plusieurs agents IA à la fois, dans plein de sessions. Sauf que les apps n'ont pas arrêté de s'alourdir à cause de fonctionnalités auxquelles je ne touche jamais, et les petits agacements se sont accumulés. Alors j'ai fait **lmux** : j'ai viré tout ce que je n'utilise pas et gardé seulement ce dont j'ai vraiment besoin, plus les quelques trucs qui m'ont toujours manqué.

## Points forts

- **Léger.**<br>
  25 Mo, et presque 0 % de CPU au repos, que tu aies un workspace ouvert ou vingt. C'est du Swift natif sur libghostty : pas d'Electron, pas de moteur de navigateur, et une dizaine de réglages en tout.

- **Tu quittes, tu mets à jour, tu redémarres : tout revient.**<br>
  Tu retrouves tes workspaces, tes splits et tes dossiers, et chaque session Claude Code ou Codex reprend là où elle en était. Tu en as fermé une la semaine dernière ? History (`⇧⌘H`) la retrouve et la rouvre.

- **Savoir quel agent a besoin de toi.**<br>
  Le statut vient directement des hooks de Claude Code et de Codex lui-même : en cours, a besoin de toi, terminé ou en échec. Tu as un contour autour du panneau, un badge sur sa ligne dans la barre latérale et une notification par événement, et `⇧⌘J` t'amène à celui qui attend. N'importe quel autre agent peut s'y brancher avec une simple séquence d'échappement. lmux ne wrappe jamais `claude` ni `codex` : il se contente d'écouter.

- **Rattraper un prompt.**<br>
  Tu appuies sur Entrée, tu vois dans quel panneau c'est parti, et là : « oh putain. » Survole le message, clique sur `×` : Claude revient à l'état d'avant, sans redémarrer, comme si de rien n'était. `✎` fait pareil, mais te rend le prompt pour que tu le corriges et le renvoies. (Claude Code uniquement.)

  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/gifs/forget-x-dark.webp">
    <img src="assets/gifs/forget-x-light.webp" alt="Clic sur le × d'un prompt envoyé par erreur : le prompt et la réponse de Claude disparaissent" width="700">
  </picture>

- **Récupérer ta config cmux.**<br>
  En un clic, tu récupères ton thème, tes polices, tes raccourcis, et même tes workspaces et splits ouverts, avec leurs sessions Claude et Codex qui reprennent. Comme un nouveau navigateur qui importe tes favoris depuis Chrome. Tu changes d'avis ? Undo Import remet tout comme avant.

- **La saisie en coréen, sans accroc.**<br>
  Je suis dev coréen, donc celle-là, c'est perso. Pas de syllabes perdues ou massacrées pendant la frappe, et le hangeul prend exactement deux cellules. Le japonais et le chinois (pinyin, zhuyin) [ont eu droit au même traitement](https://lmux.dev/docs/korean-input/#chinese-and-japanese-input) : le curseur s'affiche dans le texte en cours de composition, les flèches restent à l'IME, et `⌃C` fait toujours Ctrl+C. [한국어로 보기 →](https://lmux.dev/docs/ko/)

Il y a aussi des onglets dans chaque panneau, les titres de session tirés de Claude Code, 26 thèmes et la copie en markdown. Pour le reste, voir **[toutes les fonctionnalités](docs/features.md)**.

## Installation

### Télécharger

<a href="https://github.com/sooftware/lmux/releases/latest/download/lmux-arm64.dmg">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/download-macos-dark.svg">
    <img src="assets/download-macos.svg" alt="Télécharger l'app pour macOS" width="146" height="60">
  </picture>
</a>

Ouvre le .dmg et glisse lmux.app dans Applications. Le zip et les anciennes versions sont sur [GitHub Releases](https://github.com/sooftware/lmux/releases).

### Homebrew

```sh
brew install --cask sooftware/tap/lmux
```

macOS 14+ sur Apple silicon. Pour compiler depuis les sources, voir [App/README.md](App/README.md).

Docs : [lmux.dev/docs](https://lmux.dev/docs/)

## Utilisation

**Premier lancement.** Si tu viens de cmux, lmux te propose de récupérer ta config et tes workspaces ouverts. Il propose ensuite d'installer quelques hooks Claude Code, en te montrant le diff exact qu'il va appliquer à ton `settings.json` avant de toucher à quoi que ce soit. Accepte les deux, lance `claude` dans n'importe quel panneau, et la barre latérale t'indique quel agent tourne, lequel a fini et lequel t'attend.

**Codex aussi.** Si le CLI Codex est installé, lmux propose ensuite d'installer ses hooks de la même manière (cette fois, le diff porte sur `~/.codex/hooks.json`). Au prochain démarrage, Codex te demande une seule fois de valider les nouveaux hooks : choisis **Trust all and continue**.

**Au quotidien.** Voici les raccourcis par défaut. Un `keybind` dans ta config Ghostty les écrase, et les menus affichent les raccourcis en vigueur.

| pour faire ça                                 | appuie sur                                       |
|-----------------------------------------------|--------------------------------------------------|
| nouveau workspace                             | `⌘N`                                             |
| split à droite / en bas                       | `⌘D` / `⇧⌘D`                                     |
| fermer un onglet / un workspace               | `⌘W` / `⇧⌘W`, ou `×` sur une ligne survolée      |
| nouvel onglet dans le panneau                 | `⌘T`                                             |
| changer d'onglet                              | `⇧⌘[` / `⇧⌘]`, `⌃1`–`⌃8`, `⌃9` pour le dernier   |
| changer de workspace                          | `⌘1`–`⌘8`, `⌘9` pour le dernier, `⌃⌘[` / `⌃⌘]`  |
| réorganiser les workspaces                    | fais glisser une ligne                           |
| passer d'un panneau à l'autre                 | `⌘[` / `⌘]`                                      |
| zoomer sur le panneau actif (masquer le reste)| `⇧⌘↩`                                            |
| aller à l'agent qui a besoin de toi           | `⇧⌘J`                                            |
| dernière notification non lue / notifications récentes | `⇧⌘U` / clique sur la cloche |
| réinitialiser le statut d'une ligne à la main | fais un clic droit dessus, puis **Clear Status** |
| chercher dans les sessions passées            | `⇧⌘H`                                            |
| copier / modifier et renvoyer / supprimer un message | survole-le, puis `⧉` / `✎` / `×`          |
| copier la dernière réponse en markdown        | `⌥⌘C`                                            |
| annuler le prompt que tu viens d'envoyer      | `⌘Z` tant que le toast « Sent to … » est affiché |
| chercher dans le scrollback                   | `⌘F`                                             |
| afficher / masquer la barre latérale          | `⌃⌘S`                                            |
| thème, police et tout le reste                | `⌘,`                                             |

Quelques GIF courts dans [la visite guidée](docs/tour.md) montrent le contour autour des agents, History, le retour en arrière sur un message et la saisie en coréen.

## lmux vs cmux

Les deux apps tournent sur le même Mac, ouvertes avec 1, 10 et 20 workspaces (2 shells actifs dans chacun) et laissées au repos. Plus c'est bas, mieux c'est. Quand lmux n'est pas l'app au premier plan, il libère sa mémoire GPU : on le mesure donc deux fois, au premier plan et en arrière-plan derrière une autre app. Voir la [méthodologie](scripts/BENCH.md).

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/bench-scaling-dark.svg">
    <img src="assets/bench-scaling.svg" alt="Mémoire et CPU au repos avec 1, 10 et 20 workspaces : lmux au premier plan 182, 207 et 235 MB à 0.1% de CPU ; lmux en arrière-plan 45, 71 et 99 MB à 0.0% de CPU ; cmux 0.65.2 398, 548 et 661 MB à 7.2, 7.4 et 8.1% de CPU" width="760">
  </picture>
</p>

|                              | cmux 0.65.2 | lmux, au premier plan | lmux, en arrière-plan |
|------------------------------|------------:|----------------------:|----------------------:|
| Taille de l'app              | 242 Mo      | **25 Mo**             | **25 Mo**             |
| Mémoire, 1 workspace         | 398 Mo      | **182 Mo**            | **45 Mo**             |
| Mémoire, 10 workspaces       | 548 Mo      | **207 Mo**            | **71 Mo**             |
| Mémoire, 20 workspaces       | 661 Mo      | **235 Mo**            | **99 Mo**             |
| CPU au repos, 1 workspace    | 7,16 %      | **0,07 %**            | **0,00 %**            |
| CPU au repos, 10 workspaces  | 7,39 %      | **0,12 %**            | **0,00 %**            |
| CPU au repos, 20 workspaces  | 8,10 %      | **0,10 %**            | **0,00 %**            |
| Réglages                     | ~200        | **~10**               | **~10**               |

<sub>M4 Pro, macOS 26.6.2, lmux 0.0.102 vs cmux 0.65.2. 2 panneaux par workspace, tous les shells actifs, 5 mesures en alternance, valeurs médianes. La mémoire correspond à l'empreinte physique de tous les processus de l'app ; la taille de l'app est celle du `.app` Apple silicon sur le disque. L'écran était verrouillé pendant les mesures, donc cmux était lui aussi en arrière-plan. Sa mémoire varie beaucoup selon l'état des fenêtres, alors prends ses chiffres comme une photo à un instant T. Les shells et les agents dans les panneaux sont les mêmes des deux côtés et ne sont pas comptés : on mesure ici le coût du terminal lui-même. Chez lmux, l'écart de 0,07 à 0,12 % selon le nombre de workspaces reste dans le bruit de mesure.</sub>

Le CPU au repos, c'est le chiffre qui compte le plus pour moi : c'est lui qui vide ta batterie pendant que vingt agents attendent que tu lises ce qu'ils ont écrit.

**Pourquoi pas lmux ?**

- Tu utilises le navigateur intégré de cmux, ses workspaces SSH, ses widgets de ports et de PR, ses commandes perso, ou tu as besoin de plus de scripting que ce que permettent `lmux send` et `lmux new-workspace`.
- Tu as besoin de Linux ou de Windows.
- Tu aimes avoir un réglage pour tout. cmux en a à peu près deux cents.

Dans ce cas, prends cmux. C'est un super outil, et j'ai encore beaucoup à apprendre de lui.

## Contribuer

Chaque changement doit respecter ces règles :

- **La légèreté d'abord.** Une fonctionnalité qui ajoute surtout du poids saute, même si elle est sympa. La CI recale toute PR qui fait passer le CPU au repos au-dessus du budget.
- **Ne jamais wrapper `claude`** (ni `codex`). lmux écoute via les hooks et les fichiers que les agents écrivent déjà, donc ils marchent exactement pareil avec ou sans lui. Même `✎`, `×` et `⌘Z` ne modifient pas une session : ils pilotent le menu de rewind de Claude Code lui-même, dans le `claude` en cours, donc rien ne redémarre.
- **Une UI calme.** Une notification par événement (plus un rappel optionnel), un indicateur par ligne, et rien ne clignote sauf si quelque chose a vraiment besoin de toi.

Tout est bienvenu, d'une coquille corrigée à un module entier, tant que ça respecte ces règles. Le build, les tests et la règle de périmètre sont dans [CONTRIBUTING.md](CONTRIBUTING.md). Pour une nouvelle fonctionnalité, ouvre d'abord une issue.

## FAQ

**C'est un fork de cmux ?**
> Non. Même idée en plus petit, écrit de zéro et sous licence MIT. Il n'y a pas une ligne de code de cmux dans ce repo. Voici [ce qui distingue lmux de cmux](https://lmux.dev/docs/vs-cmux/).

**Pourquoi pas Ghostty et tmux ?**
> C'est ce que j'utilisais avant cmux, et c'est un très bon setup. Mais ça ne te donne ni une barre latérale qui sait quel agent t'attend, ni un prompt que tu peux rattraper, ni des sessions Claude et Codex qui reprennent toutes seules après un redémarrage. lmux, c'est en gros libghostty plus ces trois choses-là.

**Ça marche avec Codex ?**
> Oui. Avec le CLI Codex, tu as le statut, les notifications, la reprise au redémarrage, ses propres titres de session, History et la copie en markdown. Modifier, supprimer et annuler un envoi, c'est réservé à Claude Code. Codex demande une fois s'il doit faire confiance aux hooks de lmux (« Trust all and continue ») ; tant que tu n'as pas dit oui, il tourne sans.

**D'autres agents ? Linux ?**
> N'importe quel CLI tourne dedans. La reprise, History et les actions au survol sont faits pour Claude Code et Codex, les deux que j'utilise toute la journée. Mais tout agent peut avoir le statut et les notifications s'il signale son état comme Codex, avec une seule séquence d'échappement (OSC 7501) : `printf '\e]7501;state=blocked:app=my-agent\e\\'`, émise par `my-agent` lui-même ([comment faire](docs/agents.md#any-agent-osc-7501)). Linux et Windows, non : lmux est en AppKit natif sur libghostty, et un portage, ce serait une autre app.

**Ça envoie des données quelque part ?**
> Non. lmux ne fait aucun appel réseau. Pas de télémétrie, pas de rapports de crash, même pas de vérification des mises à jour (Homebrew s'en occupe). Tout ce qu'il écrit sur le disque, et comment le supprimer, tient en [un paragraphe de la page des fonctionnalités](docs/features.md#what-does-lmux-write-to-disk-and-how-do-i-remove-it).

D'autres questions ? Voir la [FAQ](https://lmux.dev/docs/faq/).

## Remerciements

- [Ghostty](https://github.com/ghostty-org/ghostty) et libghostty, pour avoir fait le plus dur
- [cmux](https://github.com/manaflow-ai/cmux), pour l'idée et la disposition que lmux lui emprunte


<p align="center">
  Si lmux t'a déjà permis d'annuler un prompt parti dans le mauvais panneau, une étoile aide d'autres personnes à découvrir le projet.<br><br>
  <a href="https://github.com/sooftware/lmux"><img src="https://img.shields.io/github/stars/sooftware/lmux?style=social" alt="Mettre une étoile à lmux sur GitHub"></a>
</p>

<sub>MIT. Sans lien avec cmux, Ghostty, Anthropic ou OpenAI ; leurs noms servent uniquement à indiquer avec quoi lmux fonctionne. Les licences tierces sont dans <a href="App/THIRD_PARTY_NOTICES.md">THIRD_PARTY_NOTICES</a>, également fourni dans lmux.app.</sub>
