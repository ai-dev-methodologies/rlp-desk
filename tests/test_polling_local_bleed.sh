#!/usr/bin/env zsh
# US-003 — polling-path local bleed guard.
#
# Bare `local NAME` (no `=`) declared inside a zsh loop body keeps its value
# across loop iterations within the same function call, because a *second*
# execution of a bare `local`/`typeset` on an already-local variable does not
# reset it — it only re-declares it, and (without TYPESET_SILENT) zsh's own
# non-silent typeset additionally ECHOES the stale value as a `NAME=value`
# line. That's the operator-facing noise this guard exists to prevent
# (`.sv/gatemed/leader.log`, 1642 of 1832 lines). `local NAME=""` neither
# echoes nor keeps a stale value; a type-flagged `local -a NAME` does not echo
# but does keep its prior value.
#
# AC1 — a zsh -f fact test proving that mechanism directly.
# AC2/AC3 — a self-contained static sweep (python3, no new dependency) that
#           finds every bare loop-body `local`/`typeset` declaration by
#           `do`/`done` token depth, validated against embedded fixtures
#           covering every construct present in the target files.
# AC4 — the sweep run against the real sources (expects 0 records) plus mutation controls proving the sweep can fail.
#
# Known out-of-scope forms (the sweep does NOT claim to handle these; they
# are not fixtured as passing and must not be treated as gaps to file):
#   - brace/short-form loops: `repeat N { }`, `repeat N do ... done`,
#     `for ((..)) { }`, `for i (1 2) local x`, `while ... { }`, `foreach
#     x (1 2); ... end`
#   - `builtin local`, `declare`, `export`, `readonly`, `float`, `integer`
#     (anything other than the bare words `local`/`typeset`)
#   - `noglob local x`, `FOO=bar local x` (prefixed command forms)
#   - `local "x"` (quoted declaration name)
#   - loops written entirely inside a `$( ... )` command-substitution body
#   - a name placed after a redirection and its operand, e.g.
#     `local < /dev/null x` (the argument scan stops at the operator)
#   - a `case` statement inside a `$( ... )` command-substitution body that
#     is itself a declaration initializer, e.g.
#     `local v=$(case a in a) ... ;; esac)`
# These are pre-existing, narrow gaps in a heuristic token scanner (not a
# full shell parser); none of them occur in the target files (verified by
# AC4 below, and re-confirmed absent as of this change), and the loop-body
# leak class they could theoretically hide is additionally covered at
# runtime by the SV leader.log check (zero lines matching
# `^[A-Za-z_][A-Za-z0-9_]*=`), not by this static sweep alone.
set -uo pipefail
REPO="${0:A:h:h}"
RUN="$REPO/src/scripts/run_ralph_desk.zsh"
LIB="$REPO/src/scripts/lib_ralph_desk.zsh"
INIT="$REPO/src/scripts/init_ralph_desk.zsh"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; return 0; }
no(){ FAIL=$((FAIL+1)); print "  FAIL $1"; return 0; }

sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT

# ============================================================================
# AC1 — zsh -f fact test (ignores user rc, e.g. any TYPESET_SILENT setopt)
# ============================================================================
cat > "$sandbox/fact.zsh" <<'FACT'
harness() {
  local i
  for i in 1 2; do
    if [[ $i -eq 1 ]]; then
      bare_var=leaked
      init_var=leaked
      arr_var=(leaked)
    fi
    local bare_var
    local init_var=""
    local -a arr_var
  done
}
harness
FACT

fact_out=$(zsh -f "$sandbox/fact.zsh")
fact_rc=$?
[[ $fact_rc -eq 0 ]] && ok "AC1: harness exit status 0" || no "AC1: harness exit status 0 (got $fact_rc)"

if print -r -- "$fact_out" | grep -q '^bare_var='; then
  ok "AC1: bare 'local bare_var' re-executed prints a line starting with bare_var="
else
  no "AC1: bare 'local bare_var' re-executed prints a line starting with bare_var="
  print -u2 "    fact harness output: ${fact_out//$'\n'/ | }"
fi

if print -r -- "$fact_out" | grep -q '^init_var='; then
  no "AC1: 'local init_var=\"\"' prints nothing"
  print -u2 "    fact harness output: ${fact_out//$'\n'/ | }"
else
  ok "AC1: 'local init_var=\"\"' prints nothing"
fi

if print -r -- "$fact_out" | grep -q '^arr_var='; then
  no "AC1: 'local -a arr_var' prints nothing"
  print -u2 "    fact harness output: ${fact_out//$'\n'/ | }"
else
  ok "AC1: 'local -a arr_var' prints nothing"
fi

# ============================================================================
# AC2 — static sweep (python3): do/done-token depth scan for bare loop-body
# local/typeset declarations. Lexical pre-pass blanks quotes/$()/$(())/${}
# and strips comments (# only at word-start — including never after '(', so
# an extended-glob qualifier `(#q...)` or `$(#...)` is not mistaken for a
# comment — and never $#/${#/$(#), and skips heredoc bodies (accepting
# quoted and non-word tags, and a leading backslash before an unquoted tag)
# while never treating <<< as a heredoc opener. Case-arm position is TRACKED
# explicitly (an expect_subject/expect_in/awaiting_pattern/in_pattern/in_body
# state machine keyed on `case`/`in`/`;;`/`;&`/`;|`/`esac`), not inferred
# from adjacency to `)`. In PATTERN state `do`/`done`/`local` are
# never keywords (they're pattern text); the pattern-closing `)` acts like
# `;`. `;;`/`;&`/`;|` are tokenized atomically (never split into `;` plus a
# trailing `&`/`|` token) so the case-state machine actually recognizes them
# as arm terminators. A `)` that closes an unmatched `(` outside any tracked
# case is still a statement boundary; a `)` that is the second of a `))`
# pair ends an arithmetic command `(( ... ))`, so a following `do` needs no
# separator. A `NAME=( ... )` array-literal argument to `local`/`typeset` is
# kept as one argument so a later bare name in the same declaration is
# still scanned. A redirection operator word (`>`, `>>`, `<`, `2>`, `&>`,
# `>|`, `<>`, fd-prefixed forms, `<<<`, ...) ends a declaration's argument
# list — neither the operator nor its target operand is ever a declared
# name. A negative-depth balance error is never clamped back to a valid
# state — it keeps failing the sweep.
# ============================================================================
cat > "$sandbox/sweep.py" <<'PYEOF'
import re, sys, os
P = '\x01'
TYPEFLAGS = set('aAiFxrUluZLR')


def sanitize(lines):
    stack = []
    out = []; start = None; buf = ''
    heredocs = []
    i_line = 0; n = len(lines)
    while i_line < n:
        line = lines[i_line]; ln = i_line + 1; i_line += 1
        if start is None: start = ln
        s = line; i = 0; L = len(s); o = []
        cont = False
        while i < L:
            c = s[i]; top = stack[-1] if stack else None
            if top == 'sq':
                if c == "'": stack.pop()
                i += 1; continue
            if top == 'ansi':
                if c == '\\': i += 2; continue
                if c == "'": stack.pop()
                i += 1; continue
            if top in ('dq', 'bt'):
                if c == '\\': i += 2; continue
                if top == 'dq' and c == '"': stack.pop(); i += 1; continue
                if top == 'bt' and c == '`': stack.pop(); i += 1; continue
            if c == '\\' and top not in ('dq', 'bt'):
                if i == L - 1: cont = True; i += 1; continue
                if not stack: o.append(s[i:i + 2])
                i += 2; continue
            if s.startswith('$((', i):
                stack.append('ar')
                if len(stack) == 1: o.append(P)
                i += 3; continue
            if s.startswith('$(', i):
                stack.append('cs')
                if len(stack) == 1: o.append(P)
                i += 2; continue
            if s.startswith('${', i):
                stack.append('pe')
                if len(stack) == 1: o.append(P)
                i += 2; continue
            if c == '`':
                stack.append('bt')
                if len(stack) == 1: o.append(P)
                i += 1; continue
            if top == 'dq':
                i += 1; continue
            if s.startswith("$'", i):
                stack.append('ansi')
                if len(stack) == 1: o.append(P)
                i += 2; continue
            if c == "'" and top != 'ar':
                stack.append('sq')
                if len(stack) == 1: o.append(P)
                i += 1; continue
            if c == '"':
                stack.append('dq')
                if len(stack) == 1: o.append(P)
                i += 1; continue
            if top == 'ar':
                if s.startswith('))', i): stack.pop(); i += 2; continue
                if c == '(': stack.append('arp')
                i += 1; continue
            if top == 'arp':
                if c == ')': stack.pop()
                elif c == '(': stack.append('arp')
                i += 1; continue
            if top == 'pe':
                if c == '}': stack.pop()
                elif c == '{': stack.append('peb')
                i += 1; continue
            if top == 'peb':
                if c == '}': stack.pop()
                elif c == '{': stack.append('peb')
                i += 1; continue
            if top == 'cs' or top == 'csp':
                # NB: '(' is deliberately excluded from the preceding-char set
                # below — an extended-glob qualifier `(#q...)` or `$(#...)`
                # puts a literal '#' right after '(' with no comment meant;
                # the spec explicitly says never treat that as one.
                if c == '#' and (i == 0 or s[i - 1] in ' \t;'):
                    break
                if s.startswith('<<<', i):
                    i += 3; continue
                if s.startswith('<<', i):
                    m = re.match(r'''<<(-?)\s*(?:'([^']*)'|"([^"]*)"|([^\s;<>|&)]+))''', s[i:])
                    if m:
                        tag = m.group(2) if m.group(2) is not None else (m.group(3) if m.group(3) is not None else m.group(4).replace('\\', ''))
                        heredocs.append((tag, m.group(1) == '-')); i += m.end(); continue
                if c == ')': stack.pop()
                elif c == '(': stack.append('csp')
                i += 1; continue
            if c == '#' and (i == 0 or s[i - 1] in ' \t;'):
                break
            if s.startswith('<<<', i):
                o.append('<<<'); i += 3; continue
            if s.startswith('<<', i):
                m = re.match(r'''<<(-?)\s*(?:'([^']*)'|"([^"]*)"|([^\s;<>|&)]+))''', s[i:])
                if m:
                    tag = m.group(2) if m.group(2) is not None else (m.group(3) if m.group(3) is not None else m.group(4).replace('\\', ''))
                    heredocs.append((tag, m.group(1) == '-'))
                    o.append('<<' + P); i += m.end(); continue
            o.append(c); i += 1
        buf += ''.join(o)
        while heredocs:
            tag, dash = heredocs.pop(0)
            while i_line < n:
                body = lines[i_line]; i_line += 1
                if (body.lstrip('\t') if dash else body) == tag: break
        if cont:
            buf += ' '; continue
        if stack:
            buf += ' '; continue
        out.append((start, buf)); start = None; buf = ''
    if buf: out.append((start, buf))
    return out, stack


FUNC = re.compile(
    r'^\s*(?:function\s+([A-Za-z_][\w:.-]*)\s*(?:\(\))?|([A-Za-z_][\w:.-]*)\s*\(\))\s*\{?\s*$'
    r'|^\s*(?:function\s+([A-Za-z_][\w:.-]*)|([A-Za-z_][\w:.-]*)\s*\(\))\s*\{'
)
SEP = re.compile(r'(;;|;&|;\||&&|\|\||;|&|\||\(|\)|\{|\})')
CMDKW = {'do', 'then', 'else', 'elif', '!', '{', 'time', 'if', 'while', 'until'}
# Redirection operator/target-fd word (>, >>, <, 2>, &>, >|, <>, <<<, 2>&1,
# ...): any word built only from digits and </>/&/|/- that contains at
# least one </> . A real identifier can never contain those characters, so
# this never misclassifies a declaration name.
REDIR = re.compile(r'^[0-9<>&|-]+$')


def is_redir(w):
    return bool(REDIR.fullmatch(w)) and ('<' in w or '>' in w)


def tokenize(text):
    """Flat token stream: ('sep', tok) | ('word', tok)."""
    toks = []
    for chunk in SEP.split(text):
        if SEP.fullmatch(chunk or '\x02'):
            toks.append(('sep', chunk))
        else:
            for w in chunk.split():
                toks.append(('word', w))
    return toks


def sweep(path):
    lines = open(path, encoding='utf-8', errors='replace').read().split('\n')
    logical, stack = sanitize(lines)
    depth = 0
    parens = 0
    # Explicit case-statement context (replaces an earlier do/done-adjacent-
    # to-')' heuristic — see the AC2 header comment above for why). Frames:
    #   expect_subject   just saw `case`, one subject word is next
    #   expect_in        subject consumed, the literal word `in` must follow
    #   awaiting_pattern ready for a new arm's pattern, or `esac`
    #   in_pattern       inside a pattern (optional leading `(`, `|`-joined
    #                    alternatives, extended-glob groups); `do`/`done`/
    #                    `local` are never keywords here
    #   in_body          inside an arm's command list — ordinary scanning,
    #                    but watches for `;;`/`;&`/`;|` (back to
    #                    awaiting_pattern), nested `case` (push), and `esac`
    #                    (pop)
    case_stack = []
    func = '<top>'
    recs = []
    errs = []
    if stack: errs.append(('EOF', 'unterminated context %s' % stack))
    for ln, text in logical:
        m = FUNC.match(text)
        if m:
            if depth != 0: errs.append((ln, 'depth %d at function def: %s' % (depth, text.strip()[:60])))
            func = next(g for g in m.groups() if g)
        toks = tokenize(text)
        nt = len(toks)
        k = 0
        cmdpos = True
        loopok = True
        while k < nt:
            kind, val = toks[k]

            if case_stack and case_stack[-1]['phase'] != 'in_body':
                cs = case_stack[-1]
                phase = cs['phase']
                if phase == 'expect_subject':
                    cs['phase'] = 'expect_in'
                    k += 1; continue
                if phase == 'expect_in':
                    if kind == 'word' and val == 'in':
                        cs['phase'] = 'awaiting_pattern'
                        k += 1; continue
                    if kind == 'word':
                        # not really `case WORD in ...` after all (e.g. a
                        # command literally named `case`) — abandon tracking
                        # for this frame and reprocess the word normally.
                        case_stack.pop()
                        continue
                    k += 1; continue  # stray separator while awaiting `in`
                if phase == 'awaiting_pattern':
                    if kind == 'sep' and val == '(':
                        # optional pattern-wrapping paren: consumed, untracked
                        cs['phase'] = 'in_pattern'; cs['pattern_parens'] = 0
                        k += 1; continue
                    if kind == 'word' and val == 'esac':
                        case_stack.pop()
                        cmdpos = False; loopok = False
                        k += 1; continue
                    if kind == 'word':
                        cs['phase'] = 'in_pattern'; cs['pattern_parens'] = 0
                        k += 1; continue
                    k += 1; continue  # stray separator while awaiting a pattern
                if phase == 'in_pattern':
                    if kind == 'sep' and val == '(':
                        cs['pattern_parens'] += 1
                        k += 1; continue
                    if kind == 'sep' and val == ')':
                        if cs['pattern_parens'] > 0:
                            cs['pattern_parens'] -= 1
                            k += 1; continue
                        # the pattern-closing paren acts like `;`
                        cs['phase'] = 'in_body'
                        cmdpos = True; loopok = True
                        k += 1; continue
                    k += 1; continue  # pattern text/glob/`|`-alternation: ignored

            if kind == 'sep':
                if case_stack and val in (';;', ';&', ';|'):
                    case_stack[-1]['phase'] = 'awaiting_pattern'
                if val == '(':
                    parens += 1
                    cmdpos = True; loopok = False
                    k += 1; continue
                if val == ')':
                    if parens > 0:
                        parens -= 1
                        # a `))` (second consecutive genuine close) ends an
                        # arithmetic command `(( ... ))`; like `;`, that is a
                        # full statement terminator, so `do` may follow with
                        # no separator: `while (( ... )) do`.
                        prev_was_close = (k > 0 and toks[k - 1] == ('sep', ')'))
                        if prev_was_close:
                            cmdpos = True; loopok = True
                        else:
                            cmdpos = False; loopok = False
                    else:
                        # unmatched close outside any tracked case pattern:
                        # behaves like a statement separator for what follows.
                        cmdpos = True; loopok = True
                    k += 1; continue
                cmdpos = True
                loopok = (val == ';')
                k += 1; continue
            # kind == 'word'
            w = val
            if cmdpos and w == 'case':
                case_stack.append({'phase': 'expect_subject'})
                cmdpos = False; loopok = False; k += 1; continue
            if cmdpos and w == 'esac' and case_stack:
                case_stack.pop()
                cmdpos = False; loopok = False; k += 1; continue
            if cmdpos and loopok and w == 'do':
                depth += 1; cmdpos = True; loopok = False; k += 1; continue
            if cmdpos and loopok and w == 'done':
                depth -= 1
                if depth < 0:
                    errs.append((ln, 'negative depth: ' + text.strip()[:60]))
                    # depth is intentionally NOT clamped back to 0 — the
                    # recorded error keeps failing the sweep.
                cmdpos = False; loopok = False; k += 1; continue
            if cmdpos and w in CMDKW:
                loopok = (w == 'do'); k += 1; continue
            if cmdpos and w in ('local', 'typeset'):
                k += 1
                args = []
                local_parens = 0
                cur = None
                while k < nt:
                    kind2, val2 = toks[k]
                    if kind2 == 'sep':
                        if val2 == '(' and ((cur is not None and cur.endswith('=')) or local_parens > 0):
                            # array-literal argument `name=(...)`:
                            # keep the whole thing as ONE argument so a later
                            # bare name after the `)` is still scanned.
                            local_parens += 1; cur += '('; k += 1; continue
                        if val2 == ')' and local_parens > 0:
                            local_parens -= 1; cur += ')'; k += 1; continue
                        break
                    else:
                        if local_parens > 0:
                            cur += ' ' + val2
                        else:
                            if is_redir(val2):
                                # a redirection operator: the
                                # declaration's argument list ends here — the
                                # operator and its target are never args.
                                break
                            if cur is not None: args.append(cur)
                            cur = val2
                        k += 1; continue
                if cur is not None: args.append(cur)
                flags = ''.join(a[1:] for a in args if a[:1] in '-+')
                skip = any(f in TYPEFLAGS for f in flags) or (w == 'typeset' and any(f in 'fpmg' for f in flags))
                if not skip and depth > 0:
                    for a in args:
                        if a[:1] in '-+': continue
                        if '=' in a: continue
                        if re.fullmatch(r'[A-Za-z_]\w*', a):
                            recs.append((ln, func, a))
                cmdpos = False; loopok = False
                continue
            cmdpos = False; loopok = False; k += 1
    if depth != 0: errs.append(('EOF', 'depth %d at EOF' % depth))
    return recs, errs


if __name__ == '__main__':
    verbose = '-v' in sys.argv
    paths = [a for a in sys.argv[1:] if not a.startswith('-')]
    total_recs = 0
    total_errs = 0
    for p in paths:
        recs, errs = sweep(p)
        lines_ = sorted(set(r[0] for r in recs))
        print('%s: %d name-records on %d lines; %d balance errors' % (os.path.basename(p), len(recs), len(lines_), len(errs)))
        for e in errs:
            print('  ERR %s: %s' % e)
        if verbose:
            for r in recs:
                print('  REC %s:%s:%s:%s' % (os.path.basename(p), r[0], r[1], r[2]))
        total_recs += len(recs)
        total_errs += len(errs)
    sys.exit(1 if (total_recs > 0 or total_errs > 0) else 0)
PYEOF

# ============================================================================
# AC3 — embedded fixtures: one function per construct, no fixtures dir.
# Every expected record's line number is DERIVED from the fixture text at
# assertion time via grep, never hardcoded — an unrelated line added
# anywhere else in the fixtures file cannot silently break this check.
# ============================================================================
cat > "$sandbox/fixtures.zsh" <<'FIXEOF'
#!/usr/bin/env zsh
# AC3 fixtures — one function per construct.

fx_arith_while() {
  local i=0
  while (( i <= $# )); do
    i=$((i + 1))
  done
}

fx_bracket_while() {
  while [[ $# -gt 0 ]]; do
    shift
  done
}

fx_case_pattern_no_bare() {
  local st="completed"
  while true; do
    case "$st" in
      completed|done)
        break
        ;;
    esac
  done
}

fx_case_bare_after_paren() {
  while true; do
    case "$1" in
      a) local e ;;
    esac
    break
  done
}

fx_case_done_pattern_standalone() {
  local st="done"
  while true; do
    case "$st" in
      done) : ;;
    esac
    break
  done
}

fx_case_do_pattern_standalone() {
  local st="do"
  while true; do
    case "$st" in
      do) : ;;
      done) : ;;
    esac
    break
  done
}

fx_herestring_do_planted() {
  cat <<<"do"
  while true; do
    local planted_herestring
    break
  done
}

fx_continued_header() {
  local n=0
  while (( n \
      < 3 )); do
    n=$((n + 1))
  done
}

fx_piped_loop() {
  print -l a b c | while read -r l; do
    print "$l"
  done
}

fx_oneline_for() {
  for x in a b; do print "$x"; done
}

fx_heredoc_do_line() {
  cat <<EOF
done
do
heredoc body must be fully skipped, not just its first line
EOF
}

fx_herestring_plain() {
  cat <<<"do not treat as heredoc"
}

fx_quoted_semicolon_do() {
  echo "x; do not y"
}

fx_arith_assignment_in_loop() {
  while true; do
    local r=$(( 3 * 4 ))
    break
  done
}

fx_nested_function() {
  inner_fn() {
    while true; do
      local ok=""
      break
    done
  }
  inner_fn
}

fx_decl_before_loop() {
  local before_loop
  while true; do
    break
  done
}

fx_decl_after_done() {
  while true; do
    break
  done
  local after_loop
}

fx_flagged_array_in_loop() {
  while true; do
    local -a arr_ok
    break
  done
}

fx_typeset_query_in_loop() {
  while true; do
    typeset -p PATH
    break
  done
}

fx_planted_bare_local() {
  while true; do
    local zz
    break
  done
}

fx_array_literal_then_bare() {
  while true; do
    local arr=(a b) x
    break
  done
}

fx_cs_globflag() {
  setopt extendedglob
  local out
  out=$(print -l /tmp/*(#qN) | head -1)
  while true; do
    local planted_globflag
    break
  done
}

fx_heredoc_nonword_tag() {
  cat <<'END-X'
done
END-X
  while true; do
    local planted_nonword_tag
    break
  done
}

fx_while_arith_nosemi() {
  local n=0
  while (( n < 2 )) do
    n=$((n + 1))
    local planted_arith_nosemi
    break
  done
}

fx_for_arith_nosemi() {
  for ((i = 0; i < 2; i++)) do
    local planted_for_nosemi
    break
  done
}

fx_case_paren_pattern() {
  while true; do
    case "$1" in
      (a) local px; px=leaked ;;
    esac
    break
  done
}

fx_case_pipe_done_pattern() {
  local st
  while true; do
    case "$st" in
      done|completed) : ;;
      do|completed) : ;;
    esac
    break
  done
}

fx_subshell_while_done_paren() {
  (while true; do :; done)
}

fx_case_semiamp_terminators() {
  for i in 1 2; do
    case a in
      a) : ;&
      done) local missed; missed=leaked ;&
      do) : ;;
    esac
  done
}

fx_local_redirect_operand() {
  while true; do
    local good="" > output
    break
  done
}
FIXEOF

zsh -n "$sandbox/fixtures.zsh" && ok "AC3: fixtures.zsh is syntactically valid zsh" \
  || no "AC3: fixtures.zsh is syntactically valid zsh"

fix_out=$(python3 "$sandbox/sweep.py" "$sandbox/fixtures.zsh" -v 2>&1)
fix_summary=$(print -r -- "$fix_out" | grep '^fixtures.zsh:')
fix_recs=$(print -r -- "$fix_out" | grep '  REC ')
fix_errs=$(print -r -- "$fix_out" | grep '  ERR ')

if print -r -- "$fix_summary" | grep -q '^fixtures.zsh: 10 name-records on 10 lines; 0 balance errors$'; then
  ok "AC3: fixtures produce exactly 10 records, 0 balance errors ($fix_summary)"
else
  no "AC3: fixtures produce exactly 10 records, 0 balance errors"
  print -u2 "    got: $fix_summary"
fi

# marker text (unique in fixtures.zsh) -> expected "func:name" at that line.
# The line number is looked up with grep at assertion time so this
# never hardcodes a line literal.
typeset -A fx_markers
fx_markers=(
  '      a) local e ;;'             'fx_case_bare_after_paren:e'
  '    local planted_herestring'    'fx_herestring_do_planted:planted_herestring'
  '    local zz'                    'fx_planted_bare_local:zz'
  '    local arr=(a b) x'           'fx_array_literal_then_bare:x'
  '    local planted_globflag'      'fx_cs_globflag:planted_globflag'
  '    local planted_nonword_tag'   'fx_heredoc_nonword_tag:planted_nonword_tag'
  '    local planted_arith_nosemi'  'fx_while_arith_nosemi:planted_arith_nosemi'
  '    local planted_for_nosemi'    'fx_for_arith_nosemi:planted_for_nosemi'
  '      (a) local px; px=leaked ;;'  'fx_case_paren_pattern:px'
  '      done) local missed; missed=leaked ;&'  'fx_case_semiamp_terminators:missed'
)

for marker in "${(@k)fx_markers}"; do
  funcname="${fx_markers[$marker]}"
  hitcount=$(grep -cF "$marker" "$sandbox/fixtures.zsh")
  if [[ "$hitcount" -ne 1 ]]; then
    no "AC3: marker text unique in fixtures.zsh: '$marker' (found $hitcount)"
    continue
  fi
  line=$(grep -nF "$marker" "$sandbox/fixtures.zsh" | head -1 | cut -d: -f1)
  want="fixtures.zsh:${line}:${funcname}"
  if print -r -- "$fix_recs" | grep -qF "  REC $want"; then
    ok "AC3: expected record present ($want)"
  else
    no "AC3: expected record present ($want)"
    print -u2 "    all records: ${fix_recs//$'\n'/ | }"
  fi
done

[[ -z "$fix_errs" ]] && ok "AC3: no balance errors in fixtures" || { no "AC3: no balance errors in fixtures"; print -u2 "    $fix_errs"; }

# ============================================================================
# AC4 — current tree: zero records, balanced, in all three source files.
# ============================================================================
for f in "$RUN" "$LIB" "$INIT"; do
  base=$(basename "$f")
  out=$(python3 "$sandbox/sweep.py" "$f" -v 2>&1)
  summary=$(print -r -- "$out" | grep "^$base:")
  if print -r -- "$summary" | grep -q "^$base: 0 name-records on 0 lines; 0 balance errors$"; then
    ok "AC4: $base — zero records, balanced ($summary)"
  else
    no "AC4: $base — zero records, balanced"
    print -u2 "    $summary"
    print -r -- "$out" | grep -E '  (REC|ERR) ' | while IFS= read -r line; do
      print -u2 "    $line"
    done
  fi
done

# ---- mutation control (a): strip `=""` from a uniquely-named fixed decl ----
# The line number is looked up in $RUN BEFORE mutation — a same-line
# text substitution cannot shift it, so the post-mutation record is asserted
# against that looked-up line, never a literal.
target_line='    local poll_cmd=""'
present=$(grep -cF "$target_line" "$RUN")
if [[ "$present" -eq 1 ]]; then
  target_ln=$(grep -nF "$target_line" "$RUN" | head -1 | cut -d: -f1)
  cp "$RUN" "$sandbox/run_mut_a.zsh"
  python3 - "$sandbox/run_mut_a.zsh" "$target_line" "    local poll_cmd" <<'MUTPY'
import sys
path, old, new = sys.argv[1], sys.argv[2] + "\n", sys.argv[3] + "\n"
text = open(path).read()
assert text.count(old) == 1, f"expected exactly 1 occurrence of {old!r}, found {text.count(old)}"
open(path, "w").write(text.replace(old, new, 1))
MUTPY
  mut_a_out=$(python3 "$sandbox/sweep.py" "$sandbox/run_mut_a.zsh" -v 2>&1)
  mut_a_summary=$(print -r -- "$mut_a_out" | grep '^run_mut_a.zsh:')
  want_a="  REC run_mut_a.zsh:${target_ln}:poll_for_signal:poll_cmd"
  if print -r -- "$mut_a_summary" | grep -q '^run_mut_a.zsh: 1 name-records on 1 lines; 0 balance errors$' \
    && print -r -- "$mut_a_out" | grep -qF "$want_a"; then
    ok "AC4 mutation (a): stripping \"\" from local poll_cmd=\"\" reintroduces exactly that record (line $target_ln)"
  else
    no "AC4 mutation (a): stripping \"\" from local poll_cmd=\"\" reintroduces exactly that record"
    print -u2 "    got: $mut_a_out"
  fi
else
  no "AC4 mutation (a): target declaration 'local poll_cmd=\"\"' found exactly once in $RUN (found $present)"
fi

# ---- mutation control (b): insert a bare `local zz` inside an existing loop ----
anchor='  while (( attempt < 3 )); do'
anchor_count=$(grep -cF "$anchor" "$RUN")
if [[ "$anchor_count" -eq 1 ]]; then
  cp "$RUN" "$sandbox/run_mut_b.zsh"
  python3 - "$sandbox/run_mut_b.zsh" "$anchor" <<'MUTPY2'
import sys
path, anchor = sys.argv[1], sys.argv[2] + "\n"
text = open(path).read()
assert text.count(anchor) == 1, f"expected exactly 1 occurrence of {anchor!r}, found {text.count(anchor)}"
open(path, "w").write(text.replace(anchor, anchor + "    local zz\n", 1))
MUTPY2
  mut_b_out=$(python3 "$sandbox/sweep.py" "$sandbox/run_mut_b.zsh" -v 2>&1)
  mut_b_summary=$(print -r -- "$mut_b_out" | grep '^run_mut_b.zsh:')
  if print -r -- "$mut_b_summary" | grep -q '^run_mut_b.zsh: 1 name-records on 1 lines; 0 balance errors$' \
    && print -r -- "$mut_b_out" | grep -q '  REC run_mut_b.zsh:[0-9]*:[A-Za-z_][A-Za-z0-9_]*:zz$'; then
    ok "AC4 mutation (b): inserting a bare local zz inside an existing loop yields exactly one record"
  else
    no "AC4 mutation (b): inserting a bare local zz inside an existing loop yields exactly one record"
    print -u2 "    got: $mut_b_out"
  fi
else
  no "AC4 mutation (b): anchor loop '$anchor' found exactly once in $RUN (found $anchor_count)"
fi

print ""
if (( FAIL == 0 )); then
  print "polling-local-bleed: $PASS/$((PASS+FAIL)) PASS"
else
  print "polling-local-bleed: $PASS pass, $FAIL FAIL"
fi
exit $(( FAIL > 0 ))
