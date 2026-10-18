# Flathub Packaging and Publishing Guide

This directory contains the Flatpak manifests and setup files to package and publish `AirplaneGame` (`io.github._0x07dc.AirplaneGame`) to [Flathub](https://flathub.org).

---

## 1. Prerequisites for Local Testing

To test building the Flatpak locally on your Linux workstation:

```bash
# Arch Linux
sudo pacman -S flatpak flatpak-builder

# Ubuntu / Debian
sudo apt install flatpak flatpak-builder

# Fedora
sudo dnf install flatpak flatpak-builder
```

Install the Freedesktop 24.08 Platform and SDK runtimes:
```bash
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install flathub org.freedesktop.Platform//24.08 org.freedesktop.Sdk//24.08
```

---

## 2. Testing the Build Locally

You can test the build directly from your local workspace using `io.github._0x07dc.AirplaneGame.local.yaml`:

```bash
cd dist/flatpak

# Build the flatpak into build-dir
flatpak-builder --user --install --force-clean build-dir io.github._0x07dc.AirplaneGame.local.yaml

# Run the installed flatpak
flatpak run io.github._0x07dc.AirplaneGame
```

To run with verbose output or debug flags:
```bash
flatpak run -v io.github._0x07dc.AirplaneGame
```

---

## 3. Flathub Quality & Linting Checks

Flathub runs automated linters on all pull requests. You can verify your manifest and metadata locally:

```bash
# Install flatpak-builder-lint (if available via pipx or cargo)
pipx install flatpak-builder-lint

# Lint the manifest
flatpak-builder-lint manifest io.github._0x07dc.AirplaneGame.yaml

# Lint the AppStream metadata (already validated)
appstreamcli validate --no-net ../common/io.github._0x07dc.AirplaneGame.metainfo.xml
```

---

## 4. Submitting to Flathub

Flathub accepts new applications via Pull Request to the [flathub/flathub](https://github.com/flathub/flathub) repository.

### Step 1: Fork the Flathub Repository
1. Visit `https://github.com/flathub/flathub` and click **Fork**.
2. Clone your fork locally:
   ```bash
   git clone git@github.com:<your-github-username>/flathub.git /tmp/flathub
   cd /tmp/flathub
   ```

### Step 2: Create a New Branch for AirplaneGame
```bash
git checkout -b new-app-io.github._0x07dc.AirplaneGame
```

### Step 3: Add Manifest and Submodule or Sources
Create a new branch with `io.github._0x07dc.AirplaneGame.yaml`:
```bash
cp /path/to/AirplaneGame/dist/flatpak/io.github._0x07dc.AirplaneGame.yaml ./io.github._0x07dc.AirplaneGame.yaml
```

Make sure the `sources` in `io.github._0x07dc.AirplaneGame.yaml` point to the public GitHub repository and your tagged release commit:
```yaml
    sources:
      - type: git
        url: https://github.com/0x07dc/AirplaneGame.git
        tag: v0.1.1
        commit: <COMMIT_HASH>
```

### Step 4: Commit and Push
```bash
git add io.github._0x07dc.AirplaneGame.yaml
git commit -m "Add io.github._0x07dc.AirplaneGame"
git push origin new-app-io.github._0x07dc.AirplaneGame
```

### Step 5: Open a Pull Request
1. Go to `https://github.com/flathub/flathub/pulls` and open a Pull Request from your branch.
2. The Flathub automated CI bots (buildbot) will trigger test builds for `x86_64` and `aarch64`.
3. The Flathub review team will review the sandboxing permissions (`finish-args`).
   - Wayland: Native Wayland client.
   - DRI: Vulkan 1.3 3D renderer.
   - PulseAudio: Low-latency ALSA/Pulse/PipeWire audio.
   - Network: UDP Dogfighting multiplayer networking.
4. Once merged, Flathub will automatically create a dedicated repository:
   `https://github.com/flathub/io.github._0x07dc.AirplaneGame`
   where future version updates and releases are published.

---

## 5. Releasing Updates on Flathub

After your app is on Flathub, publishing updates is simple:
1. Tag a new release in your main repository (`git tag v0.2.0 && git push origin v0.2.0`).
2. Update the `tag` and `commit` in `io.github._0x07dc.AirplaneGame.yaml` inside your `flathub/io.github._0x07dc.AirplaneGame` repository.
3. Add a `<release version="0.2.0" date="...">` entry to `dist/common/io.github._0x07dc.AirplaneGame.metainfo.xml`.
4. Push to Flathub: buildbot will build and distribute the new version to millions of Linux users worldwide!
