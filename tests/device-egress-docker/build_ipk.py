"""Use Make's own expansion for package metadata, scripts and install recipe."""
import os
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import sys


def root_owner(info):
    info.uid = info.gid = 0
    info.uname = info.gname = "root"
    return info

source = Path(os.environ["PACKAGE_SOURCE"]).resolve()
output = Path(os.environ["PACKAGE_OUTPUT"]).resolve()
output.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="openclash-ipk-") as temporary:
    work = Path(temporary)
    build, data, control = (work / name for name in ("build", "data", "control"))
    for directory in (build, data, control):
        directory.mkdir()
    compiler = shutil.which("po2lmo")
    if not compiler:
        # The package ships po2lmo's C sources; host compilation needs no SDK.
        compiler = str(work / "po2lmo")
        subprocess.run([os.environ.get("CC", "cc"), "-o", compiler,
                        str(source / "tools/po2lmo/src/po2lmo.c"),
                        str(source / "tools/po2lmo/src/template_lmo.c")], check=True)
    shutil.copy(compiler, work / "po2lmo-host")
    (work / "bin").mkdir()
    (work / "bin/po2lmo").symlink_to(work / "po2lmo-host")
    if sys.platform == "darwin":
        # Build/Prepare uses GNU sed's argument-less -i spelling.
        sed = work / "bin/sed"
        sed.write_text('#!/bin/sh\nif [ "$1" = -i ]; then shift; exec /usr/bin/sed -i "" "$@"; fi\nexec /usr/bin/sed "$@"\n')
        sed.chmod(0o755)
    # Drop SDK includes/BuildPackage evaluation, retaining the actual definitions.
    text = "\n".join(line for line in (source / "Makefile").read_text().splitlines()
                     if not line.startswith("include ") and not line.startswith("$(eval $(call BuildPackage,"))
    text += "\n" + f"""
CURDIR := {source}
PKG_BUILD_DIR := {build}
CP := cp -fpR
INSTALL_DIR := mkdir -p
INSTALL_DATA := cp -fp
LN := ln -sf
$(eval $(Package/$(PKG_NAME)))
export IPK_NAME = $(PKG_NAME)
export IPK_VERSION = $(PKG_VERSION)
export IPK_DEPENDS = $(subst +,,$(DEPENDS))
export IPK_ARCH = $(PKGARCH)
export IPK_DESCRIPTION = $(Package/$(PKG_NAME)/description)
export IPK_MAINTAINER = $(MAINTAINER)
.PHONY: assemble
assemble:
	$(Build/Prepare)
	$(call Package/$(PKG_NAME)/install,{data})
	@python3 -c 'import os,json; open("{work}/metadata.json","w").write(json.dumps({{k:v for k,v in os.environ.items() if k.startswith("IPK_")}}))'
"""
    for script in ("conffiles", "preinst", "postinst", "prerm", "postrm"):
        text += f"\nexport IPK_{script} = $(Package/$(PKG_NAME)/{script})\n"
    makefile = work / "package.mk"
    makefile.write_text(text)
    env = dict(os.environ, PATH=str(work / "bin") + os.pathsep + os.environ["PATH"])
    subprocess.run([os.environ["PACKAGE_MAKE"], "-f", str(makefile), "assemble"],
                   cwd=source, env=env, check=True, stdout=subprocess.DEVNULL)
    metadata = json.loads((work / "metadata.json").read_text())
    for script in ("conffiles", "preinst", "postinst", "prerm", "postrm"):
        if metadata["IPK_" + script]:
            (control / script).write_text(metadata["IPK_" + script] + "\n")
    # OpenWrt default lifecycle wrappers execute UCI defaults and init scripts.
    for script in ("postinst", "prerm"):
        path = control / script
        if path.exists():
            path.rename(control / (script + "-pkg"))
        path.write_text('#!/bin/sh\n. "${IPKG_INSTROOT}/lib/functions.sh"\n'
                        f'default_{script} "$0" "$@"\n')
    dependencies = metadata["IPK_DEPENDS"].split()
    size = sum(path.stat().st_size for path in data.rglob("*") if path.is_file())
    (control / "control").write_text(f'Package: {metadata["IPK_NAME"]}\nVersion: {metadata["IPK_VERSION"]}\nArchitecture: {metadata["IPK_ARCH"]}\n'
        + "Depends: " + ", ".join(["libc"] + dependencies) + "\n"
        + f'Installed-Size: {size}\nSection: luci\nMaintainer: {metadata["IPK_MAINTAINER"]}\n'
        + "Description: " + " ".join(metadata["IPK_DESCRIPTION"].split()) + "\n")
    for path in control.iterdir():
        if path.name not in ("control", "conffiles"):
            path.chmod(0o755)
    for name, directory in (("control.tar.gz", control), ("data.tar.gz", data)):
        with tarfile.open(work / name, "w:gz", format=tarfile.GNU_FORMAT) as archive:
            for path in sorted(directory.iterdir()):
                archive.add(path, arcname="./" + path.name, filter=root_owner)
    (work / "debian-binary").write_text("2.0\n")
    # opkg accepts OpenWrt's gzip tar container as well as Debian ar containers.
    with tarfile.open(output, "w:gz", format=tarfile.GNU_FORMAT) as archive:
        for name in ("debian-binary", "control.tar.gz", "data.tar.gz"):
            archive.add(work / name, arcname="./" + name)
print(output)
