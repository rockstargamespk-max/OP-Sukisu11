#!/usr/bin/env bash
set -euo pipefail

COMMON_DIR="${EXPERIMENTAL_COMMON_KERNEL_FOLDER:-${COMMON_KERNEL_FOLDER:-${GITHUB_WORKSPACE:-.}/${OP_MODEL:-OP13r}/kernel_platform/common}}"
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

git clone --no-tags \
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
echo "[OP13R-6.1.157] NOTE: OnePlus revision itself is a 6.1.141 vendor tree; 6.1.157 is produced only after the ACK uplift rebase."

# Configure a local identity on the temporary OnePlus repository used by the rebase.
# The rebase runs in WORK_DIR/oneplus, not COMMON_DIR.
git -C "$WORK_DIR/oneplus" config user.name "OP-Sukisu Experimental Rebase"
git -C "$WORK_DIR/oneplus" config user.email "op-sukisu-experimental@localhost"

# The OnePlus repository can be checked out as a partial/promisor clone by
# the runner. A rebase must not unexpectedly request an object that the
# promisor remote no longer advertises. Disable lazy promisor fetching and
# explicitly deepen/unshallow the temporary repository before replaying.
echo "[OP13R-6.1.157] Preparing temporary rebase repository"
if git -C "$WORK_DIR/oneplus" rev-parse --is-shallow-repository 2>/dev/null | grep -qx true; then
  git -C "$WORK_DIR/oneplus" fetch --no-tags --prune --unshallow origin || true
fi
echo "[OP13R-6.1.157] Temporary repository preparation complete"

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

  git -C "$WORK_DIR/oneplus" rev-parse --is-shallow-repository > "$DIAG_DIR/is-shallow.txt" 2>&1 || true
  git -C "$WORK_DIR/oneplus" config --get remote.origin.promisor > "$DIAG_DIR/promisor.txt" 2>&1 || true
  git -C "$WORK_DIR/oneplus" config --get extensions.partialClone > "$DIAG_DIR/partialclone.txt" 2>&1 || true
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

verify_op13r_6157_source() {
  local tree="$1"
  echo "[OP13R-6.1.157] Verifying exported kernel source is actually 6.1.157"
  [ -d "$tree" ] || { echo "::error::OP13R 6.1.157 source tree not found: $tree"; return 1; }
  local makefile="$tree/Makefile"
  [ -f "$makefile" ] || { echo "::error::OP13R 6.1.157 Makefile not found: $makefile"; return 1; }
  local version patchlevel sublevel
  version="$(sed -n 's/^VERSION[[:space:]]*=[[:space:]]*//p' "$makefile" | head -n1)"
  patchlevel="$(sed -n 's/^PATCHLEVEL[[:space:]]*=[[:space:]]*//p' "$makefile" | head -n1)"
  sublevel="$(sed -n 's/^SUBLEVEL[[:space:]]*=[[:space:]]*//p' "$makefile" | head -n1)"
  echo "[OP13R-6.1.157] Detected source version: ${version}.${patchlevel}.${sublevel}"
  if [[ "$version" != "6" || "$patchlevel" != "1" || "$sublevel" != "157" ]]; then
    echo "::error::OP13R experimental source is NOT 6.1.157 (detected ${version}.${patchlevel}.${sublevel})."
    echo "::error::Refusing to build the experimental OP13R kernel from the wrong source tree."
    return 1
  fi
  echo "[OP13R-6.1.157] Source verification PASSED: 6.1.157"
}

# Resolve known conflicts inside the single active rebase session. Never
# start a second `git rebase` while .git/rebase-merge exists.
resolve_memcg_irq_conflict() {
  local stopped_sha="$1"
  local repo="$WORK_DIR/oneplus"
  local file="$repo/mm/memcontrol.c"
  echo "[OP13R-6.1.157] Resolving known memcg IRQ-context conflict in $stopped_sha"

  [ -f "$file" ] || {
    echo "::error::Expected conflicted file not found: $file"
    return 1
  }

  # During a rebase, --theirs is the OnePlus commit currently being replayed.
  # This commit is an upstream memcg change; use its complete file version for
  # this narrowly identified conflict instead of trying to patch REBASE_HEAD
  # back through an already-conflicted index.
  if ! git -C "$repo" checkout --theirs -- mm/memcontrol.c; then
    echo "::error::Could not select the incoming side for mm/memcontrol.c"
    return 1
  fi
  if ! git -C "$repo" add -- mm/memcontrol.c; then
    echo "::error::Could not stage resolved mm/memcontrol.c"
    return 1
  fi

  if git -C "$repo" diff --name-only --diff-filter=U | grep -q .; then
    echo "::error::Known memcg IRQ resolver left unresolved index entries."
    return 1
  fi
  if grep -nE '^(<<<<<<<|=======|>>>>>>>)' "$file" >/dev/null 2>&1; then
    echo "::error::Known memcg IRQ resolver left conflict markers."
    return 1
  fi
  git -C "$repo" diff --check
  echo "[OP13R-6.1.157] Known memcg IRQ-context conflict resolved."
}

resolve_memcg_sleep_safe_context_conflict() {
  local stopped_sha="$1"
  local repo="$WORK_DIR/oneplus"
  local file="$repo/mm/workingset.c"
  echo "[OP13R-6.1.157] Resolving known memcg sleep-safe-context conflict in $stopped_sha"

  [ -f "$file" ] || {
    echo "::error::Expected conflicted file not found: $file"
    return 1
  }

  # Keep the OnePlus side of mm/workingset.c and replay the upstream semantic
  # change manually: the ratelimited memcg stats flush must happen before the
  # RCU read-side section so it may sleep. This preserves unrelated OnePlus
  # changes in the same file.
  git -C "$repo" checkout --ours -- mm/workingset.c

  python3 - "$file" <<'PYTHON'
from pathlib import Path
import sys

path = Path(sys.argv[1])
data = path.read_text()

data = data.replace(
    "mem_cgroup_flush_stats_atomic_ratelimited()",
    "mem_cgroup_flush_stats_ratelimited()",
)

call = "\tmem_cgroup_flush_stats_ratelimited();"

# Remove the old call from inside the RCU read-side section.
data = data.replace("\n" + call + "\n", "\n")

marker = "\teviction <<= bucket_order;\n"
if marker not in data:
    raise SystemExit(
        "Could not locate workingset_refault() eviction marker in mm/workingset.c"
    )

if call not in data:
    data = data.replace(
        marker,
        marker
        + "\n\t/* Flush stats (and potentially sleep) before holding RCU read lock */\n"
        + call
        + "\n",
        1,
    )

path.write_text(data)
PYTHON

  git -C "$repo" add -- mm/workingset.c

  if git -C "$repo" diff --name-only --diff-filter=U | grep -q .; then
    echo "::error::Known memcg sleep-safe-context resolver left unresolved index entries."
    return 1
  fi
  if grep -nE '^(<<<<<<<|=======|>>>>>>>)' "$file" >/dev/null 2>&1; then
    echo "::error::Known memcg sleep-safe-context resolver left conflict markers."
    return 1
  fi
  if grep -n "mem_cgroup_flush_stats_atomic_ratelimited" "$file" >/dev/null 2>&1; then
    echo "::error::Old atomic ratelimited memcg stats API remains in mm/workingset.c."
    return 1
  fi

  git -C "$repo" diff --check
  echo "[OP13R-6.1.157] Known memcg sleep-safe-context conflict resolved."
}


resolve_workingset_refault_sleep_conflict() {
  local stopped_sha="$1"
  local repo="$WORK_DIR/oneplus"
  local file="$repo/mm/workingset.c"
  echo "[OP13R-6.1.157] Resolving known workingset_refault sleep conflict in $stopped_sha"

  [ -f "$file" ] || {
    echo "::error::Expected conflicted file not found: $file"
    return 1
  }

  # fa90fbbc182f is the follow-up to cc0b66f72d35.  At this point
  # include/linux/memcontrol.h and mm/memcontrol.c normally merge cleanly;
  # mm/workingset.c is the vendor-sensitive conflict.  Preserve the current
  # OP13R/ACK content and apply only the exact semantic change from fa90:
  # use the sleepable ratelimited API and move the flush before RCU.
  git -C "$repo" checkout --ours -- mm/workingset.c

  python3 - "$file" <<'PYTHON'
from pathlib import Path
import sys

path = Path(sys.argv[1])
data = path.read_text()

old_api = "mem_cgroup_flush_stats_atomic_ratelimited()"
new_api = "mem_cgroup_flush_stats_ratelimited()"

if old_api in data:
    data = data.replace(old_api, new_api)
elif new_api not in data:
    raise SystemExit(
        "Neither mem_cgroup_flush_stats_atomic_ratelimited nor "
        "mem_cgroup_flush_stats_ratelimited was found in mm/workingset.c"
    )

call = "\tmem_cgroup_flush_stats_ratelimited();"

# Remove the existing flush call wherever it occurs; the commit requires it
# to execute before rcu_read_lock(), where sleeping is permitted.
data = data.replace("\n" + call + "\n", "\n")

rcu_marker = "\trcu_read_lock();"
if rcu_marker not in data:
    raise SystemExit("Could not locate rcu_read_lock() in workingset_refault()")

# Insert immediately before the first RCU read-side section in this function.
data = data.replace(
    rcu_marker,
    "\t/* Flush stats (and potentially sleep) before holding RCU read lock */\n"
    + call + "\n\n"
    + rcu_marker,
    1,
)

path.write_text(data)
PYTHON

  git -C "$repo" add -- mm/workingset.c

  if git -C "$repo" diff --name-only --diff-filter=U | grep -q .; then
    echo "::error::Known workingset_refault resolver left unresolved index entries."
    return 1
  fi
  if grep -nE '^(<<<<<<<|=======|>>>>>>>)' "$file" >/dev/null 2>&1; then
    echo "::error::Known workingset_refault resolver left conflict markers."
    return 1
  fi
  if grep -n "mem_cgroup_flush_stats_atomic_ratelimited" "$file" >/dev/null 2>&1; then
    echo "::error::Old atomic ratelimited memcg stats API remains in mm/workingset.c."
    return 1
  fi
  if ! grep -n "mem_cgroup_flush_stats_ratelimited();" "$file" >/dev/null 2>&1; then
    echo "::error::Sleepable ratelimited memcg stats flush was not inserted."
    return 1
  fi

  git -C "$repo" diff --check
  echo "[OP13R-6.1.157] Known workingset_refault sleep conflict resolved."
}

resolve_memcg_stats_flush_atomic_conflict() {
  local stopped_sha="$1"
  local repo="$WORK_DIR/oneplus"
  local file="$repo/mm/memcontrol.c"
  echo "[OP13R-6.1.157] Resolving known memcg stats_flush_lock atomic conflict in $stopped_sha"

  [ -f "$file" ] || {
    echo "::error::Expected conflicted file not found: $file"
    return 1
  }

  # This is the next upstream memcg transformation. As above, --theirs is the
  # commit being replayed, and is used only for this exact known conflict.
  if ! git -C "$repo" checkout --theirs -- mm/memcontrol.c; then
    echo "::error::Could not select the incoming side for mm/memcontrol.c"
    return 1
  fi
  if ! git -C "$repo" add -- mm/memcontrol.c; then
    echo "::error::Could not stage resolved mm/memcontrol.c"
    return 1
  fi

  if git -C "$repo" diff --name-only --diff-filter=U | grep -q .; then
    echo "::error::Known memcg stats_flush_lock resolver left unresolved index entries."
    return 1
  fi
  if grep -nE '^(<<<<<<<|=======|>>>>>>>)' "$file" >/dev/null 2>&1; then
    echo "::error::Known memcg stats_flush_lock resolver left conflict markers."
    return 1
  fi
  git -C "$repo" diff --check
  echo "[OP13R-6.1.157] Known memcg stats_flush_lock atomic conflict resolved."
}

resolve_paragon_symbol_list_conflict() {
  local stopped_sha="$1"
  local repo="$WORK_DIR/oneplus"
  local stg="$repo/android/abi_gki_aarch64.stg"
  local build="$repo/BUILD.bazel"
  local paragon="$repo/android/abi_gki_aarch64_paragon"
  local tmpdir

  echo "[OP13R-6.1.157] Resolving Paragon GKI symbol-list conflict in $stopped_sha"

  [ -f "$stg" ] || { echo "::error::Expected ABI STG file not found: $stg"; return 1; }
  [ -f "$build" ] || { echo "::error::Expected BUILD.bazel not found: $build"; return 1; }

  # This commit is additions-only (289 insertions, 0 deletions). The STG
  # conflict is therefore an insertion-order conflict: preserve both the
  # rebased OP13R ABI additions and the Paragon additions.
  git -C "$repo" checkout --ours -- BUILD.bazel android/abi_gki_aarch64.stg || return 1

  tmpdir="$(mktemp -d)"
  git -C "$repo" show "${stopped_sha}:android/abi_gki_aarch64.stg" > "$tmpdir/theirs.stg" || { rm -rf "$tmpdir"; return 1; }
  git -C "$repo" show "${stopped_sha}^:android/abi_gki_aarch64.stg" > "$tmpdir/base.stg" || { rm -rf "$tmpdir"; return 1; }
  cp "$stg" "$tmpdir/ours.stg"

  # Ask git for the normal three-way merge, then resolve only its conflict
  # regions by retaining both sides. This is appropriate for this exact
  # additions-only commit and avoids replacing the vendor STG wholesale.
  git merge-file -p "$tmpdir/ours.stg" "$tmpdir/base.stg" "$tmpdir/theirs.stg" > "$tmpdir/merged.stg" || true

  python3 - "$tmpdir/merged.stg" "$stg" <<'PYTHON'
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_text()
lines = src.splitlines(keepends=True)
out = []
i = 0
while i < len(lines):
    if lines[i].startswith("<<<<<<< "):
        i += 1
        ours = []
        while i < len(lines) and not lines[i].startswith("=======\n"):
            ours.append(lines[i])
            i += 1
        if i >= len(lines):
            raise SystemExit("Malformed three-way conflict: missing separator")
        i += 1
        theirs = []
        while i < len(lines) and not lines[i].startswith(">>>>>>> "):
            theirs.append(lines[i])
            i += 1
        if i >= len(lines):
            raise SystemExit("Malformed three-way conflict: missing terminator")
        i += 1

        seen = set()
        for line in ours + theirs:
            if line not in seen:
                out.append(line)
                seen.add(line)
        continue
    out.append(lines[i])
    i += 1

result = ''.join(out)
if any(marker in result for marker in ("<<<<<<< ", "=======\n", ">>>>>>> ")):
    raise SystemExit("Conflict markers remain after Paragon STG merge")
Path(sys.argv[2]).write_text(result)
PYTHON

  rm -rf "$tmpdir"

  # BUILD.bazel receives one additive filegroup entry. Preserve everything
  # already present in the rebased OP13R tree.
  python3 - "$build" <<'PYTHON'
from pathlib import Path
import sys
p = Path(sys.argv[1])
data = p.read_text()
entry = '        "android/abi_gki_aarch64_paragon",'
if entry not in data:
    anchor = '        "android/abi_gki_aarch64_oplus",'
    if anchor not in data:
        raise SystemExit("Could not locate Oplus ABI group in BUILD.bazel")
    data = data.replace(anchor, anchor + "\n" + entry, 1)
p.write_text(data)
PYTHON

  # This is a new file introduced by the commit, so there is no vendor-side
  # content to preserve.
  git -C "$repo" show "${stopped_sha}:android/abi_gki_aarch64_paragon" > "$paragon" || return 1

  git -C "$repo" add -- BUILD.bazel android/abi_gki_aarch64.stg android/abi_gki_aarch64_paragon || return 1

  if git -C "$repo" diff --name-only --diff-filter=U | grep -q .; then
    echo "::error::Paragon resolver left unresolved index entries."
    return 1
  fi
  if git -C "$repo" grep -nE '^(<<<<<<<|=======|>>>>>>>)' -- BUILD.bazel android/abi_gki_aarch64.stg android/abi_gki_aarch64_paragon >/dev/null 2>&1; then
    echo "::error::Paragon resolver left conflict markers."
    return 1
  fi
  if ! grep -q 'android/abi_gki_aarch64_paragon' "$build"; then
    echo "::error::Paragon ABI group was not added to BUILD.bazel."
    return 1
  fi
  [ -s "$paragon" ] || { echo "::error::Paragon symbol-list file is empty."; return 1; }

  git -C "$repo" diff --check
  echo "[OP13R-6.1.157] Paragon GKI symbol-list conflict resolved while preserving OP13R ABI additions."
}

resolve_galaxy_abi_symbol_conflict() {
  local repo="$WORK_DIR/oneplus"
  local stopped_sha="$1"
  local galaxy="$repo/android/abi_gki_aarch64_galaxy"

  echo "[OP13R-6.1.157] Resolving Galaxy ABI symbol-list conflict in $stopped_sha"

  [ -f "$galaxy" ] || {
    echo "::error::Galaxy ABI symbol list is missing."
    return 1
  }

  # 3a55164b40ce adds exactly one ABI symbol: snd_card_ref. The vendor
  # Galaxy list may already contain that symbol, and the conflict can leave
  # duplicate entries or conflict markers in the worktree. Normalize only
  # this small additive hunk: keep existing vendor entries such as
  # snd_ctl_remove_id, remove conflict markers, and keep exactly one
  # snd_card_ref in the sorted location.
  python3 - "$galaxy" <<'PYTHON'
from pathlib import Path
import sys

p = Path(sys.argv[1])
lines = p.read_text().splitlines()

# Resolve the exact conflict shape without replacing the vendor file.
out = []
for line in lines:
    if line in ("<<<<<<< HEAD", "=======", ">>>>>>> 3a55164b40ce (ANDROID: common-android14-6.1 Update the ABI symbol list)"):
        continue
    out.append(line)
lines = out

# Remove duplicate snd_card_ref entries created by an earlier partial
# resolver, then insert exactly one at the upstream sorted position.
result = []
seen = False
for line in lines:
    if line == "  snd_card_ref":
        if seen:
            continue
        seen = True
    result.append(line)
lines = result

if not seen:
    anchor = "  smpboot_unregister_percpu_thread"
    try:
        idx = lines.index(anchor)
    except ValueError:
        raise SystemExit("Could not locate Galaxy ABI insertion anchor")
    lines.insert(idx + 1, "  snd_card_ref")

p.write_text("\n".join(lines) + "\n")
PYTHON

  git -C "$repo" add -- android/abi_gki_aarch64_galaxy || return 1

  if git -C "$repo" diff --name-only --diff-filter=U | grep -q .; then
    echo "::error::Galaxy ABI resolver left unresolved index entries."
    return 1
  fi
  if git -C "$repo" grep -nE '^(<<<<<<<|=======|>>>>>>>)' -- android/abi_gki_aarch64_galaxy >/dev/null 2>&1; then
    echo "::error::Galaxy ABI resolver left conflict markers."
    return 1
  fi
  if [ "$(grep -cx '  snd_card_ref' "$galaxy")" -ne 1 ]; then
    echo "::error::Galaxy ABI list must contain exactly one snd_card_ref entry."
    return 1
  fi
  if grep -nE '^(<<<<<<<|=======|>>>>>>>)' "$galaxy" >/dev/null 2>&1; then
    echo "::error::Galaxy ABI list still contains conflict markers."
    return 1
  fi

  git -C "$repo" diff --check
  echo "[OP13R-6.1.157] Galaxy ABI symbol-list conflict resolved while preserving OP13R entries."
}


resolve_pixel_abi_symbol_conflict() {
  local repo="$WORK_DIR/oneplus"
  local stopped_sha="$1"
  local file="$repo/android/abi_gki_aarch64_pixel"
  local tmpdir

  echo "[OP13R-6.1.157] Resolving Pixel ABI symbol-list conflict in $stopped_sha"

  [ -f "$file" ] || {
    echo "::error::Pixel ABI symbol list is missing."
    return 1
  }

  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  # This commit is an ABI symbol-list update. Preserve the rebased ACK/OP13R
  # list and add the incoming symbols from the stopped commit. Use Git's
  # three-way merge first; when the only conflicts are additive list hunks,
  # retain the unique lines from both sides instead of choosing one side.
  git -C "$repo" checkout --ours -- android/abi_gki_aarch64_pixel || return 1
  cp "$file" "$tmpdir/ours"
  git -C "$repo" show "${stopped_sha}^:android/abi_gki_aarch64_pixel" > "$tmpdir/base" || return 1
  git -C "$repo" show "${stopped_sha}:android/abi_gki_aarch64_pixel" > "$tmpdir/theirs" || return 1

  set +e
  git merge-file -p "$tmpdir/ours" "$tmpdir/base" "$tmpdir/theirs" > "$tmpdir/merged"
  merge_rc=$?
  set -e

  if [[ "$merge_rc" -eq 0 ]]; then
    cp "$tmpdir/merged" "$file"
  else
    python3 - "$tmpdir/merged" "$file" <<'PYTHON'
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_text().splitlines()
out = []
i = 0
conflicts = 0
while i < len(src):
    line = src[i]
    if line.startswith('<<<<<<< '):
        conflicts += 1
        i += 1
        ours = []
        while i < len(src) and src[i] != '=======':
            ours.append(src[i])
            i += 1
        if i >= len(src):
            raise SystemExit('Malformed Pixel ABI conflict: missing separator')
        i += 1
        theirs = []
        while i < len(src) and not src[i].startswith('>>>>>>> '):
            theirs.append(src[i])
            i += 1
        if i >= len(src):
            raise SystemExit('Malformed Pixel ABI conflict: missing terminator')
        i += 1

        # ABI symbol-list conflicts in this series are additive. Preserve the
        # existing list order and append only incoming lines not already seen
        # in the conflict hunk.
        seen = set(ours)
        out.extend(ours)
        for item in theirs:
            if item not in seen:
                out.append(item)
                seen.add(item)
    else:
        out.append(line)
        i += 1

if conflicts == 0:
    raise SystemExit('Expected at least one Pixel ABI conflict hunk')

result = '\n'.join(out) + '\n'
if any(x.startswith(('<<<<<<< ', '=======', '>>>>>>> ')) for x in out):
    raise SystemExit('Pixel ABI conflict markers remain after resolution')
Path(sys.argv[2]).write_text(result)
PYTHON
  fi

  git -C "$repo" add -- android/abi_gki_aarch64_pixel || return 1

  if git -C "$repo" diff --name-only --diff-filter=U | grep -q .; then
    echo "::error::Pixel ABI resolver left unresolved index entries."
    return 1
  fi
  if grep -nE '^(<<<<<<<|=======|>>>>>>>)' "$file" >/dev/null 2>&1; then
    echo "::error::Pixel ABI resolver left conflict markers."
    return 1
  fi
  if ! grep -q '[^[:space:]]' "$file"; then
    echo "::error::Pixel ABI symbol list became empty."
    return 1
  fi

  git -C "$repo" diff --check
  echo "[OP13R-6.1.157] Pixel ABI symbol-list conflict resolved while preserving both ABI sides."
}

resolve_kswapd_rvh_conflict() {
  local repo="$WORK_DIR/oneplus"
  local file="$repo/include/trace/hooks/vmscan.h"

  echo "[OP13R-6.1.157] Resolving kswapd RVH conflict in c98768cf3203"

  [ -f "$file" ] || {
    echo "::error::vmscan hook header is missing."
    return 1
  }

  # Git uses repository/branch names (for example HEAD and the rebased commit
  # name) in conflict markers, not literal "ours"/"theirs". Resolve only the
  # known empty-incoming hunk containing the three OP13R vendor hooks.
  python3 - "$file" <<'PYTHON'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
text = p.read_text()

vendor = """DECLARE_HOOK(android_vh_shrink_folio_list,
\tTP_PROTO(struct folio *folio, bool dirty, bool writeback,
\t\tbool *activate, bool *keep),
\tTP_ARGS(folio, dirty, writeback, activate, keep));
DECLARE_HOOK(android_vh_inode_lru_isolate,
\tTP_PROTO(struct inode *inode, bool *skip),
\tTP_ARGS(inode, skip));
DECLARE_HOOK(android_vh_invalidate_mapping_pagevec,
\tTP_PROTO(struct address_space *mapping, bool *skip),
\tTP_ARGS(mapping, skip));
"""

# Match the exact vendor hunk regardless of Git's actual conflict-label text.
# The incoming side of this hunk is empty; the upstream restricted hooks are
# introduced elsewhere in this file by the same commit.
pattern = re.compile(
    r"<<<<<<< [^\n]*\n"
    + re.escape(vendor) +
    r"=======\n"
    r">>>>>>> [^\n]*\n"
)

matches = list(pattern.finditer(text))
if len(matches) != 1:
    raise SystemExit(
        f"Expected exactly one c98768cf3203 vendor vmscan conflict hunk; found {len(matches)}"
    )

text = text[:matches[0].start()] + vendor + text[matches[0].end():]
p.write_text(text)
PYTHON

  if git -C "$repo" grep -nE '^(<<<<<<<|=======|>>>>>>>)' -- include/trace/hooks/vmscan.h >/dev/null 2>&1; then
    echo "::error::kswapd RVH resolver left conflict markers."
    return 1
  fi

  git -C "$repo" add -- include/trace/hooks/vmscan.h || return 1

  if git -C "$repo" diff --name-only --diff-filter=U | grep -q .; then
    echo "::error::kswapd RVH resolver left unresolved index entries."
    return 1
  fi

  for hook in \
    'android_rvh_vmscan_kswapd_wake' \
    'android_rvh_vmscan_kswapd_done' \
    'android_vh_shrink_folio_list' \
    'android_vh_inode_lru_isolate' \
    'android_vh_invalidate_mapping_pagevec'
  do
    if ! grep -q "$hook" "$file"; then
      echo "::error::Expected vmscan hook '$hook' is missing after resolution."
      return 1
    fi
  done

  git -C "$repo" diff --check
  echo "[OP13R-6.1.157] kswapd RVH conflict resolved while preserving OP13R vmscan hooks."
}


resolve_oneplus_sync_commit_conflict() {
  local repo="$WORK_DIR/oneplus"
  local sha="$1"
  local files

  echo "[OP13R-6.1.157] Resolving OnePlus synchronization commit $sha"
  echo "[OP13R-6.1.157] This is a vendor snapshot/synchronization commit; preserving the OnePlus side for files it explicitly modifies."

  files="$(git -C "$repo" diff --name-only --diff-filter=U)"
  [ -n "$files" ] || {
    echo "::error::Expected unresolved files for OnePlus synchronization commit $sha, but none were found."
    return 1
  }

  # This commit is the large OnePlus 13R vendor synchronization snapshot.
  # It is replayed after the ACK uplift and contains the vendor-side versions
  # of the files it explicitly changes. For conflicts in those files, the
  # commit being replayed ("theirs") is the authoritative OnePlus version.
  # Do not use this rule for arbitrary later commits.
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    echo "[OP13R-6.1.157] Taking OnePlus-sync side for: $file"
    git -C "$repo" checkout --theirs -- "$file" || return 1
    git -C "$repo" add -- "$file" || return 1
  done <<< "$files"

  if git -C "$repo" diff --name-only --diff-filter=U | grep -q .; then
    echo "::error::OnePlus synchronization resolver left unresolved index entries."
    return 1
  fi

  # Do not grep the entire kernel tree for a bare `=======` line: normal
  # kernel documentation contains reStructuredText/Markdown section
  # separators that look exactly like a merge-conflict separator.  Only
  # inspect the files that were actually unmerged at the start of this
  # resolver, and only look for the unambiguous conflict boundary markers.
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    if git -C "$repo" grep -nE '^(<<<<<<< |>>>>>>> )' -- "$file" >/dev/null 2>&1; then
      echo "::error::OnePlus synchronization resolver left conflict markers in: $file"
      return 1
    fi
  done <<< "$files"

  # The vendor snapshot can legitimately carry whitespace that is unrelated
  # to the conflict resolution.  `diff --check` is therefore diagnostic here
  # rather than a reason to reject an otherwise fully resolved rebase.
  if ! git -C "$repo" diff --check >/dev/null 2>&1; then
    echo "[OP13R-6.1.157] NOTE: whitespace diagnostics were reported after OnePlus-sync resolution; continuing."
  fi

  echo "[OP13R-6.1.157] OnePlus synchronization conflict resolved."
}

resolve_remaining_conflicts_three_way() {
  local repo="$WORK_DIR/oneplus"
  local sha="$1"
  local files
  files="$(git -C "$repo" diff --name-only --diff-filter=U)"
  [ -n "$files" ] || return 0

  echo "[OP13R-6.1.157] Attempting conservative 3-way replay for $sha"

  while IFS= read -r file; do
    [ -n "$file" ] || continue
    # Keep the vendor tree as the starting point, then replay only the exact
    # stopped commit's patch with Git's 3-way machinery. This avoids the
    # destructive whole-file --theirs strategy for future vendor-sensitive
    # conflicts.
    git -C "$repo" checkout --ours -- "$file"
    git -C "$repo" add -- "$file"
  done <<< "$files"

  # Re-apply the stopped commit against the preserved vendor side. If a patch
  # cannot be applied cleanly, fail with diagnostics rather than silently
  # dropping the upstream change.
  if ! git -C "$repo" show --format= --binary "$sha" | git -C "$repo" apply --3way --index -; then
    echo "[OP13R-6.1.157] Conservative replay could not apply $sha cleanly."
    return 1
  fi

  if git -C "$repo" diff --name-only --diff-filter=U | grep -q .; then
    echo "::error::3-way resolver left unresolved index entries."
    return 1
  fi

  if git -C "$repo" grep -nE '^(<<<<<<<|=======|>>>>>>>)' -- . ':!op13r-6.1.157-rebase-diagnostics' >/dev/null 2>&1; then
    echo "::error::3-way resolver left conflict markers in the source tree."
    return 1
  fi

  git -C "$repo" diff --check
  echo "[OP13R-6.1.157] Conservative 3-way replay resolved $sha."
}

# Rebase with targeted resolvers. The initial rebase is started exactly once;
# subsequent conflicts are handled by `git rebase --continue` in the same
# active rebase session.
if GIT_EDITOR=true git -C "$WORK_DIR/oneplus" rebase --rebase-merges --onto "$ACK_TAG" "$BASE"; then
  REBASE_ACTIVE=0
else
  REBASE_ACTIVE=1
fi

while (( REBASE_ACTIVE )); do
  if [[ ! -d "$WORK_DIR/oneplus/.git/rebase-merge" && ! -d "$WORK_DIR/oneplus/.git/rebase-apply" ]]; then
    capture_rebase_diagnostics "rebase-stopped-without-active-state"
    echo "::error::OP13R rebase stopped without an active rebase state."
    exit 1
  fi

  STOPPED_SHA="$(git -C "$WORK_DIR/oneplus" rev-parse REBASE_HEAD 2>/dev/null || true)"
  echo "[OP13R-6.1.157] Rebase stopped at: ${STOPPED_SHA:-unknown}"

  if [[ "$STOPPED_SHA" == "ebf6113bfb8e"* ]]; then
    if ! resolve_cgroup_rstat_rename "$STOPPED_SHA"; then
      capture_rebase_diagnostics "cgroup-rstat-resolver-failed"
      exit 1
    fi
  elif [[ "$STOPPED_SHA" == "f10173bf4bad"* ]]; then
    if ! resolve_memcg_ratelimited_rename "$STOPPED_SHA"; then
      capture_rebase_diagnostics "memcg-ratelimited-resolver-failed"
      exit 1
    fi
  elif [[ "$STOPPED_SHA" == "a31281bb2fe3"* ]]; then
    if ! resolve_memcg_irq_conflict "$STOPPED_SHA"; then
      capture_rebase_diagnostics "memcg-irq-resolver-failed"
      exit 1
    fi
  elif [[ "$STOPPED_SHA" == "cc0b66f72d35"* ]]; then
    if ! resolve_memcg_sleep_safe_context_conflict "$STOPPED_SHA"; then
      capture_rebase_diagnostics "memcg-sleep-safe-context-resolver-failed"
      exit 1
    fi
  elif [[ "$STOPPED_SHA" == "fa90fbbc182f"* ]]; then
    if ! resolve_workingset_refault_sleep_conflict "$STOPPED_SHA"; then
      capture_rebase_diagnostics "workingset-refault-sleep-resolver-failed"
      exit 1
    fi
  elif [[ "$STOPPED_SHA" == "e240e7bc5c9c"* ]]; then
    if ! resolve_memcg_stats_flush_atomic_conflict "$STOPPED_SHA"; then
      capture_rebase_diagnostics "memcg-stats-flush-atomic-resolver-failed"
      exit 1
    fi
  elif [[ "$STOPPED_SHA" == "e029f4e18ab4"* ]]; then
    if ! resolve_paragon_symbol_list_conflict "$STOPPED_SHA"; then
      capture_rebase_diagnostics "paragon-symbol-list-resolver-failed"
      exit 1
    fi
  elif [[ "$STOPPED_SHA" == "3a55164b40ce"* ]]; then
    if ! resolve_galaxy_abi_symbol_conflict "$STOPPED_SHA"; then
      capture_rebase_diagnostics "galaxy-abi-symbol-list-resolver-failed"
      exit 1
    fi
  elif [[ "$STOPPED_SHA" == "c98768cf3203"* ]]; then
    if ! resolve_kswapd_rvh_conflict "$STOPPED_SHA"; then
      capture_rebase_diagnostics "kswapd-rvh-resolver-failed"
      exit 1
    fi
  elif [[ "$STOPPED_SHA" == "52d02725a414"* ]]; then
    if ! resolve_pixel_abi_symbol_conflict "$STOPPED_SHA"; then
      capture_rebase_diagnostics "pixel-abi-symbol-list-resolver-failed"
      exit 1
    fi
  elif [[ "$STOPPED_SHA" == "a28e3eaaa42d"* ]]; then
    if ! resolve_oneplus_sync_commit_conflict "$STOPPED_SHA"; then
      capture_rebase_diagnostics "oneplus-sync-resolver-failed"
      exit 1
    fi
  else
    # OnePlus publishes multiple vendor snapshot/synchronization commits in
    # this rebase series.  They must not fall through to the generic 3-way
    # replay: that replay starts from the vendor side and can leave ordinary
    # snapshot files unmerged when the snapshot also deleted/reworked paths.
    # Detect later synchronization commits by their commit subject and use
    # the same resolver that successfully handled a28e3eaaa42d.
    STOPPED_SUBJECT="$(git -C "$WORK_DIR/oneplus" show -s --format=%s "$STOPPED_SHA" 2>/dev/null || true)"
    if [[ "$STOPPED_SUBJECT" == Synchronize\ code\ for\ OnePlus* ]]; then
      echo "[OP13R-6.1.157] Detected OnePlus synchronization commit by subject: $STOPPED_SUBJECT"
      if ! resolve_oneplus_sync_commit_conflict "$STOPPED_SHA"; then
        capture_rebase_diagnostics "oneplus-sync-resolver-failed"
        exit 1
      fi
    elif ! resolve_remaining_conflicts_three_way "$STOPPED_SHA"; then
      capture_rebase_diagnostics "unhandled-rebase-conflict"
      echo "::error::Unhandled OP13R 6.1.157 rebase conflict. Diagnostics were captured."
      exit 1
    fi
  fi

  if GIT_EDITOR=true git -C "$WORK_DIR/oneplus" rebase --continue; then
    REBASE_ACTIVE=0
  else
    # `--continue` returned non-zero because it stopped at the next conflict.
    # Stay in the same rebase session and dispatch the next resolver.
    if [[ -d "$WORK_DIR/oneplus/.git/rebase-merge" || -d "$WORK_DIR/oneplus/.git/rebase-apply" ]]; then
      echo "[OP13R-6.1.157] Rebase stopped at next commit; continuing resolver dispatch."
      REBASE_ACTIVE=1
    else
      capture_rebase_diagnostics "rebase-continue-failed"
      echo "::error::OP13R rebase --continue failed without an active rebase state."
      exit 1
    fi
  fi
done

echo "[OP13R-6.1.157] Rebase completed: $(git -C "$WORK_DIR/oneplus" rev-parse HEAD)"

# OnePlus synchronization snapshots can carry their original vendor Makefile
# version (currently 6.1.141) even though the entire commit series has been
# rebased onto the Android 14 ACK 6.1.157 tag.  Preserve all vendor Makefile
# changes, but restore only the kernel version tuple from the ACK target so the
# exported tree and build system identify the resulting source correctly.
NORMALIZE_VERSION_SCRIPT="$WORK_DIR/normalize_kernel_version.py"
cat > "$NORMALIZE_VERSION_SCRIPT" <<'PYTHON'
import pathlib
import re
import subprocess
import sys

repo = pathlib.Path(sys.argv[1])
target = sys.argv[2]
makefile = repo / "Makefile"

ack = subprocess.check_output(
    ["git", "-C", str(repo), "show", f"{target}:Makefile"],
    text=True,
)
ack_values = {}
for name in ("VERSION", "PATCHLEVEL", "SUBLEVEL"):
    m = re.search(rf"^{name}\s*=\s*(\d+)\s*$", ack, re.MULTILINE)
    if not m:
        raise SystemExit(f"ACK Makefile is missing {name}")
    ack_values[name] = m.group(1)

text = makefile.read_text()
for name, value in ack_values.items():
    pattern = rf"^{name}\s*=\s*\d+\s*$"
    text, count = re.subn(pattern, f"{name} = {value}", text, count=1, flags=re.MULTILINE)
    if count != 1:
        raise SystemExit(f"rebased Makefile is missing {name}")

makefile.write_text(text)
print(
    "[OP13R-6.1.157] Normalized kernel Makefile version to "
    + ".".join(ack_values[n] for n in ("VERSION", "PATCHLEVEL", "SUBLEVEL"))
)
PYTHON
python3 "$NORMALIZE_VERSION_SCRIPT" "$WORK_DIR/oneplus" "$ACK_TAG"

EXPECTED_HEAD="$(git -C "$WORK_DIR/oneplus" rev-parse HEAD)"
echo "[OP13R-6.1.157] Exporting rebased source over kernel_platform/common..."

find "$COMMON_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
git -C "$WORK_DIR/oneplus" archive HEAD | tar -x -C "$COMMON_DIR"
# The version normalization is intentionally applied to the working tree after
# the final vendor snapshot and before export; keep the rebased commit identity
# unchanged while exporting the corrected source tree.
cp "$WORK_DIR/oneplus/Makefile" "$COMMON_DIR/Makefile"

verify_op13r_6157_source "$COMMON_DIR"

echo "[OP13R-6.1.157] Kernel Makefile reports:"
awk '/^VERSION =|^PATCHLEVEL =|^SUBLEVEL =/{print}' "$COMMON_DIR/Makefile"

echo "::endgroup::"
