#!/bin/bash
# Collects the clinic networks of clinics/sources.json from their sites,
# reads them with Claude, checks them against public/packages/ and publishes
# what changed (clinics/collect_clinics.dart). The monthly workflow runs it;
# it can also be run by hand: ./build_clinics.sh [--only=id,id]
#
# Needs: dart, google-chrome (pages whose list a script draws) and the key
# ANTHROPIC_API_KEY — from the environment, or the line of the local .env.
# A network that cannot be read keeps its previous files (build/warnings.txt);
# a failed check publishes nothing (build/errors.txt).

set -e
cd "$(dirname "$0")"

if [ -z "$ANTHROPIC_API_KEY" ] && [ -f .env ]; then
  ANTHROPIC_API_KEY="$(grep -E '^ANTHROPIC_API_KEY=' .env | cut -d= -f2- || true)"
  export ANTHROPIC_API_KEY
fi
if [ -z "$ANTHROPIC_API_KEY" ]; then
  echo "Clinics: ANTHROPIC_API_KEY is not set" >&2
  exit 1
fi

rm -rf build/packages tmp/clinics
dart run clinics/collect_clinics.dart "$@"
rm -rf tmp/clinics
rmdir tmp 2>/dev/null || true
