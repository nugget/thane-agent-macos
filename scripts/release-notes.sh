#!/usr/bin/env bash
# Extract the CHANGELOG section for a specific version. Prints the body of
# "## [VERSION] - DATE" through the next "## [" heading (exclusive), with
# leading/trailing blank lines trimmed.
#
# Usage: release-notes.sh <version> [changelog-path]

set -euo pipefail

if [ "$#" -lt 1 ]; then
    echo "usage: $0 <version> [changelog-path]" >&2
    exit 1
fi

version="${1#v}"
changelog="${2:-CHANGELOG.md}"

if [ ! -f "$changelog" ]; then
    echo "changelog not found: $changelog" >&2
    exit 1
fi

# Grab the body between "## [<version>] ..." and the next "## [" heading.
body="$(awk -v target="[${version}]" '
    /^## \[/ {
        if (capture) exit
        if (index($0, "## " target) == 1) { capture = 1; next }
    }
    capture { print }
' "$changelog")"

if [ -z "$body" ]; then
    echo "no CHANGELOG entry found for version ${version}" >&2
    exit 1
fi

# Trim leading and trailing blank lines.
printf '%s\n' "$body" | sed -e '/./,$!d' | awk '
    { lines[NR] = $0 }
    END {
        last = NR
        while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--
        for (i = 1; i <= last; i++) print lines[i]
    }
'
