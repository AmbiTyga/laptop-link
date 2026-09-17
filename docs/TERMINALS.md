# Shared interactive terminals

The server app can open a real, persistent `/bin/zsh -i` shell in a terminal window. Codex, Claude, and other MCP hosts use `link_terminal_*` tools to send input to that same shell. Commands, prompts, ANSI colors, and interactive programs appear on the receiving Mac. Working directory and shell variables persist within the session. Shell startup files are loaded as they are for an interactive shell.

Choose **New Terminal** in the server's menu to start a locally controlled session, or use `link_terminal_open` to open an agent-controlled session. **Show Terminals** brings existing windows back. Closing a window hides it; **End Session** terminates the shell and its foreground/background job-control groups. Quitting the server ends all its sessions. Programs that deliberately detach into another OS session are outside this cleanup guarantee.

## Sharing control

**Take Control** blocks agent input, resize, and close requests. Type directly into the window, including Ctrl+C to interrupt the foreground program. **Return Control** lets the agent send input again. Output remains readable in both modes. A control epoch changes at each handoff, so delayed input prepared before a handoff cannot silently run after control returns.

A takeover discards input queued inside the server but cannot undo bytes already delivered to the PTY or stop a command already running. Use Ctrl+C or End Session when that is wanted. Local keyboard, paste, and mouse input are rejected while the agent owns input. Normal terminal protocol replies remain enabled so interactive applications can query the terminal.

Agents must read the latest output and inspect shell state after a handoff. There is no remote operation that overrides local ownership. Different MCP hosts sharing the enrollment key belong to the same agent side; this is not a separate ownership lock per AI host.

## MCP workflow

1. `link_status` identifies the server boot and supported methods.
2. `link_terminal_open` accepts initial `cwd`, `env`, `cols`, and `rows`; save `session_id` and `control_epoch`.
3. `link_terminal_write` accepts exact `text` or base64 `data`. Include `\n` to submit a command, or `\u0003` for Ctrl+C. Supply the current control epoch.
4. `link_terminal_read` reports state, owner, epoch, and combined output. Carry `output.next_offset` to the next read. `link_terminal_list` finds existing sessions after reconnecting.
5. `link_terminal_resize` changes the PTY dimensions. `link_terminal_close` ends an agent-controlled session.

A successful write acknowledges queued bytes, not command completion. The terminal has one combined stdout/stderr stream with ANSI control sequences; the session's exit code belongs to the shell when it exits. There is no automatic per-command timeout. Use `link_exec_*` for separate stdout/stderr, per-command exit status, or enforced execution timeouts. Those background jobs do not appear in terminal windows.

## Reconnects and limits

BLE disconnection leaves the shell running and locally usable. Reconnect within the same server boot, list/read the existing session, and resume its output cursor. A lost write response must be recovered using `link_retry` with the original request ID. Never repeat uncertain keystrokes under a new UUID. Restarting the server loses sessions and creates a new boot identity; no crash recovery is promised.

Each session retains a rolling byte history capped by `outputBytesPerStream` (default 4 MiB). `output.first_offset` and `output.total_bytes` are absolute offsets. If a requested cursor expired, the response starts at the oldest retained byte and sets `output.truncated: true`. Reads return at most 32768 bytes; writes and queued input are limited to 65536 bytes. ANSI and UTF-8 sequences can span reads.

Active sessions are capped by `maximumConcurrentJobs`; at most `min(32, maximumJobsPerRun)` sessions may be opened per server run. Terminal limits are separate from background-job counts. `allowCommands: false` disables terminal operations too. The workspace restricts initial cwd; interactive commands run with the user's normal account permissions.

The window uses the vendored MIT-licensed SwiftTerm renderer. PTY lifecycle, bounded output, and control ownership are implemented by the server. Builds need no network downloads.

## Local UI check

`./scripts/check-terminal-window.sh` opens a temporary terminal window and checks rendered output, control buttons, blocked typing, and hiding without terminating the shell. It requires a logged-in macOS GUI session. An optional PNG path captures only the test window.
