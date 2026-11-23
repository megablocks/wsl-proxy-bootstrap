# WSL Proxy Bootstrap

Secure, rerunnable setup for an isolated Google Chrome profile routed through an SSH SOCKS5 tunnel on Ubuntu/Debian under WSL2.

> **Release status:** the final hardening changes are in open PR [#3](https://github.com/megablocks/wsl-proxy-bootstrap/pull/3), intentionally unmerged. The commands below pin the independently reviewed installer commit so they do not fetch the older `main` copy or change unexpectedly.

## One-command install

Run as your normal WSL user — **never with `sudo`**:

```bash
curl -fsSL https://raw.githubusercontent.com/megablocks/wsl-proxy-bootstrap/a8d6274e6a7c7c766540bbf52bc7b239fe987ee8/install.sh | bash
```

The installer itself uses `sudo` only for APT/keyring/repository operations. On first run it creates a new, dedicated Ed25519 key inside the WSL filesystem, prints **only the public key**, and exits with status 20. Before enrollment it installs no launchers, configuration, service, or shell hook, and it does not start or claim a tunnel.

1. Enroll the printed public key in the intended remote account's `authorized_keys`.
2. Rerun only after enrollment:

```bash
curl -fsSL https://raw.githubusercontent.com/megablocks/wsl-proxy-bootstrap/a8d6274e6a7c7c766540bbf52bc7b239fe987ee8/install.sh | WSL_PROXY_ENROLLED=1 bash
```

A supplied key must already exist in the WSL filesystem and still requires explicit enrollment confirmation:

```bash
curl -fsSL https://raw.githubusercontent.com/megablocks/wsl-proxy-bootstrap/a8d6274e6a7c7c766540bbf52bc7b239fe987ee8/install.sh | \
  WSL_PROXY_SSH_HOST=example.net \
  WSL_PROXY_SSH_USER=proxy-user \
  WSL_PROXY_KEY_PATH="$HOME/.ssh/proxy_ed25519" \
  WSL_PROXY_ENROLLED=1 bash
```

Do not reuse or download shared private keys. If any private key has been distributed in a ZIP or other bundle, treat it as compromised, revoke it, and generate a dedicated replacement.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `WSL_PROXY_SSH_HOST` | `khalbali.com` | SSH server hostname or address |
| `WSL_PROXY_SSH_USER` | `root` | Remote SSH account |
| `WSL_PROXY_KEY_PATH` | `$HOME/.ssh/wsl-proxy_ed25519` | Absolute private-key path inside WSL |
| `WSL_PROXY_SSH_PORT` | `22` | SSH port |
| `WSL_PROXY_HOST_FINGERPRINT` | empty | Optional pinned OpenSSH `SHA256:...` host-key fingerprint |
| `WSL_PROXY_ENROLLED` | `0` | Must be `1` after public-key enrollment |

SSH always uses the tool-specific `~/.local/share/wsl-proxy/known_hosts` and disables the global/user default host-key files; it never changes `~/.ssh/known_hosts`. Before SSH can append a first-seen key or the pinned-key flow can replace the managed file, the helper creates and verifies a timestamped pre-edit backup. Without a pinned fingerprint, `StrictHostKeyChecking=accept-new` trusts first use and rejects later changes. With a fingerprint, the scanned key must match before it is atomically installed in the managed file and SSH starts. Obtain fingerprints over an independent trusted channel. The bootstrap does not enable legacy `ssh-rsa` or `ssh-dss` algorithms.

## Commands

Ensure `$HOME/.local/bin` is in `PATH`, then use:

- `proxy-on` — start the Linux-side SSH tunnel, verify the owned SSH PID/start identity and command, confirm that PID owns `127.0.0.1:1080`, and complete a SOCKS5 handshake.
- `proxy-off` — stop only a process whose recorded PID, start identity, per-start token, owner, and SSH command all match.
- `proxy-status` — report only enrollment-gated, process-owned SOCKS5 readiness; unrelated listeners are unsafe, not ready.
- `proxy-chrome [URL]` — start the tunnel, then launch Chrome with an isolated profile, SOCKS5 proxy, and resolver rules that prevent local DNS fallback.
- `proxy-copy` — explicitly copy stdin through `clip.exe`, when WSL interop provides it.
- `proxy-paste` — explicitly emit clipboard text through `powershell.exe`, when available.

Clipboard helpers run only when invoked. They do not log clipboard contents. No Windows executable is started in the background, Chrome is never auto-launched, no Scheduled Task is created, and the installer never writes to `/mnt/c` or another Windows host mount.

## Service behavior

When systemd is PID 1 and the user manager works, the installer starts the `systemd --user` service without retries, verifies readiness, and only then enables it. Otherwise it verifies a tracked fallback process before adding one clearly delimited block to `~/.bashrc`. Failed or timed-out starts are stopped, disabled where applicable, and leave no fallback PID record or retry policy. Reruns replace the shell block rather than duplicating it.

Before each install lifecycle's first managed overwrite, the installer records every collision and copies its original into a validated deterministic manifest under `~/.local/share/wsl-proxy/originals-v1/`. In addition, every actual edit of an existing managed file first creates and verifies a timestamped pre-edit backup under `~/.local/share/wsl-proxy/backups/pre-edit/`. A fallback-shell lifecycle captures the exact pre-edit `~/.bashrc` separately, stages and syntax-checks the replacement in the same directory, and commits it with an atomic rename. Idempotent reruns neither duplicate the block nor create backups when no content changes.

Uninstall marks the lifecycle complete and restores collided files plus the exact pre-install `.bashrc` when that lifecycle edited it. A reinstall archives the completed lifecycle and captures fresh originals, so intervening user files are not lost. Timestamped uninstall backups are separate. Keys, the isolated Chrome profile, logs, manifests, and all backup data remain under the user's WSL home.

## Uninstall

From a clone of the repository:

```bash
./uninstall.sh
```

Uninstall disables the managed service, stops only a fully validated recorded tunnel process, and atomically restores every collided file from the install-time manifest. If the lifecycle changed `.bashrc`, uninstall restores its exact pre-install bytes (or removes it if it was originally absent), while first preserving the current file in a timestamped uninstall backup. Files that were originally absent are removed. Keys, browser data, logs, manifests, pre-edit backups, and uninstall backups remain. Packages and the Google repository are unchanged.

## Security model

- Refuses root execution and unsupported non-WSL/non-Debian systems.
- Supports amd64 only, matching Google's Chrome Linux repository.
- Installs Google's signing key into a dedicated APT keyring and uses `signed-by=`.
- Binds SOCKS5 only to loopback and uses a canonical root-owned, non-writable SSH executable with batch mode, identity isolation, keepalives, and forward-failure detection.
- Uses a dedicated Ed25519 key and never downloads secret keys.
- Requires explicit enrollment confirmation in both managed configuration and a matching enrollment gate before any tunnel activation.
- Resolves every mutation path, rejects symlink traversal, and fails closed on Windows-backed filesystem types (including alternate mountpoints) before mutation.
- Verifies timestamped backups before each edit of an existing managed file; `.bashrc` updates use validated same-directory staging and atomic rename, with exact lifecycle restoration on uninstall.
- Makes no operational claim until `proxy-on` validates process owner/identity/start token, listener ownership, and a real SOCKS5 handshake.
- Uses a separate Chrome profile and forces name resolution through the SOCKS path.
- Does not modify Windows-host files, create Windows automation, or broadly terminate processes.

This protects local setup and reduces accidental leakage; it does not make an untrusted SSH server, browser extension, or destination trustworthy.

## Development and tests

```bash
sudo apt-get install shellcheck acl
./tests/test.sh
```

The suite uses no WSL dependency, network, or live SSH server. It checks syntax and ShellCheck; root refusal under root or non-root CI; pre-enrollment file gating; symlink and simulated alternate-mount escapes; verified timestamped backups for existing managed files and successful host-key replacement; atomic `.bashrc` replacement, metadata preservation, and injected rename failure; exact `.bashrc` restoration; current and legacy lifecycle behavior; managed-block idempotency; enrollment-gate enforcement; unrelated SOCKS listeners; stale PIDs; fallback/systemd failure cleanup; fingerprint mismatch; isolated known-hosts behavior; manifest restoration; clipboard behavior; and static security scans.

`--internal-test-dry-run` is an explicit test-only seam: it prints a warning, forces package/network/service/tunnel startup and shell hooks off, and marks generated helpers permanently inert unless a test deliberately edits its disposable config. `--internal-test-shell-hook` and `--internal-test-shell-cleanup` keep those same inert startup guarantees but exercise fallback shell-hook installation and cleanup inside the supplied disposable `HOME`. Persistent writes stay inside that test `HOME`; temporary paths are separately mount-validated. `--internal-test-root-refusal` performs only a simulated uid-0 refusal. None of these options can silently relax a production installation.

## License

MIT
