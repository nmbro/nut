#!/usr/bin/env bash

# Check that NUT's generated configure script and shell scripts work the
# same with several autotools generations and /bin/sh implementations.
# The Jenkins "shellcheck" quick tests cover the same ground with one
# agent per OS; this runs it on one Linux machine.
#
# Usage:
#
#     nut-sh-matrix.sh [-o ONCE_SET] GITDIR COMMIT SET...
#
# SET names an autotools set built by build-autotools.sh, found in
# $AT_PREFIX/<set> (default /opt/at). For every SET:
#   1. autogen.sh on a fresh worktree of COMMIT
#   2. <shell> -n configure, for every shell
#   3. a real ./configure run under every shell (CONFIG_SHELL), in
#      parallel, and the resulting config.h and Makefiles compared across
#      shells: the same generated script must give the same result
#      whichever shell runs it
# Once, in the tree of ONCE_SET (default: the first SET) configured with dash:
#   4. check-scripts-syntax with every shell (git-tracked scripts), and
#      <shell> -n on the scripts configure generated
#   5. tests/nut-driver-enumerator-test.sh with every shell
#   6. each make implementation: <make> -n all, and the shellcheck target
#
# Work trees and logs go to $WORKDIR/<commit> (default $HOME/shm).
# Exit code is 1 if any check failed. In GitHub Actions (GITHUB_ACTIONS=true)
# failures are also printed as error annotations, and the results listed in
# the job summary (GITHUB_STEP_SUMMARY).

set -uo pipefail

ONCE_SET=""
if [ "${1-}" = "-o" ]; then ONCE_SET=$2; shift 2; fi
if [ $# -lt 3 ]; then
  sed -n 's/^#     //p' "$0" >&2; exit 2
fi
GITDIR=$1 COMMIT=$2; shift 2
SETS=("$@")
[ -n "$ONCE_SET" ] || ONCE_SET=${SETS[0]}
AT_PREFIX=${AT_PREFIX:-/opt/at}

SHELLS=(dash bash ksh mksh yash posh busybox-sh zsh-sh)
MAKES=(make bmake)
WORK=${WORKDIR:-$HOME/shm}/$(git -C "$GITDIR" rev-parse --short "$COMMIT")
CONFIG_OPTS=(--with-all=no --with-doc=no --with-libltdl=no --disable-silent-rules)

rm -rf "$WORK"; git -C "$GITDIR" worktree prune; mkdir -p "$WORK/bin"
# busybox and zsh as plain sh paths CONFIG_SHELL can take; zsh only in
# sh emulation: in native mode its -n passed the broken configure of PR #3782
printf '#!/bin/sh\nexec busybox sh "$@"\n' > "$WORK/bin/busybox-sh"
printf '#!/bin/sh\nexec zsh --emulate sh "$@"\n' > "$WORK/bin/zsh-sh"
chmod +x "$WORK/bin/"*
PATH=$WORK/bin:$PATH

fail=0 STEP="" T0=0
now() { date +%s%N; }
elapsed() { local d=$(( ($(now) - T0) / 100000000 )); printf '%d.%d' $((d / 10)) $((d % 10)); }
summary() { [ -z "${GITHUB_STEP_SUMMARY-}" ] || printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"; }
step() { STEP="$*"; printf '%-58s' "$STEP"; T0=$(now); }
ok()   { local t; t=$(elapsed); printf 'ok   %5ss\n' "$t"; summary "| $STEP | ok | ${t}s |"; }
bad()  {
  local t; t=$(elapsed); printf 'FAIL %5ss  %s\n' "$t" "$*"; fail=1
  summary "| $STEP | **FAIL**: $(printf '%s' "$*" | tr '|' '/') | ${t}s |"
  [ "${GITHUB_ACTIONS-}" != true ] || printf '::error title=%s::%s\n' "$STEP" "$*"
}
shname() { echo "${1// /-}"; }

summary "### Shell portability: ${SETS[*]}" "" "| Check | Result | Time |" "|---|---|---|"

step "shells and makes installed"
missing=""
for p in "${SHELLS[@]}" busybox zsh "${MAKES[@]}" shellcheck file; do
  command -v "$p" >/dev/null || missing+=" $p"
done
[ -z "$missing" ] && ok || bad "not found:$missing"

T_START=$(date +%s)
for set in "${SETS[@]}"; do
  P=$AT_PREFIX/$set
  SRC=$WORK/$set
  # a real worktree: autogen.sh takes NUT's version from git
  git -C "$GITDIR" worktree add -f -q --detach "$SRC" "$COMMIT"

  step "[$set] autogen ($("$P/bin/autoconf" --version | sed -n '1s/.* //p'))"
  if (cd "$SRC" && PATH=$P/bin:$PATH ./autogen.sh) > "$SRC.autogen.log" 2>&1; then ok
  else bad "$(grep -m1 "^FAILED" "$SRC.autogen.log" || tail -1 "$SRC.autogen.log")"; fi
  # autogen.sh's own `sh -n` self-check fails after writing configure;
  # carry on to see what each shell makes of it
  [ -s "$SRC/configure" ] || continue

  synfail=0
  for sh in "${SHELLS[@]}"; do
    step "[$set] $sh -n configure"
    # exit status decides; ksh93's "`...` obsolete" warnings do not count
    # (NUT's check-scripts-syntax filters them the same way)
    if out=$($sh -n "$SRC/configure" 2>&1); then ok
    else bad "$(echo "$out" | grep -v 'obsolete, use \$(' | head -1 | cut -c1-90)"; synfail=1; fi
  done
  [ $synfail = 0 ] || continue

  # real configure under each shell, all at once; out-of-tree builds
  step "[$set] configure under ${#SHELLS[@]} shells (parallel)"
  pids=()
  for sh in "${SHELLS[@]}"; do
    B=$WORK/$set.build-$(shname "$sh"); mkdir -p "$B"
    ( cd "$B" && CONFIG_SHELL="$(command -v "$sh")" \
        $sh "$SRC/configure" "${CONFIG_OPTS[@]}" > configure.log 2>&1 ) &
    pids+=($!)
  done
  rcs=(); for p in "${pids[@]}"; do wait "$p"; rcs+=($?); done
  failed=""; i=0
  for sh in "${SHELLS[@]}"; do [ "${rcs[$i]}" = 0 ] || failed+=" $(shname "$sh")"; i=$((i+1)); done
  [ -z "$failed" ] && ok || bad "configure failed with:$failed"

  # same script, same inputs: results must not depend on the shell
  step "[$set] config.h + Makefiles identical across shells"
  ref=$WORK/$set.build-dash diffs=""
  # differ by design: the build dir's own path, the shell that ran it,
  # and how that shell's echo suppresses a newline (yash: \c, not -n)
  norm() { sed -e "s|$WORK/$set\.build-[a-z-]*|@BUILDDIR@|g" "$1" |
           grep -v -E '^(SHELL|CONFIG_SHELL|ECHO_C|ECHO_N) = |^#define (CONFIG_SHELL|NUT_SHELL)'; }
  for sh in "${SHELLS[@]:1}"; do
    B=$WORK/$set.build-$(shname "$sh")
    [ -f "$B/config.status" ] || continue
    d=$(cd "$ref" && for f in include/config.h $(find . -name Makefile | sort); do
          diff <(norm "$f") <(norm "$B/$f") > "$B/diff.$(echo "$f" | tr / _)" 2>&1 || echo "$f"
        done)
    [ -n "$d" ] && diffs+=" $(shname "$sh"):$(echo $d | wc -w)files"
  done
  [ -z "$diffs" ] && ok || bad "differs from dash:$diffs"
done

# once, in ONCE_SET's dash-configured tree
set=$ONCE_SET SRC=$WORK/$ONCE_SET B=$WORK/$ONCE_SET.build-dash
if [ -f "$B/config.status" ]; then
  # NUT's check-scripts-syntax, inline: its recipe walks `git ls-files` in
  # the current dir, which in an out-of-tree build dir is not a checkout.
  # Same selection (file(1) says shell script) and same rules: bash
  # scripts with bash only, POSIX ones with every shell.
  step "check-scripts-syntax (git-tracked), all shells"
  out="" n=0
  while IFS= read -r f; do
    case "$(file -b "$SRC/$f")" in
      *"Bourne-Again shell script"*) shs=bash ;;
      *"shell script"*) shs="${SHELLS[*]}" ;;
      *) continue ;;
    esac
    n=$((n+1))
    for sh in $shs; do $sh -n "$SRC/$f" >/dev/null 2>&1 || out+=" $f($sh)"; done
  done < <(git -C "$SRC" ls-files)
  [ -z "$out" ] && ok || bad "$out"
  printf '    (%d tracked scripts)\n' $n

  step "generated scripts: <shell> -n"
  gen=$(cd "$B" && find . -type f ! -name config.status ! -name libtool -perm -u+x -exec sh -c 'head -c 64 "$1" | grep -q "^#! */bin/\(ba\)\?sh"' _ {} \; -print)
  out=""
  for f in $gen; do for sh in "${SHELLS[@]}"; do
    case "$(head -1 "$B/$f")" in *bash*) [ "$sh" = bash ] || continue;; esac
    $sh -n "$B/$f" >/dev/null 2>&1 || out+=" $f($(shname "$sh"))"
  done; done
  [ -z "$out" ] && ok || bad "$out"
  printf '    (%d generated scripts)\n' "$(echo $gen | wc -w)"

  step "nut-driver-enumerator-test, all shells"
  # without zsh, as on NUT's Jenkins (skipShells: zsh, tcsh, csh); the
  # configured script from the build dir (left to itself the test
  # finds the unconfigured .sh.in in the source tree)
  SP="$(for s in "${SHELLS[@]}"; do case $s in bash|zsh-sh) ;; *) command -v "$s" ;; esac; done | tr '\n' ' ')bash"
  if (cd "$SRC/tests" && SERVICE_FRAMEWORK=selftest SHELL_PROGS="$SP" \
        NDE="$B/scripts/upsdrvsvcctl/nut-driver-enumerator.sh" ./nut-driver-enumerator-test.sh) > "$WORK/nde.log" 2>&1; then ok
  else bad "failed cases per shell: $(grep '^Testing' "$WORK/nde.log" | grep -v "STATUS_CODE='MATCHED'" |
              sed "s/.*SHELL='\([^']*\)'.*/\1/; s|.*/||" | sort | uniq -c | awk '{printf "%s:%s ", $2, $1}')"; fi

  for mk in "${MAKES[@]}"; do
    step "$mk: -n all + shellcheck target"
    if (cd "$B" && $mk -n all >/dev/null && $mk shellcheck >/dev/null) > "$WORK/$mk.log" 2>&1; then ok
    else bad "see $mk.log in the logs artifact"; fi
  done
elif printf '%s\n' "${SETS[@]}" | grep -qx "$ONCE_SET"; then
  step "checks of the configured tree ($ONCE_SET)"
  bad "skipped: configure did not complete with $ONCE_SET"
fi

echo "total $(( $(date +%s) - T_START ))s, $([ $fail = 0 ] && echo PASS || echo FAIL)"
exit $fail
