<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
    <img src="assets/logo.svg" alt="lmux" width="240">
  </picture>
</p>

<h3 align="center">light mux.</h3>

<p align="center">
  Una terminal nativa y ligera para macOS, pensada para pasarte el día entero en Claude Code y Codex.
</p>

<p align="center">
  <a href="https://github.com/sooftware/lmux/releases/latest/download/lmux-arm64.dmg">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="assets/download-macos-dark.svg">
      <img src="assets/download-macos.svg" alt="Descargar la app para macOS" width="146" height="60">
    </picture>
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.ko.md">한국어</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ja.md">日本語</a> | Español | <a href="README.de.md">Deutsch</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.ru.md">Русский</a> | <a href="README.tr.md">Türkçe</a> | <a href="README.vi.md">Tiếng Việt</a>
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
    <img src="assets/hero/hero-light.webp" alt="lmux: cinco workspaces en la barra lateral, cada uno en un estado distinto (trabajando, terminado, necesita una respuesta, falló, esperándote); un prompt escrito en un split donde Claude Code y Codex trabajan uno al lado del otro" width="900">
  </picture>
</p>

---

Hace poco, trabajando en la terminal, me quedé pensando.

*¿En qué momento se han vuelto tan pesadas las terminales? ¿Y de verdad hace falta que lo sean?*

Hoy en día las apps de terminal traen navegador, workspaces por SSH y hasta badges de PR. Con tantas funciones, es normal que pesen. La IA ha cambiado mucho mi forma de trabajar, pero para mí una terminal sigue siendo solo una pantalla donde va y viene texto. Yo, al menos, no uso ni el navegador ni los workspaces por SSH dentro de la terminal. Con los ajustes, igual: soy de los que lo dejan casi todo por defecto. Lo que sí ha cambiado es que antes tenía una sola terminal abierta y ahora me paso el día hablando con varios agentes de IA a la vez, cada uno en su sesión. Pero la app no paraba de engordar a base de funciones que nunca toco, y las pequeñas molestias se iban acumulando. Así que me hice **lmux**. Le he dejado fuera todo lo que no uso: tiene lo que necesito de verdad y esas cosas que siempre había echado en falta.

## Lo más destacado

- **Ligera.**<br>
  Una app de 25 MB que en reposo ronda el 0 % de CPU, tengas un workspace abierto o veinte. Swift nativo sobre libghostty: nada de Electron, nada de motor de navegador, y unos diez ajustes.

- **Cierras, actualizas, reinicias… y todo sigue ahí.**<br>
  Vuelven los mismos workspaces, splits y carpetas, y cada sesión de Claude Code o Codex sigue donde la dejaste. ¿Cerraste una la semana pasada? History (`⇧⌘H`) la encuentra y la recupera.

- **Sabes en todo momento qué agente te necesita.**<br>
  El estado sale directamente de los hooks de Claude Code y del propio Codex: en marcha, te necesita, terminado o con error. Aparece un anillo en el panel y un badge en la fila, te llega una sola notificación por evento y con `⇧⌘J` saltas al que está esperando. Cualquier otro agente puede sumarse con una sola secuencia de escape. lmux nunca hace de wrapper de `claude` ni de `codex`: solo escucha.

- **Deshaz un prompt.**<br>
  Pulsas Enter, ves a qué panel ha ido y piensas: «mierda». Pasas el cursor por el turno, pulsas `×` y Claude rebobina hasta justo antes, sin reiniciar, como si nunca hubiera pasado. `✎` hace lo mismo, pero te devuelve el prompt para que lo corrijas y lo vuelvas a enviar. (Solo en Claude Code.)

  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/gifs/forget-x-dark.webp">
    <img src="assets/gifs/forget-x-light.webp" alt="Al pulsar × en un prompt enviado por error, desaparecen el prompt y la respuesta de Claude" width="700">
  </picture>

- **Tráete tu configuración de cmux.**<br>
  Con un clic te traes el tema, las fuentes, los atajos e incluso los workspaces y splits que tengas abiertos, y sus sesiones de Claude y Codex siguen donde estaban. Es como cuando un navegador nuevo importa tus marcadores de Chrome. Si te arrepientes, Undo Import lo deja todo como estaba.

- **Entrada en coreano que funciona sin más.**<br>
  Soy desarrollador coreano, así que esto me toca de cerca. No se pierden ni se rompen sílabas mientras escribes, y el hangul ocupa exactamente dos celdas. Con el japonés y el chino (pinyin, zhuyin) [pasa lo mismo](https://lmux.dev/docs/korean-input/#chinese-and-japanese-input): el cursor aparece dentro del texto que estás componiendo, las flechas siguen en manos del IME y `⌃C` sigue siendo Ctrl+C. [한국어로 보기 →](https://lmux.dev/docs/ko/)

También tiene pestañas en cada panel, títulos de sesión sacados de Claude Code, 26 temas y copiar como markdown. El resto está en **[la lista completa de funciones](docs/features.md)**.

## Instalación

### Descarga

<a href="https://github.com/sooftware/lmux/releases/latest/download/lmux-arm64.dmg">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/download-macos-dark.svg">
    <img src="assets/download-macos.svg" alt="Descargar la app para macOS" width="146" height="60">
  </picture>
</a>

Abre el .dmg y arrastra lmux.app a Aplicaciones. El zip y las versiones anteriores están en [GitHub Releases](https://github.com/sooftware/lmux/releases).

### Homebrew

```sh
brew install --cask sooftware/tap/lmux
```

macOS 14+ en Apple silicon. Para compilarla desde el código fuente, mira [App/README.md](App/README.md).

Documentación: [lmux.dev/docs](https://lmux.dev/docs/)

## Uso

**Primer arranque.** Si vienes de cmux, lmux te ofrece traerte tu configuración y tus workspaces abiertos. Después te propone instalar unos cuantos hooks de Claude Code y, antes de tocar nada, te enseña el diff exacto que va a aplicar a tu `settings.json`. Acepta las dos cosas, ejecuta `claude` en cualquier panel y la barra lateral empezará a decirte qué agente está en marcha, cuál ha terminado y cuál te está esperando.

**Codex también.** Si tienes instalado el CLI de Codex, lmux te propone a continuación instalar sus hooks, del mismo modo (esta vez el diff es sobre `~/.codex/hooks.json`). La próxima vez que arranques Codex, te pedirá que confíes en los hooks nuevos (solo esa vez). Elige **Trust all and continue**.

**El día a día.** Estos son los atajos por defecto. Un `keybind` en tu configuración de Ghostty tiene prioridad, y los menús muestran siempre lo que tengas asignado.

| para hacer esto                               | pulsa                                            |
|-----------------------------------------------|--------------------------------------------------|
| nuevo workspace                               | `⌘N`                                             |
| split a la derecha / abajo                    | `⌘D` / `⇧⌘D`                                     |
| cerrar una pestaña / un workspace             | `⌘W` / `⇧⌘W`, o `×` en la fila bajo el cursor    |
| nueva pestaña en el panel                     | `⌘T`                                             |
| cambiar de pestaña                            | `⇧⌘[` / `⇧⌘]`, `⌃1`–`⌃8`, `⌃9` para la última    |
| cambiar de workspace                          | `⌘1`–`⌘8`, `⌘9` para el último, `⌃⌘[` / `⌃⌘]`   |
| reordenar workspaces                          | arrastra una fila                                |
| moverte entre paneles                         | `⌘[` / `⌘]`                                      |
| ampliar el panel activo (ocultar el resto)    | `⇧⌘↩`                                            |
| ir al agente que te necesita                  | `⇧⌘J`                                            |
| última sin leer / notificaciones recientes    | `⇧⌘U` / clic en la campana                       |
| restablecer a mano el estado de una fila      | clic derecho sobre ella y luego **Clear Status** |
| buscar sesiones anteriores                    | `⇧⌘H`                                            |
| copiar / editar y reenviar / quitar un turno  | pasa el cursor por encima y luego `⧉` / `✎` / `×` |
| copiar la última respuesta como markdown      | `⌥⌘C`                                            |
| deshacer el prompt que acabas de mandar       | `⌘Z` mientras se ve el aviso "Sent to …"         |
| buscar en el scrollback                       | `⌘F`                                             |
| mostrar u ocultar la barra lateral            | `⌃⌘S`                                            |
| tema, fuente y todo lo demás                  | `⌘,`                                             |

En [el tour](docs/tour.md) hay GIFs cortos del anillo de los agentes, History, cómo deshacer un turno y la entrada en coreano.

## lmux vs cmux

Las dos apps en el mismo Mac, abiertas con 1, 10 y 20 workspaces (2 shells activas en cada uno) y en reposo. Cuanto más bajo, mejor. lmux libera su memoria de GPU cuando no es la app que estás mirando, así que lo medí dos veces: en primer plano y en segundo plano, detrás de otra app. Los detalles están en la [metodología](scripts/BENCH.md).

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/bench-scaling-dark.svg">
    <img src="assets/bench-scaling.svg" alt="Memoria y CPU en reposo con 1, 10 y 20 workspaces: lmux en primer plano 182, 207 y 235 MB al 0.1% de CPU; lmux en segundo plano 45, 71 y 99 MB al 0.0% de CPU; cmux 0.65.2 398, 548 y 661 MB al 7.2, 7.4 y 8.1% de CPU" width="760">
  </picture>
</p>

|                              | cmux 0.65.2 | lmux, en primer plano | lmux, en segundo plano |
|------------------------------|------------:|----------------------:|-----------------------:|
| Tamaño de la app             | 242 MB      | **25 MB**             | **25 MB**              |
| Memoria, 1 workspace         | 398 MB      | **182 MB**            | **45 MB**              |
| Memoria, 10 workspaces       | 548 MB      | **207 MB**            | **71 MB**              |
| Memoria, 20 workspaces       | 661 MB      | **235 MB**            | **99 MB**              |
| CPU en reposo, 1 workspace   | 7,16 %      | **0,07 %**            | **0,00 %**             |
| CPU en reposo, 10 workspaces | 7,39 %      | **0,12 %**            | **0,00 %**             |
| CPU en reposo, 20 workspaces | 8,10 %      | **0,10 %**            | **0,00 %**             |
| Ajustes                      | ~200        | **~10**               | **~10**                |

<sub>M4 Pro, macOS 26.6.2, lmux 0.0.102 vs cmux 0.65.2. 2 paneles por workspace, todas las shells activas, 5 ejecuciones intercaladas, medianas. La memoria es la huella física (physical footprint) de todos los procesos de la app; el tamaño de la app es el `.app` para Apple silicon en disco. La pantalla estuvo bloqueada durante la prueba, por lo que cmux también estaba en segundo plano. Su memoria varía mucho según el estado de la ventana, así que toma sus cifras como una foto puntual. Las shells y los agentes que corren dentro de los paneles son los mismos en ambos lados y no se cuentan; esto es lo que cuesta la terminal en sí. Que lmux oscile entre 0,07 y 0,12 % según el número de workspaces entra dentro del ruido normal entre ejecuciones.</sub>

La CPU en reposo es la cifra que más me importa, porque es lo que se come la batería mientras veinte agentes esperan a que leas lo que han escrito.

**¿Cuándo no usar lmux?**

- Usas el navegador integrado de cmux, los workspaces por SSH, los widgets de puertos y de PR, los comandos personalizados, o necesitas más scripting del que dan `lmux send` y `lmux new-workspace`.
- Necesitas Linux o Windows.
- Quieres poder ajustarlo todo. cmux tiene unos doscientos ajustes.

En ese caso, quédate con cmux. Es genial, y yo voy a seguir aprendiendo de él.

## Contribuir

Cada cambio tiene que cumplir estas reglas:

- **Ligereza ante todo.** Una función que sobre todo añade peso se queda fuera, aunque esté bien tenerla. El CI falla si un PR sube la CPU en reposo por encima del límite.
- **Nada de wrappers sobre `claude`** (ni `codex`). lmux escucha a través de hooks y de los archivos que los agentes ya escriben, así que funcionan exactamente igual con lmux o sin él. Ni siquiera `✎`, `×` y `⌘Z` editan una sesión: manejan el propio menú de rebobinado de Claude Code en el `claude` que está corriendo, así que no se reinicia nada.
- **Una interfaz tranquila.** Recibes una notificación por evento (más un recordatorio opcional) y un indicador por fila, y nada parpadea salvo que algo te necesite de verdad.

Cualquier aporte es bienvenido, desde una errata hasta módulos enteros, mientras encaje con estas reglas. En [CONTRIBUTING.md](CONTRIBUTING.md) está todo: cómo compilar, los tests y la regla de alcance. Si es una función nueva, abre antes un issue.

## FAQ

**¿Es un fork de cmux?**
> No. Es la misma idea con un alcance más acotado, escrita desde cero y con licencia MIT. En este repo no hay código de cmux. Aquí explico [en qué se diferencian lmux y cmux](https://lmux.dev/docs/vs-cmux/).

**¿Por qué no Ghostty y tmux?**
> Es lo que usaba antes de cmux, y funciona bien. Pero no te da una barra lateral que sepa qué agente te está esperando, un prompt que puedas deshacer ni sesiones de Claude y Codex que se retomen solas al volver a abrir. lmux es básicamente libghostty más esas tres cosas.

**¿Funciona con Codex?**
> Sí. Con el CLI de Codex tienes estado, notificaciones, reanudación al reiniciar, sus propios títulos de sesión, History y copiar como markdown. Editar, quitar y deshacer el envío son solo para Claude Code. Codex te pide una vez que confíes en los hooks de lmux ("Trust all and continue"); hasta que lo hagas, funciona sin ellos.

**¿Otros agentes? ¿Linux?**
> Puedes ejecutar cualquier CLI. Reanudar, History y las acciones al pasar el cursor están hechos para Claude Code y Codex, los dos en los que vivo, pero cualquier agente puede tener estado y notificaciones si lo comunica igual que Codex, con una secuencia de escape (OSC 7501): `printf '\e]7501;state=blocked:app=my-agent\e\\'`, que imprime el propio `my-agent` ([cómo](docs/agents.md#any-agent-osc-7501)). ¿Linux y Windows? No. lmux es AppKit nativo sobre libghostty, y portarlo sería hacer otra app.

**¿Envía datos a algún sitio?**
> No. lmux no hace ninguna llamada de red. Ni telemetría, ni informes de fallos, ni siquiera comprueba si hay actualizaciones (de eso se encarga Homebrew). Todo lo que escribe en disco, y cómo borrarlo, está en [un párrafo de la página de funciones](docs/features.md#what-does-lmux-write-to-disk-and-how-do-i-remove-it).

¿Más preguntas? Mira las [FAQ](https://lmux.dev/docs/faq/).

## Agradecimientos

- [Ghostty](https://github.com/ghostty-org/ghostty) y libghostty, por hacer la parte difícil
- [cmux](https://github.com/manaflow-ai/cmux), por la idea y el layout que lmux toma prestados


<p align="center">
  Si alguna vez has podido deshacer con lmux un prompt enviado al panel equivocado, una estrella ayuda a que más gente descubra el proyecto.<br><br>
  <a href="https://github.com/sooftware/lmux"><img src="https://img.shields.io/github/stars/sooftware/lmux?style=social" alt="Dale una estrella a lmux en GitHub"></a>
</p>

<sub>MIT. Sin afiliación con cmux, Ghostty, Anthropic ni OpenAI; sus nombres se usan solo para describir con qué funciona lmux. Las licencias de terceros están en <a href="App/THIRD_PARTY_NOTICES.md">THIRD_PARTY_NOTICES</a>, que también va incluido dentro de lmux.app.</sub>
