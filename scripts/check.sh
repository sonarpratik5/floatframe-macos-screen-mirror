#!/bin/bash
set -euo pipefail

test_args=(-parallel-testing-enabled NO)
case "${1:-}" in
  "") test_args+=(-only-testing:popupTests) ;;
  --ui-tests) ;;
  *) echo "Usage: bash scripts/check.sh [--ui-tests]" >&2; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then
  echo "Usage: bash scripts/check.sh [--ui-tests]" >&2
  exit 2
fi

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

build_args=(
  -project popup.xcodeproj
  -scheme popup
  -destination 'platform=macOS'
  -derivedDataPath "${POPUP_DERIVED_DATA_PATH:-$project_root/build/DerivedData}"
  CODE_SIGN_IDENTITY=-
)

for configuration in Debug Release; do
  xcodebuild "${build_args[@]}" -configuration "$configuration" build
done

xcodebuild "${build_args[@]}" -configuration Debug \
  "${test_args[@]}" test
