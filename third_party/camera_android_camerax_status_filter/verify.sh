#!/usr/bin/env bash
# Integrity guard of this fork. Fails if the approved origin, the patches, the app's pin, override
# or lockfile, or the filter itself differ from what was approved; rebuilds package/ from the
# official pub.dev archive plus patches/ and compares it byte for byte. Needs no Flutter or JDK.
# usage: bash third_party/camera_android_camerax_status_filter/verify.sh <work dir outside the repository>
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
WORK=${1:?work dir}

# What was approved. Changing any of these is a decision to review, not a maintenance edit.
NAME=camera_android_camerax
VERSION='0.7.4+8'
SHA=977f54512d338b3b36d7f82929794886766d8f41ae84a48fe103eb0106ecfe25
URL='https://pub.dev/api/archives/camera_android_camerax-0.7.4%2B8.tar.gz'
PATCH1=0001-drop-VideoRecordEvent-Status-before-Pigeon.patch
PATCH1_SHA=9852fa3975a8a6be1885951fb4a525a00c2a85c05a26df807aa2cfab077a520e
PATCH2=0002-status-filter-tests.patch
PATCH2_SHA=42375e31b40c22d9ba295972402ecf313a30773b5c9e0376a9715b537e833ac1
PACKAGE_PATH=third_party/camera_android_camerax_status_filter/package
LISTENER=android/src/main/java/io/flutter/plugins/camerax/VideoRecordEventListenerProxyApi.java
# F2 only replaces camera-video at exactly this CameraX version: a different one loses F2 silently.
CAMERAX=1.6.2

FAILED=0
fail() { echo "FAIL: $*"; FAILED=$((FAILED + 1)); }
sha_of() { sha256sum "$1" | cut -d' ' -f1; }
# Git may check the app's files out with CRLF (core.autocrlf); this tree is always LF.
lf() { tr -d '\r' < "$1"; }
# Prints the lines of a top-level YAML block, without comments and blank lines.
yaml_block() { lf "$1" | awk -v key="$2:" '$0 == key {on = 1; next} on && /^[^ #]/ {exit} on && !/^ *(#|$)/'; }
# Prints one two-space-indented entry of such a block.
yaml_entry() { awk -v key="  $1:" 'index($0, key) == 1 {on = 1; print; next} on && /^ {0,2}[^ ]/ {exit} on'; }

# --- origin declared by this folder
[ "$(lf "$HERE/package/pubspec.yaml" | sed -n 's/^name: //p')" = "$NAME" ] \
  || fail "package/pubspec.yaml is not $NAME"
[ "$(lf "$HERE/package/pubspec.yaml" | sed -n 's/^version: //p')" = "$VERSION" ] \
  || fail "package/pubspec.yaml version is not $VERSION"
grep -qF "\`$VERSION\`" "$HERE/UPSTREAM.md" || fail "UPSTREAM.md does not state version $VERSION"
grep -qF "\`$SHA\`" "$HERE/UPSTREAM.md" || fail "UPSTREAM.md does not state archive sha256 $SHA"
grep -qF "\`$URL\`" "$HERE/UPSTREAM.md" || fail "UPSTREAM.md does not state the archive URL"

# --- the app's pin, override and lockfile
[ "$(yaml_block "$ROOT/pubspec.yaml" dependencies | grep "^  $NAME:")" = "  $NAME: $VERSION" ] \
  || fail "pubspec.yaml does not pin $NAME: $VERSION"
EXPECTED_OVERRIDE="  $NAME:
    path: $PACKAGE_PATH"
[ "$(yaml_block "$ROOT/pubspec.yaml" dependency_overrides | yaml_entry "$NAME")" = "$EXPECTED_OVERRIDE" ] \
  || fail "pubspec.yaml dependency_overrides does not point $NAME at $PACKAGE_PATH"
EXPECTED_LOCK="  $NAME:
    dependency: \"direct main\"
    description:
      path: \"$PACKAGE_PATH\"
      relative: true
    source: path
    version: \"$VERSION\""
[ "$(yaml_block "$ROOT/pubspec.lock" packages | yaml_entry "$NAME")" = "$EXPECTED_LOCK" ] \
  || fail "pubspec.lock entry of $NAME is not the path package at $VERSION"

# --- CameraX and F2
grep -qF "val cameraxVersion = \"$CAMERAX\"" "$HERE/package/android/build.gradle.kts" \
  || fail "the plugin no longer asks for CameraX $CAMERAX"
grep -qF "substitute(module(\"androidx.camera:camera-video:$CAMERAX\"))" "$ROOT/android/app/build.gradle.kts" \
  || fail "android/app/build.gradle.kts no longer substitutes camera-video $CAMERAX by F2"

# --- the filter: Status returns before anything is posted to the main thread or to Pigeon
awk '
  /event instanceof VideoRecordEvent\.Status\) \{$/ && !filter { filter = NR }
  filter && NR == filter + 1 && /^ *return;$/ { returns = 1 }
  /\.runOnMainThread\(/ && !post { post = NR }
  END { exit !(filter && returns && post && filter < post) }
' "$HERE/package/$LISTENER" || fail "the Status filter is missing or misplaced in $LISTENER"

# --- patches: exactly the two approved files
[ "$(ls "$HERE/patches" | wc -l)" -eq 2 ] || fail "patches/ does not hold exactly the 2 approved files"
PATCHES_OK=1
[ -f "$HERE/patches/$PATCH1" ] && [ "$(sha_of "$HERE/patches/$PATCH1")" = "$PATCH1_SHA" ] \
  || { fail "patch 0001 is missing or changed"; PATCHES_OK=0; }
[ -f "$HERE/patches/$PATCH2" ] && [ "$(sha_of "$HERE/patches/$PATCH2")" = "$PATCH2_SHA" ] \
  || { fail "patch 0002 is missing or changed"; PATCHES_OK=0; }

# --- archive + patches = package/
mkdir -p "$WORK"; cd "$WORK"
[ ! -e rebuilt ] || { echo "REFUSED: $WORK/rebuilt already exists"; exit 2; }
[ -f upstream.tar.gz ] || curl -fsSL -o upstream.tar.gz "$URL" || fail "could not download $URL"
if [ ! -f upstream.tar.gz ] || [ "$(sha_of upstream.tar.gz)" != "$SHA" ]; then
  fail "upstream archive sha256 is not $SHA"
elif [ "$PATCHES_OK" -eq 1 ]; then
  mkdir rebuilt
  tar -xzf upstream.tar.gz -C rebuilt --no-same-owner
  # example/ is not needed by a consumer and is left out of package/.
  rm -rf rebuilt/example
  (cd rebuilt && patch -p1 --binary -s < "$HERE/patches/$PATCH1" && patch -p1 --binary -s < "$HERE/patches/$PATCH2") \
    || fail "the patches do not apply to the archive"
  # No exclusions: a stray file in package/ (.dart_tool, build, pubspec.lock) is also a difference.
  if diff -rq rebuilt "$HERE/package"; then echo IDENTICAL; else fail "package/ differs from archive + patches"; fi
fi

if [ "$FAILED" -ne 0 ]; then echo "GUARD FAILED: $FAILED check(s)"; exit 1; fi
echo "GUARD OK: $NAME $VERSION"
