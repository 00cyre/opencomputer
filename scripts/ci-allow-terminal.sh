#!/bin/bash
# CI only: lets Terminal use Accessibility and Screen Recording on a disposable GitHub macOS
# runner, so scripts/record-demo.sh can run the demo inside Terminal and show the guard for
# the agent's own app. Best effort: if the runner's TCC database is not writable, the
# recording falls back to running the demo from the CI shell. Never run this on your own Mac.
set -u
[ "${CI:-}" = true ] && [ "${GITHUB_ACTIONS:-}" = true ] || { echo "CI only; nothing changed."; exit 1; }
DB="/Library/Application Support/com.apple.TCC/TCC.db"
for SERVICE in kTCCServiceAccessibility kTCCServiceScreenCapture kTCCServicePostEvent; do
  sudo sqlite3 "$DB" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, indirect_object_identifier, flags, last_modified) VALUES ('$SERVICE', 'com.apple.Terminal', 0, 2, 4, 1, 'UNUSED', 0, CAST(strftime('%s','now') AS INTEGER));" \
    || echo "Could not allow $SERVICE for Terminal."
done
sudo sqlite3 "$DB" "SELECT service, auth_value FROM access WHERE client = 'com.apple.Terminal';" || true
# macOS 15 and later also ask, in a dialog that stays on screen, before an app captures the
# screen without the system picker. A future date for Terminal here answers that question.
APPROVALS="$HOME/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals"
mkdir -p "$(dirname "$APPROVALS")"
for KEY in /System/Applications/Utilities/Terminal.app com.apple.Terminal; do
  defaults write "$APPROVALS" "$KEY" -date "2099-01-01 00:00:00 +0000" || echo "Could not pre-approve screen capture for $KEY."
done
killall replayd 2>/dev/null || true
sw_vers -productVersion
exit 0
