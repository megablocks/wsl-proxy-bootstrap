# WSL Proxy Bootstrap

Secure, rerunnable setup for an isolated Google Chrome profile routed through an SSH SOCKS5 tunnel on Ubuntu/Debian under WSL2.

> **Release status:** development happens through pull requests into `dev`. The one-command installer below is the expected stable public path and becomes usable after this change is reviewed and promoted to `main`. Until then, clone the PR branch and inspect/run `install.sh` locally.

## One-command install

Run as your normal WSL user — **never with `sudo`**:

```bash
curl -fsSL https://raw.githubusercontent.com/megablocks/wsl-proxy-bootstrap/main/install.sh | bash
```

The installer itself uses `sudo` only for APT/keyring/repository operations. On first run it creates a new, dedicated Ed25519 key inside the WSL filesystem, prints **only the public key**, and exits with status 20. It does not start a tunnel or claim that the proxy works.

1. Enroll the printed public key in the intended remote account's `authorized_keys`.
2. Rerun only after enrollment:

```bash
curl -fsSL https://raw.githubusercontent.com/megablocks/wsl-proxy-bootstrap/main/install.sh | WSL_PROXY_ENROLLED=1 bash
```

A supplied key must already exist in the WSL filesystem and still requires explicit enrollment confirmation:

```bash
curl -fsSL https://raw.githubusercontent.com/megablocks/wsl-proxy-bootstrap/main/install.sh | \
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

Without a pinned fingerprint, SSH uses `StrictHostKeyChecking=accept-new`: first use is trusted and later changes are rejected. For stronger verification, obtain the server fingerprint over an independent trusted channel and set `WSL_PROXY_HOST_FINGERPRINT`. The bootstrap does not enable legacy `ssh-rsa` or `ssh-dss` algorithms.

## Commands

Ensure `$HOME/.local/bin` is in `PATH`, then use:

- `proxy-on` — start the Linux-side SSH tunnel and wait for `127.0.0.1:1080`.
- `proxy-off` — stop only the managed service/process.
- `proxy-status` — report listener/service state.
- `proxy-chrome [URL]` — start the tunnel, then launch Chrome with an isolated profile, SOCKS5 proxy, and resolver rules that prevent local DNS fallback.
- `proxy-copy` — explicitly copy stdin through `clip.exe`, when WSL interop provides it.
- `proxy-paste` — explicitly emit clipboard text through `powershell.exe`, when available.

Clipboard helpers run only when invoked. They do not log clipboard contents. No Windows executable is started in the background, Chrome is never auto-launched, no Scheduled Task is created, and the installer never writes to `/mnt/c` or another Windows host mount.

## Service behavior

When systemd is PID 1 and the user manager works, the installer enables a `systemd --user` service. Otherwise it adds one clearly delimited managed block to `~/.bashrc`; interactive shells use that block only to ensure the Linux-side tunnel exists. Reruns replace that block rather than duplicating it.

Before changing `~/.bashrc`, SSH proxy configuration, launchers, or the user service, the installer saves changed originals under `~/.local/share/wsl-proxy/backups/`. The isolated Chrome profile, logs, and dedicated key remain under the user's WSL home.

## Uninstall

From a clone of the repository:

```bash
./uninstall.sh
```

Uninstall disables the managed service, stops only the recorded tunnel process, removes only the managed block/files, and saves removed files in a timestamped backup. It intentionally preserves keys, browser data, logs, and all backups. It does not remove system packages or the Google repository.

## Security model

- Refuses root execution and unsupported non-WSL/non-Debian systems.
- Supports amd64 only, matching Google's Chrome Linux repository.
- Installs Google's signing key into a dedicated APT keyring and uses `signed-by=`.
- Binds SOCKS5 only to loopback and uses SSH batch mode, identity isolation, keepalives, and forward-failure detection.
- Uses a dedicated Ed25519 key and never downloads secret keys.
- Requires explicit enrollment confirmation before any tunnel activation.
- Makes no operational claim until `proxy-on` observes the local listener after an SSH start.
- Uses a separate Chrome profile and forces name resolution through the SOCKS path.
- Does not modify Windows-host files, create Windows automation, or broadly terminate processes.

This protects local setup and reduces accidental leakage; it does not make an untrusted SSH server, browser extension, or destination trustworthy.

## Development and tests

```bash
sudo apt-get install shellcheck
./tests/test.sh
```

The suite uses no WSL dependency, network, or live SSH server. It checks syntax, ShellCheck, root refusal, fake-`HOME` installation, enrollment stopping, idempotent managed blocks, reversible uninstall, clipboard behavior, and scans for host-mount writes, weak SSH algorithms, embedded private keys, probable credentials, and broad process termination.

## License

MIT
