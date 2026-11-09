#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/swift-env.sh"
source "$AW_PROJECT_ROOT/Scripts/sparkle-tools.sh"
# Dedicated Keychain account; never exports or prints a private signing key.
"$AW_SPARKLE_TOOL_DIR/bin/generate_keys" --account dev.awatcher.app
AW_PUBLIC_KEY="$("$AW_SPARKLE_TOOL_DIR/bin/generate_keys" --account dev.awatcher.app -p)"
export AW_PUBLIC_KEY
python3 - "$AW_PROJECT_ROOT/Resources/Info.plist" <<'PY'
import base64, os, plistlib, sys
path = sys.argv[1]
key = os.environ['AW_PUBLIC_KEY'].strip()
assert len(base64.b64decode(key, validate=True)) == 32, 'Invalid public key'
with open(path, 'rb') as f:
    info = plistlib.load(f)
existing = info.get('SUPublicEDKey')
if existing and existing != key:
    sys.exit('Refusing to replace an existing update trust key. See docs/dev/auto-update.md.')
info['SUPublicEDKey'] = key
with open(path, 'wb') as f:
    plistlib.dump(info, f, sort_keys=False)
print('Update public key configured. Private key remains in the login Keychain.')
PY
