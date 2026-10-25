#!/bin/zsh
# C-01 regression: the leader must not DEADLOCK when SIGINT/SIGTERM/SIGHUP lands while it is
# inside a builtin stdio write.
#
# Root cause (reproduced + sampled, .omc/artifacts/c01-signal-deadlock/): zsh runs a trap
# synchronously inside the signal handler (zhandler -> dotrap). When the signal interrupts a
# builtin `echo`/`print` flush the process holds that stdio lock, and every fork the trap path
# then performs with fd redirection ($(...), pipes, `cmd 2>/dev/null`, `cmd > f`) deadlocks in
# the child (redup -> fileno -> flockfile) on the inherited, locked FILE; the leader blocks
# reading the child and never exits (the pane/lock/registry/report cleanup never completes).
# libc strftime/localtime inside the handler can also self-deadlock on the tz rwlock.
#
# This test drives the REAL code: the real lib is sourced at file scope and the real
# `_on_signal` chain (`_emit_launch_record_outcome`, `_emit_final_cost_log` -> `write_cost_log`,
# `cleanup` -> `generate_campaign_report`, `unregister_leader`, `log`, ...) is extracted from
# run_ralph_desk.zsh with the same brace-depth awk as tests/test_signal_trap.sh. A synthetic
# campaign loop that does back-to-back builtin stdio writes (the worst case for the race) runs
# against an isolated `tmux -L` server with two live panes; the harness is signalled at a random
# phase and must exit within a bound; more than MAX_HANGS hangs in the trial set is a FAIL.
#
# Sizing: the pre-fix hang rate of the `stress` mode was measured at 165/300 (55%); with 40
# trials P(<= 2 hangs | pre-fix) < 1e-10. Tolerance: zsh runs a trap through execlist -> fflush(stdout), so a signal
# that lands inside the few stdout flockfile/funlockfile instructions of the interrupted code still self-deadlocks
# (sampled: flockfile -> zhandler -> dotrap -> fflush -> flockfile). That floor was measured at ~1 in 1000-3000 deliveries
# in these worst-case loops (the leader itself spends almost all its time in sleep/tmux calls), so a clean run must not
# fail on 1-2 of 64; 3+ hangs is P < 1e-4 for the fixed code. The trials also assert that the cleanup the
# chain exists for really happened (exit 128+signum, cleanup exactly once, launch-record
# exit_code, metadata INTERRUPTED, final cost row, report, own lock + registry released, panes
# gone), so "no hang" cannot be bought by skipping the work.
#
# Platform note: the flockfile deadlock is a macOS libc behaviour; on Linux this test is a
# plain behavioural check of the same chain (not verified on Linux from this session).
#
# Static signal-path analysis (H-R5-01): xtrace prints nothing from inside a function called with stderr redirected or from a compound command
# whose stderr is redirected, so the traced guard below cannot see a fork there. The analyzer (`_c01_scan`, further down) reads the canonical text zsh
# prints (`${functions[f]}`, tokenized with `${(z)}`) of an over-approximated closure of `_on_signal` (built from raw text; currently 23 functions, a superset of the real call graph) and flags those constructs; its self-test table is
# confirmed against real xtrace. ACCEPTED LIMITS (none of them occurs on the signal path today; the analysis is not a full shell parser):
#   - a quoted or escaped command word is resolved only in plain simple-command position (`'f' 2>/dev/null`, `\f 2>/dev/null`); a word built from
#     `$var`, a command word that is itself a `$(...)`, or an `eval`/`builtin`/`command` prefix are not followed;
#   - `case` arms (`x) cmd 2>/dev/null ;;`), `coproc`, `exec {fd}>...` / fd-number juggling other than `exec 2>`, and several heredocs on one line;
#   - an escaped `\$(` inside `[[ ... ]]` is judged as a fork (a false positive, never a miss);
#   - a change of the xtrace option itself on the path (`set +x`, `unsetopt xtrace`, `setopt noxtrace`) is not flagged;
#   - `_sigsafe_sh '...'` clean-child scripts are single opaque quoted words: nothing inside them is analysed (they run in a fresh zsh with no xtrace);
#   - nested function definitions inside a signal-path function (a redirected call to such a function is not analysed; today the only nested definition
#     on the path is inside a _sigsafe_sh child script).
# A construct of one of these kinds appearing on the signal path would have to be added to the self-test (and handled) first.
#
# Cleanup when this test is killed from OUTSIDE (Q-01): no leader, no tmux server it created and no temp byte may survive (bound ~15 s; asserted per kill mode by
# tests/test_signal_deadlock_external_kill.zsh: TERM, INT, HUP, closed stdout, SIGKILL of the test, SIGKILL of its process group, orphaned leaders, normal exit).
# Two halves (the in-process traps and the reaper; code and rationale next to `_final_cleanup` and `_REAPER_PL` below):
#   - HUP/INT/TERM traps end the test with 128+signo. With the reaper up the handler does nothing else (it must not fork, and a raw `kill -9 <pid>` could hit a
#     recycled pid); the reaper does the cleanup. SIGPIPE is deliberately left at its default action (status 141): see the note at the traps.
#   - SIGKILL runs no trap, so ONE reaper (perl, started before any leader, own process group, signals ignored, stdio on /dev/null) outlives the test, waits for it to
#     be gone, then stops and kills the trial subshells and leaders that REGISTERED themselves (`$TMP/subs`, `$TMP/pids`: "<pid> <own clock>", written before
#     exec) and their descendants, kills the tmux servers of the run (labels are recorded BEFORE the server is created) and removes $TMP. It signals only what it
#     can prove is ours (registration time against process start time, then ancestry in the same `ps` snapshot): a command line that merely mentions $TMP or this
#     script authorises nothing. It is a child of the test, never of a leader, so the hang classifier below (which counts the leader's children) cannot see it.
# LIMITS: without perl the reaper is absent (one loud stderr line) and only the traps and the normal exit clean up; the handler then execs a fresh zsh
# of this file (`--degraded-cleanup`) that signals a recorded pid only after checking its start time against its registration time, and kills each leader once, so a
# child it forked at that instant can orphan; descendants are not hunted. The reaper itself being
# SIGKILLed, or the whole machine/session going away with it, is not covered; a SIGKILL in the first tens of milliseconds, before the reaper is ready, leaves only the
# empty $TMP (no process exists yet); a closed stdout pipe is noticed at the next stdout write, which is between modes and at the end unless C01_PROGRESS is set;
# a leader's descendants are found only while the leader is alive (an exec'd child that outlives its killed parent, e.g. an old tmux client or sleep, is short-lived
# and left to finish). Pane life (B-C2-04) does not exist in this design. $TMP honours $TMPDIR (macOS `mktemp -d` alone does not). Verified on macOS only (BSD
# `ps -axww -o pid=,ppid=,stat=,etime=,command=`, lsof); not on Linux.
# Leaders are exec'd through a perl that unblocks INT/TERM/HUP in the signal mask (a long-lived zsh driver can leak a BLOCKED INT mask to every fork, and zsh keeps an inherited mask,
# so the leader's INT trap would never fire in a builtin loop: backlog item 2); without perl it is a plain exec and the INT-mask check is skipped. C01_UNBLOCK=0 disables the reset.
# C01_KEEP_TMP=1 keeps $TMP for debugging (the reaper still kills processes and servers but leaves the directory).
#
# Knobs: C01_TRIALS_STRESS / C01_TRIALS_STRESSLOG / C01_TRIALS_STRESSDEBUG (default 40/12/12),
#        C01_PAR (default 12), C01_BUDGET_S (exit budget per trial, default 10), C01_MAX_HANGS (default 2),
#        C01_PROGRESS (non-empty: print one "." per trial started; default off).
set -uo pipefail
SELF="${0:A}"; ARGV0="$0"   # ARGV0: the script path as invoked, i.e. what appears in the test's own `ps` command line

# Degraded cleanup (no perl, so no reaper): the signal handler execs a fresh clean zsh of this file in this mode, and the EXIT trap runs it as a child. It runs in
# normal context, so it may fork `ps`: a recorded pid is signalled only if the live process with that pid started no later than its registration time + 2 s
# (a recycled pid starts after the registrant died) AND its command line (same `ps` call) names this run: a leader (pids/) must run `$TMP/harness.zsh` or still
# carry the test's own command line (between fork and exec it is a forked copy of the test), a trial subshell (subs/) must carry the test's own command line
# (ARGV0, the path as invoked). Then the tmux servers of the run are ended, their socket files and $TMP removed. Descendants of a killed leader are not hunted (no
# reaper): a child it was forking at that instant can orphan. Usage: --degraded-cleanup <TMP> <exit status> <script path as invoked>
if [[ "${1:-}" == --degraded-cleanup ]]; then
  TMP="${2:-}"; zmodload zsh/datetime
  [[ "$TMP" == /*/rlpc01.* ]] || exit "${3:-0}"
  _secs() { local e="${1// /}" d=0 s=0 x; [[ "$e" == *-* ]] && { d=${e%%-*}; e=${e#*-}; }; for x in ${(s.:.)e}; do s=$(( s * 60 + 10#$x )); done; print -r -- $(( d * 86400 + s )); }
  for f in "$TMP"/subs/*(N) "$TMP"/pids/*(N); do   # subshells first: they would spawn new leaders
    read -r p reg < "$f" 2>/dev/null || continue
    [[ "$p" == <2-> && "$reg" == <-> ]] || continue
    line=$(ps -o etime= -o command= -p "$p" 2>/dev/null); [[ -n "$line" ]] || continue
    read -r et cmd <<< "$line"   # ps pads etime (procps ~11 columns, BSD right-aligned); `read` splits without needing EXTENDED_GLOB, which a bare ${x## #} does
    (( EPOCHSECONDS - $(_secs "$et") <= reg + 2 )) || continue
    if [[ "${f:h:t}" == pids ]]; then [[ "$cmd" == *"$TMP/harness.zsh"* || ( -n "${4:-}" && "$cmd" == *"$4"* ) ]] || continue
    else [[ -n "${4:-}" && "$cmd" == *"$4"* ]] || continue; fi
    kill -9 "$p" 2>/dev/null
  done
  for f in "$TMP"/labels/*(N); do
    l=$(<"$f"); [[ "$l" == rlpc01_* ]] || continue
    tmux -L "$l" kill-server >/dev/null 2>&1; rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$UID/$l"
  done
  [[ -n "${C01_KEEP_TMP:-}" ]] && print -u2 "kept: $TMP" || rm -rf "$TMP"
  exit "${3:-0}"
fi

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
RUN="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"
LIB="$ROOT_DIR/src/scripts/lib_ralph_desk.zsh"
[[ -f "$RUN" ]] || { print -u2 "FAIL: run script not found: $RUN"; exit 1; }
[[ -f "$LIB" ]] || { print -u2 "FAIL: lib script not found: $LIB"; exit 1; }
for _tool in jq git; do
  command -v "$_tool" >/dev/null 2>&1 || { print -u2 "FAIL: $_tool not installed"; exit 1; }
done
zmodload zsh/datetime zsh/system   # zsh/system provides $sysparams[pid]

N_STRESS=${C01_TRIALS_STRESS:-40}
N_STRESSLOG=${C01_TRIALS_STRESSLOG:-12}
N_STRESSDEBUG=${C01_TRIALS_STRESSDEBUG:-12}
N_STRESSREFRESH=${C01_TRIALS_STRESSREFRESH:-24}
PAR=${C01_PAR:-12}
BUDGET_S=${C01_BUDGET_S:-10}
MAX_HANGS=${C01_MAX_HANGS:-2}

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; }
no(){ FAIL=$((FAIL+1)); print -u2 "  FAIL $1"; }

HAVE_TMUX=0; command -v tmux >/dev/null 2>&1 && HAVE_TMUX=1
TMP=$(mktemp -d "${${TMPDIR:-/tmp}%/}/rlpc01.XXXXXX") || { print -u2 "FAIL: cannot create a temp dir under ${TMPDIR:-/tmp}"; exit 1; }   # macOS bare `mktemp -d` ignores $TMPDIR
[[ "$TMP" == /* ]] || TMP="$PWD/$TMP"
mkdir -p "$TMP/res" "$TMP/pids" "$TMP/labels" "$TMP/subs"
MAIN_PID=$$

# --- Q-01 cleanup, in-process half: signal traps + EXIT (the out-of-group reaper below is the half that survives SIGKILL) ---
# zsh runs a trap synchronously inside the signal handler (see the C-01 root cause above): a signal that interrupted a stdio write leaves the handler holding that
# lock, and a fork with fd redirection or a pipe made from there ($(...), `cmd 2>/dev/null`) deadlocks in the child. So with the reaper up (the normal case) the
# HUP/INT/TERM handler does NOTHING but end the process with 128+n: every signal sent to a pid is authorised by an identity check (registration time against the
# process start time, see the reaper), which needs `ps`, i.e. a fork. Without perl (degraded, loud warning at start) the handler execs a fresh clean zsh of this
# file in `--degraded-cleanup` mode (top of the file): no fork happens in the handler, and the identity check runs in normal context.
_reaper_up() { [[ -s "$TMP/reaper.ready" ]]; }
_final_cleanup() {   # EXIT trap (normal context)
  local f l; local -a lbls live
  if _reaper_up; then
    live=("$TMP"/subs/*(N) "$TMP"/pids/*(N))
    (( ${#live} )) && return 0   # a trial is still registered (abnormal exit): leave records, servers and $TMP to the reaper, which stops and kills the tree
  else
    command zsh -f "$SELF" --degraded-cleanup "$TMP" 0 "$ARGV0"   # no reaper: the same identity-checked cleanup the degraded handler uses
    return 0
  fi
  lbls=(); for f in "$TMP"/labels/*(N); do l=$(<"$f"); [[ -n "$l" ]] && lbls+=("$l"); done
  # tmux 3.8 leaves the socket FILE behind after kill-server or after a server exits by itself (B-H2-03): remove it too
  (( ${#lbls} )) && command zsh -fc 'for l; do tmux -L "$l" kill-server >/dev/null 2>&1; rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$UID/$l"; done' zsh "${lbls[@]}"
  [[ -n "${C01_KEEP_TMP:-}" ]] && print -u2 "kept: $TMP" || command rm -rf "$TMP"
}
_on_kill() {   # <signal number>: HUP INT TERM end the test with 128+n
  (( ${sysparams[pid]} == MAIN_PID )) || exit $(( 128 + $1 ))   # a forked trial subshell may inherit this trap: it only dies, the main process cleans up
  trap - EXIT HUP INT TERM                                       # a second signal during the cleanup kills at once; the reaper finishes the job
  _reaper_up || exec zsh -f "$SELF" --degraded-cleanup "$TMP" $(( 128 + $1 )) "$ARGV0"   # no fork in the handler: a fresh zsh does the identity-checked cleanup
  exit $(( 128 + $1 ))
}
# SIGPIPE (closed stdout) is deliberately NOT trapped: the write that raises it holds the stdio lock; the default action ends the process at once (status 141)
# and the reaper does the cleanup.
trap '_final_cleanup' EXIT
trap '_on_kill 1' HUP
trap '_on_kill 2' INT
trap '_on_kill 15' TERM

# --- Q-01 cleanup, out-of-group half: the reaper. SIGKILL (of the test, or of its whole process group as the npm runner's `kill 9,-$p` does) runs no trap,
# so one helper process outlives it. It is a direct child of THIS shell (never of a leader: the hang classifier counts the leader's children), starts its own
# process group, ignores HUP/INT/TERM/PIPE, has stdio on /dev/null, and polls until this process is gone (a zombie counts as gone: getppid changes at exit).
# OWNERSHIP RULE: a signal is sent only to (a) a REGISTERED process: a trial subshell or leader that wrote "<pid> <its own clock>" into $TMP/subs or $TMP/pids
# before doing anything else, and whose start time (now - etime from `ps`) is not later than that registration time (+2 s of ps resolution), so a recycled
# pid, which starts after the registrant died, is rejected; leaders must also run `$TMP/harness.zsh`, subshells must carry the test's own exact command line;
# (b) a descendant of such a verified process in the same `ps` snapshot. A command line that merely mentions $TMP or the script name authorises nothing.
# Targets are SIGSTOPped until the set stops growing (a stopped process cannot fork), re-verified in a fresh snapshot, and only then SIGKILLed; a pid that fails
# re-verification is SIGCONTed instead. tmux servers are ended by recorded label (`tmux -L <label> kill-server`), by `rlpc01_<testpid>_*` socket name, and, for an
# unlinked socket, by an open socket path through lsof; socket files are unlinked; then $TMP is removed. It repeats until a round finds nothing; after a normal
# exit it finds nothing and ends at once.
read -r -d '' _REAPER_PL <<'PERL'
use strict; use warnings; use File::Path qw(remove_tree);
my ($tpid, $tmp, $keep) = @ARGV; $keep = '' unless defined $keep;
exit 2 unless defined $tmp && $tpid =~ /^[1-9][0-9]*$/ && $tmp =~ m{^/(?:[^/\0]+/)*rlpc01\.[A-Za-z0-9]+$};
$SIG{$_} = 'IGNORE' for qw(HUP INT TERM PIPE QUIT);
setpgrp(0, 0);
open(STDIN, '<', '/dev/null'); open(STDOUT, '>', '/dev/null'); open(STDERR, '>', '/dev/null');
my $direct = (getppid() == $tpid) ? 1 : 0;
my $tag = "rlpc01_${tpid}_";
my $sockdir = ($ENV{TMUX_TMPDIR} || '/tmp') . '/tmux-' . $<;
sub slurp { my ($f) = @_; open(my $fh, '<', $f) or return ''; my $l = <$fh>; close $fh; $l = '' unless defined $l; $l =~ s/\s+//g; $l }
sub files { my ($d) = @_; opendir(my $dh, $d) or return (); my @f = map { "$d/$_" } grep { !/^\./ } readdir $dh; closedir $dh; @f }
sub secs { my ($e) = @_; my $d = 0; $d = $1 * 86400, $e = $2 if $e =~ /^(\d+)-(.*)$/; my $s = 0; $s = $s * 60 + $_ for split /:/, $e; $d + $s }
sub ptable {   # pid => [ppid, stat, command, start-time-in-epoch-seconds (now - etime)]
  my %t; my $now = time;
  open(my $ph, '-|', 'ps', '-axww', '-o', 'pid=', '-o', 'ppid=', '-o', 'stat=', '-o', 'etime=', '-o', 'command=') or return %t;
  while (my $l = <$ph>) { chomp $l; next unless $l =~ /^\s*(\d+)\s+(\d+)\s+(\S+)\s+(\S+)\s+(.*)$/; my ($p, $pp, $st, $et, $cm) = ($1, $2, $3, $4, $5); $t{$p} = [$pp, $st, $cm, $now - secs($et)] }
  close $ph; %t;
}
my %t0 = ptable(); my $tcmd = $t0{$tpid} ? $t0{$tpid}[2] : undef;   # the test's own command line: its forked subshells carry the same one
sub gone {
  return 1 if $direct && getppid() != $tpid;
  return 1 unless kill 0, $tpid;
  return 0 if $direct;
  my $s = `ps -o stat= -p $tpid 2>/dev/null`; return $s =~ /^\s*Z/ ? 1 : 0;
}
if (open(my $fh, '>', "$tmp/reaper.ready.$$")) { print $fh "$$\n"; close $fh; rename("$tmp/reaper.ready.$$", "$tmp/reaper.ready") }
sub marked {   # pids we own in snapshot $t: verified registered roots and, by ppid in the same snapshot, all their descendants
  my ($t) = @_; my %mark;
  for my $d ('subs', 'pids') {
    for my $f (files("$tmp/$d")) {
      open(my $fh, '<', $f) or next; my $l = <$fh>; close $fh;
      next unless defined $l && $l =~ /^([1-9][0-9]*) ([0-9]+)\s*$/;
      my ($p, $reg) = ($1, $2);
      my $e = $t->{$p};
      next unless $e && $p > 1 && $p != $$ && $p != $tpid && $e->[3] <= $reg + 2 && $e->[1] !~ /^Z/;
      next unless $d eq 'pids' ? index($e->[2], "$tmp/harness.zsh") >= 0 : (defined $tcmd && $e->[2] eq $tcmd);
      $mark{$p} = 1;
    }
  }
  for (my $grew = 1; $grew;) {
    $grew = 0;
    for my $p (keys %$t) { next if $mark{$p} || $p <= 1 || $p == $$ || $p == $tpid; if ($mark{$t->{$p}[0]}) { $mark{$p} = 1; $grew = 1 } }
  }
  %mark;
}
sub reap {
  my ($n, %stopped) = (0);
  # SIGSTOP until the owned set stops growing, then SIGKILL: a stopped process cannot fork, so a child born while we were looking is found by the next snapshot
  # instead of escaping as an orphan of a killed parent (B-H2-04). A pid is recorded as stopped only if the STOP was delivered, together with the start time the
  # snapshot showed for it. Every later signal to that pid (CONT or KILL) is sent only while a fresh snapshot still shows the SAME start time: if the process died
  # and the pid was recycled, the replacement gets nothing (A-C1-02). The STOP itself rests on the snapshot taken a few milliseconds earlier.
  my $same = sub { my ($t, $p) = @_; $t->{$p} && abs($t->{$p}[3] - $stopped{$p}[1]) <= 2 };
  for (1 .. 8) {
    my %t = ptable(); my %mark = marked(\%t);
    for my $p (keys %stopped) {
      my $s = $same->(\%t, $p);
      next if $s && $mark{$p};            # still ours and still stopped
      kill 'CONT', $p if $s;              # the same process, but no longer in the owned set: release it
      delete $stopped{$p};                # a replacement under the same pid gets no signal (and is picked up again below if it is owned)
    }
    my @new = grep { !$stopped{$_} && $t{$_}[1] !~ /^Z/ } keys %mark;
    last unless @new;
    for my $p (@new) { $stopped{$p} = [time, $t{$p}[3]] if kill 'STOP', $p }
    select(undef, undef, undef, 0.05);
  }
  my %t = ptable(); my %mark = marked(\%t);   # final re-verification right before the kill
  for my $p (sort { $a <=> $b } keys %stopped) {
    next unless $same->(\%t, $p);             # not the process we stopped: no signal at all
    if ($mark{$p}) { $n++ if kill 9, $p } else { kill 'CONT', $p }
  }
  my %lbl;
  for my $f (files("$tmp/labels")) { my $l = slurp($f); $lbl{$l} = 1 if $l =~ /^rlpc01_[0-9]+_[A-Za-z]+_[0-9]+$/ }
  for my $f (files($sockdir)) { my ($b) = $f =~ m{([^/]+)$}; $lbl{$b} = 1 if index($b, $tag) == 0 && $b =~ /^rlpc01_[0-9]+_[A-Za-z]+_[0-9]+$/ }
  for my $l (sort keys %lbl) { $n++ if system('tmux', '-L', $l, 'kill-server') == 0; unlink("$sockdir/$l") if -S "$sockdir/$l" }
  my %t2 = ptable();
  for my $p (keys %t2) {
    next unless $t2{$p}[2] =~ m{^(?:\S*/)?tmux(?:\s|:|$)} && $t2{$p}[1] !~ /^Z/;   # candidates for lsof only; the kill is authorised by the open socket path below
    open(my $lh, '-|', 'lsof', '-a', '-p', $p, '-U', '-Fn') or next;
    my $hit = 0;
    while (my $l = <$lh>) { chomp $l; next unless $l =~ s/^n//; $hit = 1 if index($l, "/$tag") >= 0 || grep { index($l, "/$_") >= 0 } keys %lbl }
    close $lh;
    $n++ if $hit && kill 9, $p;
  }
  if (-e $tmp && $keep eq '') { remove_tree($tmp); $n++ unless -e $tmp }
  $n;
}
until (gone()) { select(undef, undef, undef, 0.25) }
for (1 .. 8) { last unless reap(); select(undef, undef, undef, 0.3) }
exit 0;
PERL
# Leader launch hardening (backlog item 2, .omc/artifacts/backlog-2026-10-25/w2-item2.md): a long-lived zsh driver can end up with SIGINT BLOCKED in its signal
# mask, every fork inherits it, zsh keeps the inherited mask, so the leader's INT trap is armed but INT is never delivered while it runs a builtin-only loop (a
# spurious INT "deadlock"). With perl the leader is exec'd through a mask-resetting perl (same pid, so the recorded pid, the hang classifier and the reaper still see
# the leader); without perl it is a plain exec. C01_UNBLOCK=0 turns the reset off (used to show the INT-mask check below fails without it).
typeset -a _LEADER_PRE=() _PRE_BLOCK=()
if command -v perl >/dev/null 2>&1; then
  [[ "${C01_UNBLOCK:-1}" == 0 ]] || _LEADER_PRE=(perl -MPOSIX -e 'sigprocmask(SIG_UNBLOCK, POSIX::SigSet->new(SIGINT, SIGTERM, SIGHUP)); exec @ARGV or die "exec: $!"')
  perl -e "$_REAPER_PL" -- $$ "$TMP" "${C01_KEEP_TMP:+keep}" </dev/null >/dev/null 2>&1 &!   # &! = background AND disown: the trial loop's `wait` and job counts must not see it
  for (( _i = 0; _i < 300; _i++ )); do [[ -s "$TMP/reaper.ready" ]] && break; sleep 0.05; done
  [[ -s "$TMP/reaper.ready" ]] || print -u2 "WARNING: the Q-01 reaper did not start within 15 s: cleanup after SIGKILL of this test is NOT covered (traps only)"
else
  print -u2 "WARNING: perl not found: Q-01 cleanup after SIGKILL of this test (or of its process group) is degraded to the traps only; HUP/INT/TERM and normal exit are still cleaned"
fi

# --- Extract the REAL implementation (brace-depth aware; same awk as test_signal_trap.sh) ---
_extract_fn() {
  awk -v fn="$1" '
    $0 ~ "^"fn"\\(\\) \\{" { in_fn=1; depth=0 }
    in_fn { for (i=1;i<=length($0);i++){c=substr($0,i,1); if(c=="{")depth++; else if(c=="}"){depth--; if(depth==0){print; in_fn=0; next}}}
            print }' "$2"
}
TRAP_LINES=$(grep -A3 "^  trap '_emit_launch_record_outcome; _emit_final_cost_log; cleanup' EXIT$" "$RUN" | head -4)
[[ -n "$TRAP_LINES" ]] || { print -u2 "FAIL: EXIT/INT/TERM/HUP trap-arm block not found in $RUN"; exit 1; }
REQUIRED_FNS=(_emit_launch_record_outcome _emit_final_cost_log _untracked_names _untracked_complete_warning _on_signal cleanup)
for _f in $REQUIRED_FNS; do
  [[ -n "$(_extract_fn "$_f" "$RUN")" ]] || { print -u2 "FAIL: function $_f not found in $RUN"; exit 1; }
done
# Helpers that exist only once the fix is applied (extracted when present, so the same test runs
# unmodified against the pre-fix tree for the red run).
OPTIONAL_FNS=(_sigsafe_tmux)

# --- Campaign-shaped template tree, copied per trial ---------------------------------------
TPL="$TMP/template"
_make_template() {
  local R="$TPL/root" DESKD="$TPL/root/.claude/ralph-desk" L="$TPL/root/.claude/ralph-desk/logs/c01" i n m
  mkdir -p "$L" "$DESKD/memos" "$DESKD/plans" "$DESKD/runtime"
  git -C "$R" init -q -b main 2>/dev/null || git -C "$R" init -q
  local -a G=(git -C "$R" -c user.email=t@t -c user.name=t -c commit.gpgsign=false)
  print a > "$R/a.txt"; "${G[@]}" add -A; "${G[@]}" commit -qm one
  print b >> "$R/a.txt"; print c > "$R/b.txt"; "${G[@]}" add -A; "${G[@]}" commit -qm two
  print dirty >> "$R/a.txt"; print u1 > "$R/untracked1.txt"; print u2 > "$R/untracked2.txt"
  print -r -- $'## Objective\nDo the thing\nmore\nmore' > "$DESKD/plans/prd-c01.md"
  for ((i=1;i<=12;i++)); do
    n=$(printf %03d $i)
    print -r -- '{"us_id":"US-00'$((i%3+1))'"}' > "$L/iter-$n-done-claim.json"
    print x > "$L/iter-$n.worker-prompt.md"
    m=gpt-6-luna; (( i > 6 )) && m=gpt-5.6-terra
    print -r -- '{"iteration":'$i',"estimated_tokens":'$((i*100))',"token_source":"estimated","us_id":"US-00'$((i%3+1))'","worker_model":"'$m'","worker_engine":"codex","worker_effort":"high","verifier_engine":"claude","note":""}' >> "$L/cost-log.jsonl"
  done
  print -r -- '{"ts":"2020-01-01T00:00:00Z","slug":"c01","leader":"zsh","pid":1,"phase":"launched"}' > "$L/launch-record.json"
  print -r -- '{"campaign_status":"RUNNING"}' > "$L/metadata.json"
  # production always has status.json (update_status); generate_campaign_report reads .model_upgraded from it
  print -r -- '{"model_upgraded":1,"iteration":12}' > "$L/status.json"
}
mkdir -p "$TPL/root"; _make_template

# --- Harness: real lib sourced at file scope + real extracted signal-path functions ---------
HAR="$TMP/harness.zsh"
{
  cat <<'HDR'
#!/bin/zsh
# usage: harness.zsh <T dir> <LOOP_MODE stress|stresslog> ; env: C01_LIB C01_LIBDIR C01_DEBUG
set -uo pipefail
setopt POSIX_TRAPS
T="$1"; LOOP_MODE="${2:-stress}"
HDR
  print -r -- 'source "$C01_LIB"'
  print -r -- 'typeset -g SIGNAL_RECEIVED=""'
  print -r -- 'COST_LOG_FINAL_WRITTEN=0'
  print -r -- 'LAUNCH_RECORD_OUTCOME_WRITTEN=0'
  for _f in $OPTIONAL_FNS $REQUIRED_FNS; do _extract_fn "$_f" "$RUN"; print; done
  cat <<'STATE'
# ---- synthetic campaign state (the globals main()/top-level would have set) ----
SLUG="c01"; ROOT="$T/root"; DESK="$ROOT/.claude/ralph-desk"
LOGS_DIR="$DESK/logs/$SLUG"; MEMOS_DIR="$DESK/memos"; RUNTIME_DIR="$DESK/runtime"
METADATA_FILE="$LOGS_DIR/metadata.json"; STATUS_FILE="$LOGS_DIR/status.json"
COST_LOG="$LOGS_DIR/cost-log.jsonl"; DONE_CLAIM_FILE="$LOGS_DIR/done-claim.json"; VERDICT_FILE="$LOGS_DIR/verdict.json"
COMPLETE_SENTINEL="$DESK/memos/$SLUG-complete.md"; BLOCKED_SENTINEL="$DESK/memos/$SLUG-blocked.md"
LOCKFILE_PATH="$T/lock.d/leader.lock"; LOCKFILE_ACQUIRED=0
RUNNER_LOCKFILE_PATH="$T/lock.d/runner.lock"
LIB_DIR="$C01_LIBDIR"; ROOT_HASH="c01hash"; SESSION_NAME="c01-sess"; START_TIME=$(date +%s)
ITERATION=12; MAX_ITER=20; CONSECUTIVE_FAILURES=0; VERIFIED_US="US-001,US-002"
BASELINE_COMMIT="$(git -C "$ROOT" rev-parse HEAD~1 2>/dev/null || echo none)"
CAMPAIGN_REPORT_GENERATED=0; SV_REPORT_GENERATED=0; WITH_SELF_VERIFICATION=0
DEBUG="${C01_DEBUG:-0}"; DEBUG_LOG="$LOGS_DIR/debug.log"
WORKER_MODEL=gpt-6-luna; WORKER_ENGINE=codex; VERIFIER_MODEL=sonnet; VERIFIER_ENGINE=claude
CONSENSUS_MODE=off; CONSENSUS_MODEL=x; FINAL_CONSENSUS_MODEL=y
WORKER_CODEX_REASONING=high; WORKER_EFFORT=""
COST_LOG_NOTE=""; LAUNCH_RECORD_FILE="$LOGS_DIR/launch-record.json"
CAMPAIGN_UNTRACKED_SNAPSHOT_OK=1; CAMPAIGN_PREEXISTING_UNTRACKED=""
WORKER_PANE="${C01_WORKER_PANE:-}"; VERIFIER_PANE="${C01_VERIFIER_PANE:-}"; CONSENSUS_PANE=""
CURRENT_US=US-002; VERIFY_MODE=per-us; CLAUDE_VERDICT=""; CODEX_VERDICT=""; CONSENSUS_ROUND=0
[[ -n "${C01_TZ_REFRESH:-}" ]] && _RLP_TZ_REFRESH_S=$C01_TZ_REFRESH   # stressrefresh: every log call re-reads the UTC offset
main() {
STATE
  print -r -- "$TRAP_LINES"
  cat <<'LOOP'
  mkdir -p "$(dirname "$RUNNER_LOCKFILE_PATH")" 2>/dev/null
  acquire_slug_lock "$RUNNER_LOCKFILE_PATH" || { echo "lock-busy"; exit 1; }
  register_leader "tmux"
  LOCKFILE_ACQUIRED=1
  : > "$T/ready"
  local i=0
  case "$LOOP_MODE" in
    stress)    # worst case: back-to-back builtin stdio writes, no sleep
      while (( SECONDS < 45 )); do echo "[main] tick $((++i)) payload payload payload payload"; done ;;
    stresslog) # the leader's own log() in a tight loop
      while (( SECONDS < 45 )); do log "tick $((++i)) payload payload payload payload payload"; done ;;
  esac
}
main "$@"
LOOP
} > "$HAR"
chmod +x "$HAR"

# --- One trial: isolated tmux server (2 panes), start harness, signal at a random phase ----
# Writes $TMP/res/<mode>.<id> as space-separated key=value fields.
_trial() {
  local mode="$1" id="$2" dbg="$3" loop="$4" sig="$5" delay_ms="$6" tzr="${7:-}"
  # Q-01: register this trial subshell BEFORE anything else, then make sure the main process is still our parent: if it died first, the reaper may already
  # have read subs/, so stop here instead of spawning a leader nobody will reap.
  local subpid=${sysparams[pid]}
  print -r -- "$subpid $EPOCHSECONDS" > "$TMP/subs/$mode.$id"; [[ "${sysparams[ppid]}" == "$MAIN_PID" ]] || return 9
  local T; T=$(mktemp -d "$TMP/trial.XXXXXX") || return 9
  cp -R "$TPL/." "$T/"; mkdir -p "$T/lock.d" "$T/tmp"   # the leader's TMPDIR: anything it leaves there is litter
  local lbl="rlpc01_${$}_${mode}_${id}" sock="" w="" v=""
  if (( HAVE_TMUX )); then
    print -r -- "$lbl" > "$TMP/labels/$mode.$id"
    tmux -L "$lbl" -f /dev/null new-session -d -s c01 -x 100 -y 30 'cat' 2>/dev/null
    tmux -L "$lbl" -f /dev/null split-window -t c01 'cat' 2>/dev/null
    sock=$(tmux -L "$lbl" display -p '#{socket_path}' 2>/dev/null)
    local -a panes; panes=($(tmux -L "$lbl" list-panes -t c01 -F '#{pane_id}' 2>/dev/null))
    w="${panes[1]:-}"; v="${panes[2]:-}"
  fi
  local -A expect=(INT 130 TERM 143 HUP 129)
  # sig and delay_ms are drawn by the PARENT loop (`_run_mode`): background subshells all inherit the parent's RANDOM state and would
  # repeat one signal and one delay for every trial of a run.
  # env -i is not used on purpose: the real leader inherits the operator environment.
  # The leader registers its own pid before exec (no window between fork and the record) and stops if its trial subshell is already gone.
  ( print -r -- "${sysparams[pid]} $EPOCHSECONDS" > "$TMP/pids/$mode.$id"; [[ "${sysparams[ppid]}" == "$subpid" ]] || exit 1
    [[ -n "$sock" ]] && export TMUX="$sock,1,0" || unset TMUX
    export TMPDIR="$T/tmp" C01_LIB="$LIB" C01_LIBDIR="${LIB:h}" C01_DEBUG="$dbg" C01_TZ_REFRESH="$tzr" C01_WORKER_PANE="$w" C01_VERIFIER_PANE="$v"
    exec "${_PRE_BLOCK[@]}" "${_LEADER_PRE[@]}" zsh -f "$HAR" "$T" "$loop" </dev/null >"$T/out" 2>"$T/err" ) &
  local pid=$!
  local waited=0
  until [[ -f "$T/ready" ]] || ! kill -0 $pid 2>/dev/null; do sleep 0.02; (( ++waited > 500 )) && break; done
  sleep $(( delay_ms / 1000.0 ))                  # 50..950 ms after ready: arbitrary loop phase
  kill -$sig $pid 2>/dev/null
  local hang=0 ec="" budget_ticks=$(( BUDGET_S * 10 )) t=0 t0=$EPOCHREALTIME
  while kill -0 $pid 2>/dev/null; do
    sleep 0.1
    (( ++t >= budget_ticks )) && { hang=1; break; }
  done
  local lat=$(( EPOCHREALTIME - t0 ))
  local hangnote=""
  if (( hang )); then
    local -a kids; kids=($(pgrep -P $pid 2>/dev/null))
    hangnote="kids=${#kids}"
    # Diagnostics for every hang (L-14): Linux/BSD ps know ignored/caught, macOS ps only blocked/pending/sigmask.
    { print -r -- "--- HANG $mode.$id sig=$sig pid=$pid kids=${#kids}"
      { ps -o ignored= -p $$ >/dev/null 2>&1 && ps -o pid=,stat=,ignored=,caught= -p $pid; } || ps -o pid=,stat=,blocked=,pending=,sigmask= -p $pid 2>&1
    } > "$TMP/hang-ps.$mode.$id"
    # Classify EVERY hang by its stack (macOS `sample`), not only the first one: the only hang we tolerate is the stdio-lock floor, i.e.
    # a signal that landed inside flockfile/funlockfile of the interrupted fflush and a handler whose own fflush->flockfile blocks
    # (nested zhandler -> dotrap -> fflush -> flockfile, no fork / wait / FILE-table frame anywhere in the call tree).
    local floor=unknown
    # (C01_SAMPLE_CMD overrides the stack sampler; "none" simulates a host without one, to prove that an unclassifiable hang FAILS)
    local _smp="${C01_SAMPLE_CMD:-sample}"
    if command -v "$_smp" >/dev/null 2>&1; then
      "$_smp" $pid 1 2>/dev/null | sed -E '/^Total number in stack/,$d' > "$TMP/hang-sample.$mode.$id"
      if grep -q 'zhandler' "$TMP/hang-sample.$mode.$id" && grep -q 'flockfile' "$TMP/hang-sample.$mode.$id" \
         && ! grep -qE 'fork|__sfp|open_memstream|redup|getoutput|waitforpid|waitjobs|zwaitjob' "$TMP/hang-sample.$mode.$id"; then floor=1; else floor=0; fi
      { print -r -- "--- HANG $mode.$id sig=$sig pid=$pid kids=${#kids} floor=$floor; leader stack (call tree, filtered):"
        grep -E 'flockfile|fflush|zhandler|dotrap|bin_print|fork|__sfp|open_memstream|redup|getoutput|waitfor|waitjobs|execwhile' "$TMP/hang-sample.$mode.$id" | sed -E 's/^[ +!:|]+//' | cut -c1-110 | head -14
        if [[ -n "${kids[1]:-}" ]]; then
          print -r -- "--- child ${kids[1]} stack:"
          sample ${kids[1]} 1 2>/dev/null | grep -E 'redup|fileno|flockfile|getoutput|readoutput|prefork' | sed -E 's/^[ +!:|]+//' | cut -c1-110 | head -8
        fi
      } > "$TMP/hang-evidence.$mode.$id" 2>&1
    fi
    hangnote="$hangnote floor=$floor"
    for c in $kids; do kill -9 $c 2>/dev/null; done
    kill -9 $pid 2>/dev/null; wait $pid 2>/dev/null
  else
    wait $pid; ec=$?
  fi
  local L="$T/root/.claude/ralph-desk/logs/c01"
  local cleanups cost_rows lr_exit meta report lock_left reg_left panes_left debug_final tmp_left=0
  local -a _tl; _tl=("$T"/tmp/*(N)); (( ${#_tl} )) && tmp_left=1
  cleanups=$(grep -c '^\[.*\] Cleaning up\.\.\.$' "$T/out" 2>/dev/null); cleanups=${cleanups:-0}
  cost_rows=$(wc -l < "$L/cost-log.jsonl" 2>/dev/null | tr -d ' '); cost_rows=${cost_rows:-0}
  lr_exit=$(jq -r '.exit_code // empty' "$L/launch-record.json" 2>/dev/null)
  meta=$(jq -r '.campaign_status // empty' "$L/metadata.json" 2>/dev/null)
  report=0; grep -q '^## Suggested Next Actions' "$L/campaign-report.md" 2>/dev/null && grep -q 'INTERRUPTED' "$L/campaign-report.md" 2>/dev/null && report=1
  lock_left=0; [[ -e "$T/lock.d/runner.lock" ]] && lock_left=1
  reg_left=0; local f; for f in "$L"/../.rlp-desk-leaders-c01hash.d/*(N); do reg_left=1; done
  panes_left=0; (( HAVE_TMUX )) && panes_left=$(tmux -L "$lbl" list-panes -a 2>/dev/null | wc -l | tr -d ' ')
  debug_final=1; (( dbg )) && { grep -q '\[FLOW\] final status=INTERRUPTED' "$L/debug.log" 2>/dev/null || debug_final=0; }
  print -r -- "hang=$hang sig=$sig ec=${ec:-none} exp=${expect[$sig]} cleanups=$cleanups cost_rows=$cost_rows lr_exit=${lr_exit:-none} meta=${meta:-none} report=$report lock_left=$lock_left reg_left=$reg_left panes_left=${panes_left:-0} debug_final=$debug_final tmp_left=$tmp_left lat=$(printf %.1f $lat) $hangnote" > "$TMP/res/$mode.$id"
  if (( HAVE_TMUX )); then tmux -L "$lbl" kill-server 2>/dev/null; [[ -n "$sock" ]] && rm -f "$sock"; fi
  rm -f "$TMP/pids/$mode.$id" "$TMP/subs/$mode.$id" "$TMP/labels/$mode.$id"   # leader dead and reaped, server killed: drop the records (a recycled pid is never killed later)
  rm -rf "$T"
}

_run_mode() {   # <mode label> <trials> <debug 0|1> <harness loop stress|stresslog> [<_RLP_TZ_REFRESH_S override>]
  local mode="$1" n="$2" dbg="$3" loop="$4" tzr="${5:-}" i=0 sig dl
  local -a sigs=(INT TERM HUP)
  while (( i < n )); do
    while (( ${#jobstates} >= PAR )); do wait -n 2>/dev/null || sleep 0.05; done
    (( ++i ))
    [[ -n "${C01_PROGRESS:-}" ]] && print -n .   # progress dot: a stdout write while trials run (the Q-01 closed-pipe scenario needs one)
    sig=${sigs[$(( i % 3 + 1 ))]}; dl=$(( RANDOM % 900 + 50 ))   # drawn HERE, in the parent: round-robin signals, random delay
    _trial "$mode" $i "$dbg" "$loop" "$sig" "$dl" "$tzr" &
  done
  wait
}

print "C-01: signal during builtin stdio write must not deadlock the trap path"
print "  trials: stress=$N_STRESS stresslog=$N_STRESSLOG stressdebug=$N_STRESSDEBUG stressrefresh=$N_STRESSREFRESH parallel=$PAR budget=${BUDGET_S}s tmux=$HAVE_TMUX"
start=$EPOCHREALTIME
_run_mode stress      $N_STRESS      0 stress
_run_mode stresslog   $N_STRESSLOG   0 stresslog
_run_mode stressdebug $N_STRESSDEBUG 1 stress      # same loop, DEBUG=1 (cleanup's diagnostics block runs)
# same loop as stresslog but every log line refreshes the UTC offset (an in-process `date +%z` fork + wait): a signal can land during a refresh
_run_mode stressrefresh $N_STRESSREFRESH 0 stresslog 0
elapsed=$(( EPOCHREALTIME - start ))
print "  all trials finished in $(printf %.0f $elapsed)s"

typeset -A EXPECTED_TRIALS=(stress $N_STRESS stresslog $N_STRESSLOG stressdebug $N_STRESSDEBUG stressrefresh $N_STRESSREFRESH)
_total=0; _hang=0; _bad=0; _hang_kids=0; _hang_nonfloor=0; _hang_unknown=0; typeset -A _hang_sig=() _sig_all=()
_field() { local k="$1" line="$2" x; for x in ${=line}; do [[ "$x" == "$k="* ]] && { print -r -- "${x#*=}"; return; }; done }
# INT-mask check (deterministic): one INT trial whose launcher has SIGINT BLOCKED (perl SIG_BLOCK exec in front of the normal launch chain, for this trial only).
# With the mask-resetting exec the leader must still handle INT (exit 130, cleanup once); without it (C01_UNBLOCK=0) the blocked INT is never delivered and the
# leader hangs. Needs perl for the blocking wrapper.
if command -v perl >/dev/null 2>&1; then
  _PRE_BLOCK=(perl -MPOSIX -e 'sigprocmask(SIG_BLOCK, POSIX::SigSet->new(SIGINT)); exec @ARGV or die "exec: $!"')
  _trial intmask 1 0 stress INT 300 "" &
  wait
  _PRE_BLOCK=()
  _mline=$(<"$TMP/res/intmask.1" 2>/dev/null)
  if [[ "$(_field hang "$_mline")" == 0 && "$(_field ec "$_mline")" == 130 && "$(_field cleanups "$_mline")" == 1 ]]; then
    ok "INT-mask: a leader whose launcher had SIGINT blocked still handled INT (exit 130, cleanup once)"
  else
    no "INT-mask: a leader whose launcher had SIGINT blocked did not handle INT (the INT is never delivered to a leader that inherited the blocked mask): $_mline"
  fi
else
  print "  INT-mask check skipped: no perl (no way to block SIGINT for one trial)"
fi
for mode in stress stresslog stressdebug stressrefresh; do
  m_total=0; m_hang=0; m_bad=0
  for f in "$TMP"/res/$mode.*(N); do
    line=$(<"$f"); (( ++m_total ))
    _sig_all[$(_field sig "$line")]=$(( ${_sig_all[$(_field sig "$line")]:-0} + 1 ))
    if [[ "$(_field hang "$line")" == 1 ]]; then
      (( ++m_hang )); _hang_sig[$(_field sig "$line")]=$(( ${_hang_sig[$(_field sig "$line")]:-0} + 1 ))
      # A hung leader that still has a child process is blocked reading a forked child that deadlocked on the
      # inherited stdio lock: exactly the C-01 bug, never tolerated. Only child-less hangs are the stdio-lock floor.
      (( $(_field kids "$line") > 0 )) && (( ++_hang_kids ))
      [[ "$(_field floor "$line")" == 1 ]] || { (( ++_hang_nonfloor )); [[ "$(_field floor "$line")" == unknown ]] && (( ++_hang_unknown )); }   # N-01: unknown is not tolerated either
      continue
    fi
    good=1
    [[ "$(_field ec "$line")" == "$(_field exp "$line")" ]]     || good=0
    [[ "$(_field cleanups "$line")" == 1 ]]                     || good=0
    [[ "$(_field lr_exit "$line")" == "$(_field exp "$line")" ]] || good=0
    [[ "$(_field meta "$line")" == INTERRUPTED ]]               || good=0
    [[ "$(_field cost_rows "$line")" == 13 ]]                   || good=0
    [[ "$(_field report "$line")" == 1 ]]                       || good=0
    [[ "$(_field lock_left "$line")" == 0 ]]                    || good=0
    [[ "$(_field reg_left "$line")" == 0 ]]                     || good=0
    [[ "$(_field panes_left "$line")" == 0 ]]                   || good=0
    [[ "$(_field debug_final "$line")" == 1 ]]                  || good=0
    [[ "$(_field tmp_left "$line")" == 0 ]]                     || good=0   # no temp file left in the leader's TMPDIR
    (( good )) || { (( ++m_bad )); print -u2 "    behaviour mismatch [$mode]: $line"; }
  done
  print "  $mode: trials=$m_total hung=$m_hang (no exit within ${BUDGET_S}s) wrong-behaviour=$m_bad"
  (( _total += m_total, _hang += m_hang, _bad += m_bad ))
  (( m_total == EXPECTED_TRIALS[$mode] )) || no "$mode: expected ${EXPECTED_TRIALS[$mode]} trial results, got $m_total"
done
for e in "$TMP"/hang-evidence.*(N) "$TMP"/hang-ps.*(N[1,4]); do print -r -- "$(<"$e")" | sed 's/^/    /'; done

print "  signals drawn over all trials: INT=${_sig_all[INT]:-0} TERM=${_sig_all[TERM]:-0} HUP=${_sig_all[HUP]:-0}"
(( _total == 0 || ( ${_sig_all[INT]:-0} > 0 && ${_sig_all[TERM]:-0} > 0 && ${_sig_all[HUP]:-0} > 0 ) )) \
  && ok "the trial set covers all three signals (INT ${_sig_all[INT]:-0}, TERM ${_sig_all[TERM]:-0}, HUP ${_sig_all[HUP]:-0})" \
  || no "the trial set does not cover INT, TERM and HUP (INT ${_sig_all[INT]:-0}, TERM ${_sig_all[TERM]:-0}, HUP ${_sig_all[HUP]:-0})"
print "  hung by signal: ${(kv)_hang_sig} (INT/TERM/HUP counts; $_hang_kids of the $_hang hung leaders still had a child process)"
(( _hang_kids == 0 )) \
  && ok "no hung leader has a child process (no redirected-fork deadlock)" \
  || no "REDIRECTED-FORK DEADLOCK: $_hang_kids hung leader(s) still have a child process blocked on the inherited stdio lock (never tolerated)"
(( _hang_nonfloor == 0 )) \
  && ok "every hung leader (if any) has the stdio-lock floor stack: nested zhandler->fflush->flockfile, no fork/wait/FILE-table frame" \
  || no "NON-FLOOR HANG: $_hang_nonfloor hung leader(s) whose stack is not positively the stdio-lock floor ($_hang_unknown unclassifiable: no stack sampler; see the stacks above)"
(( _hang <= MAX_HANGS )) \
  && ok "no deadlock beyond the stdio-lock floor: $(( _total - _hang ))/$_total signalled leaders exited within ${BUDGET_S}s, $_hang hung (child-less tolerance $MAX_HANGS; INT/TERM/HUP at random phases)" \
  || no "DEADLOCK: $_hang/$_total signalled leaders did not exit within ${BUDGET_S}s, tolerance $MAX_HANGS (signal during builtin stdio write; trap path forked a redirected child)"
(( _bad == 0 )) \
  && ok "every exited trial did the full cleanup: exit 128+signum, cleanup once, launch-record exit_code, metadata INTERRUPTED, final cost row, report, lock+registry released, panes killed" \
  || no "$_bad exited trials show missing/incorrect cleanup behaviour"

# =============================================================================
# Deterministic guard (no race, runs on every platform): trace the REAL signal path (`_on_signal TERM`
# called directly, worst-case state: DEBUG=1, status.json, 3 panes, self-verification on, one scenario per terminal state,
# untracked files) under xtrace and assert it forks NOTHING but the clean-child runner. The failure class is
# "a fork whose child redirects fds", so the checker flags (1) any traced command inside a command
# substitution / pipeline / subshell / background context and (2) any external command other than
# `command zsh ...` (_sigsafe_sh). Builtins (incl. zsh/files zf_rm/zf_mv/zf_mkdir, zsh/stat, zselect) and
# shell functions are in-process and allowed. Limits: `$(<file)` is in-process and untraced (correct);
# xtrace is lost inside a function called with `2>file`, so write_cost_log is traced by an explicit pre-call.
# =============================================================================
zmodload zsh/parameter zsh/zselect 2>/dev/null; zmodload -F zsh/stat b:zstat 2>/dev/null
zmodload -F zsh/files b:zf_rm b:zf_mv b:zf_mkdir 2>/dev/null; zmodload zsh/datetime 2>/dev/null
typeset -A KNOWN
for _b in ${(k)builtins} ${(k)reswords}; do KNOWN[$_b]=1; done
for _b in $(grep -ohE '^[A-Za-z_][A-Za-z0-9_]*\(\) \{' "$LIB" "$RUN" | sed 's/() {//'); do KNOWN[$_b]=1; done

# _check_trace parses EVERY `@@pid:ctx@@ text` segment of a trace line (xtrace prints a command substitution that sits inside an
# assignment as `@@P:@@ var=@@P2:cmdsubst@@ jq ...`). PS4 carries the REAL pid (${sysparams[pid]}), because %_ shows nothing for
# `( ... )`, `cmd &`, process substitution or coproc: a command traced under any pid but the leader's is a fork of the leader.
_check_trace() {   # <trace file> <leader pid>: prints one line per violation
  local line ctx pid cmd fw sw _o _i leader="$2"; local -a w seg
  while IFS= read -r line; do
    [[ "$line" == @@* ]] || continue
    seg=("${(@s:@@:)line}")                       # "" pid:ctx " text" pid:ctx " text" ...
    for (( _i = 2; _i <= ${#seg}; _i += 2 )); do
      pid=${seg[_i]%%:*}; ctx=${seg[_i]#*:}; cmd=${seg[_i+1]# }
      w=(${(z)cmd}); fw=${w[1]:-}; sw=${w[2]:-}
      # The one allowed foreign-pid line is the plain-exec of the clean child: the forked child itself prints `zsh -fc ...` under its own
      # pid just before the exec (it runs no other traced command: the fresh zsh does not inherit xtrace).
      if [[ "$pid" != "$leader" ]]; then
        [[ "$fw" == zsh && "$sw" == -fc ]] || print -r -- "FOREIGN-PID[$pid vs leader $leader,$ctx] $cmd"
        continue
      fi
      if [[ "$ctx" == *(cmdsubst|pipe|subsh|backgnd)* ]]; then print -r -- "FORK-CONTEXT[$ctx] $cmd"; continue; fi
      [[ -z "$fw" || "$fw" == *=* || "$fw" == '(('* || "$fw" == '[[' ]] && continue
      # libc-lock builtins: strftime (tz rwlock) and print/printf -v (open_memstream -> __sfp FILE-table lock) self-deadlock
      # when the signal interrupted the same libc critical section (sampled hang: bin_print -> open_memstream -> __sfp -> zhandler).
      if [[ "$fw" == strftime ]]; then print -r -- "LIBC-LOCK[$ctx] $cmd"; continue; fi
      if [[ "$fw" == (print|printf) ]]; then
        for _o in ${w[2,-1]}; do
          [[ "$_o" == -* && "$_o" != -- ]] || break
          [[ "$_o" =~ '^-[a-zA-Z]*v' ]] && { print -r -- "LIBC-LOCK[$ctx] $cmd"; continue 2; }
        done
      fi
      [[ "$fw" == zsh && "$sw" == -fc ]] && continue   # _sigsafe_sh (xtrace prints `command zsh -fc` without `command`)
      [[ -n "${KNOWN[$fw]:-}" ]] || { print -r -- "EXTERNAL[$ctx] $cmd"; continue; }
      [[ "$fw" == command ]] && print -r -- "EXTERNAL[$ctx] $cmd"
    done
  done < "$1"
  return 0
}

# Discrimination control on REAL traces (no hand-written trace text): one zsh run executes every pattern the checker must flag,
# one control run executes only what the signal path may do.
cat > "$TMP/selftest-bad.zsh" <<'EOS'
zmodload zsh/datetime zsh/system   # zsh/system provides $sysparams[pid]
print -r -- ${sysparams[pid]} > "$1"
PS4='@@${sysparams[pid]}:%_@@ '
setopt PROMPT_SUBST xtrace   # PS4 only expands ${...} with PROMPT_SUBST
( : in-subshell )
: in-background &
wait
x=$(print in-cmdsubst)
print in-pipe | cat
cat <(print in-procsub) > /dev/null
printf -v REPLY %04d 5
strftime -s x %Y
command rm -f /nonexistent-c01-selftest
date -u > /dev/null
y=$(print inline-in-assignment)
EOS
cat > "$TMP/selftest-good.zsh" <<'EOS'
zmodload zsh/datetime zsh/system   # zsh/system provides $sysparams[pid]
print -r -- ${sysparams[pid]} > "$1"
PS4='@@${sysparams[pid]}:%_@@ '
setopt PROMPT_SUBST xtrace
z=1
print -r -- plain-builtin
[[ -n $z ]] && : fine
zsh -fc 'true'
printf '%s\n' plain-printf
EOS
zsh -f "$TMP/selftest-bad.zsh" "$TMP/selftest-bad.pid" >/dev/null 2>"$TMP/selftest-bad.trace"
zsh -f "$TMP/selftest-good.zsh" "$TMP/selftest-good.pid" >/dev/null 2>"$TMP/selftest-good.trace"
_vbad=$(_check_trace "$TMP/selftest-bad.trace" "$(<$TMP/selftest-bad.pid)"); _vgood=$(_check_trace "$TMP/selftest-good.trace" "$(<$TMP/selftest-good.pid)")
_miss=(); for _pat in 'in-subshell' 'in-background' 'in-cmdsubst' 'in-pipe' 'in-procsub' 'printf -v' 'strftime' 'rm -f /nonexistent-c01' 'date -u' 'inline-in-assignment'; do
  [[ "$_vbad" == *"$_pat"* ]] || _miss+=("$_pat")
done
[[ "$_vbad" == *"FOREIGN-PID"*"in-subshell"* ]] || _miss+=("subshell-by-pid")
(( ${#_miss} == 0 )) && [[ -z "$_vgood" ]] \
  && ok "trace checker, on real traces: flags subshell and background (by pid, which %_ cannot see), cmd-subst, pipe, process substitution, printf -v, strftime, command rm, date and an inline x=\$(...); accepts builtins, assignments, printf and 'zsh -fc'" \
  || no "trace checker self-test failed: undetected=(${_miss[*]}) false-positives=$(print -r -- "$_vgood" | head -3)"

# The trace case also forces the UTC-offset refresh to be DUE (`_RLP_TZ_REFRESH_S=0 _RLP_TZOFF_AT=0`) while `_on_signal TERM` runs, so the guard
# proves the handler's log calls take the cached-offset branch: a lib whose _rlp_local_ts lost its SIGNAL_RECEIVED guard would fork `date` here.
# One traced scenario per terminal state so every branch of cleanup/generate_campaign_report is exercised on its own:
#   interrupted (no sentinel), blocked (BLOCKED only: the Reason:/Category: parse), complete (COMPLETE only: untracked warning).
# All of them: DEBUG=1, a status.json that DISAGREES with the cost log (the both-numbers line), 3 panes, self-verification ON with TWO
# reports whose mtime order is the reverse of their name order (001 newest), untracked files, a PRD with a dash-form heading.
_har=$(<"$HAR")
_har=${_har/'  case "$LOOP_MODE" in'/$'  case "$LOOP_MODE" in\n    trace) zmodload zsh/system; print -r -- ${sysparams[pid]} > "$T/leader.pid"; PS4=\'@@${sysparams[pid]}:%_@@ \'; setopt PROMPT_SUBST xtrace; write_cost_log 12; COST_LOG_FINAL_WRITTEN=1; _RLP_TZ_REFRESH_S=0; _RLP_TZOFF_AT=0; _on_signal TERM ;;'}
_har=${_har/WITH_SELF_VERIFICATION=0/WITH_SELF_VERIFICATION=1}
_har=${_har/CONSENSUS_PANE=\"\"/CONSENSUS_PANE=\"%3\"}
print -r -- "$_har" > "$TMP/harness_trace.zsh"
_trace_scenario() {   # <name> <state interrupted|blocked|complete>
  local name="$1" state="$2" GT="$TMP/guard-$1" want
  mkdir -p "$GT" "$GT/lock.d"; cp -R "$TPL/." "$GT/"
  local GM="$GT/root/.claude/ralph-desk/memos" GL="$GT/root/.claude/ralph-desk/logs/c01"
  [[ "$state" == complete ]] && print -r -- done > "$GM/c01-complete.md"
  [[ "$state" == blocked ]] && print -r -- $'Reason: stuck\nCategory: infra_failure' > "$GM/c01-blocked.md"
  print -r -- '{"model_upgraded":0,"iteration":12}' > "$GL/status.json"   # the cost log escalates (luna -> terra): deliberate disagreement
  print new > "$GT/root/newdeliverable.txt"
  print r1 > "$GL/self-verification-report-001.md"; print r2 > "$GL/self-verification-report-002.md"
  touch -t 202001010000 "$GL/self-verification-report-002.md"
  print -r -- $'## Objective\nx\n\n### US-001: a\n\n### US-002 - b' > "$GT/root/.claude/ralph-desk/plans/prd-c01.md"
  # TMUX points at a socket that does not exist: the traced tmux calls fail fast and can never reach a real server.
  ( export TMUX="$TMP/no-such-tmux-socket,1,0" C01_LIB="$LIB" C01_LIBDIR="${LIB:h}" C01_DEBUG=1 C01_WORKER_PANE="%1" C01_VERIFIER_PANE="%2"
    zsh -f "$TMP/harness_trace.zsh" "$GT" trace </dev/null >"$GT/out" 2>"$TMP/guard-$name.trace"; print $? > "$GT/rc" )
  local rc=$(<"$GT/rc") traced=$(grep -c '^@@' "$TMP/guard-$name.trace") leader; leader=$(<"$GT/leader.pid")
  case $state in complete) want="Final State: COMPLETE";; blocked) want="Final State: BLOCKED";; *) want="Final State: INTERRUPTED";; esac
  (( traced > 200 )) && grep -qF "$want" "$GT/out" && [[ "$rc" == 143 ]] \
    && ok "[$name] trace run reached the end of the real chain (rc=143, $traced traced commands, '$want')" \
    || no "[$name] trace run did not complete the chain (rc=$rc, traced=$traced, wanted '$want')"
  local viol; viol=$(_check_trace "$TMP/guard-$name.trace" "$leader")
  local forks; forks=$(grep -c '^@@[0-9]*:[^@]*@@ zsh -fc ' "$TMP/guard-$name.trace")
  if [[ -z "$viol" ]]; then
    ok "[$name] signal path forks only the clean-child runner: $forks x 'zsh -fc' via _sigsafe_sh, every other traced command ran in the leader pid, 0 command substitutions / pipes / bare externals / libc-lock builtins"
  else
    no "[$name] signal path forks redirected children ($(print -r -- "$viol" | wc -l | tr -d ' ') violations); first ones:"
    print -r -- "$viol" | sort | uniq -c | sort -rn | head -15 | sed 's/^/    /' >&2
  fi
  local rep="$GL/campaign-report.md"
  grep -qE 'Escalation count: [0-9]+ ladder move\(s\) \(status\.json model_upgraded=0 .*disagreement, printing both\)' "$rep" 2>/dev/null \
    && ok "[$name] status.json cross-check: the both-numbers disagreement line (status 0 vs 1 escalation) was produced from the file read by the clean child" \
    || no "[$name] the status.json disagreement line is missing: $(grep -m1 'Escalation count' "$rep" 2>/dev/null)"
  grep -qF "See: $GL/self-verification-report-001.md" "$rep" 2>/dev/null \
    && ok "[$name] the NEWEST self-verification report (by mtime, not by name) is the one linked" \
    || no "[$name] report does not link the newest SV report: $(grep -m1 'self-verification-report' "$rep" 2>/dev/null)"
  # the DEBUG per-US diagnostic: expected_us comes from the clean child via the shared heading constant (both the colon and
  # the dash heading of the PRD must count: 2/2), verified_count from VERIFIED_US in-process.
  grep -q 'per_us_coverage=.* verified=2/2' "$GL/debug.log" 2>/dev/null \
    && ok "[$name] DEBUG per-US coverage diagnostic counted 2/2 (shared heading regexp + in-process counts)" \
    || no "[$name] DEBUG per-US coverage line wrong: $(grep -m1 per_us_coverage "$GL/debug.log" 2>/dev/null)"
  [[ "$state" == blocked ]] && { grep -q 'Blocked reason: stuck' "$rep" 2>/dev/null \
    && ok "[$name] BLOCKED sentinel Reason: parsed into the report" || no "[$name] BLOCKED reason missing from the report"; }
  [[ "$state" == complete ]] && { grep -E 'WARNING: campaign reached COMPLETE with [0-9]+ untracked' "$rep" 2>/dev/null | grep -q 'newdeliverable.txt' \
    && ok "[$name] COMPLETE path produced the specific untracked-deliverables warning naming newdeliverable.txt" \
    || no "[$name] the COMPLETE untracked-deliverables warning is missing: $(grep -m1 -i 'warning' "$rep" 2>/dev/null)"; }
}
# N-06 / H-R5-01 / K-02 / K-03: xtrace output is LOST inside a shell function that is called with STDERR redirected (`f 2>/dev/null`, `f |& g`,
# `2>/dev/null f`) AND inside a compound command whose stderr is redirected (`while ...; done < f 2>/dev/null`, `{ ...; } 2>/dev/null`, `( ... ) 2>`,
# `if ...; fi \<newline> 2>/dev/null`, `for ...; { ...; } 2>`, `case ...; esac 2>`, a function definition `g() { ...; } 2>`), and `exec 2>/dev/null` silences
# everything after it. The traced guard above cannot see a fork in any of them, so they are checked statically over the signal path (an over-approximated
# closure of `_on_signal`, built from raw text; currently 23 functions, a superset of the real call graph; computed below). The analysis runs on the CANONICAL function text zsh itself prints (`${functions[f]}` after sourcing the real
# lib and the extracted run functions: continuations joined, comments gone, redirections after their command, quoting resolved), tokenized with `${(z)...}`:
# quoted words (including every `_sigsafe_sh '...'` clean-child script) are single opaque tokens, so no quote or continuation state machine is needed.
#   Only redirects of fd 2 count: `2>`, `2>>`, `2>&n`, `&>`, `&>>`, `>& file`, `>>&`, `|&`; `1>&2`, `>&2` and `>file` are stdout-only and pass.
#   FN-CALL   a user-defined function called with a stderr redirect (the only one allowed on the signal path is write_cost_log, pre-traced explicitly
#             above, and its body must contain no command substitution or pipe)
#   COMPOUND  a `done|fi|esac|}|)` closer carrying a stderr redirect, unless allow-listed in _ALLOW_REDIR_CLOSERS ("<function>|<closer> <redirects>") AND its
#             block body forks nothing (no `$(` other than `$(<`, no backtick, `<(`/`>(`, pipe or `&`)
#   EXEC      `exec` with only redirections, one of which is a stderr redirect
#   COND-FORK a `[[ ... ]]` / `(( ... ))` carrying a stderr redirect whose expression forks (a conditional has no body, so a plain `[[ =~ ]] 2>/dev/null`
#             hides no command and is fine)
#   Ceiling: alias expansion is not modelled; a heredoc body is skipped by a line pass that finds `<<WORD` as a real operator token, so a heredoc on
#   the signal path is only supported when its lines are tokenizable one by one; none exists there today.
typeset -gA _ALLFN _ALLOW_REDIR_CLOSERS
_ALLOW_REDIR_CLOSERS=()
_c01_forky() {   # <tokens...>: returns 0 when a token forks (command substitution other than $(<...), backtick, process substitution, pipe, background)
  local x
  for x in "$@"; do
    [[ "$x" == \'* ]] && continue   # a single-quoted word is data (e.g. a child script)
    [[ "$x" == '|' || "$x" == '|&' || "$x" == '&' || "$x" == '&!' || "$x" == '&|' || "$x" == coproc ]] && return 0
    [[ "$x" =~ '\$\([^<(]|`|[<>]\(' ]] && return 0
  done
  return 1
}
_c01_OPRE='^([0-9]*|\{[A-Za-z_][A-Za-z0-9_]*\})(<>|<<<|<<-?|<&|<|>>&|>&|>>|>\||>!|>|&>>|&>\||&>!|&>)$'
_c01_is_op() { [[ "$1" =~ $_c01_OPRE || "$1" == '|&' ]]; }
_c01_hits_stderr() {   # <op token> <next token>: returns 0 when the redirection operator touches fd 2 (or fd 1 and 2 together)
  local op="$1" nxt="${2:-}"
  [[ "$op" == '|&' ]] && return 0
  [[ "$op" =~ $_c01_OPRE ]] || return 1
  local fd="${match[1]}" o="${match[2]}"
  [[ "$fd" == 2 ]] && return 0
  [[ -n "$fd" ]] && return 1
  [[ "$o" == '&>'* || "$o" == '>>&' ]] && return 0
  if [[ "$o" == '>&' ]]; then [[ "$nxt" == <-> || "$nxt" == - ]] && return 1; return 0; fi   # `>&2` / `>&-` are stdout-only; `>& file` merges both
  return 1
}
_c01_flush() {   # evaluates the segment collected by _c01_scan (dynamic scope: reads its locals)
  local w k i
  if (( _hit )); then
    if (( _iscond )); then
      _c01_forky "${_condtoks[@]}" && print -r -- "COND-FORK $_fn: ${_condtoks[*]} $_descr"
    elif [[ -n "$_closer" ]]; then
      k="$_fn|$_closer $_descr"
      if [[ -z "${_ALLOW_REDIR_CLOSERS[$k]:-}" ]]; then print -r -- "COMPOUND $_fn: $_closer $_descr"
      elif _c01_forky "${(@)_t[_bodystart,_closeridx]}"; then print -r -- "ALLOW-LISTED-BODY-FORKS $_fn: $_closer $_descr"; fi
    else
      i=1
      while (( i <= ${#_seg} )); do   # skip assignments (`V="a b"`, `a[1]=x`, `a=( ... )`) and precommand modifiers
        w=${_seg[i]}
        if [[ "$w" =~ '^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=' ]]; then
          if [[ "$w" == *'=(' ]]; then while (( i <= ${#_seg} )) && [[ "${_seg[i]}" != ')' ]]; do (( ++i )); done; fi
          (( ++i )); continue
        fi
        [[ "$w" == (noglob|nocorrect|time|-) ]] && { (( ++i )); continue; }
        break
      done
      w=${(Q)${_seg[i]:-}}   # quotes and backslashes of the command word removed (S-02): `'f' 2>/dev/null` and `\f 2>/dev/null` still call f
      if [[ "$w" == exec ]]; then (( i == ${#_seg} )) && print -r -- "EXEC $_fn: $_descr"
      elif [[ -n "$w" && -n "${_ALLFN[$w]:-}" ]]; then print -r -- "FN-CALL $_fn:$w"; fi
    fi
  fi
  _seg=(); _hit=0; _descr=''; _closer=''; _iscond=0; _condtoks=()
}
_c01_scan() {   # <function name> <canonical text>: prints one line per violation
  local _fn="$1" _text="$2" tok nxt line d j cmdpos hd=''
  local -a _t _seg _condtoks stk lines lt
  local -i _hit=0 _iscond=0 _bodystart=0 _closeridx=0 i=1 n
  local _closer='' _descr=''
  # heredoc pass: drop the body lines of every real `<<WORD` operator (a quoted `} 2>/dev/null` inside it is data, not code)
  lines=("${(@f)_text}"); _text=''
  for line in "${lines[@]}"; do
    if [[ -n "$hd" ]]; then [[ "${line##$'\t'#}" == "$hd" ]] && hd=''; continue; fi
    if [[ "$line" == *'<<'* && "$line" != *'<<<'* ]]; then
      lt=(${(z)line})
      for (( j = 1; j < ${#lt}; j++ )); do
        [[ "${lt[j]}" == '<<' || "${lt[j]}" == '<<-' ]] && { hd=${lt[j+1]//[\'\"\\]/}; break; }
      done
    fi
    _text+="$line"$'\n'
  done
  _t=(${(z)_text}); n=${#_t}
  while (( i <= n )); do
    tok=${_t[i]}; nxt=${_t[i+1]:-}
    if [[ "$tok" == (';'|';;'|';&'|';|'|'&&'|'||'|'|'|'&'|'&!'|'&|') ]]; then _c01_flush; (( ++i )); continue; fi   # separators end the command
    if [[ "$tok" == '|&' ]]; then _hit=1; _descr+="${_descr:+ }|&"; _c01_flush; (( ++i )); continue; fi
    cmdpos=0; (( ${#_seg} == 0 && _iscond == 0 )) && [[ -z "$_closer" ]] && cmdpos=1
    if (( cmdpos )); then
      case "$tok" in
        '{'|'(') stk+=($i); (( ++i )); continue ;;
        if|while|until) stk+=($i); (( ++i )); continue ;;
        for|select|case|repeat|foreach) stk+=($i) ;;
        then|do|else|elif|'!') (( ++i )); continue ;;
        done|fi|esac|'}'|')')
          _closer=$tok; _closeridx=$i
          if (( ${#stk} )); then _bodystart=${stk[-1]}; stk[-1]=(); else _bodystart=$i; fi
          (( ++i )); continue ;;
        '[[')
          _iscond=1; d=$(( i + 1 ))
          while (( d <= n )) && [[ "${_t[d]}" != ']]' ]]; do _condtoks+=("${_t[d]}"); (( ++d )); done
          i=$(( d + 1 )); continue ;;
        '(('*) _iscond=1; _condtoks=("$tok"); (( ++i )); continue ;;
      esac
    fi
    if _c01_is_op "$tok"; then
      _c01_hits_stderr "${tok#\{*\}}" "$nxt" && { _hit=1; _descr+="${_descr:+ }$tok $nxt"; }
      i=$(( i + 2 )); continue
    fi
    _seg+=("$tok"); (( ++i ))
  done
  _c01_flush
}

# Discrimination on constructed functions. Each body is canonicalized by real zsh; where it carries the marked fork `x=$(print MARK)` it is ALSO run
# under real xtrace: a must-flag construct has to LOSE the marked fork from the trace (so the blind spot is real) and a must-pass construct has to KEEP it.
# _case <name> <expected violation kinds, sorted, "-" = none> <trace: H hidden | V visible | - not traced> <body>
typeset -ga _cases=()
_case() { _cases+=("$1"$'\x01'"$2"$'\x01'"$3"$'\x01'"$4"); }
_case while-done-stderr   COMPOUND  H $'while read -r l; do x=$(print MARK); done < /etc/hosts 2>/dev/null'
_case brace-group         COMPOUND  H $'{ x=$(print MARK); } 2>/dev/null'
_case if-fi               COMPOUND  H $'if true; then x=$(print MARK); fi 2>/dev/null'
_case fi-continued        COMPOUND  H $'if true; then\n  x=$(print MARK)\nfi \\\n  2>/dev/null'
_case subshell-oneline    COMPOUND  H $'( x=$(print MARK) ) 2>/dev/null'
_case for-brace           COMPOUND  H $'for i in 1; { x=$(print MARK); } 2>/dev/null'
_case case-esac           COMPOUND  H $'case x in (x) x=$(print MARK);; esac 2>/dev/null'
_case funcdef-redirect    COMPOUND  H $'g() { x=$(print MARK); } 2>/dev/null\ng'
_case closer-merge-both   COMPOUND  H $'{ x=$(print MARK); } &>/dev/null'
_case closer-2-dup        COMPOUND  H $'{ x=$(print MARK); } 2>&1'
_case exec-stderr         EXEC      H $'exec 2>/dev/null\nx=$(print MARK)'
_case fn-pipe-amp         FN-CALL   H $'uf |& cat'
_case fn-redirect-first   FN-CALL   H $'2>/dev/null uf'
_case fn-quoted-prefix    FN-CALL   H $'V="a b" uf 2>/dev/null'
_case fn-while-cond       FN-CALL   H $'while uf 2>/dev/null; do break; done'
_case fn-until-cond       FN-CALL   H $'until uf 2>/dev/null; do :; done'
_case fn-elif-cond        FN-CALL   H $'if false; then :; elif uf 2>/dev/null; then :; fi'
_case fn-after-andand     FN-CALL   H $'true && uf 2>/dev/null'
_case fn-amp-redirect     FN-CALL   H $'uf &>/dev/null'
_case fn-amp-append       FN-CALL   H $'uf &>>/dev/null'
_case fn-2-dup-1          FN-CALL   H $'uf 2>&1'
_case fn-append           FN-CALL   H $'uf 2>>/dev/null'
_case fn-after-if-not     FN-CALL   H $'if ! uf 2>/dev/null; then :; fi'
_case fn-quoted-word      FN-CALL   H $'\'uf\' 2>/dev/null'
_case fn-backslash-word   FN-CALL   H $'\\uf 2>/dev/null'
_case fn-merge-file       FN-CALL   H $'uf >& /dev/null'
_case cond-with-fork      COND-FORK H $'[[ $(print MARK) == MARK ]] 2>/dev/null'
_case closer-after-heredoc COMPOUND H $'cat <<\'E\' >/dev/null\n} 2>/dev/null\nE\n{ x=$(print MARK); } 2>/dev/null'
_case closer-stdout-dup   -         V $'{ x=$(print MARK); } 1>&2'
_case closer-stdout-dup2  -         V $'{ x=$(print MARK); } >&2'
_case closer-stdout-file  -         V $'{ x=$(print MARK); } >/dev/null'
_case fn-stdout-only      -         V $'uf >/dev/null'
_case fn-stdout-dup       -         V $'uf 1>&2'
_case heredoc-data        -         V $'cat <<\'E\' >/dev/null\n} 2>/dev/null\nfi 2>/dev/null\nE\nx=$(print MARK)'
_case string-data         -         V $'print -r -- "} 2>/dev/null"; print -r -- \'done 2>/dev/null\'\nx=$(print MARK)'
_case assign-glob-chars   -         - $'x=${y//[(){}]/} 2>/dev/null'
_case empty-array-assign  -         - $'list=() 2>/dev/null'
_case cond-no-fork        -         - $'[[ $a =~ \'^x\' ]] 2>/dev/null'
_case arith-no-fork       -         - $'(( a = 1 )) 2>/dev/null'
_case builtin-redirect    -         - $'zf_rm -f x 2>/dev/null'
_case cmdsubst-file       -         - $'own=$(<f) 2>/dev/null'
_case zstat-redirect      -         - $'_sz=(); zstat -A _sz +size f 2>/dev/null'
_case prefix-builtin      -         - $'V=1 print -r -- x 2>/dev/null'
_case keyword-as-arg      -         - $'print -r -- done fi esac 2>/dev/null'
_case inner-simple        -         - $'if true; then print x 2>/dev/null; fi'
_case child-script        -         - $'_sigsafe_sh \'while read l; do :; done 2>/dev/null\n  } 2>/dev/null\' zsh a'
_case child-script-concat -         - $'_sigsafe_sh \'f() {\n\'"${functions[f]}"\'\n}\nwhile read m; do :; done < <(jq "$2" 2>/dev/null)\' zsh x'

_c01_run_cases() {   # prints one line per mismatching case; the number of cases checked is left in _cases_n, traced controls in _cases_traced
  local row name want tr body i n=0 nt=0 kinds cnt
  local -a canon
  { print -r -- 'uf() { x=$(print MARK); }'
    i=0; for row in "${_cases[@]}"; do (( ++i )); print -r -- "c$i() {"; print -r -- "${row##*$'\x01'}"; print -r -- "}"; done
    i=0; for row in "${_cases[@]}"; do (( ++i )); print -r -- "print -r -- '@@CASE $i'; print -r -- \"\${functions[c$i]}\""; done
  } > "$TMP/cases.zsh"
  zsh -f "$TMP/cases.zsh" > "$TMP/cases.canon" 2>"$TMP/cases.err" || { print -r -- "case batch did not load: $(<"$TMP/cases.err")"; return; }
  local cur=0 line
  while IFS= read -r line; do
    if [[ "$line" == '@@CASE '* ]]; then cur=${line#@@CASE }; canon[cur]=''; else canon[cur]+="$line"$'\n'; fi
  done < "$TMP/cases.canon"
  _ALLFN[uf]=1
  i=0
  for row in "${_cases[@]}"; do
    (( ++i )); (( ++n ))
    name=${row%%$'\x01'*}; row=${row#*$'\x01'}; want=${row%%$'\x01'*}; row=${row#*$'\x01'}; tr=${row%%$'\x01'*}; body=${row#*$'\x01'}
    kinds=${(j: :)${(ou)${${(f)"$(_c01_scan "case:$name" "${canon[i]}")"}%% *}}}; [[ -n "$kinds" ]] || kinds=-
    [[ "$kinds" == "$want" ]] || print -r -- "$name: static verdict [$kinds], expected [$want]"
    if [[ "$tr" != - ]]; then
      (( ++nt ))
      { print -r -- 'zmodload zsh/system; uf() { x=$(print MARK); }'; print -r -- "probe() {"; print -r -- "$body"; print -r -- "}"
        print -r -- 'PS4=$'"'"'@@${sysparams[pid]}:%_@@ '"'"'; setopt PROMPT_SUBST xtrace'; print -r -- 'probe'; } > "$TMP/trace-case.zsh"
      zsh -f "$TMP/trace-case.zsh" </dev/null >/dev/null 2>"$TMP/trace-case.err"
      cnt=$(grep -c 'print MARK' "$TMP/trace-case.err")
      if [[ "$tr" == H && "$cnt" != 0 ]]; then print -r -- "$name: real xtrace still shows the marked fork ($cnt lines): the construct is not blind, the rule is wrong"; fi
      if [[ "$tr" == V && "$cnt" == 0 ]]; then print -r -- "$name: real xtrace lost the marked fork: the construct IS blind, the rule misses it"; fi
    fi
  done
  _cases_n=$n; _cases_traced=$nt
  unset "_ALLFN[uf]"
}
typeset -gi _cases_n=0 _cases_traced=0
_c01_run_cases > "$TMP/cases.mm"; _mm=$(<"$TMP/cases.mm")
[[ -z "$_mm" && $_cases_n -ge 40 ]] \
  && ok "K-02/K-03 analyzer self-test: $_cases_n constructs (every redirect form, continuations, one-line groups, |&, exec 2>, 2>file before the command, quoted prefixes, heredoc and string data, stdout-only dups) classified as expected; $_cases_traced of them also run under real xtrace: each flagged one loses the marked fork, each passing one keeps it" \
  || no "K-02/K-03 analyzer self-test ($_cases_n constructs): $_mm"
# the signal path = every function reachable from _on_signal by name (an over-approximation: safe for a "must not contain" check)
for _b in $(grep -ohE '^[A-Za-z_][A-Za-z0-9_]*\(\) \{' "$LIB" "$RUN" | sed 's/() {//'); do _ALLFN[$_b]=1; done
typeset -A _seen
_q=(_on_signal)
while (( ${#_q} )); do
  _fn=${_q[1]}; _q=("${(@)_q[2,-1]}"); [[ -n "${_seen[$_fn]:-}" ]] && continue; _seen[$_fn]=1
  _src="$LIB"; grep -q "^$_fn() {" "$LIB" || _src="$RUN"
  for _w in ${(u)${(f)"$(_extract_fn $_fn $_src | grep -vE '^[[:space:]]*#' | grep -oE '[A-Za-z_][A-Za-z0-9_]*')"}}; do
    [[ "$_w" != "$_fn" && -n "${_ALLFN[$_w]:-}" ]] && _q+=($_w)
  done
done
_path_fns=(${(ko)_seen})
_path_miss=(); for _fn in _emit_launch_record_outcome _emit_final_cost_log cleanup _untracked_names _untracked_complete_warning generate_campaign_report write_cost_log unregister_leader log log_debug log_error _on_signal _sigsafe_tmux; do
  [[ -n "${_seen[$_fn]:-}" ]] || _path_miss+=($_fn)
done
(( ${#_path_fns} >= 13 && ${#_path_miss} == 0 )) \
  && ok "signal path enumerated from _on_signal by name: ${#_path_fns} functions (includes the 13 known ones: ${_path_fns[*]})" \
  || no "signal-path enumeration is broken: ${#_path_fns} functions, missing known ones: ${_path_miss[*]}"
# canonical text of every signal-path function: the real lib sourced and the extracted run functions defined in a fresh zsh, then `${functions[f]}`
{ print -r -- 'set -uo pipefail'; print -r -- 'setopt POSIX_TRAPS'; print -r -- 'source "$C01_LIB"'
  for _f in $OPTIONAL_FNS $REQUIRED_FNS; do _extract_fn "$_f" "$RUN"; print; done
  for _fn in $_path_fns; do print -r -- "print -r -- '@@FN $_fn'; print -r -- \"\${functions[$_fn]}\""; done
} > "$TMP/canon-real.zsh"
C01_LIB="$LIB" zsh -f "$TMP/canon-real.zsh" > "$TMP/canon-real.out" 2>"$TMP/canon-real.err"
typeset -A _CANON; _cur=''
while IFS= read -r _line; do
  if [[ "$_line" == '@@FN '* ]]; then _cur=${_line#@@FN }; _CANON[$_cur]=''; else _CANON[$_cur]+="$_line"$'\n'; fi
done < "$TMP/canon-real.out"
_canon_empty=(); for _fn in $_path_fns; do [[ -n "${_CANON[$_fn]//[[:space:]]/}" ]] || _canon_empty+=($_fn); done
(( ${#_canon_empty} == 0 )) \
  && ok "canonical text obtained for all ${#_path_fns} signal-path functions (${#${(j::)${(v)_CANON}}} characters)" \
  || no "no canonical text for ${_canon_empty[*]} (the analysis would silently see nothing): $(<"$TMP/canon-real.err")"
_viol=(); for _fn in $_path_fns; do _viol+=(${(f)"$(_c01_scan $_fn "${_CANON[$_fn]}")"}); done
_vfn=(${(M)_viol:#FN-CALL*}); _vother=(${_viol:#FN-CALL*})
[[ "${(j: :)${(ou)_vfn}}" == "FN-CALL _emit_final_cost_log:write_cost_log" ]] \
  && ok "N-06 the only user function called with a STDERR redirect on the signal path is write_cost_log (via _emit_final_cost_log)" \
  || no "N-06 unexpected stderr-redirected function calls on the signal path (xtrace is blind inside them): ${_vfn[*]}"
(( ${#_vother} == 0 )) \
  && ok "H-R5-01 no stderr-redirected compound block, exec 2>, or forking conditional on the signal path (${#_path_fns} functions analysed): xtrace sees every loop and group body" \
  || no "H-R5-01 blind construct(s) on the signal path (xtrace is blind inside them; rewrite with a guard and no redirect): ${(j: | :)_vother}"
_c01_forky ${(z)${_CANON[write_cost_log]}} \
  && no "N-06 write_cost_log forks (command substitution, pipe or background): its redirected call hides it from xtrace" \
  || ok "N-06 write_cost_log has no command substitution, pipe or background of its own (nothing hidden by its redirected call)"

_trace_scenario interrupted interrupted
_trace_scenario blocked blocked
_trace_scenario complete complete

print ""
print "=== test_signal_deadlock.zsh: $PASS passed, $FAIL failed ==="
(( FAIL == 0 ))
