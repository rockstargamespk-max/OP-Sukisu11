#!/usr/bin/env bash
set -euo pipefail

COMMON_DIR="${COMMON_KERNEL_FOLDER:-${GITHUB_WORKSPACE:-.}/OP13r/kernel_platform/common}"
if [[ ! -d "$COMMON_DIR" ]]; then
  echo "::error::OP13R common kernel tree not found: $COMMON_DIR"
  exit 1
fi
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

git -C "$WORK_DIR/oneplus" checkout -B op13r-6.1.157-experimental "$ONEPLUS_REV"
GIT_EDITOR=true git -C "$WORK_DIR/oneplus" rebase --rebase-merges --onto "$ACK_TAG" "$BASE"

echo "[OP13R-6.1.157] Rebase completed: $(git -C "$WORK_DIR/oneplus" rev-parse HEAD)"
echo "[OP13R-6.1.157] Exporting rebased source over kernel_platform/common..."

find "$COMMON_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
git -C "$WORK_DIR/oneplus" archive HEAD | tar -x -C "$COMMON_DIR"

echo "[OP13R-6.1.157] Kernel Makefile reports:"
awk '/^VERSION =|^PATCHLEVEL =|^SUBLEVEL =/{print}' "$COMMON_DIR/Makefile"

echo "::endgroup::"
