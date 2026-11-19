#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export XDG_STATE_HOME="/tmp/super-harness-test-state"
mkdir -p "${XDG_STATE_HOME}"

TESTS=(
  "tests/test_adapters_spec.lua"
  "tests/test_context_spec.lua"
  "tests/test_sync_review_spec.lua"
  "tests/test_backends_ui_spec.lua"
)

echo "=============================================="
echo "Running super-harness.nvim headless test suite"
echo "=============================================="

for t in "${TESTS[@]}"; do
  echo ""
  echo "--- Running $t ---"
  nvim --headless -u NONE \
    --cmd "set rtp+=${ROOT_DIR}" \
    --cmd "runtime plugin/super_harness.lua" \
    -l "${ROOT_DIR}/${t}"
done

echo ""
echo "=============================================="
echo "✅ ALL SUPER-HARNESS.NVIM TEST SUITES PASSED!"
echo "=============================================="
