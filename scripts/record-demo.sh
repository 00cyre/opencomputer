#!/bin/bash
# Records `npm run demo` on this Mac's screen, for the live and release workflows.
# The demo runs in its own Terminal window, so the guard for the agent's own app has a host
# to protect, with the fixture in the top right corner. If Terminal lacks Accessibility or
# Screen Recording, the demo runs from this shell and the window only shows its output.
# Terminal is opened with `open`, which needs no Automation permission. Writes demo.txt,
# demo.mov and opencomputer-demo.mp4 to the folder given (default work/demo) and exits with
# the demo's status. Needs `npm run build` and `npm run fixture:build` first.
# screencapture is not stopped with a signal (in a script it ignores SIGINT, and job control
# makes it exit without writing the file): it records DEMO_RECORD_SECONDS (default 120) and
# the video is trimmed to the demo.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-work/demo}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
rm -f "$OUT"/demo.txt "$OUT"/status "$OUT"/demo.mov "$OUT"/opencomputer-demo.mp4 "$OUT"/*.command "$OUT"/terminal-doctor.json
NODE="$(command -v node)"
PACE="${DEMO_PACE_MS:-2200}"
SECONDS_MAX="${DEMO_RECORD_SECONDS:-120}"

# Lay the Terminal window out beside the fixture (520 x 332 points), or under it on a narrow screen.
DISPLAYS="$(system_profiler SPDisplaysDataType 2>/dev/null)"
read -r WIDTH HEIGHT < <(printf '%s\n' "$DISPLAYS" | awk '/UI Looks like:/ {print $4, $6; exit}')
[ -n "${WIDTH:-}" ] || read -r WIDTH HEIGHT < <(printf '%s\n' "$DISPLAYS" | awk '/Resolution:/ {print $2, $4; exit}')
WIDTH="${WIDTH:-1024}"; HEIGHT="${HEIGHT:-768}"
if [ $((WIDTH - 530)) -ge 700 ]; then
  LEFT=0; TOP=25; W=$((WIDTH - 530)); H=$((HEIGHT - 35))
else
  LEFT=0; TOP=365; W=$WIDTH; H=$((HEIGHT - 370))
fi
echo "screen ${WIDTH}x${HEIGHT}; Terminal at ${LEFT},${TOP}, ${W}x${H}"
LAYOUT="printf '\\033[3;${LEFT};${TOP}t\\033[4;${H};${W}t'"

# Opens a Terminal window running the script on stdin, placed by LAYOUT.
window() {
  local file="$OUT/$1.command"
  { echo '#!/bin/bash'; echo "$LAYOUT"; echo 'clear'; echo "cd '$PWD'"; cat; } > "$file"
  chmod +x "$file"
  open -a Terminal "$file"
}
finished() {
  for _ in $(seq 1 480); do [ -f "$OUT/status" ] && return 0; sleep 0.5; done
  return 1
}

STARTED=$(date +%s)
screencapture -v -V "$SECONDS_MAX" -x "$OUT/demo.mov" < /dev/null &
RECORDER=$!
sleep 1
window demo <<EOF
DOCTOR="\$('$NODE' bin/opencomputer.mjs doctor 2>&1)"
printf '%s\n' "\$DOCTOR" > '$OUT/terminal-doctor.json'
if grep -q '"accessibility": true' <<<"\$DOCTOR" && grep -q '"screenRecording": true' <<<"\$DOCTOR"; then
  sleep 1
  DEMO_PACE_MS=$PACE '$NODE' scripts/demo.mjs 2>&1 | tee '$OUT/demo.txt'
  echo \${PIPESTATUS[0]} > '$OUT/status'
else
  echo 'Terminal has no Accessibility or Screen Recording on this Mac: running the demo from the CI shell.'
  echo shell > '$OUT/status'
fi
EOF
finished
if [ "$(cat "$OUT/status" 2>/dev/null)" = shell ]; then
  rm -f "$OUT/status"
  : > "$OUT/demo.txt"
  window narration <<EOF
tail -n +1 -f '$OUT/demo.txt'
EOF
  sleep 3
  DEMO_PACE_MS=$PACE "$NODE" scripts/demo.mjs >> "$OUT/demo.txt" 2>&1
  echo $? > "$OUT/status"
fi
DURATION=$(( $(date +%s) - STARTED + 4 ))
STATUS="$(cat "$OUT/status" 2>/dev/null || echo 124)"
[ -f "$OUT/status" ] || echo "The demo did not finish within 4 minutes."
grep -E '"(accessibility|screenRecording)"' "$OUT/terminal-doctor.json" 2>/dev/null | sed 's/^ */Terminal /'
cat "$OUT/demo.txt" 2>/dev/null
[ "$DURATION" -le "$SECONDS_MAX" ] || echo "The demo ran longer than the ${SECONDS_MAX} s recording."
wait "$RECORDER" 2>/dev/null || true
if [ -s "$OUT/demo.mov" ] && command -v avconvert >/dev/null; then
  avconvert --preset Preset1920x1080 --source "$OUT/demo.mov" --output "$OUT/opencomputer-demo.mp4" --duration "$DURATION" \
    || avconvert --preset Preset1920x1080 --source "$OUT/demo.mov" --output "$OUT/opencomputer-demo.mp4" --replace || true
fi
rm -f "$OUT"/*.command "$OUT/status"
ls -la "$OUT"
exit "$STATUS"
