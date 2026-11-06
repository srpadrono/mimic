#!/usr/bin/env bash
# Builds the libFuzzer targets and fuzzes each for FUZZ_SECONDS (default 60). Linux only.
#
#   Fuzz/run.sh                   build, then fuzz every target
#   Fuzz/run.sh FuzzOpenAPI       one target
#
# Each target starts from its checked-in seeds in Fuzz/Corpus and grows a working corpus under
# .artifacts/fuzz/corpus, which is never written back. A crash, sanitizer report, slow input or
# memory blow-up stops that target and leaves its reproducer in .artifacts/fuzz/findings; replay one
# with `Fuzz/.build/release/<Target> <file>`. Exit status is non-zero if any target found anything.
set -euo pipefail

cd "$(dirname "$0")/.."
SECONDS_PER_TARGET="${FUZZ_SECONDS:-60}"
OUT=.artifacts/fuzz
if [ $# -gt 0 ]; then TARGETS=("$@"); else TARGETS=(FuzzHAR FuzzOpenAPI FuzzProjectDocument); fi

seeds_for() {
    case "$1" in
        FuzzHAR) echo Fuzz/Corpus/har ;;
        FuzzOpenAPI) echo Fuzz/Corpus/openapi ;;
        FuzzProjectDocument) echo Fuzz/Corpus/project ;;
        *) echo "unknown fuzz target: $1" >&2; exit 2 ;;
    esac
}

# Resolve exactly what the app ships: the fuzz package takes the root package's pins.
cp Package.resolved Fuzz/Package.resolved
swift build --package-path Fuzz -c release --sanitize=fuzzer -Xswiftc -sanitize=fuzzer,address

# Leak detection is off. The importers parse on a detached task, which can release its captures a
# moment after the callback has its result, and LeakSanitizer checks in that moment: it reported
# leaks that never reproduced. A real leak would go unreported too; crashes and memory errors still stop the run.
status=0
for target in "${TARGETS[@]}"; do
    seeds="$(seeds_for "$target")"
    corpus="$OUT/corpus/$target"
    findings="$OUT/findings/$target"
    mkdir -p "$corpus" "$findings"
    echo "::group::$target for ${SECONDS_PER_TARGET}s"
    if ! "Fuzz/.build/release/$target" "$corpus" "$seeds" \
        -dict=Fuzz/json.dict \
        -max_total_time="$SECONDS_PER_TARGET" \
        -max_len=65536 \
        -timeout=10 \
        -rss_limit_mb=2048 \
        -detect_leaks=0 \
        -artifact_prefix="$findings/" \
        -print_final_stats=1; then
        status=1
        echo "::error title=$target found a failing input::Reproducers are in $findings"
    fi
    echo "::endgroup::"
done
exit "$status"
