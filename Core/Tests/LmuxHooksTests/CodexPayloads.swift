// Generated from Codex CLI 0.166.0 hook payloads captured in a temp CODEX_HOME,
// sanitized (paths -> /Users/me/..., no account ids). Do not edit by hand.

enum CodexPayloads {
    static let interrupt = #"""
{"session_id": "01a19af7-a41b-7be0-a747-28b261b34a33", "turn_id": "01a19af7-a458-7ea2-9864-b804acb3e56c", "transcript_path": "/Users/me/.codex/sessions/2026/11/02/rollout-2026-11-02T15-34-43-01a19af7-a41b-7be0-a747-28b261b34a33.jsonl", "cwd": "/Users/me/proj", "hook_event_name": "Interrupt", "model": "gpt-6-luna", "permission_mode": "default"}
"""#
    static let permissionRequest = #"""
{"session_id": "01a19af7-a41b-7be0-a747-28b261b34a33", "turn_id": "01a19af7-a458-7ea2-9864-b804acb3e56c", "transcript_path": "/Users/me/.codex/sessions/2026/11/02/rollout-2026-11-02T15-34-43-01a19af7-a41b-7be0-a747-28b261b34a33.jsonl", "cwd": "/Users/me/proj", "hook_event_name": "PermissionRequest", "model": "gpt-6-luna", "permission_mode": "default", "tool_name": "Bash", "tool_input": {"command": "printf 'lmux' > made.txt", "description": "May I write made.txt in the workspace with the requested word?"}}
"""#
    static let postToolUse_1 = #"""
{"session_id": "01a19afa-3664-79f1-b4d9-2fd9b2ca2250", "turn_id": "01a19afa-368a-7b60-8685-019d8bfac4bf", "transcript_path": "/Users/me/.codex/sessions/2026/11/02/rollout-2026-11-02T15-37-31-01a19afa-3664-79f1-b4d9-2fd9b2ca2250.jsonl", "cwd": "/Users/me/proj", "hook_event_name": "PostToolUse", "model": "gpt-6-luna", "permission_mode": "bypassPermissions", "tool_name": "Bash", "tool_input": {"command": "cat note.txt"}, "tool_response": "hello\n", "tool_use_id": "exec-626b3641-212f-4a89-b37f-8616d3a32065"}
"""#
    static let postToolUse = #"""
{"session_id": "01a19af7-a41b-7be0-a747-28b261b34a33", "turn_id": "01a19af7-a458-7ea2-9864-b804acb3e56c", "transcript_path": "/Users/me/.codex/sessions/2026/11/02/rollout-2026-11-02T15-34-43-01a19af7-a41b-7be0-a747-28b261b34a33.jsonl", "cwd": "/Users/me/proj", "hook_event_name": "PostToolUse", "model": "gpt-6-luna", "permission_mode": "default", "tool_name": "Bash", "tool_input": {"command": "printf 'lmux' > made.txt"}, "tool_response": "zsh:1: operation not permitted: made.txt\n", "tool_use_id": "exec-4ed9d00c-81b1-4372-a018-a46e09895ce5"}
"""#
    static let preToolUse_1 = #"""
{"session_id": "01a19af7-a41b-7be0-a747-28b261b34a33", "turn_id": "01a19af7-a458-7ea2-9864-b804acb3e56c", "transcript_path": "/Users/me/.codex/sessions/2026/11/02/rollout-2026-11-02T15-34-43-01a19af7-a41b-7be0-a747-28b261b34a33.jsonl", "cwd": "/Users/me/proj", "hook_event_name": "PreToolUse", "model": "gpt-6-luna", "permission_mode": "default", "tool_name": "Bash", "tool_input": {"command": "printf 'lmux' > made.txt"}, "tool_use_id": "exec-1d7d6608-436b-49ed-be62-936aed855912"}
"""#
    static let preToolUse_2 = #"""
{"session_id": "01a19afa-3664-79f1-b4d9-2fd9b2ca2250", "turn_id": "01a19afa-368a-7b60-8685-019d8bfac4bf", "transcript_path": "/Users/me/.codex/sessions/2026/11/02/rollout-2026-11-02T15-37-31-01a19afa-3664-79f1-b4d9-2fd9b2ca2250.jsonl", "cwd": "/Users/me/proj", "hook_event_name": "PreToolUse", "model": "gpt-6-luna", "permission_mode": "bypassPermissions", "tool_name": "Bash", "tool_input": {"command": "cat note.txt"}, "tool_use_id": "exec-626b3641-212f-4a89-b37f-8616d3a32065"}
"""#
    static let preToolUse = #"""
{"session_id": "01a19af7-a41b-7be0-a747-28b261b34a33", "turn_id": "01a19af7-a458-7ea2-9864-b804acb3e56c", "transcript_path": "/Users/me/.codex/sessions/2026/11/02/rollout-2026-11-02T15-34-43-01a19af7-a41b-7be0-a747-28b261b34a33.jsonl", "cwd": "/Users/me/proj", "hook_event_name": "PreToolUse", "model": "gpt-6-luna", "permission_mode": "default", "tool_name": "Bash", "tool_input": {"command": "printf 'lmux' > made.txt"}, "tool_use_id": "exec-4ed9d00c-81b1-4372-a018-a46e09895ce5"}
"""#
    static let sessionStart_1 = #"""
{"session_id": "01a19afa-3664-79f1-b4d9-2fd9b2ca2250", "transcript_path": "/Users/me/.codex/sessions/2026/11/02/rollout-2026-11-02T15-37-31-01a19afa-3664-79f1-b4d9-2fd9b2ca2250.jsonl", "cwd": "/Users/me/proj", "hook_event_name": "SessionStart", "model": "gpt-6-luna", "permission_mode": "bypassPermissions", "source": "startup"}
"""#
    static let sessionStart = #"""
{"session_id": "01a19af7-a41b-7be0-a747-28b261b34a33", "transcript_path": "/Users/me/.codex/sessions/2026/11/02/rollout-2026-11-02T15-34-43-01a19af7-a41b-7be0-a747-28b261b34a33.jsonl", "cwd": "/Users/me/proj", "hook_event_name": "SessionStart", "model": "gpt-6-luna", "permission_mode": "default", "source": "startup"}
"""#
    static let stop = #"""
{"session_id": "01a19afa-3664-79f1-b4d9-2fd9b2ca2250", "turn_id": "01a19afa-368a-7b60-8685-019d8bfac4bf", "transcript_path": "/Users/me/.codex/sessions/2026/11/02/rollout-2026-11-02T15-37-31-01a19afa-3664-79f1-b4d9-2fd9b2ca2250.jsonl", "cwd": "/Users/me/proj", "hook_event_name": "Stop", "model": "gpt-6-luna", "permission_mode": "bypassPermissions", "stop_hook_active": false, "last_assistant_message": "# Result\n\nhello"}
"""#
    static let userPromptSubmit_1 = #"""
{"session_id": "01a19afa-3664-79f1-b4d9-2fd9b2ca2250", "turn_id": "01a19afa-368a-7b60-8685-019d8bfac4bf", "transcript_path": "/Users/me/.codex/sessions/2026/11/02/rollout-2026-11-02T15-37-31-01a19afa-3664-79f1-b4d9-2fd9b2ca2250.jsonl", "cwd": "/Users/me/proj", "hook_event_name": "UserPromptSubmit", "model": "gpt-6-luna", "permission_mode": "bypassPermissions", "prompt": "Run `cat note.txt` and reply in markdown: a heading **Result** and the word it printed."}
"""#
    static let userPromptSubmit = #"""
{"session_id": "01a19af7-a41b-7be0-a747-28b261b34a33", "turn_id": "01a19af7-a458-7ea2-9864-b804acb3e56c", "transcript_path": "/Users/me/.codex/sessions/2026/11/02/rollout-2026-11-02T15-34-43-01a19af7-a41b-7be0-a747-28b261b34a33.jsonl", "cwd": "/Users/me/proj", "hook_event_name": "UserPromptSubmit", "model": "gpt-6-luna", "permission_mode": "default", "prompt": "Create a file named made.txt containing the word lmux, then tell me you did it."}
"""#
    static let sessionEnd = #"""
{"session_id": "01a19afa-3664-79f1-b4d9-2fd9b2ca2250", "transcript_path": "/Users/me/.codex/sessions/2026/11/02/rollout-2026-11-02T15-37-31-01a19afa-3664-79f1-b4d9-2fd9b2ca2250.jsonl", "cwd": "/Users/me/proj", "hook_event_name": "SessionEnd", "reason": "other"}
"""#
}
