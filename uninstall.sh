#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
(( EUID != 0 )) || { echo 'ERROR: do not run uninstall.sh as root.' >&2; exit 1; }
[[ -n ${HOME:-} && $HOME == /* ]] || { echo 'ERROR: HOME must be an absolute Linux path.' >&2; exit 1; }
readonly MANAGED_BEGIN='# >>> wsl-proxy-bootstrap managed block >>>'
readonly MANAGED_END='# <<< wsl-proxy-bootstrap managed block <<<'
data_dir=$HOME/.local/share/wsl-proxy
backup_dir=$data_dir/backups/uninstall-$(date -u +%Y%m%dT%H%M%SZ)-$$
mkdir -p "$backup_dir"
chmod 700 "$data_dir" "$backup_dir"
backup_and_remove() {
  local target=$1 rel
  [[ -e $target ]] || return 0
  rel=${target#/}
  mkdir -p "$backup_dir/$(dirname "$rel")"
  cp -a "$target" "$backup_dir/$rel"
  rm -f "$target"
}
service=$HOME/.config/systemd/user/wsl-proxy.service
if command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1; then
  systemctl --user disable --now wsl-proxy.service 2>/dev/null || true
fi
if [[ -x $HOME/.local/bin/proxy-off ]]; then "$HOME/.local/bin/proxy-off" >/dev/null || true; fi
if [[ -f $HOME/.bashrc ]]; then
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT
  awk -v begin="$MANAGED_BEGIN" -v end="$MANAGED_END" '
    $0 == begin { managed=1; next }
    $0 == end { managed=0; next }
    !managed { print }
  ' "$HOME/.bashrc" >"$tmp"
  if ! cmp -s "$HOME/.bashrc" "$tmp"; then
    mkdir -p "$backup_dir$HOME"
    cp -a "$HOME/.bashrc" "$backup_dir$HOME/.bashrc"
    cat "$tmp" >"$HOME/.bashrc"
  fi
fi
for target in \
  "$HOME/.local/bin/wsl-proxy-tunnel" \
  "$HOME/.local/bin/proxy-on" \
  "$HOME/.local/bin/proxy-off" \
  "$HOME/.local/bin/proxy-status" \
  "$HOME/.local/bin/proxy-chrome" \
  "$HOME/.local/bin/proxy-copy" \
  "$HOME/.local/bin/proxy-paste" \
  "$HOME/.config/wsl-proxy/config" \
  "$service"; do
  backup_and_remove "$target"
done
if command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1; then systemctl --user daemon-reload; fi
printf 'Uninstalled managed launchers/configuration. Keys, Chrome profile, logs, and all backups remain in place.\nBackup: %s\n' "$backup_dir"
