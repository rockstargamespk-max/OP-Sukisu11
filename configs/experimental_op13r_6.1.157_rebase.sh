#!/usr/bin/env bash
set -euo pipefail

COMMON_DIR="${COMMON_KERNEL_FOLDER:-${GITHUB_WORKSPACE:-.}/OP13r/kernel_platform/common}"
# The source-sync action may not materialize the common project before this
# experimental step. Create the target directory here; the rebased OnePlus
# common-kernel tree is exported into it below.
mkdir -p "$COMMON_DIR"
ONEPLUS_REV="cce121851ca0d7d383b11122776901ef74f3af03"
ONEPLUS_BRANCH="oneplus/sm8650_b_16.0.0_oneplus_13r"
ACK_TAG="android14-6.1.157_r00"
WORK_DIR="${RUNNER_TEMP:-/tmp}/op13r-6.1.157-rebase"

echo "::group::Experimental OP13R Android 14 / 6.1.157 source update"
echo "[OP13R-6.1.157] OnePlus base: ${ONEPLUS_REV}"
echo "[OP13R-6.1.157] ACK target: ${ACK_TAG}"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

git clone --filter=blob:none --no-tags \
  "https://github.com/OnePlusOSS/android_kernel_common_oneplus_sm8650.git" \
  "$WORK_DIR/oneplus"

git -C "$WORK_DIR/oneplus" fetch --no-tags origin \
  "$ONEPLUS_BRANCH" "$ONEPLUS_REV"

git -C "$WORK_DIR/oneplus" fetch --no-tags \
  "https://android.googlesource.com/kernel/common" \
  "refs/tags/${ACK_TAG}:refs/tags/${ACK_TAG}"

git -C "$WORK_DIR/oneplus" checkout --detach "$ONEPLUS_REV"

BASE="$(git -C "$WORK_DIR/oneplus" merge-base "$ONEPLUS_REV" "$ACK_TAG")"
if [[ -z "$BASE" ]]; then
  echo "::error::Unable to find a common ancestor between the OnePlus OP13R source and ACK ${ACK_TAG}."
  exit 1
fi

echo "[OP13R-6.1.157] Common ancestor: ${BASE}"
echo "[OP13R-6.1.157] Rebasing OnePlus changes onto Android ACK ${ACK_TAG}..."

# Configure a local identity on the temporary OnePlus repository used by the rebase.
# The rebase runs in WORK_DIR/oneplus, not COMMON_DIR.
git -C "$WORK_DIR/oneplus" config user.name "OP-Sukisu Experimental Rebase"
git -C "$WORK_DIR/oneplus" config user.email "op-sukisu-experimental@localhost"

git -C "$WORK_DIR/oneplus" checkout -B op13r-6.1.157-experimental "$ONEPLUS_REV"

DIAG_DIR="${GITHUB_WORKSPACE:-$WORK_DIR}/op13r-6.1.157-rebase-diagnostics"
rm -rf "$DIAG_DIR"
mkdir -p "$DIAG_DIR"

capture_rebase_diagnostics() {
  local reason="${1:-rebase-failure}"
  echo "[OP13R-6.1.157] Capturing rebase diagnostics: $reason"
  {
    echo "reason=$reason"
    echo "oneplus_revision=$ONEPLUS_REV"
    echo "oneplus_branch=$ONEPLUS_BRANCH"
    echo "ack_tag=$ACK_TAG"
    echo "base=$BASE"
    echo "stopped_sha=$(git -C "$WORK_DIR/oneplus" rev-parse REBASE_HEAD 2>/dev/null || true)"
    echo
    echo "=== git status ==="
    git -C "$WORK_DIR/oneplus" status --short --untracked-files=all || true
    echo
    echo "=== conflicted files ==="
    git -C "$WORK_DIR/oneplus" diff --name-only --diff-filter=U || true
    echo
    echo "=== current diff ==="
    git -C "$WORK_DIR/oneplus" diff --no-ext-diff || true
    echo
    echo "=== staged diff ==="
    git -C "$WORK_DIR/oneplus" diff --cached --no-ext-diff || true
    echo
    echo "=== stopped commit ==="
    git -C "$WORK_DIR/oneplus" show --stat --oneline REBASE_HEAD 2>/dev/null || true
  } > "$DIAG_DIR/rebase-report.txt" 2>&1

  git -C "$WORK_DIR/oneplus" diff --binary > "$DIAG_DIR/unmerged.diff" 2>/dev/null || true
  git -C "$WORK_DIR/oneplus" status --porcelain=v1 > "$DIAG_DIR/status.txt" 2>/dev/null || true
  echo "[OP13R-6.1.157] Diagnostics: $DIAG_DIR"
}

resolve_cgroup_rstat_rename() {
  local stopped_sha="$1"
  echo "[OP13R-6.1.157] Resolving known cgroup_rstat rename conflict in $stopped_sha"

  git -C "$WORK_DIR/oneplus" checkout --ours -- .
  git -C "$WORK_DIR/oneplus" add -A

  python3 - "$WORK_DIR/oneplus" <<'PYTHON'
from pathlib import Path
import sys

root = Path(sys.argv[1])
paths = [
    root / "include/linux/cgroup.h",
    root / "kernel/cgroup/rstat.c",
    root / "mm/memcontrol.c",
]

for path in paths:
    if not path.is_file():
        raise SystemExit("missing expected file: " + str(path))
    data = path.read_text()
    data = data.replace("cgroup_rstat_flush_irqsafe", "cgroup_rstat_flush_atomic")
    path.write_text(data)
PYTHON

  git -C "$WORK_DIR/oneplus" add     include/linux/cgroup.h     kernel/cgroup/rstat.c     mm/memcontrol.c

  if git -C "$WORK_DIR/oneplus" diff --name-only --diff-filter=U | grep -q .; then
    echo "::error::Known cgroup resolver left unresolved index entries."
    return 1
  fi

  if grep -nE '^(<<<<<<<|=======|>>>>>>>)'       "$WORK_DIR/oneplus/include/linux/cgroup.h"       "$WORK_DIR/oneplus/kernel/cgroup/rstat.c"       "$WORK_DIR/oneplus/mm/memcontrol.c" 2>/dev/null; then
    echo "::error::Known cgroup resolver left conflict markers."
    return 1
  fi

  git -C "$WORK_DIR/oneplus" diff --check
  echo "[OP13R-6.1.157] Known cgroup_rstat rename conflict resolved."
}

resolve_memcg_ratelimited_rename() {
  local stopped_sha="$1"
  echo "[OP13R-6.1.157] Resolving known memcg delayed-to-ratelimited rename conflict in $stopped_sha"

  # The ACK 6.1.157 side already contains the ratelimited API. Restore that
  # side for the conflicted file, then perform the exact semantic rename in
  # the affected OnePlus file. Do not skip the upstream commit.
  git -C "$WORK_DIR/oneplus" checkout --ours -- mm/workingset.c
  git -C "$WORK_DIR/oneplus" add mm/workingset.c

  python3 - "$WORK_DIR/oneplus/mm/workingset.c" <<'PYTHON'
from pathlib import Path
import sys

path = Path(sys.argv[1])
data = path.read_text()

old = "mem_cgroup_flush_stats_delayed"
new = "mem_cgroup_flush_stats_ratelimited"

if old in data:
    data = data.replace(old, new)
elif new not in data:
    raise SystemExit(
        "Neither mem_cgroup_flush_stats_delayed nor "
        "mem_cgroup_flush_stats_ratelimited was found in mm/workingset.c"
    )

path.write_text(data)
PYTHON

  git -C "$WORK_DIR/oneplus" add mm/workingset.c

  if git -C "$WORK_DIR/oneplus" diff --name-only --diff-filter=U | grep -q .; then
    echo "::error::Known memcg resolver left unresolved index entries."
    return 1
  fi

  if grep -nE '^(<<<<<<<|=======|>>>>>>>)' \
      "$WORK_DIR/oneplus/mm/workingset.c" 2>/dev/null; then
    echo "::error::Known memcg resolver left conflict markers."
    return 1
  fi

  if grep -n "mem_cgroup_flush_stats_delayed" \
      "$WORK_DIR/oneplus/mm/workingset.c" 2>/dev/null; then
    echo "::error::Old mem_cgroup_flush_stats_delayed references remain in mm/workingset.c."
    return 1
  fi

  git -C "$WORK_DIR/oneplus" diff --check
  echo "[OP13R-6.1.157] Known memcg delayed-to-ratelimited rename conflict resolved."
}

# Rebase with a targeted resolver for the first known 6.1.157 conflict. Any
# other conflict is preserved and reported instead of being guessed at.
while true; do
  if GIT_EDITOR=true git -C "$WORK_DIR/oneplus" rebase --rebase-merges --onto "$ACK_TAG" "$BASE"; then
    break
  fi

  STOPPED_SHA="$(git -C "$WORK_DIR/oneplus" rev-parse REBASE_HEAD 2>/dev/null || true)"
  echo "[OP13R-6.1.157] Rebase stopped at: ${STOPPED_SHA:-unknown}"

  if [[ "$STOPPED_SHA" == "ebf6113bfb8e"* ]]; then
    if ! resolve_cgroup_rstat_rename "$STOPPED_SHA"; then
      capture_rebase_diagnostics "cgroup-rstat-resolver-failed"
      exit 1
    fi
    # rebase --continue may stop immediately at the next conflicting commit.
    # Do not treat that expected stop as a resolver failure; return to the
    # dispatcher so the next known resolver can handle it.
    if GIT_EDITOR=true git -C "$WORK_DIR/oneplus" rebase --continue; then
      continue
    fi
    if git -C "$WORK_DIR/oneplus" rebase --show-current-patch >/dev/null 2>&1; then
      echo "[OP13R-6.1.157] Rebase stopped at next commit; redispatching resolver."
      continue
    fi
    capture_rebase_diagnostics "rebase-continue-failed-after-cgroup-resolver"
    exit 1
  fi

  if [[ "$STOPPED_SHA" == "f10173bf4bad"* ]]; then
    if ! resolve_memcg_ratelimited_rename "$STOPPED_SHA"; then
      capture_rebase_diagnostics "memcg-ratelimited-resolver-failed"
      exit 1
    fi
    if GIT_EDITOR=true git -C "$WORK_DIR/oneplus" rebase --continue; then
      continue
    fi
    if git -C "$WORK_DIR/oneplus" rebase --show-current-patch >/dev/null 2>&1; then
      echo "[OP13R-6.1.157] Rebase stopped at next commit; redispatching resolver."
      continue
    fi
    capture_rebase_diagnostics "rebase-continue-failed-after-memcg-ratelimited-resolver"
    exit 1
  fi

  capture_rebase_diagnostics "unhandled-rebase-conflict"
  echo "::error::Unhandled OP13R 6.1.157 rebase conflict. Diagnostics were captured."
  exit 1
done

echo "[OP13R-6.1.157] Rebase completed: $(git -C "$WORK_DIR/oneplus" rev-parse HEAD)"
echo "[OP13R-6.1.157] Exporting rebased source over kernel_platform/common..."

find "$COMMON_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
git -C "$WORK_DIR/oneplus" archive HEAD | tar -x -C "$COMMON_DIR"

echo "[OP13R-6.1.157] Kernel Makefile reports:"
awk '/^VERSION =|^PATCHLEVEL =|^SUBLEVEL =/{print}' "$COMMON_DIR/Makefile"

echo "::endgroup::"
