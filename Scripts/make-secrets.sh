#!/bin/bash
# Writes Config/Secrets.xcconfig (gitignored) with the fanart.tv API key obfuscated:
# the key XORed with a random salt, both hex. Input is hidden and never echoed or committed.
# Obfuscation only keeps the key out of git and out of a plain `strings` dump; a key that
# ships inside an app can always be recovered by someone determined.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -n "${1:-}" ]; then
  echo "Pass the key at the prompt, not as an argument (arguments land in shell history)." >&2
  exit 1
fi
read -r -s -p "fanart.tv API key: " key
echo
[ -n "$key" ] || { echo "No key entered." >&2; exit 1; }

hex() { printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'; }
key_hex=$(hex "$key")
salt_hex=$(openssl rand -hex $(( ${#key_hex} / 2 )))

data=""
for (( i = 0; i < ${#key_hex}; i += 2 )); do
  data+=$(printf '%02x' $(( 0x${key_hex:i:2} ^ 0x${salt_hex:i:2} )))
done

umask 077
printf 'FANART_KEY_DATA = %s\nFANART_KEY_SALT = %s\n' "$data" "$salt_hex" > Config/Secrets.xcconfig
echo "Wrote Config/Secrets.xcconfig. Rebuild the app."
