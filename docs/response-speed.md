# Response speed meter (fork)

The speedometer is a separate status item inside CodexBar, enabled by default in
this fork. It does not replace quota icons or require Track costs. Disable it in
General → Show TPS in the menu bar. Click it to see per-model cards and select
15m, 1h, 24h or 7d. The meter reads local Codex and Claude Code logs only.

## Measurement

- One sample is one model response, not a complete agent turn. Speed is output
  tokens divided by elapsed response time. This includes reasoning and waiting
  for the first token, and is not pure decode throughput or a live token stream.
- Codex uses `session_meta`, `turn_context`, `task_started`, user-message and
  matched tool-output boundaries, ending at `token_usage_record`. Ownership must
  match the thread and turn; a response ID and model attribution are required.
  Parallel local tools must all finish before a new interval starts. Consecutive
  model calls without tools start at the previous response completion.
- `usage.output_tokens` already includes reasoning output; it is not added again.
  Missing timestamps, invalid counts, terminal/compaction boundaries, malformed
  records, unmatched tool outputs and built-in tool calls whose duration cannot
  be separated are omitted. Old logs with only cumulative counts have no speed.
- Claude Code groups content blocks by message ID and uses the latest block's
  timestamp and usage. Prompt/tool-result timestamps and the parent chain supply
  the input boundary. Tool-call responses are published when the next input or
  response establishes completion; end-turn text can publish immediately and is
  updated if another block arrives. Multi-block usage is never summed.
- Provider, model, logged reasoning effort and logged service tier are separate
  series. Unknown effort/tier remains unspecified; no account configuration is
  read to guess fast mode. Models come from log metadata, not backend inference.
- The large number is the median of up to five latest eligible responses in the
  selected window. P50/P90 and token volume use the whole selected window. The
  comparison uses the preceding seven-day observations, excluding those latest
  five; at least five baseline responses are required. It is an observed baseline,
  not a controlled benchmark; workloads and prompt lengths still vary.
- Responses under 200 output tokens are hidden by default. The checkbox includes
  them in the cards; it does not change the menu bar's default filtering. The menu
  bar follows the latest eligible model and retires its number after 30 minutes.
- Charts draw at most 80 evenly selected responses per card; metrics use all
  retained samples. Lines break across gaps greater than 15 minutes.

## Refresh, limits and privacy

Existing files are tailed every two seconds after indexing. New files are found
within 15 seconds; opening the popover or pressing Refresh discovers immediately.
Initial indexing is bounded to 16 MiB per pass, with a short pause between passes.
The app's low-power mode stretches automatic refresh to 30 minutes; manual refresh
remains available and the popover states this explicitly.

Roots are `$CODEX_HOME/{sessions,archived_sessions}` (default `~/.codex`) and
`$CLAUDE_CONFIG_DIR/projects` (default `~/.claude`). No network, API requests,
Keychain access, account files, subprocesses, hooks or dependencies are added by
the meter. JSONL is read in memory; retained samples contain IDs, model labels,
counts and timestamps, not prompts, responses or tool arguments. No new disk
cache or telemetry is written. This does not make the rest of CodexBar offline.

Seven days of samples are rebuilt from local logs on restart. Limits are 2,000
recent files, 50,000 discovered entries per root, 30,000 retained records and 8 MiB
per JSONL line. Symlink files are skipped. File replacement, truncation and changed
append boundaries reset parser state. Incomplete trailing lines wait for the next
append. The popover reports indexing, unreadable files and limited history;
missing or invalid measurements are never displayed as zero.

## Validation

Offline fixtures cover response boundaries, parallel tools, ownership, aborts,
compaction, duplicate IDs, invalid counts, Claude content blocks, incremental
partial lines, oversized records, replacement/truncation, symlinks, percentiles,
baseline isolation, filters and stale menu values. Native SwiftUI popover captures
use synthetic models in English/Chinese and light/dark appearances.

```sh
make test-fast FILTER='ResponseSpeedParserTests|ResponseSpeedScannerTests|ResponseSpeedSummaryTests|ResponseSpeedPresentationTests'
make check
CODEXBAR_SIGNING=adhoc ./Scripts/package_app.sh debug
```

The presentation takes inspiration from Tokometer. The implementation uses this
repository's Swift/AppKit/SwiftUI stack and does not vendor Tokometer source or binaries.
