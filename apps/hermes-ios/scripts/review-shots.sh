#!/bin/bash
# The screens of a design review round, into <dir>: iPhone 17 Pro chat / chats menu / pet sheet /
# component catalogue in light and dark, the chat at the largest accessibility size, in French and
# with another pet's colour, and the iPad Pro 13" split view in light and dark.
# Usage: scripts/review-shots.sh <dir>   (after a build; it runs build-for-testing itself)
set -uo pipefail
cd "$(dirname "$0")/.."
out="$(mkdir -p "$1" && cd "$1" && pwd)"
phone="iPhone 17 Pro"; pad="iPad Pro 13-inch (M5)"
dd="${DERIVED_DATA:-$HOME/Library/Caches/hermes-ios/DerivedData}"
GIT_CONFIG_GLOBAL=/dev/null xcodebuild build-for-testing -project Hermes.xcodeproj -scheme HermesApp \
  -destination "platform=iOS Simulator,name=$phone" -derivedDataPath "$dd" CODE_SIGNING_ALLOWED=NO -quiet || exit 1
for d in "$phone" "$pad"; do
  xcrun simctl boot "$d" 2>/dev/null; xcrun simctl bootstatus "$d" >/dev/null
  xcrun simctl status_bar "$d" override --time 9:41 --batteryState discharging --batteryLevel 100 --wifiBars 3 2>/dev/null
done
run() { # device appearance tag args tests…
  local d="$1" ap="$2" tag="$3" args="$4"; shift 4
  xcrun simctl ui "$d" appearance "$ap"
  local only=(); for t in "$@"; do only+=("-only-testing:HermesUITests/ReviewShots/$t"); done
  TEST_RUNNER_REVIEW_DIR="$out" TEST_RUNNER_REVIEW_TAG="$tag" TEST_RUNNER_REVIEW_ARGS="$args" \
    xcodebuild test-without-building -project Hermes.xcodeproj -scheme HermesApp \
    -destination "platform=iOS Simulator,name=$d" -derivedDataPath "$dd" "${only[@]}" 2>&1 | grep -E 'error:|Executed .* tests' | tail -2
}
AX="-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXXXL"
run "$phone" light light "" testChat testChatsMenu testPet testReplies testScreens testLiveActivity testWidgetGallery testCatalog
run "$phone" dark dark "" testChat testChatsMenu testPet testReplies testScreens testLiveActivity testWidgetGallery testCatalog
run "$phone" light ax5 "$AX" testChat testScreens testCatalog
run "$phone" light fr "-AppleLanguages (fr) -AppleLocale fr_FR" testChat testChatsMenu testPet testReplies testScreens
run "$phone" light otherpet-light "-petHue 200" testChat testPet
run "$phone" dark otherpet-dark "-petHue 200" testChat testPet
run "$pad" light light "" testChat testScreens
run "$pad" dark dark "" testChat
run "$pad" light compact "-compactWidth" testChat
run "$phone" light light "" testChatLandscape
run "$phone" dark dark "" testChatLandscape
run "$phone" light ax5 "$AX" testChatLandscape
# Accessibility settings (design-rules 7.1): Increase Contrast through simctl, Reduce
# Transparency and Reduce Motion through the simulator's accessibility defaults.
xcrun simctl ui "$phone" increase_contrast enabled
run "$phone" light contrast-light "" testChat testPet
run "$phone" dark contrast-dark "" testChat
xcrun simctl ui "$phone" increase_contrast disabled
ax() { xcrun simctl spawn "$phone" defaults write com.apple.Accessibility "$1" -bool "$2"; }
ax EnhancedBackgroundContrastEnabled true
run "$phone" light reducetransparency-light "" testChat testChatsMenu
run "$phone" dark reducetransparency-dark "" testChat
ax EnhancedBackgroundContrastEnabled false
ax ReduceMotionEnabled true
run "$phone" light reducemotion "" testPet
ax ReduceMotionEnabled false
xcrun simctl ui "$phone" appearance light; xcrun simctl ui "$pad" appearance light
# iPad shots come out in the portrait buffer: turn them to landscape.
python3 -I - "$out" <<'PY'
import sys, glob
from PIL import Image
for f in glob.glob(sys.argv[1] + "/ipad-*.png"):
    im = Image.open(f)
    if im.height > im.width: im.rotate(90, expand=True).save(f)
# The hosted iPhone landscape is drawn rotated a quarter turn clockwise: turn it upright.
for f in glob.glob(sys.argv[1] + "/iphone-chat-landscape-*.png"):
    im = Image.open(f)
    if im.height > im.width: im.rotate(90, expand=True).save(f)
PY
ls "$out" | wc -l
