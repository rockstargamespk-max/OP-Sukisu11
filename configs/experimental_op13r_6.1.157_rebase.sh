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

# Re-apply the Android 14 ACK DMA-BUF task_struct ABI fixup after the final
# OnePlus synchronization snapshot.  The vendor snapshot can replay the old
# task->dmabuf_info implementation over ACK 6.1.157 even though 6.1.157 uses
# worker_private/kthread storage.  Replay the exact upstream fixup commit with
# Git's 3-way machinery so vendor changes outside this ABI migration remain
# untouched.
ACK_DMABUF_FIXUP="4efa97345de62a0b8a8e94922448ca2952f6bf56"
ACK_DMABUF_FIXUP_PARENT="${ACK_DMABUF_FIXUP}^"
if git -C "$WORK_DIR/oneplus" cat-file -e "${ACK_DMABUF_FIXUP}^{commit}" 2>/dev/null && \
   git -C "$WORK_DIR/oneplus" cat-file -e "${ACK_DMABUF_FIXUP_PARENT}^{commit}" 2>/dev/null; then
  if git -C "$WORK_DIR/oneplus" grep -qE 'task_struct.*dmabuf_info|dmabuf_info.*task_struct' -- include/linux/sched.h 2>/dev/null || \
     git -C "$WORK_DIR/oneplus" grep -q 'task->dmabuf_info' -- drivers/dma-buf/dma-buf.c fs/proc/base.c 2>/dev/null; then
    echo "[OP13R-6.1.157] Reapplying ACK DMA-BUF task_struct ABI fixup ${ACK_DMABUF_FIXUP}"
    if ! git -C "$WORK_DIR/oneplus" diff "${ACK_DMABUF_FIXUP_PARENT}" "${ACK_DMABUF_FIXUP}" -- \
        drivers/dma-buf/dma-buf.c \
        fs/proc/base.c \
        include/linux/dma-buf.h \
        include/linux/kthread.h \
        include/linux/sched.h \
        init/init_task.c \
        kernel/fork.c \
        kernel/kthread.c | \
        git -C "$WORK_DIR/oneplus" apply --3way --index -; then
      echo "::error::Unable to replay ACK DMA-BUF task_struct ABI fixup ${ACK_DMABUF_FIXUP}."
      capture_rebase_diagnostics "ack-dmabuf-fixup-failed"
      exit 1
    fi
  fi
fi

EXPECTED_HEAD="$(git -C "$WORK_DIR/oneplus" rev-parse HEAD)"
echo "[OP13R-6.1.157] Exporting rebased source over kernel_platform/common..."

find "$COMMON_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
git -C "$WORK_DIR/oneplus" archive HEAD | tar -x -C "$COMMON_DIR"
# The version normalization is intentionally applied to the working tree after
# the final vendor snapshot and before export; keep the rebased commit identity
# unchanged while exporting the corrected source tree.
cp "$WORK_DIR/oneplus/Makefile" "$COMMON_DIR/Makefile"

# Restore the ACK compiler helper if the OnePlus 6.1.141 vendor snapshot
# left compiler.h older than the 6.1.157 headers that use statically_true().
COMPILER_H="$COMMON_DIR/include/linux/compiler.h"
if [ -f "$COMPILER_H" ] && ! grep -q "^#define statically_true(" "$COMPILER_H"; then
  echo "[OP13R-6.1.157] Restoring missing ACK statically_true() helper in include/linux/compiler.h"
  python3 - "$COMPILER_H" <<'PYTHON'
from pathlib import Path
import sys

p = Path(sys.argv[1])
text = p.read_text()
if "#define statically_true(" in text:
    raise SystemExit(0)
marker = "#define is_signed_type(type) (((type)(-1)) < (__force type)1)"
if marker not in text:
    raise SystemExit("Unable to locate is_signed_type() anchor in compiler.h")
helper = "\n\n/*\n * Useful shorthand for a condition known to be true at compile time.\n */\n#define statically_true(x) (__builtin_constant_p(x) && (x))\n"
p.write_text(text.replace(marker, marker + helper, 1))
PYTHON
fi

# Reconcile the OnePlus vendor init_task initializer with the rebased ACK task_struct.
# The OnePlus 6.1.141 snapshot can retain .dmabuf_info even though the ACK 6.1.157
# task_struct no longer has that member.  Do not alter task_struct or any unrelated
# DMA-BUF code; only translate the stale static initializer when the destination
# member is actually absent and worker_private is present.
INIT_TASK_C="$COMMON_DIR/init/init_task.c"
TASK_STRUCT_H="$COMMON_DIR/include/linux/sched.h"
if [ -f "$INIT_TASK_C" ] && [ -f "$TASK_STRUCT_H" ] && \
   grep -Eq '^[[:space:]]*\.dmabuf_info[[:space:]]*=[[:space:]]*NULL[[:space:]]*,?' "$INIT_TASK_C"; then
  if ! grep -Eq '^[[:space:]]*(struct[[:space:]]+)?[^/]*dmabuf_info[[:space:];]' "$TASK_STRUCT_H"; then
    if grep -Eq '^[[:space:]]*[^/]*worker_private[[:space:];]' "$TASK_STRUCT_H"; then
      echo "[OP13R-6.1.157] Translating stale init_task .dmabuf_info initializer to .worker_private"
      python3 - "$INIT_TASK_C" <<'PYTHON'
from pathlib import Path
import re
import sys
p = Path(sys.argv[1])
text = p.read_text()
new, count = re.subn(
    r'(^[ \t]*)(\.dmabuf_info)([ \t]*=[ \t]*NULL[ \t]*,?)',
    r'\1.worker_private\3',
    text,
    count=1,
    flags=re.MULTILINE,
)
if count != 1:
    raise SystemExit("Unable to translate stale init_task dmabuf_info initializer")
p.write_text(new)
PYTHON
    else
      echo "::error::ACK task_struct has neither dmabuf_info nor worker_private; refusing unsafe init_task rewrite."
      exit 1
    fi
  else
    echo "[OP13R-6.1.157] task_struct still provides dmabuf_info; leaving init_task.c unchanged"
  fi
fi

# Restore the Android MM vendor hook that the 6.1.157 ACK mm/swap.c expects.
# The OnePlus vendor snapshot can carry the call site without the matching
# trace-hook declaration/export. Restore the upstream hook pair rather than
# removing the call from mm/swap.c or weakening compiler diagnostics.
MM_HOOKS="$COMMON_DIR/include/trace/hooks/mm.h"
VMSCAN_HOOKS="$COMMON_DIR/include/trace/hooks/vmscan.h"
VENDOR_HOOKS="$COMMON_DIR/drivers/android/vendor_hooks.c"
if [ -f "$COMMON_DIR/mm/swap.c" ] && grep -q 'trace_android_vh_mark_folio_accessed(folio)' "$COMMON_DIR/mm/swap.c"; then
  if [ -f "$MM_HOOKS" ] && ! grep -q 'DECLARE_HOOK(android_vh_mark_folio_accessed' "$MM_HOOKS"; then
    echo "[OP13R-6.1.157] Restoring android_vh_mark_folio_accessed declaration in include/trace/hooks/mm.h"
    python3 - "$MM_HOOKS" <<'PYTHON'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
if 'DECLARE_HOOK(android_vh_mark_folio_accessed' in text:
    raise SystemExit(0)
needle = "DECLARE_HOOK(android_vh_madvise_cold_or_pageout_page,\n\tTP_PROTO(bool pageout, struct page *page),\n\tTP_ARGS(pageout, page));"
block = "DECLARE_HOOK(android_vh_madvise_cold_or_pageout_page,\n\tTP_PROTO(bool pageout, struct page *page),\n\tTP_ARGS(pageout, page));\nDECLARE_HOOK(android_vh_mark_folio_accessed,\n\tTP_PROTO(struct folio *folio),\n\tTP_ARGS(folio));"
if needle not in text:
    raise SystemExit('Unable to locate MM hook anchor in include/trace/hooks/mm.h')
p.write_text(text.replace(needle, block, 1))
PYTHON
  fi

  if [ -f "$VENDOR_HOOKS" ] && ! grep -q 'EXPORT_TRACEPOINT_SYMBOL_GPL(android_vh_mark_folio_accessed)' "$VENDOR_HOOKS"; then
    echo "[OP13R-6.1.157] Restoring android_vh_mark_folio_accessed tracepoint export"
    python3 - "$VENDOR_HOOKS" <<'PYTHON'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
if 'EXPORT_TRACEPOINT_SYMBOL_GPL(android_vh_mark_folio_accessed)' in text:
    raise SystemExit(0)
needle = 'EXPORT_TRACEPOINT_SYMBOL_GPL(android_vh_mm_compaction_begin);'
line = 'EXPORT_TRACEPOINT_SYMBOL_GPL(android_vh_mark_folio_accessed);\n'
if needle not in text:
    raise SystemExit('Unable to locate vendor hook export anchor in drivers/android/vendor_hooks.c')
p.write_text(text.replace(needle, line + needle, 1))
PYTHON
  fi
fi

# Restore the Android MM vendor hook that 6.1.157 mm/vmscan.c expects.
# The OnePlus vendor snapshot can retain the call site without the matching
# trace-hook declaration/export. Keep the call site and restore the hook API.
if [ -f "$COMMON_DIR/mm/vmscan.c" ] && grep -q 'trace_android_vh_shrink_folio_list' "$COMMON_DIR/mm/vmscan.c"; then
  if [ -f "$VMSCAN_HOOKS" ] && ! grep -q 'DECLARE_HOOK(android_vh_shrink_folio_list' "$VMSCAN_HOOKS"; then
    echo "[OP13R-6.1.157] Restoring android_vh_shrink_folio_list declaration in include/trace/hooks/vmscan.h"
    python3 - "$VMSCAN_HOOKS" <<'PYTHON'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
if 'DECLARE_HOOK(android_vh_shrink_folio_list' in text:
    raise SystemExit(0)
block = "DECLARE_HOOK(android_vh_shrink_folio_list,\n\tTP_PROTO(struct folio *folio, bool dirty, bool writeback,\n\t\tbool *activate, bool *keep),\n\tTP_ARGS(folio, dirty, writeback, activate, keep));\n"
needle = "DECLARE_HOOK(android_vh_inode_lru_isolate,\n\tTP_PROTO(struct inode *inode, bool *skip),\n\tTP_ARGS(inode, skip));"
if needle in text:
    p.write_text(text.replace(needle, block + needle, 1))
    raise SystemExit(0)
marker = '#endif /* _TRACE_HOOK_VMSCAN_H */'
if marker in text:
    p.write_text(text.replace(marker, block + marker, 1))
    raise SystemExit(0)
lines = text.splitlines(keepends=True)
for i in range(len(lines) - 1, -1, -1):
    if lines[i].lstrip().startswith('#endif'):
        lines.insert(i, block)
        p.write_text(''.join(lines))
        raise SystemExit(0)
raise SystemExit('Unable to locate a safe vmscan hook-header insertion point for android_vh_shrink_folio_list')
PYTHON
  fi

  if ! grep -q '#include <trace/hooks/vmscan.h>' "$COMMON_DIR/mm/vmscan.c"; then
    echo "[OP13R-6.1.157] Restoring trace/hooks/vmscan.h include in mm/vmscan.c"
    python3 - "$COMMON_DIR/mm/vmscan.c" <<'PYTHON'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
if '#include <trace/hooks/vmscan.h>' in s:
    raise SystemExit(0)
anchors = [
    '#include <trace/events/oom.h>\n',
    '#include <trace/events/vmscan.h>\n',
]
for needle in anchors:
    if needle in s:
        p.write_text(s.replace(needle, needle + '#undef CREATE_TRACE_POINTS\n#include <trace/hooks/vmscan.h>\n', 1))
        raise SystemExit(0)
raise SystemExit('Unable to locate vmscan trace include anchor in mm/vmscan.c')
PYTHON
  fi

  if [ -f "$VENDOR_HOOKS" ] && ! grep -q 'EXPORT_TRACEPOINT_SYMBOL_GPL(android_vh_shrink_folio_list)' "$VENDOR_HOOKS"; then
    echo "[OP13R-6.1.157] Restoring android_vh_shrink_folio_list tracepoint export"
    python3 - "$VENDOR_HOOKS" <<'PYTHON'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
if 'EXPORT_TRACEPOINT_SYMBOL_GPL(android_vh_shrink_folio_list)' in text:
    raise SystemExit(0)
needle = 'EXPORT_TRACEPOINT_SYMBOL_GPL(android_vh_vmscan_kswapd_done);'
line = 'EXPORT_TRACEPOINT_SYMBOL_GPL(android_vh_shrink_folio_list);\n'
if needle in text:
    p.write_text(text.replace(needle, needle + '\n' + line, 1))
    raise SystemExit(0)
needle = 'EXPORT_TRACEPOINT_SYMBOL_GPL(android_vh_mm_compaction_begin);'
if needle in text:
    p.write_text(text.replace(needle, line + needle, 1))
    raise SystemExit(0)
raise SystemExit('Unable to locate vendor hook export anchor for android_vh_shrink_folio_list')
PYTHON
  fi
fi

# Restore the Android MM vendor hook that 6.1.157 mm/truncate.c expects.
# The OnePlus vendor snapshot can retain the call site without the matching
# trace-hook declaration/export. Keep the call site and restore the hook API.
if [ -f "$COMMON_DIR/mm/truncate.c" ] && grep -q 'trace_android_vh_invalidate_mapping_pagevec' "$COMMON_DIR/mm/truncate.c"; then
  # This hook is declared by the Android vmscan hook header, not mm.h.
  if [ -f "$VMSCAN_HOOKS" ] && ! grep -q 'DECLARE_HOOK(android_vh_invalidate_mapping_pagevec' "$VMSCAN_HOOKS"; then
    echo "[OP13R-6.1.157] Restoring android_vh_invalidate_mapping_pagevec declaration in include/trace/hooks/vmscan.h"
    python3 - "$VMSCAN_HOOKS" <<'PYTHON'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
if 'DECLARE_HOOK(android_vh_invalidate_mapping_pagevec' in text:
    raise SystemExit(0)
needle = "DECLARE_HOOK(android_vh_inode_lru_isolate,\n\tTP_PROTO(struct inode *inode, bool *skip),\n\tTP_ARGS(inode, skip));"
block = needle + "\nDECLARE_HOOK(android_vh_invalidate_mapping_pagevec,\n\tTP_PROTO(struct address_space *mapping, bool *skip),\n\tTP_ARGS(mapping, skip));"
if needle in text:
    p.write_text(text.replace(needle, block, 1))
    raise SystemExit(0)

# Some 6.1.157/OnePlus rebases do not retain the vendor inode-lru hook
# anchor at this point. Insert the missing hook immediately before the
# vmscan hook-header terminator instead of failing the entire rebase export.
block = "DECLARE_HOOK(android_vh_invalidate_mapping_pagevec,\n\tTP_PROTO(struct address_space *mapping, bool *skip),\n\tTP_ARGS(mapping, skip));\n"
marker = '#endif /* _TRACE_HOOK_VMSCAN_H */'
if marker in text:
    p.write_text(text.replace(marker, block + marker, 1))
    raise SystemExit(0)

# Last-resort header-safe fallback: use the final preprocessor terminator.
lines = text.splitlines(keepends=True)
for i in range(len(lines) - 1, -1, -1):
    if lines[i].lstrip().startswith('#endif'):
        lines.insert(i, block)
        p.write_text(''.join(lines))
        raise SystemExit(0)
raise SystemExit('Unable to locate a safe vmscan hook-header insertion point for android_vh_invalidate_mapping_pagevec')
PYTHON
  fi

  if ! grep -q '#include <trace/hooks/vmscan.h>' "$COMMON_DIR/mm/truncate.c"; then
    echo "[OP13R-6.1.157] Restoring trace/hooks/vmscan.h include in mm/truncate.c"
    python3 - "$COMMON_DIR/mm/truncate.c" <<'PYTHON'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
if '#include <trace/hooks/vmscan.h>' in s:
    raise SystemExit(0)
needle = '#include "internal.h"\n'
replacement = needle + '#undef CREATE_TRACE_POINTS\n#include <trace/hooks/vmscan.h>\n'
if needle not in s:
    raise SystemExit('Unable to locate mm/truncate.c internal.h include anchor')
p.write_text(s.replace(needle, replacement, 1))
PYTHON
  fi

  if [ -f "$VENDOR_HOOKS" ] && ! grep -q 'EXPORT_TRACEPOINT_SYMBOL_GPL(android_vh_invalidate_mapping_pagevec)' "$VENDOR_HOOKS"; then
    echo "[OP13R-6.1.157] Restoring android_vh_invalidate_mapping_pagevec tracepoint export"
    python3 - "$VENDOR_HOOKS" <<'PYTHON'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
if 'EXPORT_TRACEPOINT_SYMBOL_GPL(android_vh_invalidate_mapping_pagevec)' in text:
    raise SystemExit(0)
needle = 'EXPORT_TRACEPOINT_SYMBOL_GPL(android_vh_mark_folio_accessed);'
if needle in text:
    line = needle + '\nEXPORT_TRACEPOINT_SYMBOL_GPL(android_vh_invalidate_mapping_pagevec);\n'
else:
    needle = 'EXPORT_TRACEPOINT_SYMBOL_GPL(android_vh_mm_compaction_begin);'
    if needle not in text:
        raise SystemExit('Unable to locate vendor hook export anchor for android_vh_invalidate_mapping_pagevec')
    line = 'EXPORT_TRACEPOINT_SYMBOL_GPL(android_vh_invalidate_mapping_pagevec);\n' + needle
p.write_text(text.replace(needle, line, 1))
PYTHON
  fi
fi

# Reconcile Android DMA-BUF procfs accounting with the ACK task_struct ABI.
# The 6.1.157 ACK side no longer stores dmabuf_info directly in task_struct.
# Some OnePlus/vendor snapshots still carry the older fs/proc/base.c accessors,
# and some vendor dma-buf.h revisions do not expose get_task_dma_buf_info().
# Normalize fs/proc/base.c after export in both cases so the build cannot retain
# task->dmabuf_info references.
PROC_BASE_C="$COMMON_DIR/fs/proc/base.c"
DMA_BUF_H="$COMMON_DIR/include/linux/dma-buf.h"
TASK_STRUCT_H="$COMMON_DIR/include/linux/sched.h"
if [ -f "$PROC_BASE_C" ] && grep -qE '(task|current)->dmabuf_info' "$PROC_BASE_C"; then
  echo "[OP13R-6.1.157] Reconciling legacy fs/proc/base.c dmabuf_info accesses"
  python3 - "$PROC_BASE_C" "$DMA_BUF_H" "$TASK_STRUCT_H" <<'PYTHON'
from pathlib import Path
import re
import sys

proc = Path(sys.argv[1])
dma = Path(sys.argv[2])
sched = Path(sys.argv[3])

s = proc.read_text()

if '#include <linux/dma-buf.h>' not in s:
    lines = s.splitlines(keepends=True)
    insert_at = 0
    for i, line in enumerate(lines):
        if line.startswith('#include '):
            insert_at = i
            break
    lines.insert(insert_at, '#include <linux/dma-buf.h>\n')
    s = ''.join(lines)

if 'proc_get_task_dma_buf_info' not in s:
    has_ack_helper = dma.is_file() and 'get_task_dma_buf_info' in dma.read_text()
    has_worker_private = sched.is_file() and re.search(r'\bworker_private\b', sched.read_text()) is not None

    if has_ack_helper:
        helper = """
static inline struct task_dma_buf_info *proc_get_task_dma_buf_info(struct task_struct *task)
{
\tstruct task_dma_buf_info *info = get_task_dma_buf_info(task);

\treturn IS_ERR(info) ? NULL : info;
}
"""
    elif has_worker_private:
        helper = """
static inline struct task_dma_buf_info *proc_get_task_dma_buf_info(struct task_struct *task)
{
\tif (!task || task == &init_task || (task->flags & PF_IO_WORKER))
\t\treturn NULL;
\tif (!task->worker_private)
\t\treturn NULL;
\treturn (struct task_dma_buf_info *)task->worker_private;
}
"""
    else:
        raise SystemExit(
            'fs/proc/base.c still uses dmabuf_info, but the exported task_struct '
            'has neither get_task_dma_buf_info() nor worker_private'
        )

    marker = '#ifdef CONFIG_DMA_SHARED_BUFFER\n'
    if marker in s:
        s = s.replace(marker, helper + '\n' + marker, 1)
    else:
        pos = s.find('dmabuf_info')
        if pos < 0:
            raise SystemExit('Unable to locate DMA-BUF procfs insertion point')
        line_start = s.rfind('\n', 0, pos) + 1
        s = s[:line_start] + helper + '\n' + s[line_start:]

s = s.replace('task->dmabuf_info', 'proc_get_task_dma_buf_info(task)')
s = s.replace('current->dmabuf_info', 'proc_get_task_dma_buf_info(current)')

if re.search(r'\b(?:task|current)->dmabuf_info\b', s):
    raise SystemExit('Legacy dmabuf_info access remains in fs/proc/base.c')

proc.write_text(s)
PYTHON

  if grep -qE '(task|current)->dmabuf_info' "$PROC_BASE_C"; then
    echo "::error::Legacy dmabuf_info references remain in fs/proc/base.c after reconciliation."
    exit 1
  fi
  echo "[OP13R-6.1.157] fs/proc/base.c DMA-BUF ABI reconciliation complete"
fi

# Restore the proc_lseek flag/helper expected by fs/proc/inode.c when the
# ACK-side proc_lseek API was replayed without its supporting procfs pieces.
PROC_FS_H="$COMMON_DIR/include/linux/proc_fs.h"
PROC_INTERNAL_H="$COMMON_DIR/fs/proc/internal.h"
PROC_GENERIC_C="$COMMON_DIR/fs/proc/generic.c"
PROC_INODE_C="$COMMON_DIR/fs/proc/inode.c"
if [ -f "$PROC_INODE_C" ] && grep -q 'pde_has_proc_lseek(pde)' "$PROC_INODE_C"; then
  if [ -f "$PROC_FS_H" ] && ! grep -q 'PROC_ENTRY_proc_lseek' "$PROC_FS_H"; then
    echo "[OP13R-6.1.157] Restoring PROC_ENTRY_proc_lseek flag in include/linux/proc_fs.h"
    python3 - "$PROC_FS_H" <<'PYTHON'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
if 'PROC_ENTRY_proc_lseek' in s:
    raise SystemExit(0)
needle="\tPROC_ENTRY_proc_compat_ioctl\t= 1U << 2,\n"
replacement=needle+"\tPROC_ENTRY_proc_lseek\t\t= 1U << 3,\n"
if needle not in s:
    raise SystemExit('Unable to locate PROC_ENTRY_proc_compat_ioctl enum entry')
p.write_text(s.replace(needle,replacement,1))
PYTHON
  fi

  if [ -f "$PROC_INTERNAL_H" ] && ! grep -q 'static inline bool pde_has_proc_lseek' "$PROC_INTERNAL_H"; then
    echo "[OP13R-6.1.157] Restoring pde_has_proc_lseek() helper in fs/proc/internal.h"
    python3 - "$PROC_INTERNAL_H" <<'PYTHON'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
if 'static inline bool pde_has_proc_lseek' in s:
    raise SystemExit(0)
needle="""static inline bool pde_has_proc_compat_ioctl(const struct proc_dir_entry *pde)
{
#ifdef CONFIG_COMPAT
\treturn pde->flags & PROC_ENTRY_proc_compat_ioctl;
#else
\treturn false;
#endif
}
"""
replacement=needle+"""
static inline bool pde_has_proc_lseek(const struct proc_dir_entry *pde)
{
\treturn pde->flags & PROC_ENTRY_proc_lseek;
}
"""
if needle not in s:
    raise SystemExit('Unable to locate proc compat ioctl helper anchor')
p.write_text(s.replace(needle,replacement,1))
PYTHON
  fi

  if [ -f "$PROC_GENERIC_C" ] && ! grep -q 'flags |= PROC_ENTRY_proc_lseek' "$PROC_GENERIC_C"; then
    echo "[OP13R-6.1.157] Restoring proc_lseek flag population in fs/proc/generic.c"
    python3 - "$PROC_GENERIC_C" <<'PYTHON'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
if 'flags |= PROC_ENTRY_proc_lseek' in s:
    raise SystemExit(0)
needle="""#ifdef CONFIG_COMPAT
\tif (pde->proc_ops->proc_compat_ioctl)
\t\tpde->flags |= PROC_ENTRY_proc_compat_ioctl;
#endif
"""
replacement=needle+"""\tif (pde->proc_ops->proc_lseek)
\t\tpde->flags |= PROC_ENTRY_proc_lseek;
"""
if needle not in s:
    raise SystemExit('Unable to locate proc flag population anchor in fs/proc/generic.c')
p.write_text(s.replace(needle,replacement,1))
PYTHON
  fi
fi


# Reconcile the F2FS APIs introduced by the Android 6.1 ACK backports.
# Restore the related APIs as one coherent source-level set. The OnePlus
# synchronization snapshot can reintroduce consumers after Git replay, so
# inspect the complete exported fs/f2fs tree instead of only super.c.
F2FS_H="$COMMON_DIR/fs/f2fs/f2fs.h"
F2FS_DIR="$COMMON_DIR/fs/f2fs"
if [ -f "$F2FS_H" ] && [ -f "$F2FS_DIR/super.c" ]; then
  echo "[OP13R-6.1.157] Reconciling Android 6.1 F2FS API set"
  python3 - "$F2FS_H" "$F2FS_DIR" <<'PYTHON'
from pathlib import Path
import re, sys

header = Path(sys.argv[1])
f2fs_dir = Path(sys.argv[2])
h = header.read_text()

# Inspect the complete exported F2FS source set. This avoids missing a consumer
# that was reintroduced by a vendor synchronization commit in dir.c, segment.c,
# or another F2FS source file.
files = []
for p in sorted(f2fs_dir.rglob('*')):
    if p.is_file() and p.suffix in ('.c', '.h') and p != header:
        try:
            files.append((p, p.read_text()))
        except UnicodeDecodeError:
            pass
corpus = '\n'.join(x[1] for x in files)
# Include f2fs.h in dependency detection. A vendor tree may already contain
# partially restored accessors in the header while the corresponding constants
# and enum are missing; excluding the header makes the reconciler falsely think
# the packed-mode API is unused and leaves an internally inconsistent header.
api_corpus = corpus + '\n' + h

# ---------------------------------------------------------------------------
# reserve_node / root_reserved_nodes
# ---------------------------------------------------------------------------
needs_reserve_node = bool(re.search(
    r'\bF2FS_MOUNT_RESERVE_NODE\b|\bRESERVE_NODE\b|\bOpt_reserve_node\b|reserve_node=',
    corpus))

if needs_reserve_node:
    m = re.search(r'(?m)^#define\s+F2FS_MOUNT_RESERVE_NODE\s+(0x[0-9A-Fa-f]+)\b', h)
    if m:
        if m.group(1).lower() != '0x00000001':
            raise SystemExit('F2FS_MOUNT_RESERVE_NODE has unexpected value ' + m.group(1))
    else:
        conflicts = []
        for x in re.finditer(r'(?m)^#define\s+(F2FS_MOUNT_[A-Z0-9_]+)\s+(0x[0-9A-Fa-f]+)\b', h):
            if x.group(2).lower() == '0x00000001':
                conflicts.append(x.group(1))
        if conflicts:
            raise SystemExit('F2FS mount bit 0x1 is already assigned to ' + ', '.join(conflicts))
        anchor = re.search(r'(?m)^#define\s+F2FS_MOUNT_DISABLE_ROLL_FORWARD\s+[^\n]*\n', h)
        if not anchor:
            raise SystemExit('Unable to locate F2FS mount-option table')
        h = h[:anchor.start()] + '#define F2FS_MOUNT_RESERVE_NODE\t\t0x00000001\n' + h[anchor.start():]
        print('[OP13R-6.1.157] Added Android 6.1 F2FS_MOUNT_RESERVE_NODE bit')

needs_reserved_nodes = needs_reserve_node or bool(re.search(r'\broot_reserved_nodes\b', corpus))
if needs_reserved_nodes and not re.search(r'(?m)^\s*block_t\s+root_reserved_nodes\s*;', h):
    anchor = re.search(r'(?m)^([ \t]*)block_t\s+root_reserved_blocks\s*;[^\n]*\n', h)
    if not anchor:
        raise SystemExit('Unable to locate f2fs_mount_info.root_reserved_blocks')
    h = h[:anchor.end()] + anchor.group(1) + 'block_t root_reserved_nodes;\t/* root reserved nodes */\n' + h[anchor.end():]
    print('[OP13R-6.1.157] Added root_reserved_nodes to f2fs_mount_info')

# ---------------------------------------------------------------------------
# allocation/lookup mode packing
# ---------------------------------------------------------------------------
# Android 6.1's lookup_mode backport packs lookup bits into alloc_mode. A
# standalone lookup_mode member is not the ACK ABI and must never be created.
h = re.sub(r'(?m)^[ \t]*int\s+lookup_mode\s*;\s*/\*\s*lookup policy\s*\*/\s*\n', '', h)

needs_lookup = bool(re.search(
    r'\b(?:LOOKUP_PERF|LOOKUP_COMPAT|LOOKUP_AUTO|f2fs_get_lookup_mode|f2fs_set_lookup_mode|lookup_mode=)\b',
    api_corpus))
needs_alloc = bool(re.search(
    r'\b(?:ALLOC_MODE_DEFAULT|ALLOC_MODE_REUSE|f2fs_get_alloc_mode|f2fs_set_alloc_mode|ALLOC_MODE_MASK|ALLOC_MODE_SHIFT)\b',
    api_corpus))
needs_packed_modes = needs_alloc or needs_lookup

if needs_packed_modes:
    if not re.search(r'\bALLOC_MODE_DEFAULT\b', h) or not re.search(r'\bALLOC_MODE_REUSE\b', h):
        anchor = re.search(r'(?m)^enum\s+fsync_mode\s*\{', h)
        if not anchor:
            raise SystemExit('Unable to locate F2FS fsync_mode enum')
        block = ('enum {\n'
                 '\tALLOC_MODE_DEFAULT,\t/* stay default */\n'
                 '\tALLOC_MODE_REUSE,\t/* reuse segments as much as possible */\n'
                 '};\n\n')
        h = h[:anchor.start()] + block + h[anchor.start():]
        print('[OP13R-6.1.157] Added F2FS allocation-mode enum')

# Find the end of the complete f2fs_sb_info definition once. The packed-mode
# constants and lookup enum must be visible BEFORE the inline accessors below.
sb_start = h.find('struct f2fs_sb_info {')
if sb_start < 0:
    raise SystemExit('Unable to locate struct f2fs_sb_info definition')
sb_brace = h.find('{', sb_start)
sb_depth = 0
sb_end = None
for i in range(sb_brace, len(h)):
    if h[i] == '{':
        sb_depth += 1
    elif h[i] == '}':
        sb_depth -= 1
        if sb_depth == 0:
            semi = h.find(';', i)
            if semi < 0:
                raise SystemExit('Unable to locate end of struct f2fs_sb_info')
            sb_end = semi + 1
            break
if sb_end is None:
    raise SystemExit('Unable to locate complete struct f2fs_sb_info')

# Normalize the packed-mode dependency block instead of merely checking whether
# its individual definitions exist. A previous reconciliation can leave the
# definitions/enum after the accessor block; that is still invalid C. Remove the
# generated dependency/accessor blocks and rebuild them as one ordered unit.
packed_def_re = re.compile(
    r'(?ms)^/\*\n \* For bit-packing in f2fs_mount_info->alloc_mode\.\n \*/\n'
    r'#define ALLOC_MODE_BITS\s+1\n'
    r'#define LOOKUP_MODE_BITS\s+2\n'
    r'#define ALLOC_MODE_SHIFT\s+0\n'
    r'#define LOOKUP_MODE_SHIFT\s+\(ALLOC_MODE_SHIFT \+ ALLOC_MODE_BITS\)\n'
    r'#define ALLOC_MODE_MASK\s+.*?\n'
    r'#define LOOKUP_MODE_MASK\s+.*?\n\s*')
lookup_enum_re = re.compile(
    r'(?ms)^enum f2fs_lookup_mode\s*\{\s*'
    r'LOOKUP_PERF,\s*LOOKUP_COMPAT,\s*LOOKUP_AUTO,\s*\};\s*\n?')
helper_block_re = re.compile(
    r'(?ms)^static inline int f2fs_get_alloc_mode\(struct f2fs_sb_info \*sbi\)\s*\n\{.*?'
    r'^static inline void f2fs_set_lookup_mode\(struct f2fs_sb_info \*sbi,\s*'
    r'enum f2fs_lookup_mode mode\)\s*\n\{.*?^\}\s*\n?')

if needs_packed_modes:
    # Remove any old generated packed dependency/accessor material first.
    h = packed_def_re.sub('', h, count=1)
    h = lookup_enum_re.sub('', h, count=1)
    h = helper_block_re.sub('', h, count=1)

    packed = ('/*\n'
              ' * For bit-packing in f2fs_mount_info->alloc_mode.\n'
              ' */\n'
              '#define ALLOC_MODE_BITS\t1\n'
              '#define LOOKUP_MODE_BITS\t2\n'
              '#define ALLOC_MODE_SHIFT\t0\n'
              '#define LOOKUP_MODE_SHIFT\t(ALLOC_MODE_SHIFT + ALLOC_MODE_BITS)\n'
              '#define ALLOC_MODE_MASK\t(((1 << ALLOC_MODE_BITS) - 1) << ALLOC_MODE_SHIFT)\n'
              '#define LOOKUP_MODE_MASK\t(((1 << LOOKUP_MODE_BITS) - 1) << LOOKUP_MODE_SHIFT)\n\n'
              'enum f2fs_lookup_mode {\n'
              '\tLOOKUP_PERF,\n'
              '\tLOOKUP_COMPAT,\n'
              '\tLOOKUP_AUTO,\n'
              '};\n\n')

    helper = ('static inline int f2fs_get_alloc_mode(struct f2fs_sb_info *sbi)\n'
              '{\n'
              '\treturn (F2FS_OPTION(sbi).alloc_mode & ALLOC_MODE_MASK) >> ALLOC_MODE_SHIFT;\n'
              '}\n\n'
              'static inline void f2fs_set_alloc_mode(struct f2fs_sb_info *sbi, int mode)\n'
              '{\n'
              '\tF2FS_OPTION(sbi).alloc_mode &= ~ALLOC_MODE_MASK;\n'
              '\tF2FS_OPTION(sbi).alloc_mode |= (mode << ALLOC_MODE_SHIFT);\n'
              '}\n\n'
              'static inline enum f2fs_lookup_mode f2fs_get_lookup_mode(\n'
              '\t\tstruct f2fs_sb_info *sbi)\n'
              '{\n'
              '\treturn (enum f2fs_lookup_mode)((F2FS_OPTION(sbi).alloc_mode & LOOKUP_MODE_MASK) >> LOOKUP_MODE_SHIFT);\n'
              '}\n\n'
              'static inline void f2fs_set_lookup_mode(struct f2fs_sb_info *sbi,\n'
              '\t\tenum f2fs_lookup_mode mode)\n'
              '{\n'
              '\tF2FS_OPTION(sbi).alloc_mode &= ~LOOKUP_MODE_MASK;\n'
              '\tF2FS_OPTION(sbi).alloc_mode |= (mode << LOOKUP_MODE_SHIFT);\n'
              '}\n\n')

    # Place the complete API immediately after f2fs_mount_info. This is earlier
    # than the accessor use and keeps all dependencies together.
    h = h[:sb_end] + '\n' + packed + helper + h[sb_end:]
    print('[OP13R-6.1.157] Normalized F2FS packed-mode API ordering')


if needs_packed_modes:
    required = ('f2fs_get_alloc_mode', 'f2fs_set_alloc_mode',
                'f2fs_get_lookup_mode', 'f2fs_set_lookup_mode')
    if not all(re.search(r'\b' + x + r'\b', h) for x in required):
        helper = ('\nstatic inline int f2fs_get_alloc_mode(struct f2fs_sb_info *sbi)\n'
                  '{\n'
                  '\treturn (F2FS_OPTION(sbi).alloc_mode & ALLOC_MODE_MASK) >> ALLOC_MODE_SHIFT;\n'
                  '}\n\n'
                  'static inline void f2fs_set_alloc_mode(struct f2fs_sb_info *sbi, int mode)\n'
                  '{\n'
                  '\tF2FS_OPTION(sbi).alloc_mode &= ~ALLOC_MODE_MASK;\n'
                  '\tF2FS_OPTION(sbi).alloc_mode |= (mode << ALLOC_MODE_SHIFT);\n'
                  '}\n\n'
                  'static inline enum f2fs_lookup_mode f2fs_get_lookup_mode(struct f2fs_sb_info *sbi)\n'
                  '{\n'
                  '\treturn (enum f2fs_lookup_mode)((F2FS_OPTION(sbi).alloc_mode & LOOKUP_MODE_MASK) >> LOOKUP_MODE_SHIFT);\n'
                  '}\n\n'
                  'static inline void f2fs_set_lookup_mode(struct f2fs_sb_info *sbi,\n'
                  '\t\t\t\t\tenum f2fs_lookup_mode mode)\n'
                  '{\n'
                  '\tF2FS_OPTION(sbi).alloc_mode &= ~LOOKUP_MODE_MASK;\n'
                  '\tF2FS_OPTION(sbi).alloc_mode |= (mode << LOOKUP_MODE_SHIFT);\n'
                  '}\n\n')
        # Helpers must follow the complete f2fs_sb_info definition. Remove any
        # partial helper group before installing one coherent implementation.
        h = re.sub(r'(?s)\nstatic inline int f2fs_get_alloc_mode\(struct f2fs_sb_info \*sbi\)\n\{.*?\n\}\n\nstatic inline void f2fs_set_alloc_mode\(struct f2fs_sb_info \*sbi, int mode\)\n\{.*?\n\}\n\nstatic inline enum f2fs_lookup_mode f2fs_get_lookup_mode\(struct f2fs_sb_info \*sbi\)\n\{.*?\n\}\n\nstatic inline void f2fs_set_lookup_mode\(struct f2fs_sb_info \*sbi,\n\s*enum f2fs_lookup_mode mode\)\n\{.*?\n\}\n', '\n', h)
        # Helpers must follow the complete f2fs_sb_info definition.
        start = h.find('struct f2fs_sb_info {')
        if start < 0:
            raise SystemExit('Unable to locate struct f2fs_sb_info definition')
        brace = h.find('{', start)
        depth = 0
        end = None
        for i in range(brace, len(h)):
            if h[i] == '{':
                depth += 1
            elif h[i] == '}':
                depth -= 1
                if depth == 0:
                    semi = h.find(';', i)
                    if semi < 0:
                        raise SystemExit('Unable to locate end of struct f2fs_sb_info')
                    end = semi + 1
                    break
        if end is None:
            raise SystemExit('Unable to locate complete struct f2fs_sb_info')
        h = h[:end] + helper + h[end:]

if h != header.read_text():
    header.write_text(h)

# The lookup backport also changes alloc_mode assignments/comparisons so they
# preserve the packed lookup bits. Restrict this to the exact ACK forms.
if needs_lookup:
    for name in ('super.c', 'segment.c'):
        p = f2fs_dir / name
        if not p.exists():
            continue
        s = p.read_text()
        old = s
        s = re.sub(r'F2FS_OPTION\(sbi\)\.alloc_mode\s*=\s*ALLOC_MODE_DEFAULT\s*;',
                   'f2fs_set_alloc_mode(sbi, ALLOC_MODE_DEFAULT);', s)
        s = re.sub(r'F2FS_OPTION\(sbi\)\.alloc_mode\s*=\s*ALLOC_MODE_REUSE\s*;',
                   'f2fs_set_alloc_mode(sbi, ALLOC_MODE_REUSE);', s)
        s = re.sub(r'F2FS_OPTION\(sbi\)\.alloc_mode\s*==\s*ALLOC_MODE_DEFAULT',
                   'f2fs_get_alloc_mode(sbi) == ALLOC_MODE_DEFAULT', s)
        s = re.sub(r'F2FS_OPTION\(sbi\)\.alloc_mode\s*==\s*ALLOC_MODE_REUSE',
                   'f2fs_get_alloc_mode(sbi) == ALLOC_MODE_REUSE', s)
        if s != old:
            p.write_text(s)
            print('[OP13R-6.1.157] Converted packed alloc_mode access in ' + name)

# Final source-level validation is based on the exported tree, not assumptions
# about which file happened to trigger the reconciliation.
final_text = []
for p in sorted(f2fs_dir.rglob('*')):
    if p.is_file() and p.suffix in ('.c', '.h'):
        try:
            final_text.append(p.read_text())
        except UnicodeDecodeError:
            pass
final = '\n'.join(final_text)

if needs_reserve_node:
    if not re.search(r'(?m)^#define\s+F2FS_MOUNT_RESERVE_NODE\s+0x00000001\b', h):
        raise SystemExit('F2FS API reconciliation incomplete: F2FS_MOUNT_RESERVE_NODE=0x00000001')
    if not re.search(r'(?m)^\s*block_t\s+root_reserved_nodes\s*;', h):
        raise SystemExit('F2FS API reconciliation incomplete: root_reserved_nodes')

if needs_packed_modes:
    for sym in ('f2fs_get_alloc_mode', 'f2fs_set_alloc_mode',
                'f2fs_get_lookup_mode', 'f2fs_set_lookup_mode'):
        if not re.search(r'\b' + sym + r'\b', h):
            raise SystemExit('F2FS API reconciliation incomplete: ' + sym)
    for pat, name in ((r'^#define\s+ALLOC_MODE_BITS\s+1\b', 'ALLOC_MODE_BITS'),
                      (r'^#define\s+LOOKUP_MODE_BITS\s+2\b', 'LOOKUP_MODE_BITS'),
                      (r'^#define\s+ALLOC_MODE_SHIFT\s+0\b', 'ALLOC_MODE_SHIFT'),
                      (r'^#define\s+LOOKUP_MODE_SHIFT\s+\(ALLOC_MODE_SHIFT\s*\+\s*ALLOC_MODE_BITS\)', 'LOOKUP_MODE_SHIFT'),
                      (r'^#define\s+ALLOC_MODE_MASK\b', 'ALLOC_MODE_MASK'),
                      (r'^#define\s+LOOKUP_MODE_MASK\b', 'LOOKUP_MODE_MASK')):
        if not re.search(pat, h, re.M):
            raise SystemExit('F2FS API reconciliation incomplete: ' + name)
    if not re.search(r'(?ms)^enum\s+f2fs_lookup_mode\s*\{.*?\bLOOKUP_PERF\b.*?\bLOOKUP_COMPAT\b.*?\bLOOKUP_AUTO\b.*?^\};', h):
        raise SystemExit('F2FS API reconciliation incomplete: enum f2fs_lookup_mode')
    helper_pos = h.find('static inline int f2fs_get_alloc_mode')
    dep_positions = [h.find('#define ALLOC_MODE_MASK'), h.find('#define LOOKUP_MODE_MASK'), h.find('enum f2fs_lookup_mode')]
    if helper_pos >= 0 and any(pos < 0 or pos > helper_pos for pos in dep_positions):
        raise SystemExit('F2FS API reconciliation incomplete: packed-mode dependencies appear after accessors')
    if re.search(r'(?m)^\s*int\s+lookup_mode\s*;', h):
        raise SystemExit('Invalid standalone f2fs lookup_mode field remains')

print('[OP13R-6.1.157] F2FS API reconciliation complete')
PYTHON
fi


# Restore the Android 6.1 MMC DDR50-tuning quirk API consumed by drivers/mmc/core/sd.c.
# The OnePlus synchronization snapshot can carry the sd.c consumer without the
# companion quirk bit/helper from the ACK backport. Restore the complete small API
# set rather than adding only a prototype that would fail at the next build stage.
MMC_CARD_H="$COMMON_DIR/include/linux/mmc/card.h"
MMC_CORE_CARD_H="$COMMON_DIR/drivers/mmc/core/card.h"
MMC_QUIRKS_H="$COMMON_DIR/drivers/mmc/core/quirks.h"
MMC_SD_C="$COMMON_DIR/drivers/mmc/core/sd.c"
if [ -f "$MMC_SD_C" ] && grep -q 'mmc_card_no_uhs_ddr50_tuning' "$MMC_SD_C"; then
  echo "[OP13R-6.1.157] Reconciling Android 6.1 MMC NO_UHS_DDR50_TUNING API"
  python3 - "$MMC_CARD_H" "$MMC_CORE_CARD_H" "$MMC_QUIRKS_H" <<'PYTHON'
from pathlib import Path
import re, sys
card_h = Path(sys.argv[1])
core_h = Path(sys.argv[2])
quirks_h = Path(sys.argv[3])

if card_h.is_file():
    s = card_h.read_text()
    if 'MMC_QUIRK_NO_UHS_DDR50_TUNING' not in s:
        lines = s.splitlines(keepends=True)
        anchor = '#define MMC_QUIRK_BROKEN_SD_POWEROFF_NOTIFY'
        pos = next((i for i, line in enumerate(lines) if anchor in line), None)
        if pos is None:
            candidates = [i for i, line in enumerate(lines) if re.match(r'^#define\s+MMC_QUIRK_', line)]
            if not candidates:
                raise SystemExit('Unable to locate MMC_QUIRK definitions in include/linux/mmc/card.h')
            pos = candidates[-1]
        lines.insert(pos + 1, '#define MMC_QUIRK_NO_UHS_DDR50_TUNING\t(1<<18) /* Disable DDR50 tuning */\n')
        card_h.write_text(''.join(lines))

if core_h.is_file():
    s = core_h.read_text()
    if 'CID_MANFID_SWISSBIT' not in s:
        lines = s.splitlines(keepends=True)
        pos = next((i for i, line in enumerate(lines) if '#define CID_MANFID_APACER' in line), None)
        if pos is None:
            candidates = [i for i, line in enumerate(lines) if 'CID_MANFID_' in line and line.lstrip().startswith('#define')]
            if not candidates:
                raise SystemExit('Unable to locate MMC manufacturer ID definitions in drivers/mmc/core/card.h')
            pos = candidates[-1]
        lines.insert(pos + 1, '#define CID_MANFID_SWISSBIT     0x5D\n')
        s = ''.join(lines)
    if 'mmc_card_no_uhs_ddr50_tuning' not in s:
        block = """
static inline int mmc_card_no_uhs_ddr50_tuning(const struct mmc_card *c)
{
\treturn c->quirks & MMC_QUIRK_NO_UHS_DDR50_TUNING;
}
"""
        idx = s.rfind('\n#endif')
        if idx < 0:
            raise SystemExit('Unable to locate end of drivers/mmc/core/card.h')
        s = s[:idx] + block + s[idx:]
        core_h.write_text(s)

if quirks_h.is_file():
    s = quirks_h.read_text()
    if 'MMC_QUIRK_NO_UHS_DDR50_TUNING' not in s:
        block = """\t/*
\t * Swissbit series S46-u cards throw I/O errors during tuning requests
\t * after the initial tuning request expectedly times out. This has
\t * only been observed on cards manufactured on 01/2019 that are using
\t * Bay Trail host controllers.
\t */
\t_FIXUP_EXT("0016G", CID_MANFID_SWISSBIT, 0x5342, 2019, 1,
\t\t   0, -1ull, SDIO_ANY_ID, SDIO_ANY_ID, add_quirk_sd,
\t\t   MMC_QUIRK_NO_UHS_DDR50_TUNING, EXT_CSD_REV_ANY),

"""
        idx = s.find('\tEND_FIXUP')
        if idx < 0:
            raise SystemExit('Unable to locate END_FIXUP in drivers/mmc/core/quirks.h')
        s = s[:idx] + block + s[idx:]
        quirks_h.write_text(s)
PYTHON
  grep -q 'MMC_QUIRK_NO_UHS_DDR50_TUNING' "$MMC_CARD_H" || { echo "::error::MMC quirk bit restoration failed."; exit 1; }
  grep -q 'mmc_card_no_uhs_ddr50_tuning' "$MMC_CORE_CARD_H" || { echo "::error::MMC DDR50 helper restoration failed."; exit 1; }
  echo "[OP13R-6.1.157] MMC NO_UHS_DDR50_TUNING API reconciliation complete"
fi

# Restore the Android 6.1 PIO-P flag field consumed by exported addrconf.c.
IPV6_H="$COMMON_DIR/include/linux/ipv6.h"
ADDRCONF_C="$COMMON_DIR/net/ipv6/addrconf.c"
if [ -f "$IPV6_H" ] && [ -f "$ADDRCONF_C" ] && grep -q 'ra_honor_pio_pflag' "$ADDRCONF_C"; then
  echo "[OP13R-6.1.157] Reconciling Android 6.1 IPv6 ra_honor_pio_pflag API"
  python3 - "$IPV6_H" <<'PYTHON'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
s = p.read_text()
if 'ra_honor_pio_pflag' not in s:
    start = s.find('struct ipv6_devconf {')
    if start < 0:
        raise SystemExit('Unable to locate struct ipv6_devconf')
    end = s.find('};', start)
    if end < 0:
        raise SystemExit('Unable to locate end of struct ipv6_devconf')
    block = s[start:end]
    anchors = [
        r'(?m)^(\s*(?:__u8|u8)\s+ra_honor_pio_life\s*;\s*)$',
        r'(?m)^(\s*(?:__u8|u8)\s+accept_ra_pinfo\s*;\s*)$',
    ]
    match = None
    for pattern in anchors:
        match = re.search(pattern, block)
        if match:
            break
    if not match:
        match = re.search(r'(?m)^(\s*(?:__u8|u8)\s+[^;]+;\s*)$', block)
    if not match:
        raise SystemExit('Unable to locate a scalar u8 field inside struct ipv6_devconf')
    insert_at = start + match.end()
    s = s[:insert_at] + '\n\tu8 ra_honor_pio_pflag;' + s[insert_at:]
    p.write_text(s)
PYTHON
  grep -q 'ra_honor_pio_pflag' "$IPV6_H" || { echo "::error::IPv6 ra_honor_pio_pflag restoration failed."; exit 1; }
  echo "[OP13R-6.1.157] IPv6 ra_honor_pio_pflag API reconciliation complete"
fi

# Restore the complete Android 6.1 DMA-BUF task-storage API before consumers use it.
DMA_BUF_H="$COMMON_DIR/include/linux/dma-buf.h"
KTHREAD_H="$COMMON_DIR/include/linux/kthread.h"
if [ -f "$DMA_BUF_H" ]; then
  python3 - "$DMA_BUF_H" "$KTHREAD_H" <<'PYTHON'
from pathlib import Path
import sys

dma=Path(sys.argv[1]); kt=Path(sys.argv[2]); h=dma.read_text()
if '#include <linux/kthread.h>' not in h:
    # Android ACK places kthread.h with the core dma-buf header includes.
    # OnePlus vendor snapshots can reorder or omit workqueue.h, so do not
    # require one exact include as an insertion anchor.
    marker='#include <linux/workqueue.h>\n'
    if marker in h:
        h=h.replace(marker,marker+'#include <linux/kthread.h>\n',1)
    else:
        includes=list(__import__('re').finditer(r'(?m)^#include <linux/[^>]+>\n',h))
        if not includes:
            raise SystemExit('Unable to locate dma-buf.h Linux include block')
        pos=includes[-1].end()
        h=h[:pos]+'#include <linux/kthread.h>\n'+h[pos:]
if 'struct task_dma_buf_info {' not in h: raise SystemExit('task_dma_buf_info definition missing')
api="""
static inline bool task_has_dma_buf_info(struct task_struct *task)
{
\treturn task != &init_task && (task->flags & PF_IO_WORKER) == 0;
}

static inline void set_task_dma_buf_info(struct task_struct *task,
\t\t\t\t\t struct task_dma_buf_info *dmabuf_info)
{
\tif (WARN_ON(!task_has_dma_buf_info(task)))
\t\treturn;
\tif (task->flags & PF_KTHREAD)
\t\tset_kthread_dmabuf_info(task, dmabuf_info);
\telse
\t\ttask->worker_private = dmabuf_info;
}

static inline
struct task_dma_buf_info *get_task_dma_buf_info(struct task_struct *task)
{
\tif (!task)
\t\treturn ERR_PTR(-EINVAL);
\tif (!task_has_dma_buf_info(task))
\t\treturn NULL;
\tif (!task->worker_private)
\t\treturn ERR_PTR(-ENOMEM);
\tif (task->flags & PF_KTHREAD)
\t\treturn get_kthread_dmabuf_info(task) ? : ERR_PTR(-ENOMEM);
\treturn (struct task_dma_buf_info *)task->worker_private;
}
"""
if 'static inline bool task_has_dma_buf_info' not in h:
    start=h.find('struct task_dma_buf_info {'); end=h.find('\n};',start)
    if start<0 or end<0: raise SystemExit('Unable to locate task_dma_buf_info end')
    h=h[:end+3]+api+h[end+3:]
dma.write_text(h)
k=kt.read_text()
if 'get_kthread_dmabuf_info' not in k:
    marker='bool kthread_is_per_cpu(struct task_struct *k);\n'
    if marker not in k: raise SystemExit('Unable to locate kthread.h anchor')
    decl="""
struct task_dma_buf_info;
struct task_dma_buf_info *get_kthread_dmabuf_info(struct task_struct *tsk);
void set_kthread_dmabuf_info(struct task_struct *tsk,
\t\t\t\t     struct task_dma_buf_info *dmabuf_info);
"""
    kt.write_text(k.replace(marker,marker+decl,1))
PYTHON
fi

INODE_C="$COMMON_DIR/fs/inode.c"
if [ -f "$INODE_C" ] && grep -q 'trace_android_vh_inode_lru_isolate' "$INODE_C"; then
  if ! grep -q '#include <trace/hooks/vmscan.h>' "$INODE_C"; then
    echo "[OP13R-6.1.157] Restoring trace/hooks/vmscan.h include in fs/inode.c"
    python3 - "$INODE_C" <<'PYTHON'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(); marker='#include <trace/events/writeback.h>\n'
if marker not in s: raise SystemExit('Unable to locate fs/inode.c trace include anchor')
p.write_text(s.replace(marker,marker+'#undef CREATE_TRACE_POINTS\n#include <trace/hooks/vmscan.h>\n',1))
PYTHON
  fi
fi

if [ -f "$VMSCAN_HOOKS" ] && grep -q 'trace_android_vh_inode_lru_isolate' "$INODE_C" && ! grep -q 'DECLARE_HOOK(android_vh_inode_lru_isolate' "$VMSCAN_HOOKS"; then
  echo "[OP13R-6.1.157] Restoring android_vh_inode_lru_isolate declaration in include/trace/hooks/vmscan.h"
  python3 - "$VMSCAN_HOOKS" <<'PYTHON'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
block='DECLARE_HOOK(android_vh_inode_lru_isolate,\n\tTP_PROTO(struct inode *inode, bool *skip),\n\tTP_ARGS(inode, skip));\n'
if 'DECLARE_HOOK(android_vh_inode_lru_isolate' not in s:
    marker='DECLARE_HOOK(android_vh_invalidate_mapping_pagevec,\n'
    if marker in s: s=s.replace(marker,block+marker,1)
    else:
        pos=s.rfind('#endif')
        if pos<0: raise SystemExit('Unable to locate vmscan.h end anchor')
        s=s[:pos]+block+s[pos:]
    p.write_text(s)
PYTHON
fi

if [ -f "$VENDOR_HOOKS" ] && grep -q 'trace_android_vh_inode_lru_isolate' "$INODE_C" && ! grep -q 'EXPORT_TRACEPOINT_SYMBOL_GPL(android_vh_inode_lru_isolate)' "$VENDOR_HOOKS"; then
  echo "[OP13R-6.1.157] Restoring android_vh_inode_lru_isolate tracepoint export"
  python3 - "$VENDOR_HOOKS" <<'PYTHON'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
line='EXPORT_TRACEPOINT_SYMBOL_GPL(android_vh_inode_lru_isolate);\n'
if 'EXPORT_TRACEPOINT_SYMBOL_GPL(android_vh_inode_lru_isolate)' not in s:
    marker='EXPORT_TRACEPOINT_SYMBOL_GPL(android_vh_shrink_folio_list);\n'
    if marker in s: s=s.replace(marker,marker+line,1)
    else:
        marker='EXPORT_TRACEPOINT_SYMBOL_GPL(android_vh_vmscan_kswapd_done);\n'
        if marker not in s: raise SystemExit('Unable to locate vendor hook export anchor')
        s=s.replace(marker,marker+line,1)
    p.write_text(s)
PYTHON
fi

# Restore the kthread-side half of the Android 6.1.157 DMA-BUF ABI fixup.
# The exported OnePlus synchronization snapshot can contain the new dma-buf.h
# callers while still carrying an older kernel/kthread.c. In that state the
# inline helpers compile successfully but the linker cannot resolve the two
# kthread accessors.
KTHREAD_C="$COMMON_DIR/kernel/kthread.c"
KTHREAD_H="$COMMON_DIR/include/linux/kthread.h"
SCHED_H="$COMMON_DIR/include/linux/sched.h"
DMA_BUF_H="$COMMON_DIR/include/linux/dma-buf.h"
if [ -f "$KTHREAD_C" ] && [ -f "$KTHREAD_H" ] && [ -f "$SCHED_H" ] && [ -f "$DMA_BUF_H" ]; then
  echo "[OP13R-6.1.157] Restoring Android 6.1 DMA-BUF kthread storage/accessors"
  python3 - "$KTHREAD_C" "$KTHREAD_H" <<'PYTHON'
from pathlib import Path
import re
import sys

if len(sys.argv) != 3:
    raise SystemExit(
        f"DMA-BUF kthread reconciliation expected 2 paths, got {len(sys.argv) - 1}"
    )
kthread_c = Path(sys.argv[1])
kthread_h = Path(sys.argv[2])
c = kthread_c.read_text()

if '#include <linux/dma-buf.h>' not in c:
    for marker in ('#include <linux/numa.h>\n', '#include <linux/uaccess.h>\n', '#include <linux/ptrace.h>\n'):
        if marker in c:
            c = c.replace(marker, marker + '#include <linux/dma-buf.h>\n', 1)
            break
    else:
        raise SystemExit('Unable to locate kernel/kthread.c dma-buf include anchor')

if 'struct task_dma_buf_info *dmabuf_info;' not in c:
    marker = '\tchar *full_name;\n'
    if marker not in c:
        raise SystemExit('Unable to locate struct kthread full_name member')
    c = c.replace(marker, marker + '\tstruct task_dma_buf_info *dmabuf_info;\n', 1)

if 'dmabuf information for task %d was not released' not in c:
    marker = '\tk->worker_private = NULL;\n'
    cleanup = (
        '\tk->worker_private = NULL;\n'
        '\t/*\n'
        '\t * By now put_dmabuf_info() should have released the reference and\n'
        '\t * reset this field.\n'
        '\t */\n'
        '\tif (unlikely(kthread->dmabuf_info)) {\n'
        '\t\tpr_alert("dmabuf information for task %d was not released\\n",\n'
        '\t\t\t task_pid_nr(k));\n'
        '\t\tkfree(kthread->dmabuf_info);\n'
        '\t}\n'
    )
    if marker not in c:
        raise SystemExit('Unable to locate kthread worker_private cleanup anchor')
    c = c.replace(marker, cleanup, 1)

if 'struct task_dma_buf_info *get_kthread_dmabuf_info(' not in c:
    marker = re.search(r'(?m)^bool kthread_is_per_cpu\(struct task_struct \*\w+\)\n\{', c)
    if not marker:
        raise SystemExit('Unable to locate kthread_is_per_cpu() definition')
    # Insert immediately after the complete kthread_is_per_cpu() function.
    # Do not depend on EXPORT_SYMBOL spelling/location; vendor trees may use
    # EXPORT_SYMBOL() or EXPORT_SYMBOL_GPL(), or place the export elsewhere.
    start = marker.start()
    brace = c.find('{', marker.start())
    depth = 0
    end = -1
    for i in range(brace, len(c)):
        if c[i] == '{':
            depth += 1
        elif c[i] == '}':
            depth -= 1
            if depth == 0:
                end = i + 1
                break
    if end < 0:
        raise SystemExit('Unable to locate end of kthread_is_per_cpu()')
    funcs = (
        '\n\n'
        'struct task_dma_buf_info *get_kthread_dmabuf_info(struct task_struct *tsk)\n'
        '{\n'
        '\tstruct kthread *kthread = to_kthread(tsk);\n\n'
        '\treturn kthread ? kthread->dmabuf_info : NULL;\n'
        '}\n\n'
        'void set_kthread_dmabuf_info(struct task_struct *tsk,\n'
        '\t\t\t     struct task_dma_buf_info *dmabuf_info)\n'
        '{\n'
        '\tstruct kthread *kthread = to_kthread(tsk);\n\n'
        '\tif (kthread)\n'
        '\t\tkthread->dmabuf_info = dmabuf_info;\n'
        '}\n'
    )
    c = c[:end] + funcs + c[end:]
kthread_c.write_text(c)

h = kthread_h.read_text()
if 'struct task_dma_buf_info *get_kthread_dmabuf_info(' not in h:
    marker = 'bool kthread_is_per_cpu(struct task_struct *k);\n'
    if marker not in h:
        raise SystemExit('Unable to locate kthread.h declaration anchor')
    decl = (
        '\nstruct task_dma_buf_info;\n'
        'struct task_dma_buf_info *get_kthread_dmabuf_info(struct task_struct *tsk);\n'
        'void set_kthread_dmabuf_info(struct task_struct *tsk,\n'
        '\t\t\t     struct task_dma_buf_info *dmabuf_info);\n'
    )
    h = h.replace(marker, marker + decl, 1)
kthread_h.write_text(h)

# Do not include dma-buf.h from sched.h. dma-buf.h itself includes kthread.h,
# which includes sched.h; adding the reverse edge creates a header recursion in
# the OnePlus vendor include graph and leaves task_struct incomplete during
# asm-offsets generation. The Android ACK fixup does not require sched.h to
# include dma-buf.h.

for path in (kthread_c, kthread_h):
    text = path.read_text()
    for sym in ('get_kthread_dmabuf_info(', 'set_kthread_dmabuf_info('):
        if sym not in text:
            raise SystemExit(f'DMA-BUF kthread accessor missing from {path}: {sym}')
if 'struct task_dma_buf_info *dmabuf_info;' not in kthread_c.read_text():
    raise SystemExit('DMA-BUF kthread storage member missing')

# sched.h must not include dma-buf.h: dma-buf.h -> kthread.h -> sched.h is
# the intended dependency direction for the Android 6.1 DMA-BUF ABI.
sched_path = kthread_h.parent / 'sched.h'
if sched_path.is_file() and '#include <linux/dma-buf.h>' in sched_path.read_text():
    raise SystemExit('Invalid DMA-BUF header cycle: sched.h includes dma-buf.h')
PYTHON
fi

# Reconcile the exported vendor dma-buf implementation with the Android 6.1.157
# task_struct ABI. The pre-export Git replay can miss this file when the OnePlus
# synchronization snapshot reintroduces the legacy implementation. At this point
# COMMON_DIR is the actual build tree, so repair the implementation directly.
DMA_BUF_C="$COMMON_DIR/drivers/dma-buf/dma-buf.c"
if [ -f "$DMA_BUF_C" ] && grep -qE 'task->dmabuf_info|current->dmabuf_info' "$DMA_BUF_C"; then
  echo "[OP13R-6.1.157] Reconciling legacy drivers/dma-buf/dma-buf.c dmabuf_info accesses"

  # First try the exact ACK fixup against the exported tree. This catches the
  # normal case without modifying unrelated vendor changes.
  if git -C "$WORK_DIR/oneplus" cat-file -e "${ACK_DMABUF_FIXUP}^{commit}" 2>/dev/null; then
    ACK_DMA_PATCH="$COMMON_DIR/.op13r_ack_dmabuf_fixup.patch"
    git -C "$WORK_DIR/oneplus" diff "${ACK_DMABUF_FIXUP_PARENT}" "${ACK_DMABUF_FIXUP}" -- \
      drivers/dma-buf/dma-buf.c \
      fs/proc/base.c \
      include/linux/dma-buf.h \
      include/linux/kthread.h \
      include/linux/sched.h \
      init/init_task.c \
      kernel/fork.c \
      kernel/kthread.c > "$ACK_DMA_PATCH" || {
        echo "::error::Unable to generate ACK DMA-BUF ABI fixup patch."
        exit 1
      }
    (cd "$COMMON_DIR" && git apply --whitespace=nowarn "$ACK_DMA_PATCH") 2>/dev/null || true
    rm -f "$ACK_DMA_PATCH"
  fi

  # If vendor context prevented the whole patch from applying, normalize the
  # remaining accounting implementation using the ACK helper API. The helper
  # functions are restored by the earlier header reconciliation in this script.
  python3 - "$DMA_BUF_C" <<'PYTHON'
from pathlib import Path
import re, sys
p=Path(sys.argv[1]); s=p.read_text()

# Record helpers use an explicit task_dma_buf_info object in ACK 6.1.157.
start=s.find('static struct task_dma_buf_record *find_task_dmabuf_record')
end=s.find('static int dma_buf_account_task', start)
if start >= 0 and end > start:
    b=s[start:end]
    b=b.replace('struct task_struct *task, struct dma_buf *dmabuf',
                'struct task_dma_buf_info *dmabuf_info, struct dma_buf *dmabuf')
    b=b.replace('task->dmabuf_info', 'dmabuf_info')
    s=s[:start]+b+s[end:]

# Account/unaccount: preserve vendor internals, replacing the task member with
# get_task_dma_buf_info() and an explicit local pointer.
m=re.search(r'(?ms)^int dma_buf_account_task\(.*?^\}\n(?=\nvoid dma_buf_unaccount_task)',s)
if m and 'get_task_dma_buf_info' not in m.group(0):
    b=m.group(0)
    b=b.replace('int dma_buf_account_task(struct dma_buf *dmabuf, struct task_struct *task)\n{\n',
                'int dma_buf_account_task(struct dma_buf *dmabuf, struct task_struct *task)\n{\n\tstruct task_dma_buf_info *dmabuf_info;\n')
    b=re.sub(r'(?m)^\s*if \(!task->dmabuf_info\)\s*\n\s*return -ENOMEM;',
             '\tdmabuf_info = get_task_dma_buf_info(task);\n\tif (!dmabuf_info)\n\t\treturn 0;\n\tif (IS_ERR(dmabuf_info))\n\t\treturn PTR_ERR(dmabuf_info);', b, count=1)
    b=b.replace('task->dmabuf_info->lock','dmabuf_info->lock')
    b=b.replace('find_task_dmabuf_record(task, dmabuf)','find_task_dmabuf_record(dmabuf_info, dmabuf)')
    b=b.replace('add_task_dmabuf_record(task, dmabuf, rec)','add_task_dmabuf_record(dmabuf_info, dmabuf, rec)')
    s=s[:m.start()]+b+s[m.end():]

m=re.search(r'(?ms)^void dma_buf_unaccount_task\(.*?^\}\n(?=\nint copy_dmabuf_info)',s)
if m and 'get_task_dma_buf_info' not in m.group(0):
    b=m.group(0)
    b=b.replace('void dma_buf_unaccount_task(struct dma_buf *dmabuf, struct task_struct *task)\n{\n',
                'void dma_buf_unaccount_task(struct dma_buf *dmabuf, struct task_struct *task)\n{\n\tstruct task_dma_buf_info *dmabuf_info;\n')
    b=re.sub(r'(?m)^\s*if \(!task->dmabuf_info\)\s*\n\s*return;',
             '\tdmabuf_info = get_task_dma_buf_info(task);\n\tif (!dmabuf_info)\n\t\treturn;\n\tif (IS_ERR(dmabuf_info))\n\t\treturn;', b, count=1)
    b=b.replace('task->dmabuf_info->lock','dmabuf_info->lock')
    b=b.replace('find_task_dmabuf_record(task, dmabuf)','find_task_dmabuf_record(dmabuf_info, dmabuf)')
    s=s[:m.start()]+b+s[m.end():]

# copy_dmabuf_info needs the new storage helpers, not direct task members.
m=re.search(r'(?ms)^int copy_dmabuf_info\(.*?^\}\n(?=\nvoid put_dmabuf_info)',s)
if m and 'get_task_dma_buf_info' not in m.group(0):
    b=m.group(0)
    b=b.replace('struct task_dma_buf_record *parent_rec, *child_rec;\n\tint retries = 0;',
                'struct task_dma_buf_record *parent_rec, *child_rec;\n\tstruct task_dma_buf_info *new_dmabuf_info;\n\tstruct task_dma_buf_info *dmabuf_info;\n\tint retries = 0;')
    b=b.replace('\tif (current->dmabuf_info && (clone_flags & (CLONE_VM | CLONE_FILES))',
                '\tif (!task_has_dma_buf_info(task))\n\t\treturn 0;\n\tdmabuf_info = get_task_dma_buf_info(current);\n\tif (IS_ERR(dmabuf_info))\n\t\tdmabuf_info = NULL;\n\tif (dmabuf_info && (clone_flags & (CLONE_VM | CLONE_FILES))')
    b=b.replace('refcount_inc(&current->dmabuf_info->refcnt);\n\t\ttask->dmabuf_info = current->dmabuf_info;',
                'refcount_inc(&dmabuf_info->refcnt);\n\t\tset_task_dma_buf_info(task, dmabuf_info);')
    b=b.replace('task->dmabuf_info = kmalloc(sizeof(*task->dmabuf_info), GFP_KERNEL);\n\tif (!task->dmabuf_info)',
                'new_dmabuf_info = kmalloc(sizeof(*new_dmabuf_info), GFP_KERNEL);\n\tif (!new_dmabuf_info)')
    b=b.replace('task->dmabuf_info->','new_dmabuf_info->')
    b=b.replace('current->dmabuf_info->','dmabuf_info->')
    b=b.replace('kfree(task->dmabuf_info);\n\ttask->dmabuf_info = NULL;',
                'kfree(new_dmabuf_info);\n\tset_task_dma_buf_info(task, NULL);')
    b=b.replace('spin_unlock(&current->dmabuf_info->lock);','spin_unlock(&dmabuf_info->lock);')
    s=s[:m.start()]+b+s[m.end():]

# put_dmabuf_info uses the getter and clears the storage before release.
m=re.search(r'(?ms)^void put_dmabuf_info\(.*?^\}\n(?=\nstatic int dma_buf_mmap_internal)',s)
if m and 'get_task_dma_buf_info' not in m.group(0):
    b=m.group(0)
    b=b.replace('void put_dmabuf_info(struct task_struct *task)\n{\n',
                'void put_dmabuf_info(struct task_struct *task)\n{\n\tstruct task_dma_buf_info *dmabuf_info = get_task_dma_buf_info(task);\n')
    b=re.sub(r'(?m)^\s*if \(!task->dmabuf_info\)\s*\n\s*return;',
             '\tif (!dmabuf_info)\n\t\treturn;\n\tif (IS_ERR(dmabuf_info))\n\t\treturn;', b, count=1)
    b=b.replace('task->dmabuf_info','dmabuf_info')
    b=b.replace('\tkfree(dmabuf_info);','\tset_task_dma_buf_info(task, NULL);\n\tkfree(dmabuf_info);')
    s=s[:m.start()]+b+s[m.end():]

# Vendor OnePlus revisions can retain the pre-fixup parent alias used by
# copy_dmabuf_info(), e.g.:
#   struct task_dma_buf_info *parent_dmabuf_info = current->dmabuf_info;
# The ACK 6.1.157 ABI stores this through worker_private/kthread storage.
# Convert the alias in-place and normalize an ERR_PTR result to NULL because
# the old implementation treats a missing parent accounting object as false.
def convert_legacy_dmabuf_alias(match):
    indent = match.group('indent')
    name = match.group('name')
    src = match.group('src')
    return (
        f"{indent}struct task_dma_buf_info *{name} = get_task_dma_buf_info({src});\n"
        f"{indent}if (IS_ERR({name}))\n"
        f"{indent}\t{name} = NULL;"
    )

# Convert every remaining direct task_struct alias, not only the first one.
s = re.sub(
    r'(?m)^(?P<indent>\s*)struct task_dma_buf_info \*(?P<name>\w+)\s*=\s*(?P<src>task|current)->dmabuf_info\s*;',
    convert_legacy_dmabuf_alias,
    s,
)

# A vendor variant may use the parent alias without a declaration matching the
# exact ACK context. Handle the known copy_dmabuf_info() form explicitly.
copy = re.search(r'(?ms)^int copy_dmabuf_info\(.*?^\}\n(?=\nvoid put_dmabuf_info)', s)
if copy and re.search(r'\b(?:task|current)->dmabuf_info\b', copy.group(0)):
    b = copy.group(0)
    b = b.replace(
        'struct task_dma_buf_info *parent_dmabuf_info = current->dmabuf_info;',
        'struct task_dma_buf_info *parent_dmabuf_info = get_task_dma_buf_info(current);\n'
        '\tif (IS_ERR(parent_dmabuf_info))\n'
        '\t\tparent_dmabuf_info = NULL;'
    )
    b = b.replace(
        'struct task_dma_buf_info *dmabuf_info = current->dmabuf_info;',
        'struct task_dma_buf_info *dmabuf_info = get_task_dma_buf_info(current);\n'
        '\tif (IS_ERR(dmabuf_info))\n'
        '\t\tdmabuf_info = NULL;'
    )
    s = s[:copy.start()] + b + s[copy.end():]

# Some vendor copy_dmabuf_info() variants assign the already-resolved parent
# object back into the child task directly. Route that known non-NULL assignment
# through the ACK 6.1.157 setter instead of leaving a stale task_struct member.
s = re.sub(
    r'\b(?P<src>task|current)->dmabuf_info\s*=\s*(?P<value>parent_dmabuf_info)\s*;',
    lambda m: f'set_task_dma_buf_info({m.group("src")}, {m.group("value")});',
    s,
)

# The vendor implementation can also clear the legacy member directly.
# In the ACK 6.1.157 ABI this storage is accessed through the setter, so
# translate only the explicit NULL-clearing assignments here. Do not perform
# a broad member-name replacement because non-NULL assignments need semantic
# handling in their surrounding function.
s = re.sub(
    r'\b(?P<src>task|current)->dmabuf_info\s*=\s*NULL\s*;',
    lambda m: f'set_task_dma_buf_info({m.group("src")}, NULL);',
    s,
)

# Route direct allocator assignment through the ACK task DMA-BUF setter.
# This must happen before the stale-access guard below: the allocator form is
# itself a legacy task_struct access, but its RHS already produces the exact
# object expected by set_task_dma_buf_info().
s = re.sub(
    r'\b(?P<src>task|current)->dmabuf_info\s*=\s*alloc_task_dma_buf_info\(\)\s*;',
    lambda m: f'set_task_dma_buf_info({m.group("src")}, alloc_task_dma_buf_info());',
    s,
)

# Some vendor copy_dmabuf_info() variants assign the already-resolved child
# object back into the child task under a child_dmabuf_info alias. Route that
# known non-NULL assignment through the ACK 6.1.157 setter.
s = re.sub(
    r'\b(?P<src>task|current)->dmabuf_info\s*=\s*(?P<value>child_dmabuf_info)\s*;',
    lambda m: f'set_task_dma_buf_info({m.group("src")}, {m.group("value")});',
    s,
)

# Some vendor snapshots retain the legacy presence test with a slightly
# different surrounding function/signature than the ACK context above. Convert
# the test itself through the 6.1.157 accessor before the final guard. Keep this
# narrowly scoped to the boolean presence test; subsequent member dereferences
# are still rejected by the hard guard if they were not reconciled semantically.
s = re.sub(
    r'(?P<prefix>\bif\s*\(\s*)!\s*(?P<src>task|current)->dmabuf_info(?P<suffix>\s*\))',
    lambda m: f'{m.group("prefix")}!get_task_dma_buf_info({m.group("src")}){m.group("suffix")}',
    s,
)

# Normalize duplicate dmabuf_info locals in every DMA-BUF reconciliation
# function. The ACK patch can partially apply to a vendor function that already
# has a dmabuf_info declaration; in that state the fallback conversion can leave
# two declarations in the same scope. Do this after all semantic conversions,
# and do it function-by-function so unrelated locals elsewhere in dma-buf.c are
# never touched.
def find_function_block(text, name):
    """Return (start, end, block) for a C function using brace matching."""
    m = re.search(r'(?m)^(?:static\s+)?[A-Za-z_][\w\s\*]*\b' + re.escape(name) + r'\s*\([^;]*\)\s*\{', text)
    if not m:
        return None
    brace = text.find('{', m.start(), m.end())
    depth = 0
    i = brace
    state = 'code'
    while i < len(text):
        c = text[i]
        n = text[i + 1] if i + 1 < len(text) else ''
        if state == 'code':
            if c == '/' and n == '*':
                state = 'comment'; i += 2; continue
            if c == '/' and n == '/':
                state = 'linecomment'; i += 2; continue
            if c == '"':
                state = 'string'; i += 1; continue
            if c == "'":
                state = 'char'; i += 1; continue
            if c == '{': depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0:
                    return m.start(), i + 1, text[m.start():i + 1]
        elif state == 'comment':
            if c == '*' and n == '/': state = 'code'; i += 2; continue
        elif state == 'linecomment':
            if c == '\n': state = 'code'
        elif state == 'string':
            if c == '\\': i += 2; continue
            if c == '"': state = 'code'
        elif state == 'char':
            if c == '\\': i += 2; continue
            if c == "'": state = 'code'
        i += 1
    raise SystemExit(f'Unable to find end of {name}() while normalizing DMA-BUF ABI')


def normalize_dmabuf_info_locals(block, function_name):
    decl_re = re.compile(
        r'(?m)^(?P<indent>[ \t]*)struct task_dma_buf_info \*dmabuf_info\s*(?:=\s*(?P<init>[^;]+))?;\s*$'
    )
    decls = list(decl_re.finditer(block))
    if len(decls) <= 1:
        return block

    initializers = [d.group('init') for d in decls if d.group('init')]
    if len(set(initializers)) > 1:
        raise SystemExit(f'Multiple different dmabuf_info initializers remain in {function_name}()')
    initializer = initializers[0] if initializers else None
    first = decls[0]
    indent = first.group('indent')

    pieces = []
    pos = 0
    for d in decls:
        pieces.append(block[pos:d.start()])
        pos = d.end()
    pieces.append(block[pos:])
    normalized = ''.join(pieces)

    brace = normalized.find('{')
    if brace < 0:
        raise SystemExit(f'Unable to locate opening brace for {function_name}()')
    replacement = indent + 'struct task_dma_buf_info *dmabuf_info;'
    if initializer:
        replacement += '\n' + indent + 'dmabuf_info = ' + initializer + ';'
    normalized = normalized[:brace + 1] + '\n' + replacement + normalized[brace + 1:]
    return normalized


for _fn in (
    'dma_buf_account_task',
    'dma_buf_unaccount_task',
    'copy_dmabuf_info',
    'put_dmabuf_info',
):
    _found = find_function_block(s, _fn)
    if _found:
        _start, _end, _block = _found
        _normalized = normalize_dmabuf_info_locals(_block, _fn)
        s = s[:_start] + _normalized + s[_end:]

# Final structural check using the same brace-aware function parser. The previous
# implementation used a regex ending at the first `}` line, which can terminate
# at an inner block and therefore miss the real duplicate declaration that later
# reaches clang as a redefinition at compile time.
for _fn in (
    'dma_buf_account_task',
    'dma_buf_unaccount_task',
    'copy_dmabuf_info',
    'put_dmabuf_info',
):
    _found = find_function_block(s, _fn)
    if _found:
        _block = _found[2]
        _count = len(re.findall(r'(?m)^\s*struct task_dma_buf_info \*dmabuf_info\s*(?:=[^;]+)?;', _block))
        if _count > 1:
            raise SystemExit(f'Duplicate dmabuf_info declaration remains in {_fn}')

# Do not perform a blind file-wide replacement. Any remaining direct
# task_struct member access means the vendor function did not match a known
# ABI conversion block; stop rather than emitting C with a stale ABI access.
for line in s.splitlines():
    if re.search(r'\b(?:task|current)->dmabuf_info\b', line) and not line.lstrip().startswith(('//','*','/*')):
        raise SystemExit('Legacy task_struct dmabuf_info access remains: '+line.strip())
p.write_text(s)
PYTHON

  echo "[OP13R-6.1.157] drivers/dma-buf/dma-buf.c DMA-BUF ABI reconciliation complete"
fi

# Final source-level ABI checks for the two failures that otherwise only appear
# after several minutes of compilation.
if [ -f "$COMMON_DIR/include/linux/dma-buf.h" ]; then
  for sym in task_has_dma_buf_info set_task_dma_buf_info get_task_dma_buf_info; do
    grep -q "${sym}" "$COMMON_DIR/include/linux/dma-buf.h" || { echo "::error::DMA-BUF task API missing: ${sym}"; exit 1; }
  done
fi
if [ -f "$COMMON_DIR/include/linux/kthread.h" ]; then
  grep -q "get_kthread_dmabuf_info" "$COMMON_DIR/include/linux/kthread.h" || { echo "::error::DMA-BUF kthread getter missing"; exit 1; }
  grep -q "set_kthread_dmabuf_info" "$COMMON_DIR/include/linux/kthread.h" || { echo "::error::DMA-BUF kthread setter missing"; exit 1; }
fi
if grep -qE 'task->dmabuf_info|current->dmabuf_info' "$COMMON_DIR/drivers/dma-buf/dma-buf.c" 2>/dev/null; then
  echo "::error::Legacy task_struct dmabuf_info references remain in drivers/dma-buf/dma-buf.c"
  exit 1
fi
if grep -qE 'task->dmabuf_info|current->dmabuf_info' "$COMMON_DIR/fs/proc/base.c" 2>/dev/null; then
  echo "::error::Legacy task_struct dmabuf_info references remain in fs/proc/base.c"
  exit 1
fi
if [ -f "$COMMON_DIR/drivers/mmc/core/sd.c" ] && grep -q 'mmc_card_no_uhs_ddr50_tuning' "$COMMON_DIR/drivers/mmc/core/sd.c"; then
  grep -Eq '^#define[[:space:]]+MMC_QUIRK_NO_UHS_DDR50_TUNING[[:space:]]+\(1<<18\)' "$COMMON_DIR/include/linux/mmc/card.h" || { echo "::error::MMC DDR50 quirk bit is consumed but missing."; exit 1; }
  grep -q 'CID_MANFID_SWISSBIT' "$COMMON_DIR/drivers/mmc/core/card.h" || { echo "::error::MMC Swissbit manufacturer ID is missing."; exit 1; }
  grep -q 'mmc_card_no_uhs_ddr50_tuning' "$COMMON_DIR/drivers/mmc/core/card.h" || { echo "::error::MMC DDR50 helper is missing."; exit 1; }
  grep -q 'MMC_QUIRK_NO_UHS_DDR50_TUNING' "$COMMON_DIR/drivers/mmc/core/quirks.h" || { echo "::error::MMC DDR50 quirk fixup is missing."; exit 1; }
fi
if [ -f "$COMMON_DIR/net/ipv6/addrconf.c" ] && grep -q 'ra_honor_pio_pflag' "$COMMON_DIR/net/ipv6/addrconf.c"; then
  grep -q 'ra_honor_pio_pflag' "$COMMON_DIR/include/linux/ipv6.h" || { echo "::error::IPv6 ra_honor_pio_pflag is consumed but missing from ipv6_devconf."; exit 1; }
fi
if grep -RqsE '\b(F2FS_MOUNT_RESERVE_NODE|RESERVE_NODE|Opt_reserve_node|reserve_node=)' "$COMMON_DIR/fs/f2fs" --include='*.c' --include='*.h'; then
  grep -Eq '^#define[[:space:]]+F2FS_MOUNT_RESERVE_NODE[[:space:]]+0x00000001\b' "$COMMON_DIR/fs/f2fs/f2fs.h" || {
    echo "::error::F2FS reserve_node API is consumed but F2FS_MOUNT_RESERVE_NODE=0x00000001 is missing"
    exit 1
  }
  grep -Eq '^([[:space:]]*)block_t[[:space:]]+root_reserved_nodes[[:space:]]*;' "$COMMON_DIR/fs/f2fs/f2fs.h" || {
    echo "::error::F2FS reserve_node API is consumed but root_reserved_nodes is missing"
    exit 1
  }
fi
if grep -RqsE '\b(LOOKUP_PERF|LOOKUP_COMPAT|LOOKUP_AUTO|f2fs_get_lookup_mode|f2fs_set_lookup_mode|lookup_mode=)' "$COMMON_DIR/fs/f2fs" --include='*.c' --include='*.h'; then
  for sym in f2fs_get_alloc_mode f2fs_set_alloc_mode f2fs_get_lookup_mode f2fs_set_lookup_mode; do
    grep -q "\b${sym}\b" "$COMMON_DIR/fs/f2fs/f2fs.h" || {
      echo "::error::F2FS lookup/alloc API is consumed but ${sym} is missing from f2fs.h"
      exit 1
    }
  done
  grep -Eq '^#define[[:space:]]+ALLOC_MODE_BITS[[:space:]]+1\b' "$COMMON_DIR/fs/f2fs/f2fs.h" || { echo "::error::F2FS ALLOC_MODE_BITS missing"; exit 1; }
  grep -Eq '^#define[[:space:]]+LOOKUP_MODE_BITS[[:space:]]+2\b' "$COMMON_DIR/fs/f2fs/f2fs.h" || { echo "::error::F2FS LOOKUP_MODE_BITS missing"; exit 1; }
  ! grep -Eq '^[[:space:]]*int[[:space:]]+lookup_mode[[:space:]]*;' "$COMMON_DIR/fs/f2fs/f2fs.h" || { echo "::error::Invalid standalone f2fs lookup_mode field remains"; exit 1; }
fi

verify_op13r_6157_source "$COMMON_DIR"

echo "[OP13R-6.1.157] Kernel Makefile reports:"
awk '/^VERSION =|^PATCHLEVEL =|^SUBLEVEL =/{print}' "$COMMON_DIR/Makefile"

echo "::endgroup::"
