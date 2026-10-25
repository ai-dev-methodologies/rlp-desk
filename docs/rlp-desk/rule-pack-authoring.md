# Rule Pack Authoring Guide

A **rule pack** is a reusable set of domain acceptance criteria (for example, "money is never a float") that you render into a campaign's test-spec. Packs are data, not code. They add criteria; they never remove or weaken anything in `governance.md`.

This guide covers the file format, how a pack is found and validated, how it is applied, and how to write rules a fresh-context Verifier can check without guessing.

## 1. How a pack reaches the Verifier

```
rule-pack apply <slug> --pack <name>     (manual, idempotent)
        |
        v
.rlp-desk/plans/test-spec-<slug>.md      block inserted before the first "## US-" heading
.rlp-desk/plans/test-spec-<slug>-US-*.md same block in every existing per-US file
        |
        v
gate-receipt <slug>                      the block is now part of the sealed contract
```

- The block sits in the test-spec's global header, so it survives `init`'s per-US split (the splitter copies everything before the first `## US-` heading into each per-US file).
- The test-spec is the trusted contract both Worker and Verifier read, and `gate-receipt` hashes it. A pack applied this way has test-spec authority and is tamper-evident.
- Nothing in the leader reads packs. Applying one is always a deliberate step. Brainstorm only **offers** it when you name a domain.

Order in brainstorm: `init` -> `rule-pack apply` -> `gate-receipt`. If a receipt already exists, `apply` prints a warning to re-run `gate-receipt` (the contract hash changed).

```bash
node ~/.claude/ralph-desk/node/run.mjs rule-pack list
node ~/.claude/ralph-desk/node/run.mjs rule-pack validate finance
node ~/.claude/ralph-desk/node/run.mjs rule-pack apply my-slug --pack finance
```

## 2. Lookup order

`<name>` is resolved to the first existing file of:

1. **Project:** `.rlp-desk/rule-packs/<name>.pack.json` (your own pack, or an override of a shipped one)
2. **Shipped:** `~/.claude/ralph-desk/node/rule-packs/<name>.pack.json` (installed from `src/node/rule-packs/`)

`<name>` must match `^[a-z][a-z0-9-]{1,31}$`. It is checked before any path is built, so a name cannot contain a separator or `..`. `rule-pack list` shows one row per name with `source: project|shipped`. A project pack with an invalid body is an error; it never falls through to the shipped pack of the same name.

`rule-pack validate` also accepts a path ending in `.json` for a pack you have not installed yet.

## 3. File format

JSON only (the project has no YAML parser and does not add dependencies).

```json
{
  "schema": "rlp-desk.rule-pack/1",
  "name": "my-domain",
  "version": "1.0.0",
  "description": "What the pack covers, and what it is not (for example: engineering guidance, not a compliance certification).",
  "recommended_for": { "risk": ["HIGH", "CRITICAL"] },
  "rules": [
    {
      "id": "MYD-001",
      "title": "Short imperative title",
      "severity": "critical",
      "statement": "One normative sentence using MUST or MUST NOT.",
      "verify": {
        "method": "test",
        "how": "The concrete test to write or the grep to run, and what result counts as a pass."
      }
    }
  ]
}
```

| Field | Rule |
|---|---|
| `schema` | exactly `rlp-desk.rule-pack/1` |
| `name` | `^[a-z][a-z0-9-]{1,31}$`; must equal the file name before `.pack.json` |
| `version` | semver `MAJOR.MINOR.PATCH`; bump it when rule text changes (it is written into the block marker) |
| `description` | non-empty; rendered under the block heading. State the pack's limits here |
| `recommended_for.risk` | optional; array of `LOW`, `MEDIUM`, `HIGH`, `CRITICAL` |
| `rules` | non-empty array |
| `rules[].id` | `^[A-Z]{2,6}-[0-9]{3}$`, unique within the pack. Verifiers cite it in `issues[].id` |
| `rules[].severity` | `critical`, `major`, or `minor` |
| `rules[].verify.method` | `test` (a test must exist and pass) or `inspect` (the Verifier reads the diff or config) |
| every string | non-empty, and must not contain the text `rlp-desk:rule-pack:` (reserved for the block markers) |

A pack contains **no commands**. The Verifier decides what to run. A pack therefore cannot cause code execution, only add criteria to judge.

## 4. What `apply` writes

```
<!-- rlp-desk:rule-pack:begin name=my-domain version=1.0.0 sha256=<64 hex of the rendered body> -->
## Domain Rule Pack: my-domain (v1.0.0)
Guidance: <description>
...
| ID | Severity | Rule | How verified |
...
<!-- rlp-desk:rule-pack:end name=my-domain -->
```

- The `sha256` in the begin marker is the hash of the text between the two markers, so a hand edit inside the block is detectable.
- Re-applying the same pack leaves the file byte-identical. Applying a changed pack replaces the block in place (one block per pack name per file).
- Rule text is flattened to one table row per rule and pipes are escaped, so rule text cannot break the table or smuggle in a `## US-` heading.
- A test-spec with no `## US-` heading gets the block appended. A missing `test-spec-<slug>.md` is an error and nothing is written.
- The block deliberately uses no `### Test` or `**T-` lines, so the test-density lint counts are unchanged.

## 5. Writing rules a fresh-context Verifier can check

The Verifier starts with no memory of your intent. For each rule it must reach "violated", "satisfied with evidence", or "cannot tell" from the text alone.

- **One normative sentence per rule.** Use MUST or MUST NOT. Split "and" rules.
- **Name the observable.** "Amounts are stored as integer minor units" is checkable; "handle money carefully" is not.
- **Make `verify.how` executable.** Say what test to write (inputs and the exact asserted value) or what to grep and what a hit means. Include the boundary: the exact value, one unit above, one unit below.
- **Require evidence.** The block tells the Verifier that a `critical` rule with no cited evidence (file:line, test name, command output) is a FAIL. Write `how` so such evidence exists.
- **Prefer `test` to `inspect`.** Use `inspect` only when no honest test exists (for example, "authorization runs before the first write").
- **Keep the pack domain-wide.** Rules that only make sense for one project belong in that project's PRD acceptance criteria, not in a shared pack.

## 6. Severity guidance

| Severity | Use when | Verifier effect |
|---|---|---|
| `critical` | a violation can lose money, leak sensitive data, or corrupt records | violated, or no evidence cited: FAIL |
| `major` | a violation causes wrong behavior that is recoverable or detectable | handled like any other acceptance criterion: reported as an issue citing the rule ID, issue severity `major` |
| `minor` | hygiene and consistency | reported as an issue citing the rule ID, issue severity `minor` |

Do not mark everything `critical`; the signal is lost.

## 7. Packs add criteria, never weaken

- A pack cannot lower required verification layers, skip consensus, or relax an Iron Law. The block says so, and `governance.md` section 1c¾ states the rule.
- If a pack rule conflicts with a PRD acceptance criterion, fix the PRD or the pack; do not rely on the Verifier to pick a winner.
- Only the pack author (or the project owner) edits a pack. A Worker must not edit `.rlp-desk/rule-packs/` or the applied block (the test-spec is already lane-protected).

## 8. Shipping a pack with rlp-desk

1. Add `src/node/rule-packs/<name>.pack.json`.
2. Run `node src/node/run.mjs rule-pack validate <name>`.
3. Run `node scripts/build-node-manifest.js` (updates `src/node/MANIFEST.txt`; `npm run manifest:check` guards it). No install-manifest change is needed: `src/node/**` is copied recursively.
4. Have someone accountable for the domain review the rule text before release. Domain packs are judgment, not mechanics. Label the pack in `description` as engineering guidance.

## 9. The shipped `finance` pack

`finance` v1.0.0 has 11 rules (FIN-001 to FIN-011) covering integer or decimal money types, one rounding mode, currency alongside every amount, idempotency keys, balanced and atomic postings, boundary validation, authorization before mutation, append-only audit, no card data or personal data in logs or fixtures, explicit time zone and injectable clock, and concurrent-debit safety.

**It is engineering guidance, not a compliance certification, and not legal or PCI advice.** Applying it does not make a system compliant with any regulation or standard.
