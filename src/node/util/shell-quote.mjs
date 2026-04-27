// POSIX-safe single-quote escape for shell argument values.
// Use when emitting commands as strings (claude/codex CLI invocations,
// tmux send-keys payloads). Defends against brackets, spaces, single
// quotes, and other shell metacharacters in model ids and slugs.
//
// Contract: shellQuote("opus") -> "'opus'"
//           shellQuote("claude-opus-4-7[1m]") -> "'claude-opus-4-7[1m]'"
//           shellQuote("model'with'quote") -> "'model'\\''with'\\''quote'"

export function shellQuote(value) {
  return "'" + String(value).replace(/'/g, "'\\''") + "'";
}
