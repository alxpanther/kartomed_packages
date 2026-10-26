#!/bin/bash
# Builds the Kartomed dictionaries from fresh sources into build/dictionaries/
# (diagnoses, medicines, then our own lists — they check their codes against
# the diagnoses), checks them against public/dictionaries/ and publishes what
# changed (dictionaries/publish.dart). The monthly workflow runs it; it can
# also be run by hand.
#
# Needs: dart, pdftotext (poppler-utils), unzip, git.
# The sources are downloaded into tmp/dictionaries/ and removed at the end.
# A source that is unavailable, or a failed check, stops the script with an
# error and publishes nothing: the previous files stay.

set -e
cd "$(dirname "$0")"

for tool in dart pdftotext unzip git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Dictionaries: '$tool' is not installed" >&2
    exit 1
  fi
done

# Always fresh sources and a clean build: nothing of a previous run may be
# published by mistake.
rm -rf tmp/dictionaries build

echo "Dictionaries: diagnoses"
dart run dictionaries/build_diagnoses.dart
echo "Dictionaries: medicines"
dart run dictionaries/build_drugs.dart
echo "Dictionaries: own lists"
dart run dictionaries/build_own_lists.dart
echo "Dictionaries: checking and publishing"
dart run dictionaries/publish.dart

rm -rf tmp/dictionaries
rmdir tmp 2>/dev/null || true
