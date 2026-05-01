# ghostty-deb

A script to build, package, and manage [Ghostty](https://github.com/ghostty-org/ghostty) — a GPU-accelerated terminal emulator — as a Debian `.deb` package on Debian/Ubuntu-based Linux distributions.

The script handles everything: cloning the Ghostty source, detecting and installing the required Zig compiler, building with release optimisations, packaging as a `.deb`, and optionally registering Ghostty as the system default terminal.

## Requirements

- Debian/Ubuntu-based Linux (amd64 or aarch64)
- A normal user account with `sudo` privileges — do not run as root

---

## Quick Start (one-liners)

Run any option directly without cloning the repo first.

**Install** — clone, build, package, and install Ghostty:
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/bradsec/ghostty-deb/main/ghostty-deb.sh) --install
```

**Install unattended** — skip all confirmation prompts:
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/bradsec/ghostty-deb/main/ghostty-deb.sh) --install --yes
```

**Update** — pull latest Ghostty, rebuild, and reinstall (skips rebuild if already up to date):
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/bradsec/ghostty-deb/main/ghostty-deb.sh) --update
```

**Check version** — show installed version and latest stable upstream release:
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/bradsec/ghostty-deb/main/ghostty-deb.sh) --version
```

**Make Ghostty the default terminal**:
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/bradsec/ghostty-deb/main/ghostty-deb.sh) --make-default
```

**Restore the original default terminal**:
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/bradsec/ghostty-deb/main/ghostty-deb.sh) --restore-default
```

**Uninstall**:
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/bradsec/ghostty-deb/main/ghostty-deb.sh) --uninstall
```

---

## Local Usage (clone first)

```bash
git clone https://github.com/bradsec/ghostty-deb.git
cd ghostty-deb
chmod +x ghostty-deb.sh
./ghostty-deb.sh --install
```

All subsequent commands work the same way:

```bash
./ghostty-deb.sh --update
./ghostty-deb.sh --version
./ghostty-deb.sh --make-default
./ghostty-deb.sh --restore-default
./ghostty-deb.sh --uninstall
./ghostty-deb.sh --build-deb
```

Add `--yes` (or `-y`) to any command to skip all confirmation prompts:

```bash
./ghostty-deb.sh --install --yes
./ghostty-deb.sh --update -y
```

---

## Options

| Option | Description |
|---|---|
| `--install` | Clone Ghostty, install Zig, build `.deb`, install it |
| `--update` | Pull latest Ghostty, rebuild `.deb`, reinstall (no-op if already up to date) |
| `--version` | Show installed version and latest stable upstream release |
| `--build-deb` | Build `.deb` only, do not install |
| `--make-default` | Register Ghostty as the default `x-terminal-emulator` |
| `--restore-default` | Restore the previous default terminal |
| `--uninstall` | Remove Ghostty and restore original terminal |
| `--yes`, `-y` | Auto-accept all prompts (for unattended/scripted runs) |
| `--help` | Show usage |

Each option (except `--version`, `--help`, and when `--yes` is set) displays a summary of what it will do and asks for confirmation before proceeding.

---

## What It Does

1. **Installs build dependencies** — GTK4, libadwaita, blueprint-compiler, and related dev libraries via `apt`
2. **Clones Ghostty** — from `https://github.com/ghostty-org/ghostty` into `~/ghostty-install/ghostty`
3. **Detects the required Zig version** — checks `build.zig.zon` first, then falls back to `src/build/zig.zig`
4. **Downloads Zig** — to `/opt/zig/<version>/` if not already present; supports both old and new tarball naming conventions from ziglang.org
5. **Builds Ghostty** — using `zig build -Doptimize=ReleaseFast`
6. **Packages as `.deb`** — staged under `~/ghostty-install/deb-build/` (wiped each build), output to `~/ghostty-install/`
7. **Installs the package** — via `sudo apt install`
8. **Prompts to set as default terminal** — after a successful install or update (skipped with `--yes`)

The built package (`ghostty-deb-local`) installs Ghostty to `/usr/local/bin/ghostty` with runtime dependencies on `libgtk-4-1`, `libadwaita-1-0`, and `libgtk4-layer-shell0`.

---

## Default Terminal Management

`--make-default` registers Ghostty with `update-alternatives` at priority 60 and saves the current default to `~/.config/ghostty-default-terminal` before overwriting it.

`--restore-default` reads that backup file to restore your previous terminal. If no backup exists, it tries common terminals in order: GNOME Terminal, GNOME Console, xterm, Konsole, Xfce Terminal, rxvt. If none are found, it lists the available alternatives and prints the manual restore command.

---

## Version Check

`--version` shows the full output of the installed `ghostty --version` alongside the latest tagged stable release fetched directly from the upstream Git repository. If you built from the `main` branch (tip channel), your version will appear ahead of the latest stable tag — this is expected.

---

## Notes

- Build time depends on your machine. On slower hardware the build can appear to hang for several minutes — particularly during the Zig compilation stage — but it is working. Do not interrupt it.
- Do not run this script with `sudo`. It calls `sudo` internally only where root access is needed (package installation, `/opt/zig`).
- Zig is installed to `/opt/zig/` and persists across builds. If Ghostty requires a different Zig version after an `--update`, the new version is downloaded alongside the old one without removing the previous.
- The build staging directory (`~/ghostty-install/deb-build/`) is wiped at the start of each build; the final `.deb` is written to `~/ghostty-install/`.
- Ghostty source is cloned once to `~/ghostty-install/ghostty` and reused on subsequent `--update` runs.
- `--update` compares the local `HEAD` against the upstream tracking branch after fetching; if they match, the rebuild is skipped entirely.
