# Debian / Ubuntu Packaging Guide

This directory contains the packaging files and build automation required to build and distribute `airplane-game` as a native `.deb` package for **Debian, Ubuntu, Linux Mint, Pop!_OS, and other Debian-derived Linux distributions**.

---

## 1. Quick Installation for End Users

### Option 1: Direct Installation of Prebuilt Package
Download and install the native `.deb` package using `apt`:
```bash
# Download from GitHub release:
curl -LO https://github.com/0x07dc/AirplaneGame/releases/download/v0.1.1/airplane-game_0.1.1_amd64.deb

# Install with automatic dependency resolution:
sudo apt install ./airplane-game_0.1.1_amd64.deb
```
*(Or install directly from the local repository build)*:
```bash
sudo apt install ./dist/debian/airplane-game_0.1.1_amd64.deb
```

*(Alternatively, use `dpkg`)*:
```bash
sudo dpkg -i airplane-game_0.1.1_amd64.deb
sudo apt install -f  # Fix any missing dependencies
```

---

## 2. Building the `.deb` Package from Source

To build a fresh Debian package directly from source:
```bash
# 1. Build the Zig binary (ReleaseFast)
zig build -Doptimize=ReleaseFast -Duse-precompiled-shaders=true

# 2. Run the Debian package assembler
python3 dist/debian/build_deb.py
```
This produces `dist/debian/airplane-game_0.1.1_amd64.deb`.

---

## 3. Package Contents & FHS Integration

The generated `.deb` package installs to standard FreeDesktop / FHS directories:
- **Executable**: `/usr/bin/airplane_game`
- **Application Launcher**: `/usr/share/applications/io.github._0x07dc.AirplaneGame.desktop`
- **AppStream Metainfo**: `/usr/share/metainfo/io.github._0x07dc.AirplaneGame.metainfo.xml`
- **Hicolor Icons**:
  - `/usr/share/icons/hicolor/64x64/apps/io.github._0x07dc.AirplaneGame.png`
  - `/usr/share/icons/hicolor/128x128/apps/io.github._0x07dc.AirplaneGame.png`
  - `/usr/share/icons/hicolor/256x256/apps/io.github._0x07dc.AirplaneGame.png`
  - `/usr/share/icons/hicolor/512x512/apps/io.github._0x07dc.AirplaneGame.png`
  - `/usr/share/icons/hicolor/scalable/apps/io.github._0x07dc.AirplaneGame.svg`
- **Documentation & License**: `/usr/share/doc/airplane-game/copyright`

---

## 4. Ubuntu Launchpad PPA Publishing (Optional)

To publish `airplane-game` to an Ubuntu Launchpad Personal Package Archive (PPA) for automatic updates:

1. Create a Launchpad account and set up your PPA (e.g. `ppa:0x07dc/airplane-game`).
2. Add your GPG key to Launchpad.
3. Build the source package (`debuild -S -sa`).
4. Upload to Launchpad:
   ```bash
   dput ppa:0x07dc/airplane-game ../airplane-game_0.1.1-1_source.changes
   ```
5. Users can then install and update with:
   ```bash
   sudo add-apt-repository ppa:0x07dc/airplane-game
   sudo apt update
   sudo apt install airplane-game
   ```
