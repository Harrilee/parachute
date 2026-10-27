#!/bin/bash
set -euo pipefail
INPUT="${1:?Usage: notarize.sh input-file evidence-prefix}"
PREFIX="${2:?Evidence prefix is required}"
: "${KEYCHAIN_PATH:?}" "${NOTARY_PROFILE:?}"
mkdir -p "$(dirname "$PREFIX")"
echo "Submitting $(basename "$INPUT") to Apple notarization"
# Save the submission ID before waiting, including when a later wait is cancelled.
xcrun notarytool submit "$INPUT" --keychain "$KEYCHAIN_PATH" --keychain-profile "$NOTARY_PROFILE" \
    --output-format json > "$PREFIX-submission.json"
SUBMISSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$PREFIX-submission.json")"
echo "Waiting for notarization submission $SUBMISSION"
WAIT_EXIT=0
xcrun notarytool wait "$SUBMISSION" --keychain "$KEYCHAIN_PATH" --keychain-profile "$NOTARY_PROFILE" \
    --timeout 30m --output-format json > "$PREFIX.json" || WAIT_EXIT=$?
xcrun notarytool log "$SUBMISSION" --keychain "$KEYCHAIN_PATH" --keychain-profile "$NOTARY_PROFILE" \
    "$PREFIX-log.json" || true
STATUS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status", "Unknown"))' "$PREFIX.json")"
[ "$WAIT_EXIT" = 0 ] && [ "$STATUS" = Accepted ] || { echo "Notarization failed or timed out: $STATUS" >&2; exit 1; }
echo "Apple accepted notarization submission $SUBMISSION"
