#!/bin/sh
# C-01: print the fork-free signal-path helpers of lib_ralph_desk.zsh (the zmodload lines the lib runs at source
# time + the REAL bodies of _rlp_civil/_rlp_utc_iso/_rlp_pad3/_sigsafe_sh) so a test harness that extracts a single function
# (cleanup, generate_campaign_report, write_cost_log, _emit_launch_record_outcome, ...) can define what that
# function now calls. Usage: sh tests/fixtures/forksafe-helpers.sh <path to lib_ralph_desk.zsh> >> harness.zsh
echo 'zmodload zsh/datetime zsh/zselect zsh/parameter 2>/dev/null'
echo 'zmodload -F zsh/stat b:zstat 2>/dev/null'
echo 'zmodload -F zsh/files b:zf_rm b:zf_mv b:zf_mkdir 2>/dev/null'
sed -n '/^_rlp_civil() {$/,/^}$/p; /^_rlp_pad3() {/p; /^_rlp_utc_iso() {/p; /^_sigsafe_sh() {/p' "$1"
