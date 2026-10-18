#!/usr/bin/env python3
"""
Automated Debian/Ubuntu (.deb) Package Builder for Airplane Combat Simulator.

Packages the pre-compiled ReleaseFast binary, AppStream metainfo, FreeDesktop launcher,
icons, and licensing into a standard Debian archive conforming to Debian Policy Manual v4.6+.

Output:
  dist/debian/airplane-game_0.1.1_amd64.deb
"""

import os
import sys
import shutil
import hashlib
import tarfile
import tempfile
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DEBIAN_DIR = REPO_ROOT / "dist" / "debian"
PKG_NAME = "airplane-game"
PKG_VER = "0.1.1"
PKG_ARCH = "amd64"
DEB_FILENAME = f"{PKG_NAME}_{PKG_VER}_{PKG_ARCH}.deb"
OUTPUT_DEB = DEBIAN_DIR / DEB_FILENAME

def compute_md5(file_path: Path) -> str:
    hasher = hashlib.md5()
    with open(file_path, "rb") as f:
        while chunk := f.read(65536):
            hasher.update(chunk)
    return hasher.hexdigest()

def ensure_binary():
    bin_path = REPO_ROOT / "zig-out" / "bin" / "airplane_game"
    if not bin_path.exists():
        print(f"[*] Binary not found at {bin_path}. Compiling with Zig ReleaseFast...")
        subprocess.run(
            ["zig", "build", "-Doptimize=ReleaseFast", "-Duse-precompiled-shaders=true"],
            cwd=REPO_ROOT,
            check=True
        )
    return bin_path

def build_deb():
    bin_path = ensure_binary()
    print(f"[*] Packaging {PKG_NAME} v{PKG_VER} ({PKG_ARCH}) into {OUTPUT_DEB.name}...")

    with tempfile.TemporaryDirectory() as tmpdir:
        staging_dir = Path(tmpdir) / "staging"
        control_dir = Path(tmpdir) / "control"
        staging_dir.mkdir(parents=True, exist_ok=True)
        control_dir.mkdir(parents=True, exist_ok=True)

        # 1. Stage binary
        usr_bin = staging_dir / "usr" / "bin"
        usr_bin.mkdir(parents=True, exist_ok=True)
        dest_bin = usr_bin / "airplane_game"
        shutil.copy2(bin_path, dest_bin)
        dest_bin.chmod(0o755)

        # 2. Stage desktop entry & metainfo
        app_dir = staging_dir / "usr" / "share" / "applications"
        app_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(REPO_ROOT / "dist" / "common" / "io.github._0x07dc.AirplaneGame.desktop", app_dir)

        metainfo_dir = staging_dir / "usr" / "share" / "metainfo"
        metainfo_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(REPO_ROOT / "dist" / "common" / "io.github._0x07dc.AirplaneGame.metainfo.xml", metainfo_dir)

        # 3. Stage icons
        for size in ["64x64", "128x128", "256x256", "512x512"]:
            icon_dir = staging_dir / "usr" / "share" / "icons" / "hicolor" / size / "apps"
            icon_dir.mkdir(parents=True, exist_ok=True)
            src_icon = REPO_ROOT / "dist" / "common" / "icons" / size / "io.github._0x07dc.AirplaneGame.png"
            if src_icon.exists():
                shutil.copy2(src_icon, icon_dir)

        scalable_dir = staging_dir / "usr" / "share" / "icons" / "hicolor" / "scalable" / "apps"
        scalable_dir.mkdir(parents=True, exist_ok=True)
        src_svg = REPO_ROOT / "dist" / "common" / "icons" / "scalable" / "io.github._0x07dc.AirplaneGame.svg"
        if src_svg.exists():
            shutil.copy2(src_svg, scalable_dir)

        # 4. Stage documentation and license
        doc_dir = staging_dir / "usr" / "share" / "doc" / PKG_NAME
        doc_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(DEBIAN_DIR / "copyright", doc_dir)
        shutil.copy2(REPO_ROOT / "LICENSE", doc_dir / "copyright.mit")

        # 5. Generate md5sums for control archive
        md5_lines = []
        for p in sorted(staging_dir.rglob("*")):
            if p.is_file():
                rel_path = p.relative_to(staging_dir)
                md5_lines.append(f"{compute_md5(p)}  {rel_path}\n")
        with open(control_dir / "md5sums", "w", encoding="utf-8") as f:
            f.writelines(md5_lines)

        # Copy control file
        shutil.copy2(DEBIAN_DIR / "control", control_dir / "control")

        # 6. Tarball filter to enforce root ownership
        def set_root_ownership(tarinfo):
            tarinfo.uid = 0
            tarinfo.gid = 0
            tarinfo.uname = "root"
            tarinfo.gname = "root"
            return tarinfo

        # 7. Create control.tar.gz
        control_tar = Path(tmpdir) / "control.tar.gz"
        with tarfile.open(control_tar, "w:gz") as tar:
            for item in sorted(control_dir.iterdir()):
                tar.add(item, arcname=f"./{item.name}", filter=set_root_ownership)

        # 8. Create data.tar.gz
        data_tar = Path(tmpdir) / "data.tar.gz"
        with tarfile.open(data_tar, "w:gz") as tar:
            for item in sorted(staging_dir.iterdir()):
                tar.add(item, arcname=f"./{item.name}", filter=set_root_ownership)

        # 9. Create debian-binary
        debian_binary = Path(tmpdir) / "debian-binary"
        debian_binary.write_text("2.0\n", encoding="ascii")

        # 10. Assemble Debian package using ar
        ar_tool = shutil.which("ar")
        if not ar_tool:
            sys.exit("[-] Error: 'ar' utility not found. Please install binutils.")

        DEBIAN_DIR.mkdir(parents=True, exist_ok=True)
        cmd = [ar_tool, "rcs", str(OUTPUT_DEB), "debian-binary", "control.tar.gz", "data.tar.gz"]
        subprocess.run(cmd, cwd=tmpdir, check=True)

    size_kb = OUTPUT_DEB.stat().st_size / 1024
    print(f"[+] Successfully built Debian package: {OUTPUT_DEB} ({size_kb:.1f} KiB)")

if __name__ == "__main__":
    build_deb()
