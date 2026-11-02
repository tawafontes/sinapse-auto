#!/usr/bin/env bash
# Proves reproduce.sh fails when it should. Each case damages a COPY of the fork and expects the exact
# failure; the real fork is compared by hash at the end.
#
# usage: bash third_party/camera_android_camerax_status_filter/pigeon_repro/selftest.sh <empty work dir outside the repository>
# ARCHIVE and PUB_CACHE as in reproduce.sh; a PUB_CACHE avoids downloading the generator per case.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
FORK=$(cd "$HERE/.." && pwd)
WORK=${1:?work dir}
mkdir -p "$WORK"; WORK=$(cd "$WORK" && pwd)
[ -z "$(ls -A "$WORK")" ] || { echo "REFUSED: $WORK is not empty"; exit 2; }

DEFINITION=package/pigeons/camerax_library.dart
GEN_DART=package/lib/src/camerax_library.g.dart
GEN_KOTLIN=package/android/src/main/java/io/flutter/plugins/camerax/CameraXLibrary.g.kt
N=0; BAD=0

tree_sum() { (cd "$1" && cat pigeon_repro/normalize_kotlin.dart pigeon_repro/reproduce.sh pigeon_repro/tool/pubspec.yaml pigeon_repro/tool/pubspec.lock "$DEFINITION" package/pigeons/copyright.txt "$GEN_DART" "$GEN_KOTLIN" | sha256sum); }
REAL_BEFORE=$(tree_sum "$FORK")

copy_fork() {
  mkdir -p "$1/pigeon_repro/tool" "$1/package/pigeons" "$1/$(dirname "$GEN_DART")" "$1/$(dirname "$GEN_KOTLIN")"
  cp "$FORK/pigeon_repro/normalize_kotlin.dart" "$FORK/pigeon_repro/reproduce.sh" "$1/pigeon_repro/"
  cp "$FORK/pigeon_repro/tool/pubspec.yaml" "$FORK/pigeon_repro/tool/pubspec.lock" "$1/pigeon_repro/tool/"
  cp "$FORK/$DEFINITION" "$FORK/package/pigeons/copyright.txt" "$1/package/pigeons/"
  cp "$FORK/$GEN_DART" "$1/$GEN_DART"
  cp "$FORK/$GEN_KOTLIN" "$1/$GEN_KOTLIN"
}

# name, exit expected (0/1), text expected in the output, perl edit, file to edit in the copy
case_of() {
  local name=$1 want_exit=$2 want_text=$3 edit=$4 file=$5
  N=$((N + 1))
  local copy="$WORK/case$N/fork" out="$WORK/case$N/out.log" before got=0
  copy_fork "$copy"
  if [ -n "$file" ]; then
    before=$(sha256sum "$copy/$file")
    perl -0pi -e "$edit" "$copy/$file"
    [ "$before" != "$(sha256sum "$copy/$file")" ] || { echo "BAD  $name: the damage did not apply"; BAD=$((BAD + 1)); return; }
  fi
  local copy_before; copy_before=$(tree_sum "$copy")
  bash "$copy/pigeon_repro/reproduce.sh" "$WORK/case$N/work" > "$out" 2>&1 || got=$?
  if [ "$got" != "$want_exit" ]; then
    echo "BAD  $name: exit $got, expected $want_exit"; sed 's/^/     /' "$out"; BAD=$((BAD + 1))
  elif ! grep -qF "$want_text" "$out"; then
    echo "BAD  $name: no '$want_text'"; sed 's/^/     /' "$out"; BAD=$((BAD + 1))
  elif [ "$copy_before" != "$(tree_sum "$copy")" ]; then
    echo "BAD  $name: the run changed the kept files"; BAD=$((BAD + 1))
  else
    echo "ok   $name"
  fi
}

case_of 'control: the unchanged fork reproduces' 0 'REPRODUCED' '' ''
case_of 'one byte of the kept Kotlin differs' 1 "FAIL: package's Kotlin = upstream + the recorded change" 's/recordingIdentityArg = args\[1\]/recordingIdentityArg = args[2]/' "$GEN_KOTLIN"
case_of 'trailing whitespace in the kept Kotlin' 1 "FAIL: package's Kotlin = upstream + the recorded change" 's/\z/\n/' "$GEN_KOTLIN"
case_of 'one byte of the kept Dart differs' 1 "FAIL: package's Dart = generator + dart format" 's/required int recordingIdentity,/required int recordingIdentitx,/' "$GEN_DART"
case_of 'the definition changed: the recorded change is no longer all' 1 'FAIL: the recorded change is all the generator changed' 's/VideoRecordEventListener\(int recordingIdentity\);/VideoRecordEventListener(int recordingIdentity, bool extra);/' "$DEFINITION"
case_of 'pubspec asks another Pigeon' 1 'does not pin pigeon 27.3.2' 's/pigeon: 27\.3\.2/pigeon: 27.3.1/' pigeon_repro/tool/pubspec.yaml
case_of 'lockfile locks another Pigeon' 1 'locks pigeon 27.3.1, not 27.3.2' 's/(  pigeon:\n(?:    .*\n|      .*\n)*?    version: )"27\.3\.2"/$1"27.3.1"/' pigeon_repro/tool/pubspec.lock
case_of 'a locked package has another content hash' 1 'the locked generator could not be resolved' 's/(name: pigeon\n      sha256: )d/${1}e/' pigeon_repro/tool/pubspec.lock
case_of 'a table layout with other tokens' 1 'not the same tokens' 's/(.*)api\.allocateRecordingIdentity\(\)/${1}api.allocateRecordingIdentity(1)/s' pigeon_repro/normalize_kotlin.dart

# The normalizer alone: a context it cannot place once is refused, whatever else the file holds.
NORMALIZE="$FORK/pigeon_repro/normalize_kotlin.dart"
native_path() { if command -v cygpath > /dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
refused() { # name file expected
  N=$((N + 1))
  local out; if out=$(cd "$WORK" && dart "$(native_path "$NORMALIZE")" formatted "$(native_path "$2")" "$(native_path "$2.out")" 2>&1); then
    echo "BAD  $1: accepted"; BAD=$((BAD + 1))
  elif [ -e "$2.out" ] || ! echo "$out" | grep -qF "$3"; then
    echo "BAD  $1: $out"; BAD=$((BAD + 1))
  else
    echo "ok   $1"
  fi
}
mkdir -p "$WORK/n"
UPSTREAM="$WORK/case1/work/upstream/$(echo "$GEN_KOTLIN" | sed 's#^package/##')"
perl -0pe 's/(\/\*\* Listens for `VideoRecordEvent`s from a `PendingRecording`\. \*\/\n)/$1$1/' "$UPSTREAM" > "$WORK/n/twice.kt"
refused 'a context found twice' "$WORK/n/twice.kt" 'expected exactly one match, found 2'
perl -0pe 's/\/\*\* Listens for `VideoRecordEvent`s from a `PendingRecording`\. \*\/\n//' "$UPSTREAM" > "$WORK/n/none.kt"
refused 'a context not found' "$WORK/n/none.kt" 'expected exactly one match, found 0'
perl -0pe 's/\n/\r\n/g' "$UPSTREAM" > "$WORK/n/crlf.kt"
refused 'a file with CRLF' "$WORK/n/crlf.kt" 'is not LF'
refused 'already applied' "$FORK/$GEN_KOTLIN" 'expected exactly one match, found 0'
rm -f "$FORK/$GEN_KOTLIN.out"

[ "$REAL_BEFORE" = "$(tree_sum "$FORK")" ] || { echo "BAD  the real fork changed"; BAD=$((BAD + 1)); }
echo "$N cases, $BAD bad"
[ "$BAD" -eq 0 ]
echo SELFTEST OK
