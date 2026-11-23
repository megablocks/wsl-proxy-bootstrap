#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly MANAGED_BEGIN='# >>> wsl-proxy-bootstrap managed block >>>'
readonly MANAGED_END='# <<< wsl-proxy-bootstrap managed block <<<'
DRY_RUN=0
INTERNAL_TEST=0
INTERNAL_TEST_SHELL_HOOK=0
INTERNAL_TEST_SHELL_CLEANUP=0
ROOT_SELF_TEST=0
for arg in "$@"; do
  case $arg in
    --dry-run) DRY_RUN=1 ;;
    --internal-test-dry-run) DRY_RUN=1; INTERNAL_TEST=1 ;;
    --internal-test-shell-hook) DRY_RUN=1; INTERNAL_TEST=1; INTERNAL_TEST_SHELL_HOOK=1 ;;
    --internal-test-shell-cleanup) DRY_RUN=1; INTERNAL_TEST=1; INTERNAL_TEST_SHELL_CLEANUP=1 ;;
    --internal-test-root-refusal) ROOT_SELF_TEST=1 ;;
    *) printf 'Usage: %s [--dry-run | --internal-test-dry-run | --internal-test-shell-hook | --internal-test-shell-cleanup | --internal-test-root-refusal]\n' "$0" >&2; exit 64 ;;
  esac
done
(( $# <= 1 )) || { printf 'ERROR: options are mutually exclusive.\n' >&2; exit 64; }

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }
check_not_root() {
  local uid=$1
  (( uid != 0 )) || die 'Do not run this installer as root. Run it as your normal WSL user; it uses sudo only for package operations.'
}
if (( ROOT_SELF_TEST )); then
  info 'Internal test: simulating uid 0; refusal is the only permitted outcome.' >&2
  check_not_root 0
  die 'internal root-refusal self-test unexpectedly continued'
fi
check_not_root "$EUID"
[[ -n ${HOME:-} && $HOME == /* && $HOME != *$'\n'* && $HOME != *$'\r'* && $HOME != *$'\t'* ]] || die 'HOME must be an absolute Linux path without control characters.'
(( INTERNAL_TEST )) && info 'INTERNAL TEST DRY RUN: platform/package/service checks are disabled; no tunnel can be started.' >&2

SSH_HOST=${WSL_PROXY_SSH_HOST:-khalbali.com}
SSH_USER=${WSL_PROXY_SSH_USER:-root}
SSH_KEY_PATH=${WSL_PROXY_KEY_PATH:-"$HOME/.ssh/wsl-proxy_ed25519"}
SSH_PORT=${WSL_PROXY_SSH_PORT:-22}
HOST_FINGERPRINT=${WSL_PROXY_HOST_FINGERPRINT:-}
ENROLLED=${WSL_PROXY_ENROLLED:-0}
[[ $SSH_HOST =~ ^[A-Za-z0-9._:-]+$ && $SSH_HOST != -* ]] || die 'WSL_PROXY_SSH_HOST contains unsupported characters.'
[[ $SSH_USER =~ ^[A-Za-z0-9._-]+$ && $SSH_USER != -* ]] || die 'WSL_PROXY_SSH_USER contains unsupported characters.'
if [[ ! $SSH_PORT =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then die 'WSL_PROXY_SSH_PORT must be 1-65535.'; fi
[[ $SSH_KEY_PATH == /* && $SSH_KEY_PATH != *$'\n'* && $SSH_KEY_PATH != *$'\r'* && $SSH_KEY_PATH != *$'\t'* ]] || die 'WSL_PROXY_KEY_PATH must be an absolute Linux path without control characters.'
[[ -z $HOST_FINGERPRINT || $HOST_FINGERPRINT =~ ^SHA256:[A-Za-z0-9+/=]+$ ]] || die 'WSL_PROXY_HOST_FINGERPRINT must be an OpenSSH SHA256 fingerprint.'
[[ $ENROLLED == 0 || $ENROLLED == 1 ]] || die 'WSL_PROXY_ENROLLED must be 0 or 1.'

config_dir=$HOME/.config/wsl-proxy
bin_dir=$HOME/.local/bin
data_dir=$HOME/.local/share/wsl-proxy
service_dir=$HOME/.config/systemd/user
config_file=$config_dir/config
enrollment_file=$data_dir/enrolled
known_hosts=$data_dir/known_hosts
pidfile=$data_dir/tunnel.pid
logfile=$data_dir/tunnel.log
manifest=$data_dir/originals-v1/manifest
originals_dir=$data_dir/originals-v1/files
preedit_root=$data_dir/backups/pre-edit
bashrc_touched=$data_dir/originals-v1/bashrc-touched
bashrc_original=$data_dir/originals-v1/bashrc-original
bashrc_original_state=$data_dir/originals-v1/bashrc-original-state
bashrc=$HOME/.bashrc
service=$service_dir/wsl-proxy.service
safe_tmp_root=${TMPDIR:-/tmp}

command -v findmnt >/dev/null || die 'findmnt (util-linux) is required for Windows-host mount safety checks.'
windows_fstype() {
  case $1 in
    drvfs|9p|cifs|smb3|ntfs|ntfs3|fuseblk|exfat|vfat) return 0 ;;
    *) return 1 ;;
  esac
}
assert_safe_path() {
  local path=$1 label=$2 owner_required=${3:-1} part current=/ probe resolved mount_info fstype source uid
  [[ $path == /* && $path != *$'\n'* && $path != *$'\r'* && $path != *$'\t'* ]] || die "$label is not a safe absolute Linux path."
  IFS='/' read -r -a parts <<<"${path#/}"
  for part in "${parts[@]}"; do
    [[ -n $part ]] || continue
    current=${current%/}/$part
    [[ ! -L $current ]] || die "$label traverses symbolic link '$current'; refusing possible Windows-host escape."
  done
  probe=$path
  while [[ ! -e $probe ]]; do
    [[ $probe != / ]] || break
    probe=$(dirname -- "$probe")
  done
  resolved=$(readlink -f -- "$probe") || die "Cannot resolve $label safely."
  mount_info=$(findmnt -T "$resolved" -n -o FSTYPE,SOURCE 2>/dev/null | head -n 1) || die "Cannot determine the backing mount for $label."
  IFS=' ' read -r fstype source _ <<<"$mount_info"
  [[ -n $fstype ]] || die "Cannot determine the backing filesystem for $label."
  if windows_fstype "$fstype" || [[ ${source:-} =~ ^[A-Za-z]: ]] || [[ ${source:-} == //* ]]; then
    die "$label is on Windows-backed filesystem '$fstype' ($source); refusing all mutation."
  fi
  if [[ -e $path && $owner_required == 1 ]]; then
    uid=$(stat -c %u -- "$path") || die "Cannot inspect ownership of $label."
    [[ $uid == "$EUID" ]] || die "$label is not owned by the invoking user."
  fi
}
assert_file_target() {
  local path=$1 label=$2
  assert_safe_path "$path" "$label"
  [[ ! -e $path || -f $path ]] || die "$label exists but is not a regular file."
}
validate_bash_syntax() {
  # bash -n does not execute an in-file "shopt -s extglob" before parsing
  # later extended patterns. Enable extglob from parser startup so valid
  # runtime .bashrc files are not rejected.
  bash -O extglob -n "$1"
}
write_shell_hook_block() {
  local output=$1
  { printf '%s\n' "$MANAGED_BEGIN" || return 1
    cat <<'BLOCK' || return 1
# Start only the enrolled, verified Linux-side SSH tunnel in interactive shells.
# Chrome and Windows programs are never auto-started.
if [[ $- == *i* ]] && [[ -x $HOME/.local/bin/proxy-on ]]; then
  "$HOME/.local/bin/proxy-on" --quiet || true
fi
BLOCK
    printf '%s\n' "$MANAGED_END" || return 1
  } >"$output" || return 1
}
build_shell_hook_candidate() {
  local output=$1 block=$2 clean=$3 source=/dev/null begin_count end_count
  [[ -f $bashrc ]] && source=$bashrc
  awk -v begin="$MANAGED_BEGIN" -v end="$MANAGED_END" '$0 == begin { managed=1; next } $0 == end { managed=0; next } !managed { print }' "$source" >"$clean" || return 1
  { cat "$clean" || return 1
    printf '\n' || return 1
    cat "$block" || return 1
  } >"$output" || return 1
  begin_count=$(awk -v marker="$MANAGED_BEGIN" '$0 == marker { count++ } END { print count + 0 }' "$output") || return 1
  end_count=$(awk -v marker="$MANAGED_END" '$0 == marker { count++ } END { print count + 0 }' "$output") || return 1
  [[ $begin_count == 1 && $end_count == 1 ]]
}

# Validate every path that this installer or its generated helpers can mutate,
# before APT, key generation, directory creation, backups, or service changes.
assert_safe_path "$HOME" HOME
[[ -d $HOME ]] || die 'HOME must already exist as a directory.'
assert_safe_path "$safe_tmp_root" "temporary directory $safe_tmp_root" 0
[[ -d $safe_tmp_root ]] || die 'TMPDIR must already exist as a directory.'
for dir in "$config_dir" "$bin_dir" "$data_dir" "$service_dir" "$(dirname -- "$SSH_KEY_PATH")" "$data_dir/originals-v1" "$originals_dir" "$data_dir/backups" "$preedit_root"; do
  assert_safe_path "$dir" "target directory $dir"
  [[ ! -e $dir || -d $dir ]] || die "Target directory '$dir' is not a directory."
done
for target in "$SSH_KEY_PATH" "$SSH_KEY_PATH.pub" "$data_dir/originals-v1/uninstalled" "$bashrc_touched" "$bashrc_original" "$bashrc_original_state" "$config_file" "$enrollment_file" "$known_hosts" "$pidfile" "$logfile" "$bashrc" "$service" \
  "$bin_dir/wsl-proxy-common" "$bin_dir/wsl-proxy-tunnel" "$bin_dir/proxy-on" "$bin_dir/proxy-off" "$bin_dir/proxy-status" "$bin_dir/proxy-chrome" "$bin_dir/proxy-copy" "$bin_dir/proxy-paste"; do
  assert_file_target "$target" "target file $target"
done
if [[ -f $bashrc ]]; then
  begin_count=$(grep -Fxc "$MANAGED_BEGIN" "$bashrc" || true)
  end_count=$(grep -Fxc "$MANAGED_END" "$bashrc" || true)
  [[ $begin_count == "$end_count" && $begin_count -le 1 ]] || die 'Malformed or duplicate managed markers exist in .bashrc.'
  if (( begin_count == 1 )) && [[ ! -f $manifest ]]; then die 'Managed marker collision exists without an active install manifest.'; fi
fi

# Validate the exact shell-hook candidate before APT, key generation, manifest
# creation, backups, or any managed operational-file replacement. This keeps an
# invalid existing .bashrc from producing a partial installation.
bashrc_preflight=$(mktemp -d -p "$safe_tmp_root" wsl-proxy-bashrc.XXXXXX)
if ! write_shell_hook_block "$bashrc_preflight/block" ||
   ! build_shell_hook_candidate "$bashrc_preflight/candidate" "$bashrc_preflight/block" "$bashrc_preflight/clean"; then
  rm -rf -- "$bashrc_preflight"
  die 'Could not build the .bashrc shell-hook candidate.'
fi
if ! validate_bash_syntax "$bashrc_preflight/candidate"; then
  rm -rf -- "$bashrc_preflight"
  die 'Generated .bashrc failed Bash syntax validation; no installation changes were made.'
fi
rm -rf -- "$bashrc_preflight"

if (( ! INTERNAL_TEST )); then
  if ! grep -qiE '(microsoft|wsl)' /proc/sys/kernel/osrelease /proc/version 2>/dev/null && [[ -z ${WSL_INTEROP:-} ]]; then
    die 'This installer supports Ubuntu/Debian under WSL2 only. No WSL marker was detected.'
  fi
  grep -qiE '(wsl2|microsoft-standard)' /proc/sys/kernel/osrelease /proc/version 2>/dev/null || die 'WSL1 is unsupported; convert this distribution to WSL2 first.'
  [[ -r /etc/os-release ]] || die 'Cannot identify this Linux distribution.'
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}:${ID_LIKE:-}" in ubuntu:*|debian:*|*:debian*) ;; *) die "Unsupported distribution '${PRETTY_NAME:-unknown}'." ;; esac
  arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
else
  arch=amd64
fi
case $arch in amd64|x86_64) ;; *) die "Unsupported architecture '$arch'; Google Chrome for Linux requires amd64." ;; esac

if (( ! DRY_RUN )); then
  command -v sudo >/dev/null || die 'sudo is required for package installation.'
  info 'Installing/updating required Ubuntu/Debian packages…'
  sudo apt-get update
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl gnupg openssh-client iproute2 util-linux coreutils
  key_tmp=$(mktemp -p "$safe_tmp_root")
  keyring_tmp=$(mktemp -p "$safe_tmp_root")
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
  info 'Dry run: skipping package repositories, network access, sudo, and tunnel startup.'
fi
SSH_BINARY=$(command -v ssh 2>/dev/null || true)
[[ -n $SSH_BINARY ]] || die 'ssh is unavailable.'
SSH_BINARY=$(readlink -f -- "$SSH_BINARY") || die 'Cannot resolve ssh executable.'
assert_safe_path "$SSH_BINARY" 'ssh executable' 0
ssh_uid=$(stat -c %u -- "$SSH_BINARY")
ssh_mode=$(stat -c %a -- "$SSH_BINARY")
[[ $ssh_uid == 0 && $(( 8#$ssh_mode & 022 )) == 0 ]] || die 'ssh executable must be root-owned and not group/world-writable.'

# Enrollment phase intentionally creates only the dedicated key. No launchers,
# configuration, service, shell hook, or readiness claim exists yet.
mkdir -p "$(dirname -- "$SSH_KEY_PATH")"
chmod 700 "$(dirname -- "$SSH_KEY_PATH")"
assert_file_target "$SSH_KEY_PATH" 'private key'
if [[ ! -f $SSH_KEY_PATH ]]; then
  command -v ssh-keygen >/dev/null || die 'ssh-keygen is unavailable even after package setup.'
  ssh-keygen -q -t ed25519 -a 64 -N '' -C 'wsl-proxy dedicated key' -f "$SSH_KEY_PATH"
  chmod 600 "$SSH_KEY_PATH"
  chmod 644 "$SSH_KEY_PATH.pub"
  info ''
  info 'ENROLLMENT REQUIRED: add this dedicated public key to the remote SSH account:'
  cat "$SSH_KEY_PATH.pub"
  info ''
  info 'No tunnel launcher, service, shell hook, or operational configuration was installed.'
  info 'After enrollment, rerun with WSL_PROXY_ENROLLED=1.'
  exit 20
fi
chmod 600 "$SSH_KEY_PATH"
if [[ $ENROLLED != 1 ]]; then
  info 'ENROLLMENT CONFIRMATION REQUIRED: the private key exists; no operational files were installed.'
  info 'After its public key is enrolled remotely, rerun with WSL_PROXY_ENROLLED=1.'
  exit 20
fi

mkdir -p "$config_dir" "$bin_dir" "$data_dir" "$service_dir" "$originals_dir"
chmod 700 "$config_dir" "$data_dir" "$data_dir/originals-v1" "$originals_dir"

tmpdir=$(mktemp -d -p "$safe_tmp_root")
trap 'rm -rf "$tmpdir"' EXIT
install_id=
if [[ -r $config_file ]] && grep -q '^WSL_PROXY_INSTALL_ID=[A-Fa-f0-9]\{32\}$' "$config_file"; then
  install_id=$(sed -n 's/^WSL_PROXY_INSTALL_ID=//p' "$config_file" | head -n 1)
fi
[[ $install_id =~ ^[A-Fa-f0-9]{32}$ ]] || install_id=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
{
  printf 'WSL_PROXY_SSH_HOST=%s\n' "$SSH_HOST"
  printf 'WSL_PROXY_SSH_USER=%s\n' "$SSH_USER"
  printf 'WSL_PROXY_KEY_PATH=%s\n' "$SSH_KEY_PATH"
  printf 'WSL_PROXY_SSH_PORT=%s\n' "$SSH_PORT"
  printf 'WSL_PROXY_SSH_BINARY=%s\n' "$SSH_BINARY"
  printf 'WSL_PROXY_TEST_INERT=%s\n' "$INTERNAL_TEST"
  printf 'WSL_PROXY_HOST_FINGERPRINT=%s\n' "$HOST_FINGERPRINT"
  printf 'WSL_PROXY_ENROLLED=1\n'
  printf 'WSL_PROXY_INSTALL_ID=%s\n' "$install_id"
} >"$tmpdir/config"

cat >"$tmpdir/wsl-proxy-common" <<'HELPER'
#!/usr/bin/env bash
# Sourced by generated launchers; callers set -Eeuo pipefail.
# shellcheck disable=SC2034
config=$HOME/.config/wsl-proxy/config
data_dir=$HOME/.local/share/wsl-proxy
pidfile=$data_dir/tunnel.pid
known_hosts=$data_dir/known_hosts
service=$HOME/.config/systemd/user/wsl-proxy.service
local_port=1080
wp_die() { echo "ERROR: $*" >&2; return 1; }
wp_windows_fstype() { case $1 in drvfs|9p|cifs|smb3|ntfs|ntfs3|fuseblk|exfat|vfat) return 0 ;; *) return 1 ;; esac; }
wp_safe_path() {
  local path=$1 part current=/ probe resolved info fstype source
  [[ $path == /* && $path != *$'\n'* && $path != *$'\r'* && $path != *$'\t'* ]] || return 1
  IFS='/' read -r -a wp_parts <<<"${path#/}"
  for part in "${wp_parts[@]}"; do
    [[ -n $part ]] || continue
    current=${current%/}/$part
    [[ ! -L $current ]] || return 1
  done
  probe=$path
  while [[ ! -e $probe ]]; do [[ $probe != / ]] || break; probe=$(dirname -- "$probe"); done
  resolved=$(readlink -f -- "$probe") || return 1
  info=$(findmnt -T "$resolved" -n -o FSTYPE,SOURCE 2>/dev/null | head -n 1) || return 1
  IFS=' ' read -r fstype source _ <<<"$info"
  [[ -n $fstype ]] || return 1
  ! wp_windows_fstype "$fstype" && [[ ! ${source:-} =~ ^[A-Za-z]: ]] && [[ ${source:-} != //* ]]
}
wp_backup_before_edit() {
  local id=$1 target=$2 root stamp backup_dir
  [[ -f $target && ! -L $target ]] || { wp_die "Cannot back up unsafe managed file: $target"; return 1; }
  root=$data_dir/backups/pre-edit
  wp_safe_path "$root" || { wp_die 'Unsafe pre-edit backup path.'; return 1; }
  mkdir -p "$root"
  stamp=$(date -u +%Y%m%dT%H%M%S.%NZ)
  backup_dir=$(mktemp -d "$root/$stamp-runtime-$$.XXXXXX")
  chmod 700 "$root" "$backup_dir"
  cp -a -- "$target" "$backup_dir/$id"
  cmp -s "$target" "$backup_dir/$id" || { wp_die "Pre-edit backup verification failed for $target"; return 1; }
  printf 'timestamp=%s\nid=%s\ntarget=%s\n' "$stamp" "$id" "$target" >"$backup_dir/metadata"
  chmod 600 "$backup_dir/metadata"
}
wp_load_config() {
  local key value wp_path binary_uid binary_mode
  if ! wp_safe_path "$config" || [[ ! -f $config || -L $config ]]; then wp_die 'Unsafe or missing managed configuration.'; return 1; fi
  WSL_PROXY_SSH_HOST='' WSL_PROXY_SSH_USER='' WSL_PROXY_KEY_PATH='' WSL_PROXY_SSH_PORT=''
  WSL_PROXY_SSH_BINARY='' WSL_PROXY_TEST_INERT='' WSL_PROXY_HOST_FINGERPRINT=''
  WSL_PROXY_ENROLLED='' WSL_PROXY_INSTALL_ID=''
  while IFS='=' read -r key value; do
    case $key in
      WSL_PROXY_SSH_HOST) WSL_PROXY_SSH_HOST=$value ;;
      WSL_PROXY_SSH_USER) WSL_PROXY_SSH_USER=$value ;;
      WSL_PROXY_KEY_PATH) WSL_PROXY_KEY_PATH=$value ;;
      WSL_PROXY_SSH_PORT) WSL_PROXY_SSH_PORT=$value ;;
      WSL_PROXY_SSH_BINARY) WSL_PROXY_SSH_BINARY=$value ;;
      WSL_PROXY_TEST_INERT) WSL_PROXY_TEST_INERT=$value ;;
      WSL_PROXY_HOST_FINGERPRINT) WSL_PROXY_HOST_FINGERPRINT=$value ;;
      WSL_PROXY_ENROLLED) WSL_PROXY_ENROLLED=$value ;;
      WSL_PROXY_INSTALL_ID) WSL_PROXY_INSTALL_ID=$value ;;
      '') ;;
      *) wp_die "Unknown configuration key '$key'."; return 1 ;;
    esac
  done <"$config"
  if [[ ! $WSL_PROXY_SSH_HOST =~ ^[A-Za-z0-9._:-]+$ || ! $WSL_PROXY_SSH_USER =~ ^[A-Za-z0-9._-]+$ ]]; then wp_die 'Invalid SSH destination configuration.'; return 1; fi
  if [[ ! $WSL_PROXY_SSH_PORT =~ ^[0-9]+$ ]] || (( WSL_PROXY_SSH_PORT < 1 || WSL_PROXY_SSH_PORT > 65535 )); then wp_die 'Invalid SSH port configuration.'; return 1; fi
  if [[ $WSL_PROXY_KEY_PATH != /* || ! $WSL_PROXY_INSTALL_ID =~ ^[A-Fa-f0-9]{32}$ ]]; then wp_die 'Invalid managed path or install identity.'; return 1; fi
  if [[ $WSL_PROXY_TEST_INERT != 0 ]]; then wp_die 'This is an inert internal-test installation; production tunnel startup is disabled.'; return 1; fi
  if [[ $WSL_PROXY_ENROLLED != 1 ]]; then wp_die 'Enrollment has not been explicitly confirmed.'; return 1; fi
  if [[ ! -f $data_dir/enrolled || $(cat "$data_dir/enrolled") != "$WSL_PROXY_INSTALL_ID" ]]; then wp_die 'Enrollment gate is absent or does not match this installation.'; return 1; fi
  for wp_path in "$HOME" "$data_dir" "$data_dir/backups/pre-edit" "$pidfile" "$known_hosts" "$data_dir/tunnel.log" "$data_dir/chrome-profile" "$WSL_PROXY_KEY_PATH" "$config" "$HOME/.local/bin"; do
    if ! wp_safe_path "$wp_path"; then wp_die "Unsafe path or Windows-backed mount detected: $wp_path"; return 1; fi
  done
  if [[ ! -x $WSL_PROXY_SSH_BINARY || -L $WSL_PROXY_SSH_BINARY ]] || ! wp_safe_path "$WSL_PROXY_SSH_BINARY"; then wp_die 'Configured ssh executable is missing or unsafe.'; return 1; fi
  binary_uid=$(stat -c %u -- "$WSL_PROXY_SSH_BINARY") || return 1
  binary_mode=$(stat -c %a -- "$WSL_PROXY_SSH_BINARY") || return 1
  if [[ $binary_uid != 0 || $(( 8#$binary_mode & 022 )) != 0 ]]; then wp_die 'Configured ssh executable is not trusted.'; return 1; fi
}
wp_start_time() { sed 's/^[^)]*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $20}'; }
wp_env_has() { tr '\0' '\n' <"/proc/$1/environ" 2>/dev/null | grep -Fxq -- "$2"; }
wp_cmd_has() { tr '\0' '\n' <"/proc/$1/cmdline" 2>/dev/null | grep -Fxq -- "$2"; }
wp_process_expected() {
  local pid=$1 start=${2:-} token=${3:-} exe
  [[ $pid =~ ^[0-9]+$ && -r /proc/$pid/stat ]] || return 1
  [[ $(stat -c %u "/proc/$pid") == "$EUID" ]] || return 1
  [[ -z $start || $(wp_start_time "$pid") == "$start" ]] || return 1
  wp_env_has "$pid" "WSL_PROXY_INSTALL_ID=$WSL_PROXY_INSTALL_ID" || return 1
  [[ -z $token ]] || wp_env_has "$pid" "WSL_PROXY_INSTANCE_TOKEN=$token" || return 1
  exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
  [[ $exe == "$WSL_PROXY_SSH_BINARY" ]] || return 1
  wp_cmd_has "$pid" '-NT' && wp_cmd_has "$pid" '-D' && wp_cmd_has "$pid" "127.0.0.1:$local_port" && \
    wp_cmd_has "$pid" '-i' && wp_cmd_has "$pid" "$WSL_PROXY_KEY_PATH" && wp_cmd_has "$pid" "$WSL_PROXY_SSH_USER@$WSL_PROXY_SSH_HOST"
}
wp_read_record() {
  WP_PID=''
  WP_START=''
  WP_TOKEN=''
  [[ -f $pidfile && ! -L $pidfile ]] || return 1
  while IFS='=' read -r key value; do case $key in PID) WP_PID=$value ;; START) WP_START=$value ;; TOKEN) WP_TOKEN=$value ;; esac; done <"$pidfile"
  [[ $WP_PID =~ ^[0-9]+$ && $WP_START =~ ^[0-9]+$ && $WP_TOKEN =~ ^[A-Fa-f0-9]{32}$ ]]
}
wp_record_valid() { wp_read_record && wp_process_expected "$WP_PID" "$WP_START" "$WP_TOKEN"; }
wp_spawn_matches() {
  local pid=$1 start=$2 token=$3
  [[ $pid =~ ^[0-9]+$ && -r /proc/$pid/stat ]] || return 1
  [[ $(stat -c %u "/proc/$pid") == "$EUID" ]] || return 1
  [[ -z $start || $(wp_start_time "$pid") == "$start" ]] || return 1
  wp_env_has "$pid" "WSL_PROXY_INSTANCE_TOKEN=$token"
}
wp_kill_spawn() {
  local pid=$1 start=$2 token=$3
  if wp_spawn_matches "$pid" "$start" "$token"; then
    kill "$pid" 2>/dev/null || true
    for _ in {1..20}; do wp_spawn_matches "$pid" "$start" "$token" || return 0; sleep 0.05; done
    kill -KILL "$pid" 2>/dev/null || return 1
    for _ in {1..20}; do wp_spawn_matches "$pid" "$start" "$token" || return 0; sleep 0.05; done
    return 1
  fi
}
wp_listener_owned() {
  local pid=$1
  ss -H -ltnp 2>/dev/null | awk -v p="$pid" -v port=":$local_port" '$4 ~ ("127[.]0[.]0[.]1" port "$") && $0 ~ ("pid=" p "([,)]|$)") { ok=1 } END { exit !ok }'
}
wp_any_listener() { ss -H -ltn 2>/dev/null | awk -v port=":$local_port" '$4 ~ ("127[.]0[.]0[.]1" port "$") { ok=1 } END { exit !ok }'; }
wp_socks5() {
  # shellcheck disable=SC2016
  timeout 2 bash -c 'exec 9<>/dev/tcp/127.0.0.1/'"$local_port"' || exit; printf "\x05\x01\x00" >&9; got=$(dd bs=1 count=2 <&9 2>/dev/null | od -An -tx1 | tr -d " \n"); [[ $got == 0500 ]]'
}
wp_ready_pid() { wp_process_expected "$1" "${2:-}" "${3:-}" && wp_listener_owned "$1" && wp_socks5; }
wp_systemd_pid() { systemctl --user show -p MainPID --value wsl-proxy.service 2>/dev/null || true; }
wp_systemd_available() { [[ -f $service ]] && command -v systemctl >/dev/null && [[ $(cat /proc/1/comm 2>/dev/null || true) == systemd ]] && systemctl --user show-environment >/dev/null 2>&1; }
wp_stop_recorded() {
  if wp_record_valid; then
    kill "$WP_PID" 2>/dev/null || true
    for _ in {1..20}; do wp_process_expected "$WP_PID" "$WP_START" "$WP_TOKEN" || break; sleep 0.1; done
    if wp_process_expected "$WP_PID" "$WP_START" "$WP_TOKEN"; then kill -KILL "$WP_PID" 2>/dev/null || return 1; fi
    for _ in {1..20}; do wp_process_expected "$WP_PID" "$WP_START" "$WP_TOKEN" || break; sleep 0.05; done
    wp_process_expected "$WP_PID" "$WP_START" "$WP_TOKEN" && return 1
  fi
  rm -f "$pidfile"
}
HELPER

cat >"$tmpdir/wsl-proxy-tunnel" <<'HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
data_dir=$HOME/.local/share/wsl-proxy
known_hosts=$data_dir/known_hosts
local_port=1080
# shellcheck disable=SC1091
. "$HOME/.local/bin/wsl-proxy-common"
wp_load_config
[[ -f $WSL_PROXY_KEY_PATH && ! -L $WSL_PROXY_KEY_PATH ]] || wp_die 'The configured private key is missing or unsafe.'
mkdir -p "$data_dir"
wp_safe_path "$known_hosts" || wp_die 'Unsafe known_hosts path.'
if [[ -e $known_hosts ]]; then
  known_hosts_mode=$(stat -c %a -- "$known_hosts") || wp_die 'Cannot inspect managed known_hosts.'
  if [[ $known_hosts_mode != 600 ]]; then wp_backup_before_edit known_hosts "$known_hosts"; chmod 600 "$known_hosts"; fi
else
  : >"$known_hosts"
  chmod 600 "$known_hosts"
fi
host_key_options=(-o StrictHostKeyChecking=accept-new)
if [[ -n $WSL_PROXY_HOST_FINGERPRINT ]]; then
  scan=$(mktemp "$data_dir/.hostkey-scan.XXXXXX")
  pinned=$(mktemp "$data_dir/.hostkey-pinned.XXXXXX")
  candidate=$(mktemp "$data_dir/.hostkey-candidate.XXXXXX")
  trap 'rm -f "$scan" "$pinned" "$candidate"' EXIT
  ssh-keyscan -T 10 -p "$WSL_PROXY_SSH_PORT" "$WSL_PROXY_SSH_HOST" >"$scan" 2>/dev/null || wp_die 'Unable to retrieve the SSH host key for pin verification.'
  while IFS= read -r key_line; do
    printf '%s\n' "$key_line" >"$candidate"
    if ssh-keygen -lf "$candidate" -E sha256 2>/dev/null | awk '{print $2}' | grep -Fxq "$WSL_PROXY_HOST_FINGERPRINT"; then printf '%s\n' "$key_line" >>"$pinned"; fi
  done <"$scan"
  [[ -s $pinned ]] || wp_die 'SSH host fingerprint mismatch; refusing to connect.'
  chmod 600 "$pinned"
  wp_backup_before_edit known_hosts "$known_hosts"
  mv -f "$pinned" "$known_hosts"
  rm -f "$scan" "$candidate"
  trap - EXIT
  host_key_options=(-o StrictHostKeyChecking=yes)
else
  # accept-new may append a first-seen host key, so preserve the exact prior file
  # immediately before SSH receives permission to edit it.
  wp_backup_before_edit known_hosts "$known_hosts"
fi
export WSL_PROXY_INSTALL_ID
exec "$WSL_PROXY_SSH_BINARY" -NT -D "127.0.0.1:$local_port" -p "$WSL_PROXY_SSH_PORT" -i "$WSL_PROXY_KEY_PATH" \
  -o BatchMode=yes -o ExitOnForwardFailure=yes -o IdentitiesOnly=yes \
  -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o HashKnownHosts=yes \
  -o UserKnownHostsFile="$known_hosts" -o GlobalKnownHostsFile=/dev/null \
  "${host_key_options[@]}" -- "$WSL_PROXY_SSH_USER@$WSL_PROXY_SSH_HOST"
HELPER

cat >"$tmpdir/proxy-on" <<'HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
quiet=0
[[ ${1:-} == --quiet ]] && quiet=1
[[ $# -le $quiet ]] || { echo 'Usage: proxy-on [--quiet]' >&2; exit 64; }
data_dir=$HOME/.local/share/wsl-proxy
pidfile=$data_dir/tunnel.pid
local_port=1080
# shellcheck disable=SC1091
. "$HOME/.local/bin/wsl-proxy-common"
wp_load_config
logfile=$data_dir/tunnel.log
mode=process
pid=
if wp_systemd_available; then
  mode=systemd
  systemctl --user start wsl-proxy.service || {
    systemctl --user disable --now wsl-proxy.service >/dev/null 2>&1 || true
    systemctl --user reset-failed wsl-proxy.service >/dev/null 2>&1 || true
    wp_die 'The managed systemd service failed to start.'
  }
else
  if wp_record_valid; then
    pid=$WP_PID
  else
    rm -f "$pidfile"
    if wp_any_listener; then wp_die "Port 127.0.0.1:$local_port is occupied by an unrelated process."; fi
    token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
    start=''
    record_tmp=''
    WSL_PROXY_INSTANCE_TOKEN=$token nohup "$HOME/.local/bin/wsl-proxy-tunnel" >>"$logfile" 2>&1 &
    pid=$!
    cleanup_spawn() { wp_kill_spawn "$pid" "$start" "$token" || echo 'ERROR: spawned tunnel process could not be stopped.' >&2; rm -f "${record_tmp:-}"; }
    trap cleanup_spawn ERR EXIT INT TERM
    for _ in {1..20}; do start=$(wp_start_time "$pid" || true); [[ $start =~ ^[0-9]+$ ]] && break; sleep 0.05; done
    [[ $start =~ ^[0-9]+$ ]] || wp_die 'The SSH tunnel process exited before it could be identified.'
    record_tmp=$(mktemp "$data_dir/.tunnel.pid.XXXXXX")
    printf 'PID=%s\nSTART=%s\nTOKEN=%s\n' "$pid" "$start" "$token" >"$record_tmp"
    chmod 600 "$record_tmp"
    mv -f "$record_tmp" "$pidfile"
    record_tmp=''
  fi
fi
for _ in {1..30}; do
  if [[ $mode == systemd ]]; then
    pid=$(wp_systemd_pid)
    systemd_start=$(wp_start_time "$pid" || true)
    if [[ $pid =~ ^[1-9][0-9]*$ && $systemd_start =~ ^[0-9]+$ ]] && wp_ready_pid "$pid" "$systemd_start"; then (( quiet )) || echo "Verified managed SOCKS5 proxy on 127.0.0.1:$local_port (systemd pid $pid)."; exit 0; fi
    systemctl --user is-active --quiet wsl-proxy.service || break
  else
    if wp_record_valid && wp_ready_pid "$WP_PID" "$WP_START" "$WP_TOKEN"; then trap - ERR EXIT INT TERM; (( quiet )) || echo "Verified managed SOCKS5 proxy on 127.0.0.1:$local_port (pid $WP_PID)."; exit 0; fi
    wp_process_expected "$pid" "${start:-}" "${token:-}" || break
  fi
  sleep 0.5
done
if [[ $mode == systemd ]]; then
  systemctl --user disable --now wsl-proxy.service >/dev/null 2>&1 || true
  systemctl --user reset-failed wsl-proxy.service >/dev/null 2>&1 || true
else
  wp_stop_recorded || wp_die 'Failed to stop the managed fallback process.'
fi
trap - ERR EXIT INT TERM
wp_die 'The managed SSH tunnel did not pass process, listener-ownership, and SOCKS5 readiness checks; it was stopped and disabled.'
HELPER

cat >"$tmpdir/proxy-off" <<'HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck disable=SC1091
. "$HOME/.local/bin/wsl-proxy-common"
wp_load_config || exit 1
if wp_systemd_available; then
  systemd_pid=$(wp_systemd_pid)
  if [[ $systemd_pid =~ ^[1-9][0-9]*$ ]]; then
    wp_process_expected "$systemd_pid" || exit 1
    systemctl --user stop wsl-proxy.service >/dev/null 2>&1 || exit 1
    for _ in {1..40}; do wp_process_expected "$systemd_pid" || break; sleep 0.05; done
    wp_process_expected "$systemd_pid" && exit 1
  elif systemctl --user is-active --quiet wsl-proxy.service; then
    exit 1
  fi
fi
wp_stop_recorded || exit 1
wp_any_listener && exit 1
echo 'WSL proxy tunnel stopped; no unverified PID was signaled.'
HELPER

cat >"$tmpdir/proxy-status" <<'HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck disable=SC1091
. "$HOME/.local/bin/wsl-proxy-common"
wp_load_config
if wp_systemd_available; then
  pid=$(wp_systemd_pid)
  systemd_start=$(wp_start_time "$pid" || true)
  if [[ $pid =~ ^[1-9][0-9]*$ && $systemd_start =~ ^[0-9]+$ ]] && wp_ready_pid "$pid" "$systemd_start"; then echo "ready: verified managed SSH pid $pid owns a working SOCKS5 listener"; exit 0; fi
elif wp_record_valid && wp_ready_pid "$WP_PID" "$WP_START" "$WP_TOKEN"; then
  echo "ready: verified managed SSH pid $WP_PID owns a working SOCKS5 listener"; exit 0
fi
if wp_any_listener; then echo 'unsafe: listener exists but is not a verified managed SSH SOCKS5 process'; exit 4; fi
echo 'stopped: no verified managed SOCKS5 tunnel'; exit 3
HELPER

cat >"$tmpdir/proxy-chrome" <<'HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail
"$HOME/.local/bin/proxy-on"
# shellcheck disable=SC1091
. "$HOME/.local/bin/wsl-proxy-common"
wp_load_config
wp_safe_path "$HOME/.local/share/wsl-proxy/chrome-profile" || { echo 'Unsafe Chrome profile path.' >&2; exit 1; }
command -v google-chrome >/dev/null || { echo 'google-chrome is missing; rerun install.sh.' >&2; exit 1; }
exec google-chrome --user-data-dir="$HOME/.local/share/wsl-proxy/chrome-profile" \
  --proxy-server=socks5://127.0.0.1:1080 '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE localhost' "$@"
HELPER
cat >"$tmpdir/proxy-copy" <<'HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail
command -v clip.exe >/dev/null || { echo 'clip.exe is unavailable. WSL interop may be disabled.' >&2; exit 1; }
clip.exe
HELPER
cat >"$tmpdir/proxy-paste" <<'HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail
command -v powershell.exe >/dev/null || { echo 'powershell.exe is unavailable. WSL interop may be disabled.' >&2; exit 1; }
powershell.exe -NoLogo -NoProfile -NonInteractive -Command '[Console]::Out.Write((Get-Clipboard -Raw))'
HELPER
cat >"$tmpdir/wsl-proxy.service" <<'UNIT'
[Unit]
Description=WSL SSH SOCKS5 proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=%h/.local/bin/wsl-proxy-tunnel
Restart=no

[Install]
WantedBy=default.target
UNIT

# Capture managed-target originals once per install lifecycle, before the first
# overwrite. .bashrc has a separate lifecycle snapshot because it is edited only
# on fallback systems and must not be rolled back when this lifecycle never
# touched it.
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
if [[ -e $data_dir/originals-v1/uninstalled ]]; then
  validate_manifest || die 'Cannot rotate an incomplete prior lifecycle manifest.'
  archive=$data_dir/backups/originals-$(date -u +%Y%m%dT%H%M%SZ)-$$
  mkdir -p "$data_dir/backups"
  mv "$data_dir/originals-v1" "$archive"
  mkdir -p "$originals_dir"
  chmod 700 "$data_dir/originals-v1" "$originals_dir"
fi
if [[ -e $manifest ]]; then
  validate_manifest || die 'The install-time originals manifest is incomplete or unsafe; refusing overwrite.'
  if ! grep -Fxq 'WSL_PROXY_TEST_INERT=1' "$config_file"; then
    [[ -x $bin_dir/proxy-off && -x $bin_dir/wsl-proxy-common ]] || die 'Existing managed stop helpers are missing; refusing reconfiguration.'
    "$bin_dir/proxy-off" >/dev/null || die 'Could not safely stop the existing tunnel before reconfiguration.'
  fi
else
  manifest_tmp=$(mktemp "$data_dir/originals-v1/.manifest.XXXXXX")
  printf 'wsl-proxy-originals-v1\n' >"$manifest_tmp"
  for i in "${!ids[@]}"; do
    id=${ids[$i]}; target=${targets[$i]}
    if [[ -e $target ]]; then cp -a -- "$target" "$originals_dir/$id"; printf '%s\tpresent\n' "$id" >>"$manifest_tmp"; else printf '%s\tabsent\n' "$id" >>"$manifest_tmp"; fi
  done
  chmod 600 "$manifest_tmp"
  mv -f "$manifest_tmp" "$manifest"
fi
backup_counter=0
backup_before_edit() {
  local id=$1 target=$2 stamp backup_dir
  [[ -e $target ]] || return 0
  assert_file_target "$target" "pre-edit backup source $target"
  stamp=$(date -u +%Y%m%dT%H%M%S.%NZ)
  backup_counter=$((backup_counter + 1))
  backup_dir=$preedit_root/$stamp-$$-$backup_counter
  mkdir -p "$backup_dir"
  chmod 700 "$preedit_root" "$backup_dir"
  cp -a -- "$target" "$backup_dir/$id"
  cmp -s "$target" "$backup_dir/$id" || die "Pre-edit backup verification failed for $target."
  printf 'timestamp=%s\nid=%s\ntarget=%s\n' "$stamp" "$id" "$target" >"$backup_dir/metadata"
  chmod 600 "$backup_dir/metadata"
}
capture_bashrc_original() {
  local state staged state_tmp
  if [[ -e $bashrc_touched ]]; then return 0; fi
  if [[ -e $bashrc_original_state ]]; then
    state=$(cat "$bashrc_original_state")
    case $state in
      present) [[ -f $bashrc_original && ! -L $bashrc_original ]] || die 'The lifecycle .bashrc original is incomplete.' ;;
      absent) [[ ! -e $bashrc_original ]] || die 'The lifecycle .bashrc original state is inconsistent.' ;;
      *) die 'The lifecycle .bashrc original state is invalid.' ;;
    esac
  else
    if [[ -e $bashrc ]]; then
      staged=$(mktemp "$data_dir/originals-v1/.bashrc-original.XXXXXX")
      cp -a -- "$bashrc" "$staged"
      cmp -s "$bashrc" "$staged" || { rm -f -- "$staged"; die 'Could not verify the lifecycle .bashrc original.'; }
      mv -f -- "$staged" "$bashrc_original"
      state=present
    else
      state=absent
    fi
    state_tmp=$(mktemp "$data_dir/originals-v1/.bashrc-state.XXXXXX")
    printf '%s\n' "$state" >"$state_tmp"
    chmod 600 "$state_tmp"
    mv -f -- "$state_tmp" "$bashrc_original_state"
  fi
  touch "$bashrc_touched"
  chmod 600 "$bashrc_touched"
}
atomic_install() {
  local source=$1 target=$2 mode=$3 target_dir staged
  target_dir=$(dirname -- "$target")
  staged=$(mktemp "$target_dir/.wsl-proxy-install.XXXXXX")
  if ! install -m "$mode" "$source" "$staged" || ! cmp -s "$source" "$staged"; then
    rm -f -- "$staged"
    die "Could not stage and validate managed target $target."
  fi
  if ! mv -f -- "$staged" "$target"; then
    rm -f -- "$staged"
    die "Could not atomically replace managed target $target."
  fi
}
install_managed() {
  local source=$1 target=$2 mode=$3 id=$4
  assert_file_target "$target" "managed target $target"
  if [[ ! -e $target ]] || ! cmp -s "$source" "$target"; then
    backup_before_edit "$id" "$target"
    atomic_install "$source" "$target" "$mode"
  fi
}
install_managed "$tmpdir/config" "$config_file" 600 config
install_managed "$tmpdir/wsl-proxy-common" "$bin_dir/wsl-proxy-common" 700 common
install_managed "$tmpdir/wsl-proxy-tunnel" "$bin_dir/wsl-proxy-tunnel" 700 tunnel
for helper in proxy-on proxy-off proxy-status proxy-chrome proxy-copy proxy-paste; do install_managed "$tmpdir/$helper" "$bin_dir/$helper" 700 "${helper//-/_}"; done
install_managed "$tmpdir/wsl-proxy.service" "$service" 600 service
printf '%s\n' "$install_id" >"$tmpdir/enrolled"
install_managed "$tmpdir/enrolled" "$enrollment_file" 600 enrollment

use_systemd=0
if (( ! DRY_RUN )) && command -v systemctl >/dev/null && [[ $(cat /proc/1/comm 2>/dev/null || true) == systemd ]] && systemctl --user show-environment >/dev/null 2>&1; then use_systemd=1; fi
add_shell_hook() {
  local staged
  write_shell_hook_block "$tmpdir/bashrc.block"
  if [[ -f $bashrc ]]; then
    awk -v begin="$MANAGED_BEGIN" -v end="$MANAGED_END" '$0 == begin { managed=1 } managed { print } $0 == end { managed=0 }' "$bashrc" >"$tmpdir/bashrc.current-block"
    if cmp -s "$tmpdir/bashrc.block" "$tmpdir/bashrc.current-block"; then
      validate_bash_syntax "$bashrc" || die 'Existing managed .bashrc failed Bash syntax validation.'
      return 0
    fi
  fi
  build_shell_hook_candidate "$tmpdir/bashrc.new" "$tmpdir/bashrc.block" "$tmpdir/bashrc.clean" || die 'Generated .bashrc managed block failed marker validation.'
  validate_bash_syntax "$tmpdir/bashrc.new" || die 'Generated .bashrc failed Bash syntax validation.'
  if [[ ! -e $bashrc ]] || ! cmp -s "$bashrc" "$tmpdir/bashrc.new"; then
    capture_bashrc_original
    backup_before_edit bashrc "$bashrc"
    staged=$(mktemp "$(dirname -- "$bashrc")/.bashrc.wsl-proxy.XXXXXX")
    if [[ -e $bashrc ]]; then
      cp -a -- "$bashrc" "$staged" || { rm -f -- "$staged"; die 'Could not preserve .bashrc metadata on the staged replacement.'; }
    else
      chmod 644 "$staged"
    fi
    if ! cat "$tmpdir/bashrc.new" >"$staged" || ! cmp -s "$tmpdir/bashrc.new" "$staged" || ! validate_bash_syntax "$staged"; then
      rm -f -- "$staged"
      die 'Could not stage and validate the .bashrc update.'
    fi
    if ! mv -f -- "$staged" "$bashrc"; then
      rm -f -- "$staged"
      die 'Could not atomically replace .bashrc; the original remains unchanged.'
    fi
  fi
}
remove_shell_hook() {
  local staged
  [[ -f $bashrc ]] || return 0
  awk -v begin="$MANAGED_BEGIN" -v end="$MANAGED_END" '$0 == begin { managed=1; next } $0 == end { managed=0; next } !managed { print }' "$bashrc" >"$tmpdir/bashrc.clean"
  if ! cmp -s "$bashrc" "$tmpdir/bashrc.clean"; then
    # A lifecycle created by this release already has an exact original. An
    # older lifecycle does not; do not mislabel its managed file as original.
    [[ -e $bashrc_touched ]] && capture_bashrc_original
    backup_before_edit bashrc "$bashrc"
    staged=$(mktemp "$(dirname -- "$bashrc")/.bashrc.wsl-proxy.XXXXXX")
    cp -a -- "$bashrc" "$staged" || { rm -f -- "$staged"; die 'Could not preserve .bashrc metadata on the staged cleanup.'; }
    cat "$tmpdir/bashrc.clean" >"$staged"
    cmp -s "$tmpdir/bashrc.clean" "$staged" || { rm -f -- "$staged"; die 'Could not validate staged .bashrc cleanup.'; }
    mv -f -- "$staged" "$bashrc" || { rm -f -- "$staged"; die 'Could not atomically clean .bashrc.'; }
  fi
}
if (( DRY_RUN )); then
  if (( INTERNAL_TEST_SHELL_HOOK )); then add_shell_hook; fi
  if (( INTERNAL_TEST_SHELL_CLEANUP )); then remove_shell_hook; fi
  info 'Dry run complete: files were written under HOME, but no service, tunnel, or auto-start hook was started.'
elif (( use_systemd )); then
  "$bin_dir/proxy-off" >/dev/null || die 'Could not safely stop a previous managed fallback tunnel.'
  systemctl --user daemon-reload
  "$bin_dir/proxy-on"
  if ! systemctl --user enable wsl-proxy.service; then
    systemctl --user disable --now wsl-proxy.service >/dev/null 2>&1 || true
    die 'Tunnel passed readiness, but enabling the user service failed; it was stopped and disabled.'
  fi
  remove_shell_hook
  info 'Installation complete with a verified, enabled systemd user service.'
else
  "$bin_dir/proxy-on"
  add_shell_hook
  info 'Installation complete with a verified fallback tunnel and interactive-shell hook.'
fi
info 'Launch isolated proxied Chrome with: proxy-chrome'
info "Install-time originals manifest: $manifest"
