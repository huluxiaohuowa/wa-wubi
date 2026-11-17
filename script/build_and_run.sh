#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
mode="${1:-run}"
pkill -x WAWubi >/dev/null 2>&1 || true
app="$("$root/script/build_app.sh")"

case "$mode" in
    run) open -n "$app" --args --settings ;;
    --verify)
        open -n "$app" --args --settings
        for attempt in {1..10}; do
            if pgrep -x WAWubi >/dev/null; then exit 0; fi
            sleep 1
        done
        exit 1
        ;;
    --debug) lldb -- "$app/Contents/MacOS/WAWubi" --settings ;;
    --logs|--telemetry)
        open -n "$app" --args --settings
        /usr/bin/log stream --info --style compact --predicate 'process == "WAWubi"'
        ;;
    *)
        echo "Usage: $0 [--verify|--debug|--logs|--telemetry]" >&2
        exit 2
        ;;
esac
