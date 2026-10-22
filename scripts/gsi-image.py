#!/usr/bin/env python3
"""Makes an emulator system-image dir that boots a GSI on Google's goldfish kernel/vendor, without super.

Usage: scripts/gsi-image.py [--secure] <google sysdir> <gsi system.img or .img.xz (ext4/erofs)> <out sysdir> [display name]
Out dir gets Google's files (APFS clones) plus:
  system.img  plain GPT: gsi_system, gsi_vendor, gsi_system_dlkm (the last two copied out of Google's super)
  ramdisk.img Google's ramdisk + an appended cpio whose fstab.ranchu mounts those by-name instead of `logical`.
vendor's own /etc/fstab.ranchu (what vold reads after switch_root) gets the same rewrite, and vendor
declares android.software.freeform_window_management (pair with a freeform AVD: display.settings.xml=freeform).
Every build.prop gets a stock Pixel 9's build and product props, and system an init rc installing the host's adb key.
--secure turns on TrebleDroid's securize (no su, ro.adb.secure=1). Both need an ext4 GSI.
source.properties gets the out dir's tag (its parent dir name) and the display name, so AVDs label it.
Needs lz4 and e2fsprogs (brew install lz4 e2fsprogs).
"""
import atexit, lzma, os, re, shutil, struct, subprocess, sys, tempfile, uuid, zlib

SECTOR, ALIGN = 512, 1 << 20
LINUX_FS = uuid.UUID("0fc63daf-8483-4772-8e79-3d69d8477de4")
PARTS = ["system", "vendor", "system_dlkm"]
# First-stage init matches fstab basenames against GPT labels; prefixed so vendor.img's own "vendor" label can't win.
LABEL = "gsi_"
FREEFORM = """<?xml version="1.0" encoding="utf-8"?>
<permissions>
    <feature name="android.software.freeform_window_management" />
</permissions>
"""
E2FS = "/opt/homebrew/opt/e2fsprogs/sbin"  # keg-only in Homebrew
# A Pixel 9 (tokay) September 2026 build, from Google's binary transparency log; that's the goldfish vendor's patch level.
PIXEL_ID, PIXEL_INC = "CP3A.260905.009", "16091614"
PIXEL = [
    (r"ro\.(?:\w+\.)?build\.fingerprint", f"google/tokay/tokay:17/{PIXEL_ID}/{PIXEL_INC}:user/release-keys"),
    (r"ro\.(?:\w+\.)?build\.(?:display\.)?id", PIXEL_ID),
    (r"ro\.(?:\w+\.)?build\.version\.incremental", PIXEL_INC),
    (r"ro\.(?:\w+\.)?build\.type", "user"),
    (r"ro\.(?:\w+\.)?build\.tags", "release-keys"),
    (r"ro\.build\.flavor", "tokay-user"),
    (r"ro\.build\.description", f"tokay-user 17 {PIXEL_ID} {PIXEL_INC} release-keys"),
    (r"ro\.build\.product", "tokay"),
    (r"ro\.product\.(?:\w+\.)?(?:name|device)", "tokay"),
    (r"ro\.product\.(?:\w+\.)?brand", "google"),
    (r"ro\.product\.(?:\w+\.)?manufacturer", "Google"),
    (r"ro\.product\.(?:\w+\.)?model", "Pixel 9"),
    (r"ro\.product\.board", "tokay"),
]
# The Vulkan HAL a Pixel 9 loads; goldfish's ranchu driver is linked under this name and the bootconfig points at it.
VULKAN = "mali"
# Google's system_ext installs the host's adb key (init.adb-setup.ranchu.sh); a GSI replaces system_ext, and
# without the key a secure adbd leaves Mini's adb unauthorized.
ADB_RC = """on post-fs-data && property:ro.boot.qemu.adb.pubkey=*
    write /data/misc/adb/adb_keys ${ro.boot.qemu.adb.pubkey}
    chown system shell /data/misc/adb/adb_keys
    chmod 0640 /data/misc/adb/adb_keys
"""
# shortcut: renamed only once every HAL has looked its module up by ro.hardware (init imports, libhardware); one
# restarted later looks for a tokay module and fails. Upgrade: give the ranchu rc, fstabs and HALs a second name.
LATE_RC = """
on property:sys.boot_completed=1
    exec u:r:phhsu_daemon:s0 root -- /system/bin/resetprop_phh ro.hardware tokay
    exec u:r:phhsu_daemon:s0 root -- /system/bin/resetprop_phh ro.boot.hardware tokay
"""


def gpt_read(path):
    """{name: (byte offset, byte size)} of a GPT disk image."""
    with open(path, "rb") as f:
        f.seek(SECTOR)
        hdr = f.read(92)
        assert hdr[:8] == b"EFI PART", f"{path}: no GPT"
        lba, n, size = struct.unpack("<QII", hdr[72:88])
        f.seek(lba * SECTOR)
        out = {}
        for _ in range(n):
            e = f.read(size)
            if e[:16] == bytes(16):
                continue
            first, last = struct.unpack("<QQ", e[32:48])
            out[e[56:128].decode("utf-16le").rstrip("\0")] = (first * SECTOR, (last - first + 1) * SECTOR)
        return out


def super_extents(path, base):
    """{logical partition: [(byte offset in file, byte size)]} from the LP metadata of a super at `base`."""
    with open(path, "rb") as f:
        f.seek(base + 4096)
        geo = f.read(52)
        assert struct.unpack("<I", geo[:4])[0] == 0x616C4467, "no LP geometry"
        f.seek(base + 3 * 4096)  # reserved 4K, geometry + backup, then primary metadata slot 0
        hdr = f.read(256)
        assert struct.unpack("<I", hdr[:4])[0] == 0x414C5030, "no LP metadata"
        header_size, = struct.unpack("<I", hdr[8:12])
        (p_off, p_n, p_sz), (x_off, x_n, x_sz) = struct.unpack("<3I", hdr[80:92]), struct.unpack("<3I", hdr[92:104])
        f.seek(base + 3 * 4096 + header_size)
        tables = f.read(struct.unpack("<I", hdr[44:48])[0])
    extents = [struct.unpack("<QIQI", tables[x_off + i * x_sz:][:24]) for i in range(x_n)]
    out = {}
    for i in range(p_n):
        e = tables[p_off + i * p_sz:][:p_sz]
        name = e[:36].rstrip(b"\0").decode()
        first, count = struct.unpack("<II", e[40:48])
        segs = extents[first:first + count]
        assert all(t == 0 for _, t, _, _ in segs), f"{name}: non-linear extent"
        out[name] = [(base + data * SECTOR, n * SECTOR) for n, _, data, _ in segs]
    return out


def copy_range(src, segs, dst, at):
    with open(src, "rb") as s:
        dst.seek(at)
        for off, size in segs:
            s.seek(off)
            while size:
                chunk = s.read(min(size, 8 << 20))
                dst.write(chunk)
                size -= len(chunk)


def gpt_write(path, parts):
    """parts: [(name, [(src, segs)], size)]. Writes a GPT disk with each partition 1 MiB aligned."""
    entries, at = b"", ALIGN
    layout = []
    for name, _, size in parts:
        size = -(-size // ALIGN) * ALIGN
        layout.append(at)
        entries += LINUX_FS.bytes_le + uuid.uuid4().bytes_le + struct.pack("<QQQ", at // SECTOR, (at + size) // SECTOR - 1, 0) \
            + name.encode("utf-16le").ljust(72, b"\0")
        at += size
    entries = entries.ljust(128 * 128, b"\0")
    total = at + ALIGN
    last = total // SECTOR - 1
    disk = uuid.uuid4().bytes_le

    def header(cur, alt, table):
        h = b"EFI PART" + struct.pack("<IIII", 0x10000, 92, 0, 0) + struct.pack("<QQQQ", cur, alt, 34, last - 33) \
            + disk + struct.pack("<QIII", table, 128, 128, zlib.crc32(entries))
        return h[:16] + struct.pack("<I", zlib.crc32(h)) + h[20:]

    with open(path, "wb") as f:
        f.truncate(total)
        mbr = bytearray(SECTOR)
        mbr[446:462] = struct.pack("<BBBBBBBBII", 0, 0, 2, 0, 0xEE, 0xFF, 0xFF, 0xFF, 1, min(last, 0xFFFFFFFF))
        mbr[510:] = b"\x55\xaa"
        f.write(mbr + header(1, last, 2).ljust(SECTOR, b"\0") + entries)
        f.seek((last - 32) * SECTOR)
        f.write(entries + header(last, 1, last - 32).ljust(SECTOR, b"\0"))
        for (_, sources, _), off in zip(parts, layout):
            pos = off
            for src, segs in sources:
                copy_range(src, segs, f, pos)
                pos += sum(n for _, n in segs)


def cpio_file(name, data, mode=0o100644):
    """One newc entry plus the trailer."""
    def entry(n, d, m):
        n = n.encode() + b"\0"
        h = b"070701" + b"".join(b"%08x" % v for v in (0, m, 0, 0, 1, 0, len(d), 0, 0, 0, 0, len(n), 0)) + n
        return h.ljust(-(-len(h) // 4) * 4, b"\0") + d.ljust(-(-len(d) // 4) * 4, b"\0")
    return entry(name, data, mode) + entry("TRAILER!!!", b"", 0)


def patch_fstab(text):
    out = []
    for line in text.splitlines():
        f = line.split()
        if f and not line.startswith("#") and "logical" in f[-1]:
            if f[0] not in PARTS:
                continue  # product/system_ext: a GSI carries its own inside system
            f[0] = f"/dev/block/by-name/{LABEL}{f[0]}"  # by-name links exist for androidboot.boot_devices = this disk
            f[-1] = ",".join(x for x in f[-1].split(",") if x != "logical")
            line = " ".join(f)
        out.append(line)
    return "\n".join(out) + "\n"


def e2(tool, *args, ok=(0,), input=None):
    r = subprocess.run([shutil.which(tool) or os.path.join(E2FS, tool), *args], input=input, capture_output=True, text=True)
    assert r.returncode in ok, f"{tool} {args}: {r.returncode} {r.stderr}"
    return r.stdout


def ext4_edit(img, path, edit, like=None):
    """Rewrites (or creates) one file in an ext4 image through edit(text), keeping the owner, mode and
    SELinux label of the file itself, or of `like` for a new file."""
    old = e2("debugfs", "-R", f"cat {path}", img)
    new = edit(old)
    if new == old:
        return
    like = like or path
    st = e2("debugfs", "-R", f"stat {like}", img)
    mode = re.search(r"Mode:\s+(\d+)", st).group(1)
    uid, gid = re.search(r"User:\s+(\d+)\s+Group:\s+(\d+)", st).groups()
    # debugfs splits its commands at spaces and still exits 0, so these host paths must have none:
    # not under the output dir, which is in "Application Support".
    tmp = tempfile.mkdtemp()
    assert " " not in tmp, tmp
    text, label = os.path.join(tmp, "text"), os.path.join(tmp, "label")
    with open(text, "w") as f:
        f.write(new)
    e2("debugfs", "-R", f"ea_get -f {label} {like} security.selinux", img)
    cmds = [f"rm {path}", f"write {text} {path}", f"sif {path} uid {uid}", f"sif {path} gid {gid}",
            f"sif {path} mode 0100{mode}", f"ea_set -f {label} {path} security.selinux"]
    e2("debugfs", "-w", "-f", "-", img, input="\n".join(cmds) + "\n")
    e2("e2fsck", "-fn", img)
    shutil.rmtree(tmp)
    assert e2("debugfs", "-R", f"cat {path}", img) == new


def fix_init_rc(text):
    """shortcut: this GSI build (LineageOS-24.0-UNOFFICIAL-20261008) dropped two `on late-fs && ro.kernel.version`
    sections into the middle of `on post-fs`, stranding `mkdir /metadata/vold` and the rest of post-fs under the
    4.14 trigger (vold then can't set up /data). Re-open post-fs after them; drop once the GSI is fixed."""
    bad = "on late-fs && property:ro.kernel.version=4.14\n    setprop bootreceiver.enable 0\n"
    i = text.find(bad)
    if i < 0 or text[i + len(bad):].startswith(("on ", "\n")):
        return text
    return text[:i + len(bad)] + "on post-fs\n" + text[i + len(bad):]


def spoof(text):
    """A build.prop with a stock Pixel 9's build and product props in place of the ones it has."""
    for key, value in PIXEL:
        text = re.sub(rf"^({key})=.*$", lambda m: f"{m[1]}={value}", text, flags=re.M)
    return re.sub(r"^ro\.kernel\.qemu=.*\n", "", text, flags=re.M)  # nothing on goldfish reads it any more


def main(base, gsi, out, display="GSI", secure=False):
    assert spoof("ro.product.cpu.abi=a\nro.product.vendor.model=b\nro.kernel.qemu=1\nro.system.build.type=userdebug\n") \
        == "ro.product.cpu.abi=a\nro.product.vendor.model=Pixel 9\nro.system.build.type=user\n"
    os.makedirs(out, exist_ok=True)
    for name in os.listdir(base):
        if name not in ("system.img", "ramdisk.img"):
            subprocess.run(["cp", "-cR", os.path.join(base, name), out], check=True)

    sysimg = os.path.join(base, "system.img")
    sup = gpt_read(sysimg)["super"][0]
    lp = super_extents(sysimg, sup)
    tmp = tempfile.mkdtemp(dir=out)
    atexit.register(shutil.rmtree, tmp, ignore_errors=True)  # a failed run leaves no half-built images behind
    vendor = os.path.join(tmp, "vendor.ext4")
    with open(vendor, "wb") as f:
        copy_range(sysimg, lp["vendor"], f, 0)
        f.truncate(f.tell() + (32 << 20))
    # Google's vendor is deduplicated (shared_blocks) and full; grow it, then un-share so it's writable.
    e2("resize2fs", "-f", vendor)
    e2("e2fsck", "-fy", "-E", "unshare_blocks", vendor, ok=(0, 1))
    ext4_edit(vendor, "/etc/fstab.ranchu", patch_fstab)  # what vold reads after switch_root
    # Declares freeform support up front, so a freeform AVD profile gets desktop windows without the dev option.
    ext4_edit(vendor, "/etc/permissions/android.software.freeform_window_management.xml", lambda _: FREEFORM,
              like="/etc/fstab.ranchu")
    # Vendor too: TrebleDroid's securize copies the vendor's identity over the system's.
    for path in ("/build.prop", "/odm/etc/build.prop"):
        ext4_edit(vendor, path, spoof)
    # A hard link: same inode, so the same label and mode, and no space. debugfs's ln leaves the link count to us.
    hal = "/lib64/hw/vulkan.ranchu.so"
    inode = re.search(r"Inode:\s+(\d+)", e2("debugfs", "-R", f"stat {hal}", vendor)).group(1)
    e2("debugfs", "-w", "-f", "-", vendor, input=f"ln {hal} /lib64/hw/vulkan.{VULKAN}.so\nsif <{inode}> links_count 2\n")
    e2("e2fsck", "-fn", vendor)
    system = os.path.join(tmp, "system.img")
    if gsi.endswith(".xz"):
        with lzma.open(gsi) as src, open(system, "wb") as dst:
            shutil.copyfileobj(src, dst, 1 << 20)
    else:
        subprocess.run(["cp", "-c", gsi, system], check=True)  # APFS clone; the GSI itself stays untouched
    with open(system, "rb") as f:
        head = f.read(1024 + 0x78)
    is_ext4 = head[1080:1082] == b"\x53\xef"
    # shortcut: erofs GSIs can't be edited here, so they get no init.rc fix, Pixel props or securize; unpack/repack
    # with mkfs.erofs if one needs them.
    rc = "/system/etc/init/hw/init.rc"
    if is_ext4 and e2("debugfs", "-R", f"stat {rc}", system).strip():
        ext4_edit(system, rc, fix_init_rc)
        for path in ("/system/build.prop", "/system/system_ext/etc/build.prop", "/system/product/etc/build.prop"):
            ext4_edit(system, path, spoof)
        # TrebleDroid's resetprop_phh, run as its own init domain, can rewrite ro.* props after boot.
        late = LATE_RC if e2("debugfs", "-R", "stat /system/bin/resetprop_phh", system).strip() else ""
        ext4_edit(system, "/system/etc/init/mini-adb.rc", lambda _: ADB_RC + late, like=rc)
        # TrebleDroid's rw-system.sh then hides its su, sets ro.adb.secure=1 and reports a locked, verified boot.
        if secure and e2("debugfs", "-R", "stat /system/phh", system).strip():
            ext4_edit(system, "/system/phh/secure", lambda _: "1\n", like=rc)
        elif secure:
            print("not a TrebleDroid GSI (no /system/phh); securize skipped")
    whole = lambda path: [(path, [(0, os.path.getsize(path))])]
    sources = {"system": whole(system), "vendor": whole(vendor), "system_dlkm": [(sysimg, lp["system_dlkm"])]}
    gpt_write(os.path.join(out, "system.img"), [(LABEL + p, sources[p], sum(n for _, segs in sources[p] for _, n in segs)) for p in PARTS])

    shutil.rmtree(tmp)

    rd = subprocess.run(["lz4", "-dc", os.path.join(base, "ramdisk.img")], check=True, capture_output=True).stdout
    key = b"first_stage_ramdisk/fstab.ranchu\0"
    i = rd.rindex(key)
    hdr = rd[i - 110:i]
    size, namesize = int(hdr[54:62], 16), int(hdr[94:102], 16)
    data_at = -(-(i + namesize) // 4) * 4
    fstab = patch_fstab(rd[data_at:data_at + size].decode())
    # The kernel unpacks concatenated cpios in order, so this later fstab replaces the original.
    extra = cpio_file("first_stage_ramdisk/fstab.ranchu", fstab.encode())
    rd += extra.ljust(-(-len(extra) // 512) * 512, b"\0")
    subprocess.run(["lz4", "-l", "-12", "-f", "-", os.path.join(out, "ramdisk.img")], input=rd, check=True, capture_output=True)

    # Self-check: partitions landed where the fstab points, and the GSI's filesystem header survived the copy.
    got = gpt_read(os.path.join(out, "system.img"))
    assert list(got) == [LABEL + p for p in PARTS], got
    with open(os.path.join(out, "system.img"), "rb") as f:
        f.seek(got[LABEL + "system"][0])
        assert f.read(1024 + 0x78)[1024 + 0x68:] == head[1024 + 0x68:]  # ext4 UUID / erofs-agnostic bytes

    props = os.path.join(out, "source.properties")
    with open(props) as f:
        text = f.read()
    for key, value in [("Pkg.Desc", f"{display} on goldfish vendor"), ("SystemImage.TagId", os.path.basename(os.path.dirname(os.path.abspath(out)))),
                       ("SystemImage.TagDisplay", display)]:
        text = re.sub(rf"^{re.escape(key)}=.*$", lambda _: f"{key}={value}", text, flags=re.M)
    with open(props, "w") as f:
        f.write(text)
    with open(os.path.join(out, "VerifiedBootParams.textproto"), "a") as f:  # Qemu.bootconfig lets these override its own
        f.write(f'param: "androidboot.hardware.vulkan={VULKAN}"\n')
    print(fstab)
    print(f"wrote {out}")


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--secure"]
    if len(args) not in (3, 4):
        sys.exit(__doc__)
    main(*args, secure="--secure" in sys.argv)
