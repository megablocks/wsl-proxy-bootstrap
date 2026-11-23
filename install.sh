#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly MANAGED_BEGIN='# >>> wsl-proxy-bootstrap managed block >>>'
readonly MANAGED_END='# <<< wsl-proxy-bootstrap managed block <<<'
DRY_RUN=0
[[ ${1:-} == '--dry-run' ]] && DRY_RUN=1
if (( $# > DRY_RUN )); then
  printf 'Usage: %s [--dry-run]\n' "$0" >&2
  exit 64
fi

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

if (( EUID == 0 )); then
  if [[ ${WSL_PROXY_TEST_MODE:-0} != 1 || $DRY_RUN != 1 ]]; then
    die 'Do not run this installer as root. Run it as your normal WSL user; it uses sudo only for package operations.'
  fi
fi
[[ -n ${HOME:-} && $HOME == /* ]] || die 'HOME must be an absolute Linux path.'

if [[ ${WSL_PROXY_TEST_MODE:-0} != 1 ]]; then
  if ! grep -qiE '(microsoft|wsl)' /proc/sys/kernel/osrelease /proc/version 2>/dev/null && [[ -z ${WSL_INTEROP:-} ]]; then
    die 'This installer supports Ubuntu/Debian under WSL2 only. No WSL kernel or WSL interop marker was detected.'
  fi
  if ! grep -qiE '(wsl2|microsoft-standard)' /proc/sys/kernel/osrelease /proc/version 2>/dev/null; then
    die 'WSL was detected, but not a WSL2 kernel. WSL1 is unsupported; convert this distribution to WSL2 first.'
  fi
  [[ -r /etc/os-release ]] || die 'Cannot identify this Linux distribution (/etc/os-release is missing).'
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}:${ID_LIKE:-}" in
    ubuntu:*|debian:*|*:debian*) ;;
    *) die "Unsupported distribution '${PRETTY_NAME:-unknown}'. Use Ubuntu or Debian under WSL2." ;;
  esac
fi

if [[ ${WSL_PROXY_TEST_MODE:-0} == 1 ]]; then
  arch=${WSL_PROXY_TEST_ARCH:-amd64}
else
  arch=$(dpkg --print-architecture 2>/dev/null || true)
  [[ -n $arch ]] || arch=$(uname -m)
fi
case $arch in
  amd64|x86_64) ;;
  *) die "Unsupported architecture '$arch'. Google Chrome for Linux is installed only on amd64; this installer will not add an incompatible repository." ;;
esac

SSH_HOST=${WSL_PROXY_SSH_HOST:-khalbali.com}
SSH_USER=${WSL_PROXY_SSH_USER:-root}
SSH_KEY_PATH=${WSL_PROXY_KEY_PATH:-"$HOME/.ssh/wsl-proxy_ed25519"}
SSH_PORT=${WSL_PROXY_SSH_PORT:-22}
HOST_FINGERPRINT=${WSL_PROXY_HOST_FINGERPRINT:-}
ENROLLED=${WSL_PROXY_ENROLLED:-0}
[[ $SSH_HOST =~ ^[A-Za-z0-9._:-]+$ && $SSH_HOST != -* ]] || die 'WSL_PROXY_SSH_HOST contains unsupported characters.'
[[ $SSH_USER =~ ^[A-Za-z0-9._-]+$ && $SSH_USER != -* ]] || die 'WSL_PROXY_SSH_USER contains unsupported characters.'
if [[ ! $SSH_PORT =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
  die 'WSL_PROXY_SSH_PORT must be 1-65535.'
fi
[[ $SSH_KEY_PATH == /* ]] || die 'WSL_PROXY_KEY_PATH must be an absolute Linux path (not a Windows path).'
[[ $SSH_KEY_PATH != /mnt/* ]] || die 'Keys on Windows-mounted paths are not supported. Keep the dedicated key inside the WSL filesystem.'
[[ $SSH_KEY_PATH != *$'\n'* && $SSH_KEY_PATH != *$'\r'* ]] || die 'WSL_PROXY_KEY_PATH must not contain control characters.'
[[ ! -L $SSH_KEY_PATH ]] || die 'WSL_PROXY_KEY_PATH must not be a symbolic link.'
[[ -z $HOST_FINGERPRINT || $HOST_FINGERPRINT =~ ^SHA256:[A-Za-z0-9+/=]+$ ]] || die 'WSL_PROXY_HOST_FINGERPRINT must be an OpenSSH SHA256 fingerprint.'

if (( ! DRY_RUN )); then
  command -v sudo >/dev/null || die 'sudo is required for package installation.'
  info 'Installing/updating required Ubuntu/Debian packages…'
  sudo apt-get update
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl gnupg openssh-client iproute2
  key_tmp=$(mktemp)
  keyring_tmp=$(mktemp)
  trap 'rm -f "${key_tmp:-}" "${keyring_tmp:-}"' EXIT
  curl --proto '=https' --tlsv1.2 -fsSL https://dl.google.com/linux/linux_signing_key.pub -o "$key_tmp"
  gpg --batch --yes --dearmor --output "$keyring_tmp" "$key_tmp"
  sudo install -m 0644 "$keyring_tmp" /usr/share/keyrings/google-chrome.gpg
  printf '%s\n' 'deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main' | sudo tee /etc/apt/sources.list.d/google-chrome.list >/dev/null
  sudo apt-get update
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y google-chrome-stable
  rm -f "$key_tmp" "$keyring_tmp"
  trap - EXIT
else
  info 'Dry run: skipping package repositories, network access, and sudo.'
fi

config_dir=$HOME/.config/wsl-proxy
bin_dir=$HOME/.local/bin
data_dir=$HOME/.local/share/wsl-proxy
service_dir=$HOME/.config/systemd/user
backup_dir=$data_dir/backups/$(date -u +%Y%m%dT%H%M%SZ)-$$
mkdir -p "$config_dir" "$bin_dir" "$data_dir" "$backup_dir" "$(dirname "$SSH_KEY_PATH")"
chmod 700 "$(dirname "$SSH_KEY_PATH")" "$config_dir" "$data_dir" "$backup_dir"

backup_changed() {
  local target=$1 source=$2 rel
  if [[ -e $target ]] && ! cmp -s "$target" "$source"; then
    rel=${target#/}
    mkdir -p "$backup_dir/$(dirname "$rel")"
    cp -a "$target" "$backup_dir/$rel"
  fi
}
install_generated() {
  local source=$1 target=$2 mode=$3
  backup_changed "$target" "$source"
  if [[ ! -e $target ]] || ! cmp -s "$target" "$source"; then
    install -m "$mode" "$source" "$target"
  fi
}

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
{
  printf 'WSL_PROXY_SSH_HOST=%q\n' "$SSH_HOST"
  printf 'WSL_PROXY_SSH_USER=%q\n' "$SSH_USER"
  printf 'WSL_PROXY_KEY_PATH=%q\n' "$SSH_KEY_PATH"
  printf 'WSL_PROXY_SSH_PORT=%q\n' "$SSH_PORT"
  printf 'WSL_PROXY_HOST_FINGERPRINT=%q\n' "$HOST_FINGERPRINT"
} > "$tmpdir/config"
install_generated "$tmpdir/config" "$config_dir/config" 600

cat > "$tmpdir/wsl-proxy-tunnel" <<'HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
config=$HOME/.config/wsl-proxy/config
[[ -r $config ]] || { echo 'wsl-proxy configuration is missing; rerun install.sh.' >&2; exit 1; }
# shellcheck disable=SC1090
. "$config"
[[ -f $WSL_PROXY_KEY_PATH ]] || { echo 'The configured private key is missing; rerun install.sh.' >&2; exit 1; }
host_key_options=(-o StrictHostKeyChecking=accept-new -o HashKnownHosts=yes)
if [[ -n ${WSL_PROXY_HOST_FINGERPRINT:-} ]]; then
  scan=$(mktemp)
  pinned=$(mktemp)
  candidate=$(mktemp)
  trap 'rm -f "$scan" "$pinned" "$candidate"' EXIT
  ssh-keyscan -T 10 -p "$WSL_PROXY_SSH_PORT" "$WSL_PROXY_SSH_HOST" >"$scan" 2>/dev/null || { echo 'Unable to retrieve the SSH host key for pin verification.' >&2; exit 1; }
  while IFS= read -r key_line; do
    printf '%s\n' "$key_line" >"$candidate"
    if ssh-keygen -lf "$candidate" -E sha256 | awk '{print $2}' | grep -Fxq "$WSL_PROXY_HOST_FINGERPRINT"; then
      printf '%s\n' "$key_line" >>"$pinned"
    fi
  done <"$scan"
  if [[ ! -s $pinned ]]; then
    echo 'SSH host fingerprint mismatch; refusing to connect.' >&2
    exit 1
  fi
  exec 3<"$pinned"
  rm -f "$scan" "$pinned" "$candidate"
  trap - EXIT
  host_key_options=(-o StrictHostKeyChecking=yes -o UserKnownHostsFile=/dev/fd/3)
fi
exec ssh -NT \
  -D 127.0.0.1:1080 \
  -p "$WSL_PROXY_SSH_PORT" \
  -i "$WSL_PROXY_KEY_PATH" \
  -o BatchMode=yes \
  -o ExitOnForwardFailure=yes \
  -o IdentitiesOnly=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  "${host_key_options[@]}" \
  -- "$WSL_PROXY_SSH_USER@$WSL_PROXY_SSH_HOST"
HELPER

cat > "$tmpdir/proxy-on" <<'HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail
quiet=0
[[ ${1:-} == '--quiet' ]] && quiet=1
[[ $# -le $quiet ]] || { echo 'Usage: proxy-on [--quiet]' >&2; exit 64; }
service=$HOME/.config/systemd/user/wsl-proxy.service
pidfile=$HOME/.local/share/wsl-proxy/tunnel.pid
logfile=$HOME/.local/share/wsl-proxy/tunnel.log
listening() { ss -H -ltn 2>/dev/null | awk '$4 ~ /127[.]0[.]0[.]1:1080$/ { found=1 } END { exit !found }'; }
if [[ -f $service ]] && command -v systemctl >/dev/null && [[ $(cat /proc/1/comm 2>/dev/null || true) == systemd ]] && systemctl --user show-environment >/dev/null 2>&1; then
  systemctl --user start wsl-proxy.service
  mode=systemd
else
  mkdir -p "$(dirname "$pidfile")"
  if [[ -s $pidfile ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    :
  else
    nohup "$HOME/.local/bin/wsl-proxy-tunnel" >>"$logfile" 2>&1 &
    echo $! >"$pidfile"
  fi
  mode=process
fi
for _ in {1..30}; do
  if listening; then
    (( quiet )) || echo "SOCKS5 proxy is listening on 127.0.0.1:1080 ($mode)."
    exit 0
  fi
  sleep 0.5
done
echo 'The SSH tunnel did not become ready. Check proxy-status and the tunnel log/service.' >&2
exit 1
HELPER

cat > "$tmpdir/proxy-off" <<'HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail
service=$HOME/.config/systemd/user/wsl-proxy.service
pidfile=$HOME/.local/share/wsl-proxy/tunnel.pid
if [[ -f $service ]] && command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1; then
  systemctl --user stop wsl-proxy.service || true
fi
if [[ -s $pidfile ]]; then
  pid=$(cat "$pidfile")
  if [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then kill "$pid"; fi
  rm -f "$pidfile"
fi
echo 'WSL proxy tunnel stopped.'
HELPER

cat > "$tmpdir/proxy-status" <<'HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail
if ss -H -ltn 2>/dev/null | awk '$4 ~ /127[.]0[.]0[.]1:1080$/ { found=1 } END { exit !found }'; then
  echo 'ready: SOCKS5 is listening on 127.0.0.1:1080'
  exit 0
fi
if command -v systemctl >/dev/null && systemctl --user is-active --quiet wsl-proxy.service 2>/dev/null; then
  echo 'starting: user service is active but the SOCKS5 listener is not ready'
  exit 2
fi
echo 'stopped: no SOCKS5 listener on 127.0.0.1:1080'
exit 3
HELPER

cat > "$tmpdir/proxy-chrome" <<'HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail
"$HOME/.local/bin/proxy-on"
command -v google-chrome >/dev/null || { echo 'google-chrome is missing; rerun install.sh.' >&2; exit 1; }
exec google-chrome \
  --user-data-dir="$HOME/.local/share/wsl-proxy/chrome-profile" \
  --proxy-server=socks5://127.0.0.1:1080 \
  '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE localhost' \
  "$@"
HELPER

cat > "$tmpdir/proxy-copy" <<'HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail
command -v clip.exe >/dev/null || { echo 'clip.exe is unavailable. WSL interop may be disabled.' >&2; exit 1; }
clip.exe
HELPER

cat > "$tmpdir/proxy-paste" <<'HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail
command -v powershell.exe >/dev/null || { echo 'powershell.exe is unavailable. WSL interop may be disabled.' >&2; exit 1; }
powershell.exe -NoLogo -NoProfile -NonInteractive -Command '[Console]::Out.Write((Get-Clipboard -Raw))'
HELPER

for helper in wsl-proxy-tunnel proxy-on proxy-off proxy-status proxy-chrome proxy-copy proxy-paste; do
  install_generated "$tmpdir/$helper" "$bin_dir/$helper" 700
done

cat > "$tmpdir/wsl-proxy.service" <<'UNIT'
[Unit]
Description=WSL SSH SOCKS5 proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=%h/.local/bin/wsl-proxy-tunnel
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=default.target
UNIT
mkdir -p "$service_dir"
install_generated "$tmpdir/wsl-proxy.service" "$service_dir/wsl-proxy.service" 600

if [[ ! -f $SSH_KEY_PATH ]]; then
  command -v ssh-keygen >/dev/null || die 'ssh-keygen is unavailable even after package setup.'
  ssh-keygen -q -t ed25519 -a 64 -N '' -C 'wsl-proxy dedicated key' -f "$SSH_KEY_PATH"
  chmod 600 "$SSH_KEY_PATH"
  chmod 644 "$SSH_KEY_PATH.pub"
  info ''
  info 'ENROLLMENT REQUIRED: add this dedicated public key to the remote SSH account:'
  cat "$SSH_KEY_PATH.pub"
  info ''
  info 'No tunnel was started and no operational claim is being made.'
  info 'After enrollment, rerun with WSL_PROXY_ENROLLED=1. The installer never downloads private keys.'
  exit 20
fi
chmod 600 "$SSH_KEY_PATH"
[[ $ENROLLED == 1 ]] || {
  info 'ENROLLMENT CONFIRMATION REQUIRED: the private key exists, but the tunnel remains disabled.'
  info 'After its public key is enrolled remotely, rerun with WSL_PROXY_ENROLLED=1.'
  exit 20
}

use_systemd=0
if (( ! DRY_RUN )) && command -v systemctl >/dev/null && [[ $(cat /proc/1/comm 2>/dev/null || true) == systemd ]] && systemctl --user show-environment >/dev/null 2>&1; then
  use_systemd=1
fi

if (( use_systemd )); then
  systemctl --user daemon-reload
  systemctl --user enable --now wsl-proxy.service
else
  bashrc=$HOME/.bashrc
  touch "$bashrc"
  awk -v begin="$MANAGED_BEGIN" -v end="$MANAGED_END" '
    $0 == begin { managed=1; next }
    $0 == end { managed=0; next }
    !managed { print }
  ' "$bashrc" > "$tmpdir/bashrc.clean"
  {
    cat "$tmpdir/bashrc.clean"
    printf '\n%s\n' "$MANAGED_BEGIN"
    cat <<'BLOCK'
# Ensure the Linux-side SSH tunnel exists only when an interactive shell starts.
# Chrome and Windows programs are never auto-started.
if [[ $- == *i* ]] && [[ -x $HOME/.local/bin/proxy-on ]]; then
  "$HOME/.local/bin/proxy-on" --quiet || true
fi
BLOCK
    printf '%s\n' "$MANAGED_END"
  } > "$tmpdir/bashrc.new"
  backup_changed "$bashrc" "$tmpdir/bashrc.new"
  if ! cmp -s "$bashrc" "$tmpdir/bashrc.new"; then cat "$tmpdir/bashrc.new" > "$bashrc"; fi
fi

if (( DRY_RUN )); then
  info 'Dry run complete: files were installed under HOME, but no service or tunnel was started.'
else
  "$bin_dir/proxy-on"
  info 'Installation complete. Launch isolated proxied Chrome with: proxy-chrome'
fi
info "Changed-file backups, if any, are in: $backup_dir"
