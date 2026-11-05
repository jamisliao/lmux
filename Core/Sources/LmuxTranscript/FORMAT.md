# Claude Code transcript format (as observed, Claude Code 2.1.280, 2026-10)

Verified read-only against ~/.claude/projects and the 2.1.280 binary. Nothing here is a
public contract; re-check on Claude Code upgrades.

## Files
- `~/.claude/projects/<cwd with / and . replaced by ->/<sessionId>.jsonl`, one JSON object
  per line, compact JSON (`"key":"value"`, no spaces), appended over time.
- Subagents now live in `<sessionId>/subagents/agent-<id>.jsonl` (+ `.meta.json`) with
  `isSidechain:true`. Main files no longer carry sidechain entries, but old ones may.
- `<sessionId>/tool-results/*.txt` hold large tool outputs referenced from entries.
- `claude -p --resume <id>` appends to the same file and keeps the session id (no fork
  unless `--fork-session`).

## Entry kinds
Chain entries (have `uuid` + `parentUuid`, plus `isSidechain`, `sessionId`, `timestamp`,
`cwd`, `version`, `gitBranch`, ...):
- `user`, `assistant`, `system`, `attachment` (hook results, environment, skill listing,
  etc. are *in the chain*, between the prompt and the first assistant entry).
- One `assistant` entry per content block (`thinking`, `text`, `tool_use`); blocks of one
  API response share `message.id`. Original markdown = the `text` blocks of a `message.id`
  joined in order.

Metadata entries (no `uuid`, pass-through): `last-prompt` (`lastPrompt`, `leafUuid`,
optional `explicit`, `rewound`), `queue-operation` (SDK prompt queue, `content` = prompt
text), `mode`, `permission-mode`, `atis-latch`, `ai-title`, `cost-state`, `pr-link`,
`file-history-snapshot`/`-delta` (keyed by `messageId`), `summary`, `custom-title`, ...

## Real human prompt vs other `user` entries
A turn starts at a `user` entry that is NOT any of:
- tool result: `toolUseResult` / `sourceToolAssistantUUID` present, or content has a
  `tool_result` block;
- `isMeta:true` (skill bodies, image source notes, "Continue from where you left off.",
  `<local-command-caveat>`), or carries `sourceToolUseID`;
- `isCompactSummary:true` (post-compaction summary, also `isVisibleInTranscriptOnly`);
- `turnOrigin` other than `human`/`sdk` (e.g. `task_notification`);
- content starting with `<bash-stdout>`, `<bash-stderr>`, `<local-command-stdout|stderr>`,
  `<task-notification>`, or `[Request interrupted by user`.
New entries have `turnOrigin: human|sdk` and `promptSource: typed|queued|sdk|...`. Typed
`!cmd` (`<bash-input>`) and slash commands (`<command-name>`) count as prompts.

A turn = the prompt plus every chain entry after it up to the next prompt (or compaction
boundary): attachments, assistant blocks, tool results, meta entries, stop-hook /
turn_duration `system` entries.

Esc (observed with the real CLI, fixtures in `Tests/LmuxTranscriptTests/Fixtures`):
- while the reply streams or a tool runs: the turn keeps its partial assistant entries (a
  running tool gets a "User rejected tool use" `tool_result`) and ends with a `user` entry
  `[Request interrupted by user]` (`… for tool use]`). No Stop hook is sent, so lmux reads
  that marker (`TranscriptIndex.Turn.interrupted`) to know Claude stopped.
- before any reply text (also while thinking): Claude puts the prompt back into the input
  box; the prompt entry stays in the chain with no reply and no marker.
- an image prompt is `[text, image]` in these captures (`[Image #1] …` text); the image block
  may also come first, so screen matching skips the `[image]` placeholder line.

## Compaction
`system` entry `subtype:"compact_boundary"` with `parentUuid:null` and
`logicalParentUuid` pointing at the pre-compaction leaf; followed by attachments and a
`user` `isCompactSummary` entry. The chain the model sees starts at the boundary;
everything before it is only in the summary text, so removing those turns is refused.

## How resume picks the leaf (from the 2.1.280 loader)
1. `H` = last non-sidechain chain entry in file order.
2. `P` = `leafUuid` of the last `last-prompt` line. If `P` doesn't exist in the file, leaf = `H`.
3. If that `last-prompt` is `explicit:true` (rewind), leaf = `P`.
4. Otherwise leaf = `H` if `H` descends from `P`, else `P`.
5. Walk up `parentUuid` from the leaf; a dangling `parentUuid` silently truncates history,
   which is why removal must relink.

## Removal as implemented
- Drop the turn's chain entries and any off-chain descendants (old branches, inline
  sidechains).
- The first kept entry whose `parentUuid` was removed gets the removed prompt's own
  `parentUuid` (may be `null`). Only that substring of the line is rewritten.
- Drop `last-prompt` lines whose `leafUuid` was removed and `queue-operation` lines whose
  `content` equals the removed prompt (both would keep the forgotten text, shown by
  `/resume`), and `ai-title` lines written after the removed prompt (Claude's generated
  title is often made of the prompt's words; `custom-title`, set by the user, is kept).
- Refuse if a kept `tool_result` would lose its `tool_use`.
- Write atomically after copying the old file to `<file>.bak` (`.bak.N` if taken); refuse
  if the file changed since it was loaded.
