#!/bin/zsh
# Performance and size report for recper, printed as Markdown.
#   scripts/bench.sh            sizes + hot-path timings + idle/choosing CPU and memory
# Builds the release bundle first. Relaunches recper (quits a running copy) to measure it.
set -euo pipefail
cd "${0:A:h}/.."

scripts/bundle.sh >/dev/null
APP=build/Recper.app
BIN=$APP/Contents/MacOS/Recper
ZIP=$(mktemp -d)/Recper.zip
ditto -c -k --keepParent $APP $ZIP

kb() { du -sk "$1" | cut -f1 }
echo "### Size\n"
echo "| | Size |"
echo "|---|---:|"
echo "| Recper.app | $(kb $APP) KB |"
echo "| Executable (arm64) | $(( $(stat -f %z $BIN) / 1024 )) KB |"
echo "| Recper.zip (download) | $(( $(stat -f %z $ZIP) / 1024 )) KB |"
echo "| Source (Swift, lines) | $(cat Sources/**/*.swift | wc -l | tr -d ' ') |"
echo "| Tests | $(grep -ho '@Test' Tests/**/*.swift | wc -l | tr -d ' ') |"
rm -rf "${ZIP:h}"

echo "\n### Hot paths (median)\n"
$BIN --benchmark

# Runtime: relaunch and sample with top (CPU averaged over 5 s, memory = resident footprint).
sample() {   # $1 = label
  local pid=$(pgrep -x Recper)
  local cpu=$(top -l 6 -s 1 -pid $pid -stats cpu | grep -E '^ *[0-9.]+ *$' | tail -5 | awk '{s+=$1; n++} END {printf "%.1f", n ? s/n : 0}')
  local mem=$(top -l 1 -pid $pid -stats mem | tail -1)
  echo "| $1 | $cpu % | $mem |"
}
pkill -x Recper 2>/dev/null || true; sleep 0.5
local t0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
open $APP
until pgrep -x Recper >/dev/null; do sleep 0.02; done
local t1=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
sleep 3
echo "\n### Runtime\n"
echo "| State | CPU | Memory |"
echo "|---|---:|---:|"
sample "Idle in the menu bar"
open "recper://start?mode=area"; sleep 1.5
sample "Choosing a target (edge glow on)"
osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1 || true   # Esc: cancel
sleep 5
sample "Idle again after cancelling"
echo "\nProcess start after \`open\`: $(perl -e "printf '%.0f', ($t1 - $t0) * 1000") ms"
echo "\n_$(sysctl -n machdep.cpu.brand_string), $(( $(sysctl -n hw.memsize) / 1073741824 )) GB, macOS $(sw_vers -productVersion)_"
