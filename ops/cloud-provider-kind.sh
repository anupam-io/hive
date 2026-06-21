#!/usr/bin/env bash
set -euo pipefail
# Install cloud-provider-kind and run it as a launchd LaunchAgent so kind
# LoadBalancer services map to host localhost ports — and survive reboots.
#
#   ./cloud-provider-kind.sh            # install + load (idempotent)
#   ./cloud-provider-kind.sh stop       # unload + remove the LaunchAgent
#
# Requires Go (for `go install`) and Docker socket access as your user.

LABEL="com.local.cloud-provider-kind"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG="/tmp/cloud-provider-kind.log"

cmd="${1:-install}"

if [ "$cmd" = "stop" ]; then
  launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "[cpk] stopped + removed $PLIST"
  exit 0
fi

command -v go >/dev/null || { echo "[cpk] need Go installed (https://go.dev/dl/)"; exit 1; }

BIN="$(go env GOPATH)/bin/cloud-provider-kind"
if [ ! -x "$BIN" ]; then
  echo "[cpk] go install sigs.k8s.io/cloud-provider-kind@latest"
  go install sigs.k8s.io/cloud-provider-kind@latest
fi
[ -x "$BIN" ] || { echo "[cpk] binary not found at $BIN after install"; exit 1; }

mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>            <string>${LABEL}</string>
  <key>ProgramArguments</key> <array><string>${BIN}</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key> <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>RunAtLoad</key>         <true/>
  <key>KeepAlive</key>         <true/>
  <key>StandardOutPath</key>   <string>${LOG}</string>
  <key>StandardErrorPath</key> <string>${LOG}</string>
</dict>
</plist>
EOF

# Reload to pick up any changes.
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load   "$PLIST"

echo "[cpk] launched. log: ${LOG}"
echo "[cpk] LoadBalancer services in kind clusters now get a localhost-bound port."
echo "[cpk] stop with: $0 stop"
