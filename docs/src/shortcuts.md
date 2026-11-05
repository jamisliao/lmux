# Shortcuts

lmux is a macOS terminal on libghostty, and these are its default shortcuts. A `keybind` in your Ghostty config wins over them, and the menus always show whatever is bound.

## Every day

| to do this | press |
|---|---|
| new workspace | `⌘N` |
| split right / down | `⌘D` / `⇧⌘D` |
| close a tab / a workspace | `⌘W` / `⇧⌘W`, or `×` on a hovered row |
| new tab in the pane | `⌘T` |
| switch tab | `⇧⌘[` / `⇧⌘]` or `⌃⇧⇥` / `⌃⇥`, `⌃1`–`⌃8`, `⌃9` for the last |
| switch workspace | `⌘1`–`⌘8`, `⌘9` for the last, `⌃⌘[` / `⌃⌘]` |
| reorder workspaces | drag a row |
| move between panes | `⌘[` / `⌘]` |
| zoom the focused pane (hide the rest) | `⇧⌘↩` |
| jump to the agent that needs you | `⇧⌘J` |
| latest unread / recent notifications | `⇧⌘U` / click the bell |
| reset a row's status by hand | right-click it, then **Clear Status** |
| search past sessions | `⇧⌘H` |
| copy / edit & resend / remove a turn | hover it, then `⧉` / `✎` / `×` |
| copy the last reply as markdown | `⌥⌘C` |
| undo the prompt you just sent | `⌘Z` while the "Sent to …" toast is up |
| find in scrollback | `⌘F` |
| toggle the sidebar | `⌃⌘S` |
| theme, font and the rest | `⌘,` |

`✎`, `×` and `⌘Z` are Claude Code only; a Codex turn shows just `⧉`.

## More

| to do this | press |
|---|---|
| move between panes by direction | `⌥⌘` + arrow |
| resize the focused pane | `⌃⌘` + arrow |
| make the panes equal | `⌃⌘=` |
| next / previous match in find | `⌘G` / `⇧⌘G` |
| font size bigger / smaller / reset | **View** menu (Ghostty's keys) |
| full screen | `⌃⌘F` |
| rename the tab / the workspace | `⌘R` / double-click the workspace's row |
| move the tab left / right | `⌥⇧⌘[` / `⌥⇧⌘]`, or drag it |
| close the pane's other tabs | `⌥⌘T` |
| zoom a tab's pane | double-click the tab |

## Changing a shortcut

Add a `keybind` line to `~/.config/ghostty/config`, in Ghostty's syntax. lmux maps Ghostty's actions onto its own: `new_window` is New Workspace, `new_tab` is a new tab in the pane, `new_split:right` and `new_split:down` split, `close_surface` closes a tab, `close_window` a workspace, `next_tab` / `previous_tab` switch tabs, `goto_tab:N` still switches workspaces (`⌘1`–`⌘9`), `goto_split:next` / `goto_split:previous` move between panes and `toggle_split_zoom` zooms.

```
keybind = super+shift+n=new_window
```

`⇧⌘J` is lmux's own; Ghostty's default binding for it stays off unless your config binds it.

With the Korean input source (or another non-Latin one) on, shortcuts with `⌘` or `⌃` still work: a key the menus miss is retried as the key a Latin layout types there. See [Korean input](korean-input.md).
