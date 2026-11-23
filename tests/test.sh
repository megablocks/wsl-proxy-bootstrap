#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
command -v shellcheck >/dev/null || fail 'shellcheck is required'
command -v python3 >/dev/null || fail 'python3 is required for socket regression tests'
command -v setfacl >/dev/null || fail 'setfacl (acl package) is required'
command -v getfacl >/dev/null || fail 'getfacl (acl package) is required'

bash -n install.sh uninstall.sh tests/test.sh
shellcheck install.sh uninstall.sh tests/test.sh
pass 'bash syntax and ShellCheck'

set +e
root_out=$(./install.sh --internal-test-root-refusal 2>&1)
root_rc=$?
set -e
[[ $root_rc != 0 ]] || fail 'root-refusal self-test unexpectedly succeeded'
grep -q 'Do not run this installer as root' <<<"$root_out" || fail 'root-refusal self-test did not exercise the production refusal'
pass 'root refusal is testable safely under root and non-root CI'

tmp=$(mktemp -d)
cleanup_pids=()
cleanup() {
  local pid
  for pid in "${cleanup_pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  rm -rf "$tmp"
}
trap cleanup EXIT
cp install.sh uninstall.sh "$tmp/"
chmod 755 "$tmp" "$tmp/install.sh" "$tmp/uninstall.sh"
if (( EUID == 0 )); then
  test_user=nobody
  test_group=nogroup
  chown -R "$test_user:$test_group" "$tmp"
  uenv() { runuser -u "$test_user" -- env "$@"; }
else
  test_user=$(id -un)
  test_group=$(id -gn)
  uenv() { env "$@"; }
fi

new_home() {
  local path=$1
  mkdir -p "$path"
  if (( EUID == 0 )); then chown -R "$test_user:$test_group" "$path"; fi
}
run_internal() { uenv HOME="$1" "$tmp/install.sh" --internal-test-dry-run; }

home=$tmp/home
new_home "$home"
printf '%s\n' '# existing user content' >"$home/.bashrc"
chmod 640 "$home/.bashrc"
cp "$home/.bashrc" "$tmp/bashrc.original"
if (( EUID == 0 )); then chown "$test_user:$test_group" "$home/.bashrc"; fi
uenv HOME="$home" python3 -c 'import os,sys; os.setxattr(sys.argv[1], b"user.wsl_proxy_test", b"preserve-me")' "$home/.bashrc"
bashrc_gid_before=$(stat -c %g "$home/.bashrc")
set +e
first=$(run_internal "$home" 2>&1)
first_rc=$?
set -e
[[ $first_rc == 20 ]] || fail "first install should stop for enrollment (got $first_rc)"
grep -q 'ENROLLMENT REQUIRED' <<<"$first" || fail 'missing enrollment notice'
grep -q '^ssh-ed25519 ' <<<"$first" || fail 'public key was not printed'
! grep -qE -- 'BEGIN .*PRIVATE KEY|PRIVATE KEY-----' <<<"$first" || fail 'private key material reached output'
[[ -f $home/.ssh/wsl-proxy_ed25519 ]] || fail 'dedicated key was not generated'
[[ ! -e $home/.local/bin/proxy-on && ! -e $home/.config/wsl-proxy/config && ! -e $home/.config/systemd/user/wsl-proxy.service ]] || fail 'operational files were installed before enrollment'
! grep -q 'wsl-proxy-bootstrap managed block' "$home/.bashrc" || fail 'shell hook was installed before enrollment'
printf '%s\n' global-before >"$home/.ssh/known_hosts"
if (( EUID == 0 )); then chown "$test_user:$test_group" "$home/.ssh/known_hosts"; fi
pass 'enrollment phase creates only a dedicated key and makes no readiness claim'

# Every symlinked mutation surface must fail before creating a key or changing its target.
for case_name in ssh bashrc config bin; do
  h=$tmp/symlink-$case_name
  escape=$tmp/escape-$case_name
  new_home "$h"
  mkdir -p "$escape"
  printf sentinel >"$escape/sentinel"
  case $case_name in
    ssh) ln -s "$escape" "$h/.ssh" ;;
    bashrc) ln -s "$escape/sentinel" "$h/.bashrc" ;;
    config) mkdir -p "$h/.config/wsl-proxy"; ln -s "$escape/sentinel" "$h/.config/wsl-proxy/config" ;;
    bin) mkdir -p "$h/.local"; ln -s "$escape" "$h/.local/bin" ;;
  esac
  if (( EUID == 0 )); then chown -h "$test_user:$test_group" "$h"/.* 2>/dev/null || true; chown -R "$test_user:$test_group" "$h" "$escape"; fi
  set +e
  symlink_out=$(run_internal "$h" 2>&1)
  symlink_rc=$?
  set -e
  [[ $symlink_rc != 0 ]] || fail "installer accepted symlinked $case_name target"
  grep -qi 'symbolic link' <<<"$symlink_out" || fail "symlinked $case_name failure was not explicit"
  [[ $(cat "$escape/sentinel") == sentinel ]] || fail "symlink escape mutated target for $case_name"
done
pass 'HOME targets reject symlink escapes for .ssh, .bashrc, config, and bin'

# Simulate an alternate Windows-backed mount without reading or writing /mnt/c.
mount_home=$tmp/mount-home
new_home "$mount_home"
mkdir -p "$mount_home/hostmount" "$tmp/mountbin"
cat >"$tmp/mountbin/findmnt" <<'FAKE'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' '9p C:\'
FAKE
chmod 755 "$tmp/mountbin/findmnt"
if (( EUID == 0 )); then chown -R "$test_user:$test_group" "$mount_home" "$tmp/mountbin"; fi
set +e
mount_out=$(uenv HOME="$mount_home" PATH="$tmp/mountbin:$PATH" WSL_PROXY_KEY_PATH="$mount_home/hostmount/key" "$tmp/install.sh" --internal-test-dry-run 2>&1)
mount_rc=$?
set -e
[[ $mount_rc != 0 ]] || fail 'installer accepted alternate Windows-backed mount'
grep -q 'Windows-backed filesystem' <<<"$mount_out" || fail "mount refusal was not explicit: $mount_out"
[[ ! -e $mount_home/hostmount/key ]] || fail 'mount safety check happened after mutation'
pass 'filesystem-type check rejects alternate Windows-backed mounts before mutation'

# A failed same-directory rename must leave .bashrc unchanged, after a verified
# timestamped pre-edit backup has already been created.
atomic_home=$tmp/atomic-home
new_home "$atomic_home"
printf '%s\n' '# atomic original' >"$atomic_home/.bashrc"
if (( EUID == 0 )); then chown "$test_user:$test_group" "$atomic_home/.bashrc"; fi
set +e
run_internal "$atomic_home" >/dev/null 2>&1
atomic_enroll_rc=$?
set -e
[[ $atomic_enroll_rc == 20 ]] || fail 'atomic-failure fixture did not stop for enrollment'
failbin=$tmp/failbin
mkdir -p "$failbin"
cat >"$failbin/mv" <<'FAKE'
#!/usr/bin/env bash
set -Eeuo pipefail
last=
for arg in "$@"; do last=$arg; done
case $last in */.bashrc) exit 73 ;; esac
exec /usr/bin/mv "$@"
FAKE
chmod 755 "$failbin/mv"
if (( EUID == 0 )); then chown -R "$test_user:$test_group" "$failbin"; fi
set +e
atomic_out=$(uenv HOME="$atomic_home" PATH="$failbin:$PATH" WSL_PROXY_ENROLLED=1 "$tmp/install.sh" --internal-test-shell-hook 2>&1)
atomic_rc=$?
set -e
[[ $atomic_rc != 0 ]] || fail 'injected .bashrc rename failure reported success'
grep -q 'original remains unchanged' <<<"$atomic_out" || fail 'atomic .bashrc failure was not explicit'
[[ $(cat "$atomic_home/.bashrc") == '# atomic original' ]] || fail 'failed atomic replacement changed .bashrc'
atomic_backup=$(find "$atomic_home/.local/share/wsl-proxy/backups/pre-edit" -type f -name bashrc -print -quit)
[[ -n $atomic_backup ]] || fail 'failed .bashrc replacement lacked a timestamped pre-edit backup'
cmp -s "$atomic_home/.bashrc" "$atomic_backup" || fail 'pre-edit backup did not preserve the exact pre-mutation .bashrc'
find "$atomic_home" -maxdepth 1 -name '.bashrc.wsl-proxy.*' -print -quit | grep -q . && fail 'failed atomic replacement left a staging file'
pass 'timestamped backup precedes atomic .bashrc replacement and rename failure is safe'

# Add collisions after key enrollment so install-time originals must be captured.
mkdir -p "$home/.local/bin" "$home/.config/wsl-proxy" "$home/.config/systemd/user" "$home/.local/share/wsl-proxy"
printf 'original proxy-on\n' >"$home/.local/bin/proxy-on"
printf 'original common\n' >"$home/.local/bin/wsl-proxy-common"
printf 'original config\n' >"$home/.config/wsl-proxy/config"
printf 'original service\n' >"$home/.config/systemd/user/wsl-proxy.service"
printf 'original managed known hosts\n' >"$home/.local/share/wsl-proxy/known_hosts"
if (( EUID == 0 )); then chown -R "$test_user:$test_group" "$home"; fi
if (( EUID == 0 )); then
  chown "$test_user:root" "$home" "$home/.bashrc"
  chmod 2770 "$home"
fi
uenv HOME="$home" setfacl -m u:root:r-- "$home/.bashrc"
getfacl -cp "$home/.bashrc" >"$tmp/bashrc.acl"
bashrc_gid_before=$(stat -c %g "$home/.bashrc")
bashrc_inode_before=$(stat -c %i "$home/.bashrc")
uenv HOME="$home" WSL_PROXY_ENROLLED=1 "$tmp/install.sh" --internal-test-shell-hook >/dev/null
bashrc_backup_count=$(find "$home/.local/share/wsl-proxy/backups/pre-edit" -type f -name bashrc | wc -l)
[[ $bashrc_backup_count == 1 ]] || fail 'first .bashrc edit did not create exactly one timestamped pre-edit backup'
bashrc_backup=$(find "$home/.local/share/wsl-proxy/backups/pre-edit" -type f -name bashrc -print -quit)
cmp -s "$tmp/bashrc.original" "$bashrc_backup" || fail 'timestamped .bashrc backup differs from the pre-install file'
[[ $(stat -c %i "$home/.bashrc") != "$bashrc_inode_before" ]] || fail '.bashrc was not replaced by same-directory rename'
[[ $(stat -c %a:%g "$home/.bashrc") == "640:$bashrc_gid_before" ]] || fail '.bashrc mode or group metadata changed during atomic replacement'
[[ $(uenv HOME="$home" python3 -c 'import os,sys; print(os.getxattr(sys.argv[1], b"user.wsl_proxy_test").decode())' "$home/.bashrc") == preserve-me ]] || fail '.bashrc extended attributes changed during atomic replacement'
getfacl -cp "$home/.bashrc" | cmp -s "$tmp/bashrc.acl" - || fail '.bashrc ACL changed during atomic replacement'
uenv HOME="$home" WSL_PROXY_ENROLLED=1 "$tmp/install.sh" --internal-test-shell-hook >/dev/null
[[ $(find "$home/.local/share/wsl-proxy/backups/pre-edit" -type f -name bashrc | wc -l) == 1 ]] || fail 'idempotent rerun created a redundant .bashrc backup'
for backed_up in config proxy_on common service; do
  candidate=$(find "$home/.local/share/wsl-proxy/backups/pre-edit" -type f -name "$backed_up" -print -quit)
  [[ -n $candidate ]] || fail "existing managed $backed_up lacked a timestamped pre-edit backup"
done
[[ $(cat "$(find "$home/.local/share/wsl-proxy/backups/pre-edit" -type f -name config -print -quit)") == 'original config' ]] || fail 'managed config pre-edit backup was not exact'
find "$home/.local/share/wsl-proxy/backups/pre-edit" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | grep -Eq '^[0-9]{8}T[0-9]{6}[.][0-9]{9}Z-' || fail 'pre-edit backup directory is not timestamped'
shellcheck "$home/.local/bin/"*
[[ $(grep -Fc '# >>> wsl-proxy-bootstrap managed block >>>' "$home/.bashrc") == 1 ]] || fail 'managed .bashrc block was missing or duplicated'
grep -q '# existing user content' "$home/.bashrc" || fail 'bashrc content was not preserved'
grep -Fxq 'wsl-proxy-originals-v1' "$home/.local/share/wsl-proxy/originals-v1/manifest" || fail 'backup manifest missing'
grep -q $'proxy_on\tpresent' "$home/.local/share/wsl-proxy/originals-v1/manifest" || fail 'collision was not recorded'
# shellcheck disable=SC2016
grep -q 'UserKnownHostsFile="$known_hosts"' "$home/.local/bin/wsl-proxy-tunnel" || fail 'managed known_hosts not configured'
grep -q 'GlobalKnownHostsFile=/dev/null' "$home/.local/bin/wsl-proxy-tunnel" || fail 'global known_hosts was not isolated'
[[ $(cat "$home/.ssh/known_hosts") == global-before ]] || fail 'global known_hosts was mutated'
set +e
inert_out=$(uenv HOME="$home" "$home/.local/bin/proxy-on" 2>&1)
inert_rc=$?
set -e
[[ $inert_rc != 0 && ! -e $home/.local/share/wsl-proxy/tunnel.pid ]] || fail 'internal test installation could start a tunnel'
grep -q 'inert internal-test installation' <<<"$inert_out" || fail 'inert test gate was not explicit'
pass 'enrolled install is idempotent, inert, atomically updates .bashrc, and isolates known_hosts'
# Explicitly activate only this disposable test HOME for runtime helper regressions.
uenv HOME="$home" sed -i 's/^WSL_PROXY_TEST_INERT=.*/WSL_PROXY_TEST_INERT=0/; s/^WSL_PROXY_SSH_HOST=.*/WSL_PROXY_SSH_HOST=127.0.0.1/; s/^WSL_PROXY_SSH_PORT=.*/WSL_PROXY_SSH_PORT=1/' "$home/.config/wsl-proxy/config"
runtime_escape=$tmp/runtime-escape
printf sentinel >"$runtime_escape"
if (( EUID == 0 )); then chown "$test_user:$test_group" "$runtime_escape"; fi
for runtime_target in tunnel.log chrome-profile; do
  ln -s "$runtime_escape" "$home/.local/share/wsl-proxy/$runtime_target"
  set +e
  uenv HOME="$home" "$home/.local/bin/proxy-status" >/dev/null 2>&1
  runtime_rc=$?
  set -e
  [[ $runtime_rc != 0 && $(cat "$runtime_escape") == sentinel ]] || fail "runtime accepted symlinked $runtime_target"
  rm "$home/.local/share/wsl-proxy/$runtime_target"
done
pass 'runtime helpers revalidate log and Chrome-profile paths before writes'

fakebin=$tmp/fakebin
mkdir -p "$fakebin"
cat >"$fakebin/systemctl" <<'FAKE'
#!/usr/bin/env bash
exit 1
FAKE
chmod 755 "$fakebin/systemctl"
if (( EUID == 0 )); then chown -R "$test_user:$test_group" "$fakebin"; fi

# Generated tunnel must enforce the independent enrollment gate.
install_id=$(sed -n 's/^WSL_PROXY_INSTALL_ID=//p' "$home/.config/wsl-proxy/config")
rm -f "$home/.local/share/wsl-proxy/enrolled"
cat >"$fakebin/ssh" <<'FAKE'
#!/usr/bin/env bash
touch "$SSH_MARKER"
exit 0
FAKE
chmod 755 "$fakebin/ssh"
if (( EUID == 0 )); then chown "$test_user:$test_group" "$fakebin/ssh"; fi
set +e
uenv HOME="$home" PATH="$fakebin:$PATH" SSH_MARKER="$tmp/ssh-called" "$home/.local/bin/wsl-proxy-tunnel" >/dev/null 2>&1
gate_rc=$?
set -e
[[ $gate_rc != 0 && ! -e $tmp/ssh-called ]] || fail 'tunnel bypassed missing enrollment gate'
printf '%s\n' "$install_id" >"$home/.local/share/wsl-proxy/enrolled"
if (( EUID == 0 )); then chown "$test_user:$test_group" "$home/.local/share/wsl-proxy/enrolled"; fi
pass 'generated tunnel independently enforces explicit enrollment'

# A fully SOCKS5-speaking unrelated listener still must not satisfy readiness.
[[ -z $(ss -H -ltn 'sport = :1080' 2>/dev/null) ]] || fail 'test port 1080 is already occupied'
cat >"$tmp/socks.py" <<'PY'
import os, socket
open(os.environ['PID_OUT'], 'w').write(str(os.getpid()))
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(('127.0.0.1',1080)); s.listen()
while True:
 c,_=s.accept()
 try:
  c.recv(3); c.sendall(b'\x05\x00')
 finally: c.close()
PY
chmod 644 "$tmp/socks.py"
if (( EUID == 0 )); then
  chown "$test_user:$test_group" "$tmp/socks.py"
  runuser -u "$test_user" -- env PID_OUT="$tmp/socks.pid" python3 "$tmp/socks.py" &
else
  PID_OUT="$tmp/socks.pid" python3 "$tmp/socks.py" &
fi
launcher_pid=$!
cleanup_pids+=("$launcher_pid")
for _ in {1..50}; do [[ -s $tmp/socks.pid ]] && ss -H -ltn 'sport = :1080' | grep -q 1080 && break; sleep 0.05; done
[[ -s $tmp/socks.pid ]] || fail 'SOCKS test listener did not start'
socks_pid=$(cat "$tmp/socks.pid")
cleanup_pids+=("$socks_pid")
set +e
listener_out=$(uenv HOME="$home" PATH="$fakebin:$PATH" "$home/.local/bin/proxy-on" 2>&1)
listener_rc=$?
set -e
[[ $listener_rc != 0 ]] || fail 'unrelated SOCKS listener passed readiness'
grep -q 'occupied by an unrelated process' <<<"$listener_out" || fail 'unrelated listener was not identified'
kill -0 "$socks_pid" 2>/dev/null || fail 'proxy-on killed unrelated listener'
kill "$socks_pid" 2>/dev/null || true
wait "$launcher_pid" 2>/dev/null || true
pass 'readiness rejects an unrelated listener even when it speaks SOCKS5'

# A stale PID record must never signal an unrelated same-user process.
if (( EUID == 0 )); then
  # shellcheck disable=SC2016
  runuser -u "$test_user" -- sh -c 'echo $$ >"$1"; exec sleep 120' sh "$tmp/sleep.pid" &
else
  # shellcheck disable=SC2016
  sh -c 'echo $$ >"$1"; exec sleep 120' sh "$tmp/sleep.pid" &
fi
sleep_launcher=$!
cleanup_pids+=("$sleep_launcher")
for _ in {1..50}; do [[ -s $tmp/sleep.pid ]] && break; sleep 0.05; done
sleep_pid=$(cat "$tmp/sleep.pid")
cleanup_pids+=("$sleep_pid")
sleep_start=$(sed 's/^[^)]*) //' "/proc/$sleep_pid/stat" | awk '{print $20}')
printf 'PID=%s\nSTART=%s\nTOKEN=%s\n' "$sleep_pid" "$sleep_start" 00000000000000000000000000000000 >"$home/.local/share/wsl-proxy/tunnel.pid"
if (( EUID == 0 )); then chown "$test_user:$test_group" "$home/.local/share/wsl-proxy/tunnel.pid"; fi
uenv HOME="$home" PATH="$fakebin:$PATH" "$home/.local/bin/proxy-off" >/dev/null
kill -0 "$sleep_pid" 2>/dev/null || fail 'proxy-off killed an unrelated process from stale PID data'
[[ ! -e $home/.local/share/wsl-proxy/tunnel.pid ]] || fail 'stale PID record was not discarded'
kill "$sleep_pid" 2>/dev/null || true
wait "$sleep_launcher" 2>/dev/null || true
pass 'stale PID start/token/command validation preserves unrelated process'

# Failed fallback connection must be cleaned up with no persistent process record.
cat >"$fakebin/ssh" <<'FAKE'
#!/usr/bin/env bash
exit 42
FAKE
chmod 755 "$fakebin/ssh"
if (( EUID == 0 )); then chown "$test_user:$test_group" "$fakebin/ssh"; fi
set +e
uenv HOME="$home" PATH="$fakebin:$PATH" "$home/.local/bin/proxy-on" >/dev/null 2>&1
fallback_rc=$?
set -e
[[ $fallback_rc != 0 ]] || fail 'failed fallback SSH start reported success'
[[ ! -e $home/.local/share/wsl-proxy/tunnel.pid ]] || fail 'failed fallback left a retry/process record'
pass 'failed fallback start leaves no connecting process record'

# Simulate systemd start failure and require explicit disable/stop cleanup.
cat >"$fakebin/cat" <<'FAKE'
#!/usr/bin/env bash
if [[ ${1:-} == /proc/1/comm ]]; then echo systemd; else exec /bin/cat "$@"; fi
FAKE
cat >"$fakebin/systemctl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
case "$*" in
  '--user show-environment') exit 0 ;;
  '--user start wsl-proxy.service') exit 1 ;;
  *) exit 0 ;;
esac
FAKE
chmod 755 "$fakebin/cat" "$fakebin/systemctl"
if (( EUID == 0 )); then chown "$test_user:$test_group" "$fakebin/cat" "$fakebin/systemctl"; fi
: >"$tmp/systemctl.log"
if (( EUID == 0 )); then chown "$test_user:$test_group" "$tmp/systemctl.log"; fi
set +e
uenv HOME="$home" PATH="$fakebin:$PATH" SYSTEMCTL_LOG="$tmp/systemctl.log" "$home/.local/bin/proxy-on" >/dev/null 2>&1
systemd_rc=$?
set -e
[[ $systemd_rc != 0 ]] || fail 'failed systemd start reported success'
grep -Fxq -- '--user disable --now wsl-proxy.service' "$tmp/systemctl.log" || fail 'failed systemd start was not disabled/stopped'
grep -Fxq 'Restart=no' "$home/.config/systemd/user/wsl-proxy.service" || fail 'service still has automatic retry policy'
pass 'failed systemd start is disabled/stopped and cannot retry persistently'

# Fingerprint mismatch must fail before ssh and retain a real on-disk managed file design.
ssh-keygen -q -t ed25519 -N '' -f "$tmp/hostkey"
keyscan_line="[example.invalid]:22 $(awk '{print $1, $2}' "$tmp/hostkey.pub")"
printf '%s\n' "$keyscan_line" >"$tmp/keyscan.line"
if (( EUID == 0 )); then chown "$test_user:$test_group" "$tmp/keyscan.line"; fi
cat >"$fakebin/ssh-keyscan" <<'FAKE'
#!/usr/bin/env bash
cat "$KEYSCAN_FILE"
FAKE
cat >"$fakebin/ssh" <<'FAKE'
#!/usr/bin/env bash
touch "$SSH_MARKER"
exit 0
FAKE
chmod 755 "$fakebin/ssh-keyscan" "$fakebin/ssh"
if (( EUID == 0 )); then chown "$test_user:$test_group" "$fakebin/ssh-keyscan" "$fakebin/ssh"; fi
trusted_ssh=$(sed -n 's/^WSL_PROXY_SSH_BINARY=//p' "$home/.config/wsl-proxy/config")
matching_fingerprint=$(ssh-keygen -lf "$tmp/hostkey.pub" -E sha256 | awk '{print $2}')
chmod 600 "$home/.local/share/wsl-proxy/known_hosts"
cp "$home/.local/share/wsl-proxy/known_hosts" "$tmp/known-hosts.before"
known_hosts_backups_before=$(find "$home/.local/share/wsl-proxy/backups/pre-edit" -type f -name known_hosts | wc -l)
uenv HOME="$home" sed -i "s|^WSL_PROXY_SSH_BINARY=.*|WSL_PROXY_SSH_BINARY=/usr/bin/true|; s|^WSL_PROXY_HOST_FINGERPRINT=.*|WSL_PROXY_HOST_FINGERPRINT=$matching_fingerprint|" "$home/.config/wsl-proxy/config"
uenv HOME="$home" PATH="$fakebin:$PATH" KEYSCAN_FILE="$tmp/keyscan.line" "$home/.local/bin/wsl-proxy-tunnel" >/dev/null
known_hosts_backups_after=$(find "$home/.local/share/wsl-proxy/backups/pre-edit" -type f -name known_hosts | wc -l)
[[ $known_hosts_backups_after == $((known_hosts_backups_before + 1)) ]] || fail 'successful pinned known_hosts replacement lacked one pre-edit backup'
known_hosts_backup=$(find "$home/.local/share/wsl-proxy/backups/pre-edit" -type f -name known_hosts -printf '%T@ %p\n' | sort -nr | head -n 1 | cut -d' ' -f2-)
cmp -s "$tmp/known-hosts.before" "$known_hosts_backup" || fail 'known_hosts pre-edit backup was not exact'
grep -Fxq "$keyscan_line" "$home/.local/share/wsl-proxy/known_hosts" || fail 'matching pinned host key was not atomically installed'
uenv HOME="$home" sed -i "s|^WSL_PROXY_SSH_BINARY=.*|WSL_PROXY_SSH_BINARY=$trusted_ssh|" "$home/.config/wsl-proxy/config"
pass 'successful managed known_hosts replacement creates a verified timestamped backup'
uenv HOME="$home" sed -i 's|^WSL_PROXY_HOST_FINGERPRINT=.*|WSL_PROXY_HOST_FINGERPRINT=SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=|' "$home/.config/wsl-proxy/config"
rm -f "$tmp/fingerprint-ssh-called"
set +e
fingerprint_out=$(uenv HOME="$home" PATH="$fakebin:$PATH" KEYSCAN_FILE="$tmp/keyscan.line" SSH_MARKER="$tmp/fingerprint-ssh-called" "$home/.local/bin/wsl-proxy-tunnel" 2>&1)
fingerprint_rc=$?
set -e
[[ $fingerprint_rc != 0 && ! -e $tmp/fingerprint-ssh-called ]] || fail 'fingerprint mismatch reached ssh'
grep -q 'fingerprint mismatch' <<<"$fingerprint_out" || fail 'fingerprint mismatch was not explicit'
! grep -q '/dev/fd/' "$home/.local/bin/wsl-proxy-tunnel" || fail 'pinned host key still relies on inherited descriptor'
pass 'fingerprint mismatch fails closed using managed on-disk known_hosts'

# Clipboard helpers remain explicit and do not log.
cat >"$fakebin/clip.exe" <<'CLIP'
#!/usr/bin/env bash
cat >"$CLIP_CAPTURE"
CLIP
cat >"$fakebin/powershell.exe" <<'POWERSHELL'
#!/usr/bin/env bash
printf paste-result
POWERSHELL
chmod 755 "$fakebin/clip.exe" "$fakebin/powershell.exe"
if (( EUID == 0 )); then chown "$test_user:$test_group" "$fakebin/clip.exe" "$fakebin/powershell.exe"; fi
printf secret-value | uenv HOME="$home" PATH="$fakebin:$PATH" CLIP_CAPTURE="$tmp/capture" "$home/.local/bin/proxy-copy"
[[ $(cat "$tmp/capture") == secret-value ]] || fail 'copy helper changed clipboard data'
[[ $(uenv HOME="$home" PATH="$fakebin:$PATH" "$home/.local/bin/proxy-paste") == paste-result ]] || fail 'paste helper failed'
! grep -Eq '(logger|tee[[:space:]])' "$home/.local/bin/proxy-copy" "$home/.local/bin/proxy-paste" || fail 'clipboard helper contains logging primitive'
pass 'clipboard helpers remain explicit and non-logging'

# Corrupt manifests must fail before stopping or restoring anything.
cp "$home/.local/share/wsl-proxy/originals-v1/manifest" "$tmp/manifest.good"
sed -i '/^service[[:space:]]/d' "$home/.local/share/wsl-proxy/originals-v1/manifest"
before_hash=$(sha256sum "$home/.local/bin/proxy-on")
set +e
uenv HOME="$home" "$tmp/uninstall.sh" >/dev/null 2>&1
corrupt_rc=$?
set -e
[[ $corrupt_rc != 0 && $(sha256sum "$home/.local/bin/proxy-on") == "$before_hash" ]] || fail 'corrupt manifest caused partial uninstall'
cp "$tmp/manifest.good" "$home/.local/share/wsl-proxy/originals-v1/manifest"
if (( EUID == 0 )); then chown "$test_user:$test_group" "$home/.local/share/wsl-proxy/originals-v1/manifest"; fi
pass 'malformed manifest fails before any restore mutation'

# Uninstall must restore collisions from install-time originals, not preserve only backups.
printf '%s\n' '# post-install user edit' >>"$home/.bashrc"
uenv HOME="$home" "$tmp/uninstall.sh" >/dev/null
[[ $(cat "$home/.local/bin/proxy-on") == 'original proxy-on' ]] || fail 'uninstall did not restore collided proxy-on'
[[ $(cat "$home/.local/bin/wsl-proxy-common") == 'original common' ]] || fail 'uninstall did not restore collided common helper'
[[ $(cat "$home/.config/wsl-proxy/config") == 'original config' ]] || fail 'uninstall did not restore collided config'
[[ $(cat "$home/.config/systemd/user/wsl-proxy.service") == 'original service' ]] || fail 'uninstall did not restore collided service'
[[ $(cat "$home/.local/share/wsl-proxy/known_hosts") == 'original managed known hosts' ]] || fail 'uninstall did not restore collided known_hosts'
[[ ! -e $home/.local/bin/wsl-proxy-tunnel ]] || fail 'uninstall retained originally absent tunnel helper'
! grep -q 'wsl-proxy-bootstrap managed block' "$home/.bashrc" || fail 'uninstall left managed bashrc block'
cmp -s "$tmp/bashrc.original" "$home/.bashrc" || fail 'uninstall did not restore the exact pre-install .bashrc'
[[ -f $home/.ssh/wsl-proxy_ed25519 ]] || fail 'uninstall deleted key data'
[[ $(cat "$home/.ssh/known_hosts") == global-before ]] || fail 'uninstall/global operation mutated global known_hosts'
pass 'manifest-driven uninstall restores collided files and exact pre-install .bashrc while preserving retained data'

# A new lifecycle must capture user changes made after the previous uninstall.
printf 'intervening user tunnel file\n' >"$home/.local/bin/wsl-proxy-tunnel"
if (( EUID == 0 )); then chown "$test_user:$test_group" "$home/.local/bin/wsl-proxy-tunnel"; fi
uenv HOME="$home" WSL_PROXY_ENROLLED=1 "$tmp/install.sh" --internal-test-dry-run >/dev/null
uenv HOME="$home" sed -i 's/^WSL_PROXY_TEST_INERT=.*/WSL_PROXY_TEST_INERT=0/' "$home/.config/wsl-proxy/config"
uenv HOME="$home" "$tmp/uninstall.sh" >/dev/null
[[ $(cat "$home/.local/bin/wsl-proxy-tunnel") == 'intervening user tunnel file' ]] || fail 'reinstall reused stale lifecycle backup'
pass 'reinstall rotates the old manifest and captures intervening user files'

# Upgrading an older fallback lifecycle to systemd-style shell cleanup must not
# snapshot the managed hook as an original and reintroduce it on uninstall.
legacy_home=$tmp/legacy-home
new_home "$legacy_home"
printf '%s\n' '# legacy original' >"$legacy_home/.bashrc"
if (( EUID == 0 )); then chown "$test_user:$test_group" "$legacy_home/.bashrc"; fi
set +e
run_internal "$legacy_home" >/dev/null 2>&1
legacy_enroll_rc=$?
set -e
[[ $legacy_enroll_rc == 20 ]] || fail 'legacy lifecycle fixture did not stop for enrollment'
uenv HOME="$legacy_home" WSL_PROXY_ENROLLED=1 "$tmp/install.sh" --internal-test-shell-hook >/dev/null
rm -f "$legacy_home/.local/share/wsl-proxy/originals-v1/bashrc-touched" "$legacy_home/.local/share/wsl-proxy/originals-v1/bashrc-original" "$legacy_home/.local/share/wsl-proxy/originals-v1/bashrc-original-state"
legacy_uninstall_home=$tmp/legacy-uninstall-home
cp -a "$legacy_home" "$legacy_uninstall_home"
if (( EUID == 0 )); then
  chown "$test_user:root" "$legacy_uninstall_home" "$legacy_uninstall_home/.bashrc"
  chmod 2770 "$legacy_uninstall_home"
fi
chmod 640 "$legacy_uninstall_home/.bashrc"
uenv HOME="$legacy_uninstall_home" python3 -c 'import os,sys; os.setxattr(sys.argv[1], b"user.wsl_proxy_legacy", b"keep-me")' "$legacy_uninstall_home/.bashrc"
uenv HOME="$legacy_uninstall_home" setfacl -m u:root:r-- "$legacy_uninstall_home/.bashrc"
getfacl -cp "$legacy_uninstall_home/.bashrc" >"$tmp/legacy-bashrc.acl"
legacy_uninstall_gid=$(stat -c %g "$legacy_uninstall_home/.bashrc")
uenv HOME="$legacy_uninstall_home" sed -i 's/^WSL_PROXY_TEST_INERT=.*/WSL_PROXY_TEST_INERT=0/' "$legacy_uninstall_home/.config/wsl-proxy/config"
uenv HOME="$legacy_uninstall_home" "$tmp/uninstall.sh" >/dev/null
! grep -q 'wsl-proxy-bootstrap managed block' "$legacy_uninstall_home/.bashrc" || fail 'legacy uninstall left the managed block'
[[ $(stat -c %a:%g "$legacy_uninstall_home/.bashrc") == "640:$legacy_uninstall_gid" ]] || fail 'legacy uninstall changed .bashrc mode or group metadata'
[[ $(uenv HOME="$legacy_uninstall_home" python3 -c 'import os,sys; print(os.getxattr(sys.argv[1], b"user.wsl_proxy_legacy").decode())' "$legacy_uninstall_home/.bashrc") == keep-me ]] || fail 'legacy uninstall dropped .bashrc extended attributes'
getfacl -cp "$legacy_uninstall_home/.bashrc" | cmp -s "$tmp/legacy-bashrc.acl" - || fail 'legacy uninstall changed .bashrc ACL'
uenv HOME="$legacy_home" WSL_PROXY_ENROLLED=1 "$tmp/install.sh" --internal-test-shell-cleanup >/dev/null
! grep -q 'wsl-proxy-bootstrap managed block' "$legacy_home/.bashrc" || fail 'legacy shell cleanup left the managed block'
[[ ! -e $legacy_home/.local/share/wsl-proxy/originals-v1/bashrc-touched ]] || fail 'legacy shell cleanup mislabeled the managed file as an original'
uenv HOME="$legacy_home" sed -i 's/^WSL_PROXY_TEST_INERT=.*/WSL_PROXY_TEST_INERT=0/' "$legacy_home/.config/wsl-proxy/config"
uenv HOME="$legacy_home" "$tmp/uninstall.sh" >/dev/null
! grep -q 'wsl-proxy-bootstrap managed block' "$legacy_home/.bashrc" || fail 'legacy lifecycle uninstall reintroduced the managed block'
pass 'legacy uninstall preserves .bashrc metadata and fallback-to-systemd cleanup cannot reintroduce the shell hook'

implementation_files=(install.sh uninstall.sh .github/workflows/ci.yml)
! grep -En '/mnt/[a-zA-Z]/|/mnt/c' "${implementation_files[@]}" || fail 'Windows host mount path found'
! grep -En -- 'WSL_PROXY_TEST_MODE|ssh-rsa|ssh-dss|HostKeyAlgorithms=.*\+' "${implementation_files[@]}" || fail 'test bypass or weak SSH compatibility found'
! grep -En -- 'BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY' "${implementation_files[@]}" || fail 'embedded private key found'
! grep -En -- '(^|[^[:alnum:]_])pkill([[:space:]]|$)|killall' "${implementation_files[@]}" || fail 'broad process termination found'
! grep -En -- '(ghp_|github_pat_|AKIA[0-9A-Z]{16}|password[[:space:]]*=)' "${implementation_files[@]}" || fail 'probable credential found'
pass 'security scans: no host paths, test bypass, weak SSH, secrets, or broad process kills'
