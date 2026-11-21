#!/usr/bin/env bash
set -euo pipefail

OFFICIAL_RELEASE="https://github.com/rrobin9/clipper-engine/releases/download/v2.1.0/Clipper-Engine-mac-arm64.zip"
OFFICIAL_SHA256="20733d7c349a8c5a692f4117f9ce1b0fd44214d288b829632eefb9e257c6c8b7"
TUNNEL_DOWNLOAD="https://github.com/cloudflare/cloudflared/releases/download/2026.11.1/cloudflared-darwin-arm64.tgz"
TUNNEL_SHA256="02fe4bcf08f2c09699cff30658228a739a0c47fb75f3653d1b8772a27ade4462"
WORK="$RUNNER_TEMP/clipper-interactive"
# This is a disposable, single-use access token (not tied to any account).
CLIPPER_ACCESS_TOKEN="$(openssl rand -hex 24)"
export CLIPPER_ACCESS_TOKEN
mkdir -p "$WORK/extracted" "$WORK/tunnel-bin"
cd "$WORK"
echo "MAC_CPU=$(uname -m) MACOS=$(sw_vers -productVersion)"
test "$(uname -m)" = arm64
TOKEN_SIZE=$(printf '%s' "$CLIPPER_ACCESS_TOKEN" | wc -c | tr -d '[:space:]')
test "$TOKEN_SIZE" -ge 32

echo "Installing unmodified, pinned original Clipper Engine release."
curl -fLSs --retry 2 --connect-timeout 15 --max-time 200 "$OFFICIAL_RELEASE" -o official.zip
printf '%s  %s\n' "$OFFICIAL_SHA256" official.zip | shasum -a 256 -c -
python3 - official.zip <<'PY'
import sys,zipfile,pathlib
with zipfile.ZipFile(sys.argv[1]) as archive:
    bad=[n for n in archive.namelist()
         if n.startswith('/') or '..' in pathlib.PurePosixPath(n).parts]
    if bad: raise SystemExit('Unsafe archive paths')
    print('Original package entries:',len(archive.namelist()))
PY
ditto -xk official.zip extracted
APP=$(find "$WORK/extracted" -maxdepth 6 -type d -name '*.app' -print -quit)
test -n "$APP"
EXEC_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")
BIN="$APP/Contents/MacOS/$EXEC_NAME"
test -f "$BIN"
lipo -archs "$BIN" | grep -qw arm64
echo "ORIGINAL_APP_INSTALLED=$(basename "$APP")"
echo "Launching official .app exactly as in the previously passing Mac M1 smoke test."
open "$APP" > launch.log 2>&1 || true

READY=0
for attempt in {1..22}; do
  CODE=$(curl --noproxy '*' -sSL --max-redirs 3 --max-time 4 -o root.html -w '%{http_code}' http://127.0.0.1:7377/ 2>/dev/null || true)
  if [[ "$CODE" == 200 ]] && grep -qi 'Clipper Engine' root.html; then READY=1; break; fi
  sleep 2
done
if [[ "$READY" != 1 ]]; then
  echo "LaunchServices did not expose interface, trying native executable directly."
  "$BIN" > direct.log 2>&1 &
  for attempt in {1..35}; do
    CODE=$(curl --noproxy '*' -sSL --max-redirs 3 --max-time 4 -o root.html -w '%{http_code}' http://127.0.0.1:7377/ 2>/dev/null || true)
    if [[ "$CODE" == 200 ]] && grep -qi 'Clipper Engine' root.html; then READY=1; break; fi
    sleep 2
  done
fi
if [[ "$READY" != 1 ]]; then
  echo "Cannot open the original app, here's the startup log:"
  echo "Listener:"; lsof -nP -iTCP:7377 -sTCP:LISTEN || true
  echo "Process list:"; ps ax -o pid,command | grep -i clipper | grep -v grep | head -20 || true
  echo "Raw HTTP headers:"; curl --noproxy '*' -sS -D - --max-time 6 -o /dev/null http://127.0.0.1:7377/ || true
  echo "Follow redirect status:"; curl --noproxy '*' -sSL --max-redirs 5 --max-time 6 -o /dev/null -w '%{http_code}\n' http://localhost:7377/ || true
  tail -60 launch.log || true
  tail -60 direct.log || true
  exit 1
fi
echo "ORIGINAL_CLIPPER_M1_PORT_7377_READY"
curl --noproxy '*' -fsS --max-time 6 http://127.0.0.1:7377/api/status | python3 -c 'import json,sys;x=json.load(sys.stdin);print("ORIGINAL_STATUS",{"app":x.get("app"),"version":x.get("version"),"mock":x.get("mock"),"platforms":x.get("platforms")});assert x.get("app")=="Clipper Engine" and x.get("mock") is False'

echo "Downloading pinned Cloudflare client for temporary TLS tunnel."
curl -fLSs --retry 2 --connect-timeout 15 --max-time 200 "$TUNNEL_DOWNLOAD" -o tunnel.tgz
printf '%s  %s\n' "$TUNNEL_SHA256" tunnel.tgz | shasum -a 256 -c -
tar -xzf tunnel.tgz -C tunnel-bin
chmod +x tunnel-bin/cloudflared
tunnel-bin/cloudflared --version

cd "$GITHUB_WORKSPACE"
node scripts/preview-proxy.mjs > "$WORK/proxy.log" 2>&1 &
PROXY_PID=$!
TUNNEL_PID=0
trap 'kill "$PROXY_PID" "$TUNNEL_PID" 2>/dev/null || true' ERR
for attempt in {1..24}; do
  CODE=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' http://127.0.0.1:7399/__proxy-ping || true)
  if [[ "$CODE" == 200 ]]; then break; fi
  sleep 1
done
test "$CODE" = 200
CODE=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' http://127.0.0.1:7399/ || true)
test "$CODE" = 401
echo "ACCESS_CONTROL_LOCAL_TEST_PASS"

"$WORK/tunnel-bin/cloudflared" tunnel --protocol http2 --no-autoupdate --url http://127.0.0.1:7399 --loglevel info > "$WORK/cloudflared.log" 2>&1 &
TUNNEL_PID=$!
PUBLIC_ORIGIN=''
for attempt in {1..70}; do
  PUBLIC_ORIGIN=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$WORK/cloudflared.log" | head -1 || true)
  if [[ -n "$PUBLIC_ORIGIN" ]]; then break; fi
  if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
    tail -65 "$WORK/cloudflared.log" || true
    exit 1
  fi
  sleep 2
done
if [[ -z "$PUBLIC_ORIGIN" ]]; then
  echo "Tunnel did not issue a domain"
  tail -65 "$WORK/cloudflared.log" || true
  exit 1
fi
echo "TEMPORARY_PREVIEW_ORIGIN=$PUBLIC_ORIGIN"
# Access URL is stored in a private workflow artifact, not printed in public logs.
echo "## Clipper Engine oficial instalado em Mac M1" >> "$GITHUB_STEP_SUMMARY"
echo "- Site do aplicativo REAL nesta VM: $PUBLIC_ORIGIN" >> "$GITHUB_STEP_SUMMARY"
echo "- O acesso exige a chave temporária privada fornecida no ChatGPT." >> "$GITHUB_STEP_SUMMARY"
echo "- A instância fica ligada por até 60 minutos após a verificação." >> "$GITHUB_STEP_SUMMARY"

UNAUTH_CODE=''
for attempt in {1..18}; do
  UNAUTH_CODE=$(curl -sS --connect-timeout 7 --max-time 15 -o "$WORK/public-unauth.html" -w '%{http_code}' "$PUBLIC_ORIGIN/" 2>/dev/null || true)
  if [[ "$UNAUTH_CODE" == 401 ]]; then break; fi
  sleep 3
done
echo "PUBLIC_UNAUTH_CODE=$UNAUTH_CODE"
if [[ "$UNAUTH_CODE" != 401 ]]; then
  echo "Runner cannot reach its own public trycloudflare URL. Checking remote accessibility externally instead."
  tail -28 "$WORK/cloudflared.log" || true
fi

if [[ "$UNAUTH_CODE" == 401 ]]; then
  LOGIN_CODE=$(curl -sS --connect-timeout 7 --max-time 15 -c "$WORK/access.cookies" -o /dev/null -w '%{http_code}' "$PUBLIC_ORIGIN/__access?key=$CLIPPER_ACCESS_TOKEN" 2>/dev/null || true)
  echo "PUBLIC_LOGIN_CODE=$LOGIN_CODE"
  test "$LOGIN_CODE" = 303
  AUTH_CODE=$(curl -sS --connect-timeout 7 --max-time 15 -b "$WORK/access.cookies" -o "$WORK/public-app.html" -w '%{http_code}' "$PUBLIC_ORIGIN/" 2>/dev/null || true)
  echo "PUBLIC_AUTHENTICATED_CODE=$AUTH_CODE"
  test "$AUTH_CODE" = 200
  grep -qi 'Clipper Engine' "$WORK/public-app.html"
  STATUS_CODE=$(curl -sS --connect-timeout 7 --max-time 15 -b "$WORK/access.cookies" -o "$WORK/public-status.json" -w '%{http_code}' "$PUBLIC_ORIGIN/api/status" 2>/dev/null || true)
  echo "PUBLIC_STATUS_CODE=$STATUS_CODE"
  test "$STATUS_CODE" = 200
  python3 - "$WORK/public-status.json" <<'PY'
import json,sys
status=json.load(open(sys.argv[1]))
assert status.get('app')=='Clipper Engine'
assert status.get('mock') is False
print('PUBLIC_ORIGINAL_APP_VERIFIED',{'app':status.get('app'),'version':status.get('version'),'mock':status.get('mock')})
PY
  echo "- ✅ Public HTTPS, auth and original API verified by runner." >> "$GITHUB_STEP_SUMMARY"
else
  echo "- ⚠️ Runner unable to reach own tunnel from inside GitHub network. Verify externally." >> "$GITHUB_STEP_SUMMARY"
fi
echo "REMOTE_CLIPPER_TUNNEL_READY"
printf '%s\n' "$PUBLIC_ORIGIN/__access?key=$CLIPPER_ACCESS_TOKEN" > "$WORK/access-url.txt"
printf '%s\n' "$PUBLIC_ORIGIN" > "$WORK/origin.txt"
chmod 600 "$WORK/access-url.txt"
echo "origin=$PUBLIC_ORIGIN" >> "$GITHUB_OUTPUT"
echo "PREVIEW_ACCESS_ARTIFACT_READY"
# Keep native processes and tunnel alive for the next job step.
