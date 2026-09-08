#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
verification_derived_data="/tmp/AI-Spotlight-Verification"
launch_services_tool="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"

unregister_verification_apps() {
  for build_configuration in Debug Release; do
    verification_app="$verification_derived_data/Build/Products/$build_configuration/PrimaryAgent.app"
    if [ -d "$verification_app" ]; then
      "$launch_services_tool" -u "$verification_app" >/dev/null 2>&1 || true
    fi
  done
}

usage() {
  echo "Usage: $0 build|test|analyze [additional xcodebuild arguments]" >&2
  exit 64
}

[ "$#" -ge 1 ] || usage

verification_action=$1
shift

case "$verification_action" in
  build|test|analyze) ;;
  *) usage ;;
esac

# App-hosted tests can register their unsigned host even when ordinary product
# registration is disabled. Remove stale registrations before and after every
# verification action so Launch Services never chooses this copy for the user.
unregister_verification_apps
trap unregister_verification_apps EXIT HUP INT TERM

cd "$repository_root"
xcodebuild "$verification_action" \
  -project AI-Spotlight.xcodeproj \
  -scheme AI-Spotlight \
  -destination 'platform=macOS' \
  -derivedDataPath "$verification_derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  REGISTER_WITH_LAUNCH_SERVICES=NO \
  "$@"
