#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
(( EUID != 0 )) || { echo 'ERROR: do not run uninstall.sh as root.' >&2; exit 1; }
[[ -n ${HOME:-} && $HOME == /* && $HOME != *$'\n'* && $HOME != *$'\r'* && $HOME != *$'\t'* ]] || { echo 'ERROR: HOME must be a safe absolute Linux path.' >&2; exit 1; }
readonly MANAGED_BEGIN='# >>> wsl-proxy-bootstrap managed block >>>'
readonly MANAGED_END='# <<< wsl-proxy-bootstrap managed block <<<'
die() { echo "ERROR: $*" >&2; exit 1; }
windows_fstype() { case $1 in drvfs|9p|cifs|smb3|ntfs|ntfs3|fuseblk|exfat|vfat) return 0 ;; *) return 1 ;; esac; }
safe_path() {
  local path=$1 part current=/ probe resolved info fstype source uid
  [[ $path == /* ]] || return 1
  IFS='/' read -r -a parts <<<"${path#/}"
  for part in "${parts[@]}"; do [[ -n $part ]] || continue; current=${current%/}/$part; [[ ! -L $current ]] || return 1; done
  probe=$path
  while [[ ! -e $probe ]]; do [[ $probe != / ]] || break; probe=$(dirname -- "$probe"); done
  resolved=$(readlink -f -- "$probe") || return 1
  info=$(findmnt -T "$resolved" -n -o FSTYPE,SOURCE 2>/dev/null | head -n 1) || return 1
  IFS=' ' read -r fstype source _ <<<"$info"
  [[ -n $fstype ]] && ! windows_fstype "$fstype" && [[ ! ${source:-} =~ ^[A-Za-z]: ]] && [[ ${source:-} != //* ]] || return 1
  if [[ -e $path ]]; then uid=$(stat -c %u -- "$path") || return 1; [[ $uid == "$EUID" ]] || return 1; fi
}
command -v findmnt >/dev/null || die 'findmnt is required for host-mount safety checks.'
data_dir=$HOME/.local/share/wsl-proxy
bin_dir=$HOME/.local/bin
config_file=$HOME/.config/wsl-proxy/config
enrollment_file=$data_dir/enrolled
known_hosts=$data_dir/known_hosts
service=$HOME/.config/systemd/user/wsl-proxy.service
manifest=$data_dir/originals-v1/manifest
originals_dir=$data_dir/originals-v1/files
bashrc_touched=$data_dir/originals-v1/bashrc-touched
bashrc_original=$data_dir/originals-v1/bashrc-original
bashrc_original_state=$data_dir/originals-v1/bashrc-original-state
bashrc=$HOME/.bashrc
backup_dir=$data_dir/backups/uninstall-$(date -u +%Y%m%dT%H%M%SZ)-$$
declare -a ids=(config enrollment known_hosts common tunnel proxy_on proxy_off proxy_status proxy_chrome proxy_copy proxy_paste service)
declare -a targets=("$config_file" "$enrollment_file" "$known_hosts" "$bin_dir/wsl-proxy-common" "$bin_dir/wsl-proxy-tunnel" "$bin_dir/proxy-on" "$bin_dir/proxy-off" "$bin_dir/proxy-status" "$bin_dir/proxy-chrome" "$bin_dir/proxy-copy" "$bin_dir/proxy-paste" "$service")
validate_manifest() {
  local id state lines
  [[ -f $manifest && ! -L $manifest && $(head -n 1 "$manifest") == wsl-proxy-originals-v1 ]] || return 1
  lines=$(wc -l <"$manifest")
  [[ $lines == $((${#ids[@]} + 1)) ]] || return 1
  for id in "${ids[@]}"; do
    state=$(awk -F '\t' -v wanted="$id" '$1 == wanted { print $2; count++ } END { if (count != 1) exit 1 }' "$manifest") || return 1
    case $state in present) [[ -f $originals_dir/$id && ! -L $originals_dir/$id ]] || return 1 ;; absent) ;; *) return 1 ;; esac
  done
}
for path in "$HOME" "$data_dir" "$backup_dir" "$bashrc" "$bashrc_touched" "$bashrc_original" "$bashrc_original_state" "$manifest" "$originals_dir" "${targets[@]}"; do safe_path "$path" || die "Unsafe symlink or Windows-backed path detected: $path"; done
validate_manifest || die 'A complete install-time originals manifest is required; nothing was changed.'
if [[ -e $bashrc_touched ]]; then
  [[ -f $bashrc_original_state && ! -L $bashrc_original_state ]] || die 'The lifecycle .bashrc state is missing; nothing was changed.'
  bashrc_state=$(cat "$bashrc_original_state")
  case $bashrc_state in
    present) [[ -f $bashrc_original && ! -L $bashrc_original ]] || die 'The lifecycle .bashrc original is missing; nothing was changed.' ;;
    absent) [[ ! -e $bashrc_original ]] || die 'The lifecycle .bashrc original state is inconsistent; nothing was changed.' ;;
    *) die 'The lifecycle .bashrc state is invalid; nothing was changed.' ;;
  esac
fi
if [[ -f $bashrc ]]; then
  begin_count=$(grep -Fxc "$MANAGED_BEGIN" "$bashrc" || true)
  end_count=$(grep -Fxc "$MANAGED_END" "$bashrc" || true)
  [[ $begin_count == "$end_count" && $begin_count -le 1 ]] || die 'Malformed or duplicate managed markers; nothing was changed.'
fi
[[ -x $bin_dir/proxy-off && -x $bin_dir/wsl-proxy-common ]] || die 'Managed stop helpers are missing; refusing uninstall while tunnel state is unknown.'
HOME=$HOME "$bin_dir/proxy-off" >/dev/null 2>&1 || die 'Could not safely stop the managed tunnel; nothing was restored.'
mkdir -p "$backup_dir"
chmod 700 "$data_dir" "$backup_dir"
if command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1; then systemctl --user disable wsl-proxy.service >/dev/null 2>&1 || true; fi
backup_current() {
  local id=$1 target=$2
  [[ -e $target ]] || return 0
  cp -a -- "$target" "$backup_dir/$id"
}
state_for() { awk -F '\t' -v wanted="$1" '$1 == wanted { print $2; found=1 } END { exit !found }' "$manifest"; }
atomic_restore() {
  local source=$1 target=$2 target_dir staged
  target_dir=$(dirname -- "$target")
  mkdir -p "$target_dir"
  staged=$(mktemp "$target_dir/.wsl-proxy-restore.XXXXXX")
  rm -f -- "$staged"
  cp -a -- "$source" "$staged"
  cmp -s "$source" "$staged" || { rm -f -- "$staged"; die "Could not validate staged restore for $target"; }
  mv -f -- "$staged" "$target" || { rm -f -- "$staged"; die "Could not atomically restore $target"; }
}
for i in "${!ids[@]}"; do
  id=${ids[$i]}; target=${targets[$i]}
  backup_current "$id" "$target"
  state=$(state_for "$id") || die "Manifest lacks required entry: $id"
  case $state in
      present)
        original=$originals_dir/$id
        [[ -f $original && ! -L $original ]] || die "Install-time original is missing or unsafe: $id"
        atomic_restore "$original" "$target"
        ;;
      absent) rm -f -- "$target" ;;
    *) die "Invalid manifest state for $id" ;;
  esac
done
if [[ -e $bashrc_touched ]]; then
  backup_current bashrc "$bashrc"
  case $bashrc_state in
    present) atomic_restore "$bashrc_original" "$bashrc" ;;
    absent) rm -f -- "$bashrc" ;;
  esac
elif [[ -f $bashrc ]]; then
  # Compatibility cleanup for lifecycles created before exact .bashrc snapshots.
  tmp=$(mktemp "$(dirname -- "$bashrc")/.bashrc.wsl-proxy-uninstall.XXXXXX")
  trap 'rm -f "$tmp"' EXIT
  cp -a -- "$bashrc" "$tmp" || die 'Could not preserve .bashrc metadata on the staged legacy cleanup.'
  awk -v begin="$MANAGED_BEGIN" -v end="$MANAGED_END" '$0 == begin { managed=1; next } $0 == end { managed=0; next } !managed { print }' "$bashrc" >"$tmp"
  if ! cmp -s "$bashrc" "$tmp"; then
    backup_current bashrc "$bashrc"
    mv -f -- "$tmp" "$bashrc" || die 'Could not atomically remove the legacy .bashrc block.'
  fi
fi
rm -f -- "$data_dir/tunnel.pid"
touch "$data_dir/originals-v1/uninstalled"
chmod 600 "$data_dir/originals-v1/uninstalled"
if command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1; then systemctl --user daemon-reload; fi
printf 'Uninstalled managed launchers/configuration and restored all collided install-time originals.\nKeys, profile, logs, manifests, and backups remain.\nBackup: %s\n' "$backup_dir"
