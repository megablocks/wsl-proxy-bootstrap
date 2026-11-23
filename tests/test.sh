#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

bash -n install.sh uninstall.sh tests/test.sh
pass 'bash syntax'
command -v shellcheck >/dev/null || fail 'shellcheck is required'
shellcheck install.sh uninstall.sh tests/test.sh
pass 'shellcheck'

if (( EUID == 0 )); then
  if HOME=$(mktemp -d) ./install.sh --dry-run >/dev/null 2>&1; then fail 'installer accepted root'; fi
  pass 'root refusal'
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
home=$tmp/home
mkdir -p "$home"
printf '%s\n' '# existing user content' >"$home/.bashrc"
set +e
first=$(HOME="$home" WSL_PROXY_TEST_MODE=1 ./install.sh --dry-run 2>&1)
first_rc=$?
set -e
[[ $first_rc == 20 ]] || fail "first install should stop for enrollment (got $first_rc)"
grep -q 'ENROLLMENT REQUIRED' <<<"$first" || fail 'missing enrollment notice'
grep -q '^ssh-ed25519 ' <<<"$first" || fail 'public key was not printed'
! grep -qE -- 'BEGIN .*PRIVATE KEY|PRIVATE KEY-----' <<<"$first" || fail 'private key material reached output'
pass 'dedicated key generation and enrollment stop'

for _ in 1 2; do
  HOME="$home" WSL_PROXY_TEST_MODE=1 WSL_PROXY_ENROLLED=1 ./install.sh --dry-run >/dev/null
done
shellcheck "$home/.local/bin/wsl-proxy-tunnel" "$home/.local/bin/proxy-on" "$home/.local/bin/proxy-off" "$home/.local/bin/proxy-status" "$home/.local/bin/proxy-chrome" "$home/.local/bin/proxy-copy" "$home/.local/bin/proxy-paste"
[[ $(grep -Fc '# >>> wsl-proxy-bootstrap managed block >>>' "$home/.bashrc") == 1 ]] || fail 'managed bashrc block duplicated'
grep -q '# existing user content' "$home/.bashrc" || fail 'bashrc content was not preserved'
pass 'fake-HOME dry run and idempotent managed block'

mkdir -p "$tmp/fakebin"
cat >"$tmp/fakebin/clip.exe" <<'CLIP'
#!/usr/bin/env bash
set -Eeuo pipefail
cat >"$CLIP_CAPTURE"
CLIP
cat >"$tmp/fakebin/powershell.exe" <<'POWERSHELL'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'paste-result'
POWERSHELL
chmod +x "$tmp/fakebin/clip.exe" "$tmp/fakebin/powershell.exe"
secret='clipboard-test-value'
printf %s "$secret" | HOME="$home" PATH="$tmp/fakebin:$PATH" CLIP_CAPTURE="$tmp/capture" "$home/.local/bin/proxy-copy"
[[ $(cat "$tmp/capture") == "$secret" ]] || fail 'copy helper changed clipboard data'
[[ $(HOME="$home" PATH="$tmp/fakebin:$PATH" "$home/.local/bin/proxy-paste") == paste-result ]] || fail 'paste helper failed'
! grep -Eq '(logger|tee[[:space:]])' "$home/.local/bin/proxy-copy" "$home/.local/bin/proxy-paste" || fail 'clipboard helper contains logging primitive'
pass 'explicit clipboard helpers do not log'

implementation_files=(install.sh uninstall.sh .github/workflows/ci.yml)
! grep -En '/mnt/[a-zA-Z]/|/mnt/c' "${implementation_files[@]}" || fail 'Windows host mount path found'
! grep -En -- 'ssh-rsa|ssh-dss|HostKeyAlgorithms=.*\+' "${implementation_files[@]}" || fail 'weak SSH compatibility found'
! grep -En -- 'BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY' "${implementation_files[@]}" || fail 'embedded private key found'
! grep -En -- '(^|[^[:alnum:]_])pkill([[:space:]]|$)|killall' "${implementation_files[@]}" || fail 'broad process termination found'
! grep -En -- '(ghp_|github_pat_|AKIA[0-9A-Z]{16}|password[[:space:]]*=)' "${implementation_files[@]}" || fail 'probable credential found'
pass 'security scans (mount writes, clipboard logging, weak SSH, private keys, broad pkill, credentials)'

if (( EUID == 0 )); then
  cp "$repo/uninstall.sh" "$tmp/uninstall.sh"
  chmod 755 "$tmp" "$tmp/uninstall.sh"
  chown -R nobody:nogroup "$tmp"
  runuser -u nobody -- env HOME="$home" "$tmp/uninstall.sh" >/dev/null
else
  HOME="$home" "$repo/uninstall.sh" >/dev/null
fi
! grep -q 'wsl-proxy-bootstrap managed block' "$home/.bashrc" || fail 'uninstall left managed bashrc block'
grep -q '# existing user content' "$home/.bashrc" || fail 'uninstall damaged bashrc content'
[[ -f $home/.ssh/wsl-proxy_ed25519 ]] || fail 'uninstall deleted user key data'
pass 'reversible uninstall preserves data'
