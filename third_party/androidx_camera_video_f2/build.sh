#!/usr/bin/env bash
# Rebuilds maven/ (androidx.camera:camera-video 1.6.2 + F2) from the official Google Maven release
# and patches/0001-*.patch, verifies every step, and compares the result with the committed files.
# See README.md.
#
# Usage: bash build.sh <work dir> [--install]
#   <work dir>  scratch directory OUTSIDE the repository; downloads are kept there between runs
#               and re-verified by SHA-256 on every run
#   --install   write the result into maven/ and SHA256SUMS (default: compare only)
#
# Needs: JDK 21 (javac, jar, javap; JAVA_HOME, default Android Studio's JBR), Android SDK with
# platforms/android-36 and build-tools/36.0.0 (ANDROID_HOME), curl, unzip, patch, perl,
# sha256sum. Tested with Git Bash on Windows (JBR 21.0.10).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
[ $# -ge 1 ] || { echo "usage: build.sh <work dir> [--install]"; exit 2; }
mkdir -p "$1"
W=$(cd "$1" && pwd)
INSTALL=${2:-}
case "$W/" in "$REPO"/*) echo "work dir must be outside the repository"; exit 2 ;; esac

if command -v cygpath >/dev/null 2>&1; then
    native() { cygpath -w "$1"; }
    SEP=';'
    DEFAULT_SDK=$(cygpath -u "${LOCALAPPDATA:-C:/Users/$USERNAME/AppData/Local}")/Android/sdk
    export MSYS_NO_PATHCONV=1
else
    native() { echo "$1"; }
    SEP=':'
    DEFAULT_SDK=$HOME/Android/Sdk
fi
JAVA_HOME=${JAVA_HOME:-"/c/Program Files/Android/Android Studio/jbr"}
JAVA_HOME=$(cd "$JAVA_HOME" && pwd)
SDK=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$DEFAULT_SDK}}
JAVAC=$JAVA_HOME/bin/javac
JAR=$JAVA_HOME/bin/jar
JAVAP=$JAVA_HOME/bin/javap
ANDROID_JAR=$SDK/platforms/android-36/android.jar
LAMBDA_STUBS=$SDK/build-tools/36.0.0/core-lambda-stubs.jar

GROUP_PATH=com/synapseauto/thirdparty/androidx/camera/camera-video/1.6.2-synapse-f2
BASE=camera-video-1.6.2-synapse-f2
P=androidx/camera/video/internal/encoder
# Fixed entry dates, the ones the upstream archives use (classes.jar entries, AAR entries).
CLASSES_DATE=1981-01-01T01:01:02Z
AAR_DATE=1980-02-01T00:00:00Z

ORIG_JAVA_SHA=fc9054b2cf4282bc9ab538d0a82c566d9103dec69bff153ad249ea5d57f755c7
F2_JAVA_SHA=3f969cef506d6bfd79ebafb27d935aac24488c14de268604c60072d33f0aa6ae

GM=https://dl.google.com/android/maven2
MC=https://repo1.maven.org/maven2
# file | url | sha256. The first four are the upstream release; the rest are only the compile
# classpath of EncoderImpl.java (the same versions the validated F2 harness build used).
INPUTS="
camera-video-1.6.2.aar|$GM/androidx/camera/camera-video/1.6.2/camera-video-1.6.2.aar|dee568da7d1ce009506a538b2916cce6f23473a835b0aeb4e8193483ff1174d0
camera-video-1.6.2-sources.jar|$GM/androidx/camera/camera-video/1.6.2/camera-video-1.6.2-sources.jar|dc8f8ac4f891fdaa76087ab43ce79b9a8386f507c5cf351d7189eabde1074a66
camera-video-1.6.2.pom|$GM/androidx/camera/camera-video/1.6.2/camera-video-1.6.2.pom|9b237fa922df0019ff3e5dba4043dca082836b7b93b9ed045061f706da831c8d
camera-video-1.6.2.module|$GM/androidx/camera/camera-video/1.6.2/camera-video-1.6.2.module|cf1e3fb9362af9c020f1126f8c56e7578f73a96b6f670136cc756a907182733c
camera-core-1.6.2.aar|$GM/androidx/camera/camera-core/1.6.2/camera-core-1.6.2.aar|ebd66f090414f4c12f23a55b5023aeee1b096da8a06c02a0b6fb3520c4ddadf6
core-1.3.2.aar|$GM/androidx/core/core/1.3.2/core-1.3.2.aar|94de196cd67950cff6ef3e1ac59015f8eaaf61840bdc238f2cf54ddef8dd0be9
annotation-jvm-1.8.1.jar|$GM/androidx/annotation/annotation-jvm/1.8.1/annotation-jvm-1.8.1.jar|9aab326d9492800991854360ac248f493ce7f7c3183519309b78ace9e240f6f6
concurrent-futures-1.1.0.jar|$GM/androidx/concurrent/concurrent-futures/1.1.0/concurrent-futures-1.1.0.jar|0ce067c514a0d1049d1bebdf709e344ed3266fe9744275682937cdcb13334e9e
core-common-2.2.0.jar|$GM/androidx/arch/core/core-common/2.2.0/core-common-2.2.0.jar|65308a06b1c00ee186cb9e19321383f043b993813f1522c47f4a3e3303bdba41
guava-33.3.1-android.jar|$MC/com/google/guava/guava/33.3.1-android/guava-33.3.1-android.jar|2c3e41d1b380f2044d257947a3aa82dabf3ae4b978622745254aa18b6cf89ab0
jspecify-1.0.0.jar|$MC/org/jspecify/jspecify/1.0.0/jspecify-1.0.0.jar|1fad6e6be7557781e4d33729d49ae1cdc8fdda6fe477bb0cc68ce351eafdfbab
"
# The ten patched class files; identical to the classes of the AAR validated on the SM-A326B
# (R2.6.22-F2 harness, camera-video-1.6.2-f2.aar sha256 1d98185b...).
F2_CLASSES="
7b8a2954e71e71356bf6e8f83a1897c7f3c880e6df3c4fe0ebd12f0a2555df85  EncoderImpl\$1\$1.class
3ad060cf1c453670fa29baccbd021f5251797d36c7c22e2195f39eca8089b85b  EncoderImpl\$1.class
178a2f0fbee325c821e4bc18112b32fe2c0dc377bdd8d20462f68960555c0787  EncoderImpl\$2.class
507457d7df0c9c44da32e146d2a5e97e901462d4de5ff1c8e2eb02ea138b425f  EncoderImpl\$3.class
c40c3479050f3d28179dc2800f33a4cfed6846e8583c3179043c33dcd7ecc177  EncoderImpl\$ByteBufferInput.class
b464b818ae2b721299a5b8c21abaa69bc7b8a9417954924d6baa0480179449f6  EncoderImpl\$InternalState.class
8d8e1772ed8b815c5053005ebdc0eec99da91010ca8b90e6fd4359609451b1b0  EncoderImpl\$MediaCodecCallback\$1.class
844a12d3821b32a56d6807c990dbf318c5849e65aee07d8ff53eafd155706687  EncoderImpl\$MediaCodecCallback.class
55f50409cbddc441b73bf70eeee7fb8ece03bf700b24a0efbd74781d6df0820d  EncoderImpl\$SurfaceInput.class
567037d68a1aa4f3b585c43efd81013c13b76db0f6033429da6bb123dc6b1902  EncoderImpl.class
"

sha() { sha256sum "$1" | cut -c1-64; }
fail() { echo "FAIL: $*"; exit 1; }
step() { echo "== $*"; }

step "toolchain"
"$JAVAC" -version 2>&1
for f in "$ANDROID_JAR" "$LAMBDA_STUBS"; do
    [ -f "$f" ] || fail "missing $f"
    echo "$(sha "$f")  $f"
done

step "inputs (downloaded once into $W/in, verified every run)"
mkdir -p "$W/in"
echo "$INPUTS" | while IFS='|' read -r name url want; do
    [ -n "$name" ] || continue
    f=$W/in/$name
    if [ ! -f "$f" ] || [ "$(sha "$f")" != "$want" ]; then
        curl -sfSL -o "$(native "$f")" "$url" || fail "download $url"
    fi
    [ "$(sha "$f")" = "$want" ] || fail "$name sha256 $(sha "$f") != $want"
    echo "ok  $want  $name"
done

step "sources: official EncoderImpl.java, then the F2 patch"
rm -rf "$W/src_orig" "$W/src_f2" "$W/out_orig" "$W/out_f2" "$W/x_up" "$W/cp" "$W/pkg"
mkdir -p "$W/src_orig" "$W/cp/video" "$W/cp/camera-core" "$W/cp/core" "$W/x_up"
(cd "$W/src_orig" && unzip -q "$W/in/camera-video-1.6.2-sources.jar" "$P/EncoderImpl.java")
[ "$(sha "$W/src_orig/$P/EncoderImpl.java")" = "$ORIG_JAVA_SHA" ] || fail "upstream EncoderImpl.java"
cp -r "$W/src_orig" "$W/src_f2"
tr -d '\r' < "$HERE"/patches/0001-*.patch > "$W/f2.patch"
patch -p1 --no-backup-if-mismatch --quiet -d "$W/src_f2" < "$W/f2.patch"
[ "$(sha "$W/src_f2/$P/EncoderImpl.java")" = "$F2_JAVA_SHA" ] || fail "patched EncoderImpl.java is not the validated F2"
echo "ok  $ORIG_JAVA_SHA  upstream EncoderImpl.java"
echo "ok  $F2_JAVA_SHA  EncoderImpl.java + F2"

step "compile the upstream source (control) and the F2 source, same flags"
(cd "$W/cp/video" && unzip -q "$W/in/camera-video-1.6.2.aar" classes.jar)
(cd "$W/cp/camera-core" && unzip -q "$W/in/camera-core-1.6.2.aar" classes.jar)
(cd "$W/cp/core" && unzip -q "$W/in/core-1.3.2.aar" classes.jar)
CP=
for j in "$W/cp/video/classes.jar" "$W/cp/camera-core/classes.jar" "$W/cp/core/classes.jar" \
         "$W/in/annotation-jvm-1.8.1.jar" "$W/in/concurrent-futures-1.1.0.jar" \
         "$W/in/guava-33.3.1-android.jar" "$W/in/core-common-2.2.0.jar" "$W/in/jspecify-1.0.0.jar"; do
    CP="$CP$SEP$(native "$j")"
done
CP=${CP#"$SEP"}
for V in orig f2; do
    mkdir -p "$W/out_$V"
    "$JAVAC" -source 8 -target 8 -g -proc:none -encoding UTF-8 -Xlint:-options -nowarn \
        -bootclasspath "$(native "$ANDROID_JAR")$SEP$(native "$LAMBDA_STUBS")" -cp "$CP" -sourcepath "" \
        -d "$(native "$W/out_$V")" "$(native "$W/src_$V/$P/EncoderImpl.java")"
done
(cd "$W/x_up" && unzip -q "$W/cp/video/classes.jar" "$P/EncoderImpl*")
[ "$(cd "$W/out_f2/$P" && ls)" = "$(cd "$W/x_up/$P" && ls)" ] || fail "class file list differs from upstream"

step "bytecode (javap -c -p, constant-pool indices removed)"
norm() {
    "$JAVAP" -c -p "$(native "$1")" | tr -d '\r' \
        | sed -E 's/#[0-9]+(, *[0-9]+)?//g; s/ldc_w/ldc/g' | grep -v '^Compiled from'
}
for f in $(cd "$W/x_up/$P" && ls); do
    diff -q <(norm "$W/out_orig/$P/$f") <(norm "$W/x_up/$P/$f") >/dev/null \
        || fail "recompiled upstream $f differs from the Google class (pipeline not neutral)"
    if diff -q <(norm "$W/out_f2/$P/$f") <(norm "$W/x_up/$P/$f") >/dev/null; then
        echo "same as upstream  $f"
    else
        case "$f" in
            EncoderImpl.class|'EncoderImpl$SurfaceInput.class') echo "F2 change         $f" ;;
            *) fail "F2 changed $f, outside EncoderImpl and EncoderImpl\$SurfaceInput" ;;
        esac
    fi
done
(cd "$W/out_f2/$P" && sha256sum EncoderImpl*.class | sed 's/ \*/  /' | sort -k2) > "$W/f2_classes.txt"
diff <(echo "$F2_CLASSES" | grep . | sort -k2) "$W/f2_classes.txt" >/dev/null \
    || fail "F2 class files are not byte-identical to the validated ones (see $W/f2_classes.txt)"
echo "ok  the 10 EncoderImpl*.class are byte-identical to the validated F2 build"

step "repack: only the EncoderImpl*.class entries of classes.jar are replaced"
mkdir -p "$W/pkg"
cp "$W/cp/video/classes.jar" "$W/pkg/classes.jar"
(cd "$W/out_f2" && "$JAR" --update --date=$CLASSES_DATE --file "$(native "$W/pkg/classes.jar")" $P/EncoderImpl*.class)
cp "$W/in/camera-video-1.6.2.aar" "$W/pkg/$BASE.aar"
(cd "$W/pkg" && "$JAR" --update --date=$AAR_DATE --file "$BASE.aar" classes.jar)
entries_same() { diff <(unzip -Z1 "$1") <(unzip -Z1 "$2") >/dev/null; }
entries_same "$W/cp/video/classes.jar" "$W/pkg/classes.jar" || fail "classes.jar entry list/order changed"
entries_same "$W/in/camera-video-1.6.2.aar" "$W/pkg/$BASE.aar" || fail "AAR entry list/order changed"
content_diff() { # names of the entries of archive $1 whose content differs in archive $2
    local a b n
    a=$(mktemp -d); b=$(mktemp -d)
    (cd "$a" && unzip -q "$1"); (cd "$b" && unzip -q "$2")
    unzip -Z1 "$1" | grep -v '/$' | while IFS= read -r n; do
        cmp -s "$a/$n" "$b/$n" || echo "$n"
    done
    rm -rf "$a" "$b"
}
[ "$(content_diff "$W/in/camera-video-1.6.2.aar" "$W/pkg/$BASE.aar")" = classes.jar ] \
    || fail "an AAR entry other than classes.jar changed"
changed=$(content_diff "$W/cp/video/classes.jar" "$W/pkg/classes.jar")
[ -n "$changed" ] && ! echo "$changed" | grep -v -q -E "^$P/EncoderImpl[^/]*\.class\$" \
    || fail "a classes.jar entry other than EncoderImpl*.class changed: $changed"
echo "ok  AAR differs from upstream only in classes.jar; classes.jar only in the 10 EncoderImpl*.class"

step "maven metadata"
mkdir -p "$W/maven/$GROUP_PATH"
cp "$W/pkg/$BASE.aar" "$W/maven/$GROUP_PATH/"
perl "$HERE/gen_metadata.pl" "$W/in/camera-video-1.6.2.pom" "$W/in/camera-video-1.6.2.module" \
    "$W/maven/$GROUP_PATH/$BASE.aar" "$W/maven/$GROUP_PATH"
(cd "$W/maven" && sha256sum $GROUP_PATH/* | sed 's/ \*/  /')

step "SHA256SUMS"
{
    echo "# Generated by build.sh. Inputs (official releases), validated sources, patched classes, outputs."
    echo "$INPUTS" | while IFS='|' read -r name url want; do
        if [ -n "$name" ]; then echo "$want  in/$name"; fi
    done
    echo "$ORIG_JAVA_SHA  src/upstream/$P/EncoderImpl.java"
    echo "$F2_JAVA_SHA  src/f2/$P/EncoderImpl.java"
    sed "s#  #  classes/$P/#" "$W/f2_classes.txt"
    (cd "$HERE" && sha256sum patches/* gen_metadata.pl | sed 's/ \*/  /')
    (cd "$W" && sha256sum maven/$GROUP_PATH/* | sed 's/ \*/  /')
} > "$W/SHA256SUMS"

step "compare with the committed files"
if [ "$INSTALL" = --install ]; then
    rm -rf "$HERE/maven"
    mkdir -p "$HERE/maven/$GROUP_PATH"
    cp "$W/maven/$GROUP_PATH"/* "$HERE/maven/$GROUP_PATH/"
    cp "$W/SHA256SUMS" "$HERE/SHA256SUMS"
    echo "installed into $HERE/maven and $HERE/SHA256SUMS"
fi
status=0
for f in "$BASE.aar" "$BASE.pom" "$BASE.module"; do
    c=$HERE/maven/$GROUP_PATH/$f
    if [ ! -f "$c" ]; then
        echo "MISSING     $f (run with --install)"; status=1
    elif cmp -s "$c" "$W/maven/$GROUP_PATH/$f"; then
        echo "IDENTICAL   $f"
    elif [ "$f" = "$BASE.aar" ] && entries_same "$c" "$W/maven/$GROUP_PATH/$f" \
            && [ -z "$(content_diff "$c" "$W/maven/$GROUP_PATH/$f")" ]; then
        echo "SAME ENTRIES $f (archive bytes differ: different JDK zip encoder)"
    else
        echo "DIFFERENT   $f"; status=1
    fi
done
cmp -s "$HERE/SHA256SUMS" "$W/SHA256SUMS" && echo "IDENTICAL   SHA256SUMS" || { echo "DIFFERENT   SHA256SUMS"; status=1; }
exit $status
