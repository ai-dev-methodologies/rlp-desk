# Model Upgrade Table

Progressive Worker model upgrade on consecutive failure per US.
CB default: 6. Override: `--cb-threshold N`. Worker only — Verifier fixed at campaign start.

## Rules
- Each row = 2-attempt window (same model for 2 consecutive fails)
- Ceiling reached → repeat same model until CB
- CB < table columns → BLOCKED at that column
- CB > 6 → repeat ceiling model beyond column 6

## GPT Pro (spark — separate token limit)

| Complexity | 1-2 | 3-4 | 5-6 | 7+ |
|------------|-----|-----|-----|-----|
| LOW | spark:low | spark:medium | spark:high | BLOCKED |
| MEDIUM | spark:medium | spark:high | spark:xhigh | BLOCKED |
| HIGH | spark:high | spark:xhigh | spark:xhigh | BLOCKED |
| CRITICAL | spark:xhigh | spark:xhigh | spark:xhigh | BLOCKED |

## Non-Pro (gpt-5.4)

| Complexity | 1-2 | 3-4 | 5-6 | 7+ |
|------------|-----|-----|-----|-----|
| LOW | 5.4:low | 5.4:medium | 5.4:high | BLOCKED |
| MEDIUM | 5.4:medium | 5.4:high | 5.4:xhigh | BLOCKED |
| HIGH | 5.4:high | 5.4:xhigh | 5.4:xhigh | BLOCKED |
| CRITICAL | 5.4:xhigh | 5.4:xhigh | 5.4:xhigh | BLOCKED |

## Claude-only

| Complexity | 1-2 | 3-4 | 5-6 | 7+ |
|------------|-----|-----|-----|-----|
| LOW | haiku | sonnet | opus | BLOCKED |
| MEDIUM | sonnet | opus | opus | BLOCKED |
| HIGH | sonnet | opus | opus | BLOCKED |
| CRITICAL | opus | opus | opus | BLOCKED |

## Complexity Evaluation (brainstorm determines this)

| Factor | LOW | MEDIUM | HIGH | CRITICAL |
|--------|-----|--------|------|----------|
| US count | 1-2 | 3-5 | 6-10 | 10+ |
| File scope | single | 2-5 | 6+ | cross-repo |
| Logic | simple CRUD | conditionals | algorithms | security/crypto |
| Dependencies | none | 1-2 | 3+ API/DB | distributed |
| Code impact | new only | modify existing | refactor | architecture change |

Overall complexity = highest factor level.
Campaign starting model = lowest US risk level (progressive upgrade handles harder US).
