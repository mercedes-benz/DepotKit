#!/bin/sh

# Fails when build, test, or documentation logs contain warnings that originate from this
# repository. Diagnostics in checked-out dependencies (`.build/checkouts/`,
# `SourcePackages/checkouts/`) are upstream and only counted.
#
# Detected:
#   - compiler, linker, and DocC diagnostics (`warning:`)
#   - Swift Testing issues recorded with warning severity (`recorded a warning`)
#   - XCTest / Swift Testing API-misuse reports (`API misuse`, `API was misused`)
#
# Ignored: the toolchain notice "Metadata extraction skipped, no AppIntents.framework dependency
# found" that xcodebuild's App Intents metadata step logs for every app and test bundle that does
# not link AppIntents. It cannot be disabled from the package or project.
#
# Usage: scripts/check-warnings.sh <log file>...

if [ "$#" -eq 0 ]; then
    echo "Usage: $0 <log file>..." >&2
    exit 2
fi

status=0
for log in "$@"; do
    if [ ! -f "$log" ]; then
        echo "error: log file '$log' not found" >&2
        exit 2
    fi

    own=$(grep -E "warning:|recorded a warning|API misuse|API was misused" "$log" \
        | grep -v "/checkouts/" \
        | grep -v -E "appintentsmetadataprocessor\[[0-9:]+\] warning: Metadata extraction skipped, no AppIntents\.framework dependency found$" \
        | sort -u)
    upstream=$(grep -E "warning:" "$log" | grep -c "/checkouts/")

    if [ -n "$own" ]; then
        count=$(printf '%s\n' "$own" | wc -l | tr -d ' ')
        echo "error: $log contains $count warning(s) from this repository:" >&2
        printf '%s\n' "$own" >&2
        status=1
    else
        echo "$log: no warnings from this repository ($upstream upstream dependency warning(s) ignored)"
    fi
done

exit $status
