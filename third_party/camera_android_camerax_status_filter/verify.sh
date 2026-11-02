#!/usr/bin/env bash
# Integrity guard of this fork. Fails if the approved origin, the patches, the app's pin, override
# or lockfile, the filter or the evidence channel differ from what was approved; rebuilds package/ from the
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
PATCH3=0003-recording-evidence-channel.patch
PATCH3_SHA=e86f3313728d97a39a6ce2b74ee79188d0af55723f36c8c3b9905199811bbfdc
PATCH4=0004-recording-evidence-tests.patch
PATCH4_SHA=a4441543325163232522f293290de614a8466e2df916fb79e6061d9c2f598282
PACKAGE_PATH=third_party/camera_android_camerax_status_filter/package
LISTENER=android/src/main/java/io/flutter/plugins/camerax/VideoRecordEventListenerProxyApi.java
PLUGIN_DART=lib/src/android_camera_camerax.dart
PIGEON_SOURCE=pigeons/camerax_library.dart
PIGEON_DART=lib/src/camerax_library.g.dart
PIGEON_KOTLIN=android/src/main/java/io/flutter/plugins/camerax/CameraXLibrary.g.kt
EVIDENCE_JUNIT=android/src/test/java/io/flutter/plugins/camerax/VideoRecordEventListenerRecordingEvidenceTest.java
EVIDENCE_DART_TEST=test/recording_evidence_contract_test.dart
EVIDENCE_CHANNEL=synapse_auto.camera_android_camerax/recording_evidence
REPRO_FILES="normalize_kotlin.dart=bac1ac5d74ad77f410ab50c8b32100811e601a8ca0c27848df39952625b6458b reproduce.sh=950ba452a59409d69e1e683940b3e283aff320da629d84843fb407712ebbabc8 selftest.sh=2e2a5fa10a66b698443ccc546e5483baac6e6ea8d2cd008528d7cc5cf3430dbe tool/pubspec.yaml=b23e3fdafef8be33ea4800032feb9f56ccb10a4fad00326765bced55fa988a41 tool/pubspec.lock=b41f8931da3822b3b0e26e0e518bdb9b5a92f69b31fbd0ce10815e71f2038b72"
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
  filter && NR == filter + 1 && /^ *reportVideoProgressOnce\(/ { reports = 1 }
  filter && NR == filter + 2 && /^ *return;$/ { returns = 1 }
  /\.runOnMainThread\(/ && !post { post = NR }
  END { exit !(filter && reports && returns && post && filter < post) }
' "$HERE/package/$LISTENER" || fail "the Status filter is missing or misplaced in $LISTENER"

# --- the evidence channel: one name on both sides, read from the duration and never from the bytes
grep -qF "\"$EVIDENCE_CHANNEL\"" "$HERE/package/$LISTENER" || fail "the evidence channel name changed in $LISTENER"
grep -qF "'$EVIDENCE_CHANNEL'" "$HERE/package/$PLUGIN_DART" || fail "the evidence channel name changed in $PLUGIN_DART"
grep -qF 'getRecordedDurationNanos() <= 0' "$HERE/package/$LISTENER" || fail "the evidence no longer reads the recorded duration"
if grep -qF '.getNumBytesRecorded' "$HERE/package/$LISTENER"; then fail "the evidence reads a byte count, which includes audio"; fi

# --- the identity: bound before START in one Pigeon constructor, and the only thing that says whose a message is
grep -qF 'VideoRecordEventListener(int recordingIdentity);' "$HERE/package/$PIGEON_SOURCE" || fail "the Pigeon definition no longer takes the identity"
grep -qF 'required int recordingIdentity,' "$HERE/package/$PIGEON_DART" || fail "$PIGEON_DART was not generated with the identity"
grep -qF 'val recordingIdentityArg = args[1] as Long' "$HERE/package/$PIGEON_KOTLIN" || fail "$PIGEON_KOTLIN was not generated with the identity"
# Native chooses it: nothing in Dart may be a source of identities again.
grep -qF 'private static final AtomicLong LAST_RECORDING_IDENTITY' "$HERE/package/$LISTENER" || fail "the identity no longer comes from one native counter of the process"
# Exhaustion is terminal: one compare-and-set, MAX_VALUE never issued, and no increment that moves on after refusing.
if grep -qE 'LAST_RECORDING_IDENTITY\.(incrementAndGet|getAndIncrement|addAndGet|getAndAdd|set|lazySet|getAndSet|updateAndGet|getAndUpdate|accumulateAndGet|getAndAccumulate)\b' "$HERE/package/$LISTENER"; then fail "the identity counter moves by something other than its one compare-and-set"; fi
grep -qF 'LAST_RECORDING_IDENTITY.compareAndSet(last, identity)' "$HERE/package/$LISTENER" || fail "the identity no longer advances by compare-and-set"
grep -qF 'last == Long.MAX_VALUE' "$HERE/package/$LISTENER" || fail "the identity allocator no longer stops at its terminal state"
grep -qF 'int allocateRecordingIdentity();' "$HERE/package/$PIGEON_SOURCE" || fail "the Pigeon definition no longer has the allocator"
grep -qF 'await VideoRecordEventListener.allocateRecordingIdentity()' "$HERE/package/$PLUGIN_DART" || fail "START no longer asks native for the identity"
if grep -qE '_lastRecordingIdentity|Random\.|DateTime\.now' "$HERE/package/$PLUGIN_DART"; then fail "$PLUGIN_DART has a source of identities or clock of its own"; fi
# Dispose withdraws the evidence before anything it can wait for or fail at.
awk '/Future<void> dispose\(int cameraId\) async \{/ {on = 1; next} on && /_clearRecordingEvidence\(\);/ {found = 1; exit} on && /await / {exit} END {exit !found}' "$HERE/package/$PLUGIN_DART" || fail "dispose no longer withdraws the evidence before its first await"
grep -qF 'Arrays.asList(kind, recordingIdentity, error)' "$HERE/package/$LISTENER" || fail "the evidence no longer carries the identity"
if grep -qF '.getFile()' "$HERE/package/$LISTENER"; then fail "the evidence reads the file path, which a later recording may reuse"; fi
grep -qF 'identity != current.token' "$HERE/package/$PLUGIN_DART" || fail "Dart no longer compares the identity"
grep -qF 'pendingRecording!.start(_bindRecordingIdentity(identity, evidenceEpoch))' "$HERE/package/$PLUGIN_DART" || fail "START is no longer bound to its own listener"
# Each side's test pins the bytes against its real implementation; here they must be the same bytes.
golden() { grep -oE '0c03070[de][0-9a-f]+' "$1" | sort -u; }
[ -n "$(golden "$HERE/package/$EVIDENCE_JUNIT")" ] && [ "$(golden "$HERE/package/$EVIDENCE_JUNIT")" = "$(golden "$HERE/package/$EVIDENCE_DART_TEST")" ] \
  || fail "the wire bytes pinned by the JUnit and the Dart tests differ"

# --- the channel's owner: one static handler, so that a second instance cannot silence the first
grep -qF 'static void _installRecordingEvidenceHandler()' "$HERE/package/$PLUGIN_DART" || fail "the channel handler is no longer the class's"
grep -qF '_recordingEvidenceChannel.setMessageHandler(_onRecordingEvidenceMessage)' "$HERE/package/$PLUGIN_DART" || fail "the channel handler is no longer the static function"
[ "$(grep -c 'setMessageHandler' "$HERE/package/$PLUGIN_DART")" -eq 1 ] || fail "$PLUGIN_DART installs more than one channel handler"
grep -qF 'getIgnoreCallsToDart()' "$HERE/package/$LISTENER" || fail "the evidence no longer stops when the plugin detaches"

# --- the procedure that rebuilds the generated files: not run here, it needs Dart
for entry in $REPRO_FILES; do
  [ -f "$HERE/pigeon_repro/${entry%%=*}" ] && [ "$(sha_of "$HERE/pigeon_repro/${entry%%=*}")" = "${entry#*=}" ] \
    || fail "pigeon_repro/${entry%%=*} is missing or changed"
done

# --- patches: exactly the four approved files
[ "$(ls "$HERE/patches" | wc -l)" -eq 4 ] || fail "patches/ does not hold exactly the 4 approved files"
PATCHES_OK=1
[ -f "$HERE/patches/$PATCH1" ] && [ "$(sha_of "$HERE/patches/$PATCH1")" = "$PATCH1_SHA" ] \
  || { fail "patch 0001 is missing or changed"; PATCHES_OK=0; }
[ -f "$HERE/patches/$PATCH2" ] && [ "$(sha_of "$HERE/patches/$PATCH2")" = "$PATCH2_SHA" ] \
  || { fail "patch 0002 is missing or changed"; PATCHES_OK=0; }
[ -f "$HERE/patches/$PATCH3" ] && [ "$(sha_of "$HERE/patches/$PATCH3")" = "$PATCH3_SHA" ] \
  || { fail "patch 0003 is missing or changed"; PATCHES_OK=0; }
[ -f "$HERE/patches/$PATCH4" ] && [ "$(sha_of "$HERE/patches/$PATCH4")" = "$PATCH4_SHA" ] \
  || { fail "patch 0004 is missing or changed"; PATCHES_OK=0; }

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
  (cd rebuilt && patch -p1 --binary -s < "$HERE/patches/$PATCH1" && patch -p1 --binary -s < "$HERE/patches/$PATCH2" \
    && patch -p1 --binary -s < "$HERE/patches/$PATCH3" && patch -p1 --binary -s < "$HERE/patches/$PATCH4") \
    || fail "the patches do not apply to the archive"
  # No exclusions: a stray file in package/ (.dart_tool, build, pubspec.lock) is also a difference.
  if diff -rq rebuilt "$HERE/package"; then echo IDENTICAL; else fail "package/ differs from archive + patches"; fi
fi

if [ "$FAILED" -ne 0 ]; then echo "GUARD FAILED: $FAILED check(s)"; exit 1; fi
echo "GUARD OK: $NAME $VERSION"
