#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/XMLFixer"
APP_NAME="${APP_NAME:-RPB XML Toolkit}"
SCHEME="${SCHEME:-XMLFixer}"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$PROJECT_DIR/build_notarized}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/builds}"
BUILD_LABEL="${BUILD_LABEL:-$(awk -F'"' '/static let buildVersion/{print $2; exit}' "$PROJECT_DIR/XMLFixer/App/XMLFixerApp.swift")}"
TEAM_ID="${TEAM_ID:-}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-}"
APPLE_ID="${APPLE_ID:-}"
APP_SPECIFIC_PASSWORD="${APP_SPECIFIC_PASSWORD:-}"
APPSTORE_CONNECT_KEY="${APPSTORE_CONNECT_KEY:-}"
APPSTORE_CONNECT_KEY_ID="${APPSTORE_CONNECT_KEY_ID:-}"
APPSTORE_CONNECT_ISSUER_ID="${APPSTORE_CONNECT_ISSUER_ID:-}"

UNSIGNED_APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
SIGNED_APP_PATH="$OUTPUT_DIR/$APP_NAME $BUILD_LABEL.app"
UPLOAD_ZIP_PATH="$OUTPUT_DIR/$APP_NAME $BUILD_LABEL-notary-upload.zip"
FINAL_ZIP_PATH="$OUTPUT_DIR/$APP_NAME $BUILD_LABEL.zip"
NOTARY_LOG_PATH="$OUTPUT_DIR/$APP_NAME $BUILD_LABEL-notary-result.json"

fail() {
  echo "error: $*" >&2
  exit 1
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "Required tool '$1' is not installed."
}

remove_path_if_exists() {
  local path="$1"
  [[ -e "$path" ]] || return 0
  rm -r "$path"
}

pick_signing_identity() {
  local identities
  identities="$(security find-identity -v -p codesigning)"
  if [[ -n "$TEAM_ID" ]]; then
    echo "$identities" | awk -v team="$TEAM_ID" '
      /Developer ID Application:/ && index($0, "(" team ")") {
        if (match($0, /"[^"]+"/)) {
          print substr($0, RSTART + 1, RLENGTH - 2)
          exit
        }
      }
    '
  else
    echo "$identities" | awk '
      /Developer ID Application:/ {
        if (match($0, /"[^"]+"/)) {
          print substr($0, RSTART + 1, RLENGTH - 2)
          exit
        }
      }
    '
  fi
}

extract_team_from_identity() {
  local identity="$1"
  if [[ "$identity" =~ \(([A-Z0-9]{10})\)$ ]]; then
    echo "${BASH_REMATCH[1]}"
  fi
}

build_app() {
  echo "==> Building $APP_NAME ($CONFIGURATION)"
  xcodebuild \
    -project "$PROJECT_DIR/XMLFixer.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    build \
    CODE_SIGNING_ALLOWED=NO \
    ONLY_ACTIVE_ARCH=NO \
    ARCHS="arm64 x86_64"
  [[ -d "$UNSIGNED_APP_PATH" ]] || fail "Build output not found at '$UNSIGNED_APP_PATH'."
}

sign_app() {
  echo "==> Signing with identity: $SIGNING_IDENTITY"
  mkdir -p "$OUTPUT_DIR"
  remove_path_if_exists "$SIGNED_APP_PATH"
  remove_path_if_exists "$UPLOAD_ZIP_PATH"
  remove_path_if_exists "$FINAL_ZIP_PATH"
  remove_path_if_exists "$NOTARY_LOG_PATH"
  cp -R "$UNSIGNED_APP_PATH" "$SIGNED_APP_PATH"

  # Clear quarantine and stale extended attributes before signing.
  xattr -cr "$SIGNED_APP_PATH"

  codesign \
    --force \
    --deep \
    --options runtime \
    --entitlements "$PROJECT_DIR/XMLFixer/XMLFixer.entitlements" \
    --timestamp \
    --sign "$SIGNING_IDENTITY" \
    "$SIGNED_APP_PATH"

  codesign --verify --deep --strict --verbose=2 "$SIGNED_APP_PATH"
}

build_notary_args() {
  if [[ -n "$NOTARYTOOL_PROFILE" ]]; then
    NOTARY_ARGS=(--keychain-profile "$NOTARYTOOL_PROFILE")
    return
  fi

  if [[ -n "$APPSTORE_CONNECT_KEY" && -n "$APPSTORE_CONNECT_KEY_ID" && -n "$APPSTORE_CONNECT_ISSUER_ID" ]]; then
    NOTARY_ARGS=(--key "$APPSTORE_CONNECT_KEY" --key-id "$APPSTORE_CONNECT_KEY_ID" --issuer "$APPSTORE_CONNECT_ISSUER_ID")
    return
  fi

  if [[ -n "$APPLE_ID" && -n "$APP_SPECIFIC_PASSWORD" ]]; then
    NOTARY_ARGS=(--apple-id "$APPLE_ID" --password "$APP_SPECIFIC_PASSWORD" --team-id "$TEAM_ID")
    return
  fi

  fail "No notary authentication configured. Set NOTARYTOOL_PROFILE, or APPSTORE_CONNECT_KEY + APPSTORE_CONNECT_KEY_ID + APPSTORE_CONNECT_ISSUER_ID, or APPLE_ID + APP_SPECIFIC_PASSWORD."
}

notarize_app() {
  echo "==> Zipping app for notarization upload"
  ditto -c -k --keepParent "$SIGNED_APP_PATH" "$UPLOAD_ZIP_PATH"

  echo "==> Submitting to Apple notarization service"
  xcrun notarytool submit "$UPLOAD_ZIP_PATH" "${NOTARY_ARGS[@]}" --wait --output-format json >"$NOTARY_LOG_PATH"

  echo "==> Stapling notarization ticket"
  xcrun stapler staple "$SIGNED_APP_PATH"
  xcrun stapler validate "$SIGNED_APP_PATH"

  echo "==> Validating Gatekeeper acceptance"
  spctl --assess --type execute --verbose=4 "$SIGNED_APP_PATH"

  echo "==> Creating final distributable zip"
  ditto -c -k --keepParent "$SIGNED_APP_PATH" "$FINAL_ZIP_PATH"
}

main() {
  require_tool xcodebuild
  require_tool codesign
  require_tool ditto
  require_tool xcrun
  require_tool spctl
  require_tool xattr

  if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(pick_signing_identity)"
  fi
  [[ -n "$SIGNING_IDENTITY" ]] || fail "No 'Developer ID Application' certificate found in your keychain."

  if [[ -z "$TEAM_ID" ]]; then
    TEAM_ID="$(extract_team_from_identity "$SIGNING_IDENTITY")"
  fi
  [[ -n "$TEAM_ID" ]] || fail "Could not infer TEAM_ID from signing identity. Set TEAM_ID explicitly."

  build_notary_args
  build_app
  sign_app
  notarize_app

  echo
  echo "Success. Notarized app and archive:"
  echo "  App: $SIGNED_APP_PATH"
  echo "  Zip: $FINAL_ZIP_PATH"
  echo "  Notary log: $NOTARY_LOG_PATH"
}

main "$@"
