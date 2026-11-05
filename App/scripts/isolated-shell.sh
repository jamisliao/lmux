# Sourced by the harness scripts (apptest, imetest, e2e, measure_idle, readme, bench):
# panes never start the user's login shell with their rc files and real history. A run
# used to append its test commands (and every `exit`) to ~/.zsh_history.
#
#   lmux_isolated_shell DIR
#     writes DIR/pane-shell (zsh, ZDOTDIR=DIR/zdot whose .zshrc only sets HISTFILE inside DIR,
#     a plain prompt and Ghostty's shell integration) and exports LMUX_PANE_COMMAND to it,
#     plus SHELL_SESSIONS_DISABLE=1 (no ~/.zsh_sessions) and HISTFILE for anything else.
#   history_stamp
#     size and mtime of the user's ~/.zsh_history (compare before / after a run).

lmux_isolated_shell() {
  local d="$1"
  mkdir -p "$d/zdot"
  : > "$d/zsh_history"
  cat > "$d/zdot/.zshrc" <<RC
HISTFILE='$d/zsh_history'
PROMPT='%~ %# '
if [ -n "\$GHOSTTY_RESOURCES_DIR" ] && [ -r "\$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration" ]; then
  source "\$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration"
fi
RC
  # Ghostty starts the pane through login(1), which keeps the environment but not every
  # variable a shell reads early: the isolation is set again right here.
  cat > "$d/pane-shell" <<SH
#!/bin/sh
export ZDOTDIR='$d/zdot' HISTFILE='$d/zsh_history' SHELL_SESSIONS_DISABLE=1
exec /bin/zsh "\$@"
SH
  chmod +x "$d/pane-shell"
  export LMUX_PANE_COMMAND="$d/pane-shell" SHELL_SESSIONS_DISABLE=1 HISTFILE="$d/zsh_history"
}

history_stamp() { stat -f '%z %m' "$HOME/.zsh_history" 2>/dev/null || echo none; }
