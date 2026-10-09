#!/usr/bin/env python3
"""Install the working collect_fs setting on fsn1 (2026-10-08).

Makes Virtualmin's "Filesystems to include in local disk space" field work and
gives it a physical-drive chooser. Three small hooks into Webmin/Virtualmin
files call disk-focus/collect-fs-lib.pl, which holds all the logic.

    install-collect-fs.py check | install | status

Backs up each file to <file>.before-collectfs-<stamp> first, rewrites in
place (keeps owner, mode, ACL, label), refuses unless every anchor matches
exactly once, and is idempotent: a file already carrying the marker is left
alone. Re-run 'install' after a Webmin or Virtualmin update wipes the hooks.
"""
import os
import shutil
import sys
import time

W = "/usr/libexec/webmin"
MARK = "fsn1 collect_fs hook"
LIB_SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "disk-focus", "collect-fs-lib.pl")
LIB_DST = W + "/disk-focus/collect-fs-lib.pl"

EDITS = {
    W + "/virtual-server/config.info": [
        ("collect_fs=Filesystems to include in local disk space,3,All local filesystems,40,,,"
         "Listed filesystems (space separated)\n",
         "collect_fs=Filesystems to include in local disk space,15,collect_fs\n"),
    ],
    W + "/virtual-server/config_info.pl": [
        ("\n1;\n",
         "\n# " + MARK + " (2026-10-08): the collect_fs field, with a physical\n"
         "# drive chooser. All logic is in disk-focus/collect-fs-lib.pl.\n"
         "sub show_collect_fs\n"
         "{\n"
         "my ($value) = @_;\n"
         "my $lib = &module_root_directory(\"disk-focus\").\"/collect-fs-lib.pl\";\n"
         "return &ui_textbox(\"collect_fs\", $value, 40).\" (drive chooser unavailable: $lib missing)\"\n"
         "\tif (!-r $lib || !do $lib);\n"
         "return &collect_fs::show_field($value);\n"
         "}\n"
         "\n"
         "sub parse_collect_fs\n"
         "{\n"
         "my ($value) = @_;\n"
         "my $lib = &module_root_directory(\"disk-focus\").\"/collect-fs-lib.pl\";\n"
         "return $in{'collect_fs'} if (!-r $lib || !do $lib);\n"
         "my $v = eval { &collect_fs::parse_field(\\%in) };\n"
         "&error(\"Filesystems to include in local disk space: $@\") if ($@);\n"
         "return $v;\n"
         "}\n"
         "\n1;\n"),
    ],
    W + "/system-status/system-status-lib.pl": [
        ("\t($info->{'disk_total'}, $info->{'disk_free'},\n"
         "\t $info->{'disk_fs'}, $info->{'disk_used'}) =\n"
         "\t\t&mount::local_disk_space();\n"
         "\t}\n",
         "\t($info->{'disk_total'}, $info->{'disk_free'},\n"
         "\t $info->{'disk_fs'}, $info->{'disk_used'}) =\n"
         "\t\t&mount::local_disk_space();\n"
         "\t# " + MARK + " (2026-10-08): honour Virtualmin's collect_fs\n"
         "\t# setting, which stock code ignores. Logic: disk-focus/collect-fs-lib.pl.\n"
         "\t# Any failure leaves the stock totals in place.\n"
         "\teval {\n"
         "\t\tmy $lib = &module_root_directory(\"disk-focus\").\"/collect-fs-lib.pl\";\n"
         "\t\tif (-r $lib && &foreign_check(\"virtual-server\")) {\n"
         "\t\t\tmy %vconfig = &foreign_config(\"virtual-server\");\n"
         "\t\t\tif ($vconfig{'collect_fs'} && do $lib) {\n"
         "\t\t\t\t&collect_fs::apply($info, $vconfig{'collect_fs'});\n"
         "\t\t\t\t}\n"
         "\t\t\t}\n"
         "\t\t};\n"
         "\t}\n"),
    ],
}


HERE = os.path.dirname(os.path.abspath(__file__))
# Our own module files (not RPM-owned; updates leave them alone). Installed
# from the kit's disk-focus/ folder, each backed up before it is replaced.
DF_FILES = ["index.cgi", "disk-focus-lib.pl"]
# Hidden module that catches the dashboard disk dial (see disk-usage/index.cgi)
DU_SRC = os.path.join(HERE, "disk-usage")
DU_DST = W + "/disk-usage"
ACL = "/etc/webmin/webmin.acl"
ICACHE = "/etc/webmin/installed.cache"
MCACHE = "/var/webmin/module.infos.cache"


def root_acl_has_du():
    for line in open(ACL):
        if line.startswith("root:"):
            return "disk-usage" in line.split()
    return False


def install_modules(stamp):
    for f in DF_FILES:
        src, dst = os.path.join(HERE, "disk-focus", f), W + "/disk-focus/" + f
        if not os.path.exists(src):
            continue
        if os.path.exists(dst) and open(src, "rb").read() == open(dst, "rb").read():
            print("unchanged", dst)
            continue
        if os.path.exists(dst):
            shutil.copy2(dst, dst + ".before-collectfs-" + stamp)
        shutil.copy2(src, dst)
        os.chmod(dst, 0o755 if f.endswith(".cgi") else 0o644)
        print("installed", dst)
    os.makedirs(DU_DST, exist_ok=True)
    for f in os.listdir(DU_SRC):
        shutil.copy2(os.path.join(DU_SRC, f), os.path.join(DU_DST, f))
        os.chmod(os.path.join(DU_DST, f), 0o755 if f.endswith(".cgi") else 0o644)
    print("installed", DU_DST)
    if not root_acl_has_du():
        shutil.copy2(ACL, ACL + ".before-collectfs-" + stamp)
        lines = open(ACL).read().splitlines(True)
        with open(ACL, "r+") as fh:
            fh.seek(0)
            for line in lines:
                if line.startswith("root:"):
                    line = line.rstrip("\n") + " disk-usage\n"
                fh.write(line)
            fh.truncate()
        print("registered disk-usage for root in", ACL)
    if "disk-usage=1\n" not in open(ICACHE).read():
        with open(ICACHE, "a") as fh:
            fh.write("disk-usage=1\n")
    if os.path.exists(MCACHE):
        os.remove(MCACHE)  # Webmin rebuilds its module list cache on demand


def plan():
    out = {}
    for f, edits in EDITS.items():
        s = open(f).read()
        if MARK in s or (f.endswith("config.info") and ",15,collect_fs\n" in s):
            out[f] = None  # already hooked
            continue
        for old, new in edits:
            n = s.count(old)
            if f.endswith("config_info.pl") and old == "\n1;\n":
                # the file ends "1;" plus trailing blank lines; hook before it
                n = 1 if s.rstrip().endswith("\n1;") else 0
            if n != 1:
                sys.exit("REFUSED: %s: anchor found %d times:\n%s" % (f, n, old))
            if f.endswith("config_info.pl") and old == "\n1;\n":
                s = s.rstrip()[: -len("\n1;")] + new
            else:
                s = s.replace(old, new)
        out[f] = s
    return out


cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
new = plan()
if cmd == "status":
    for f, s in new.items():
        print(("hooked   " if s is None else "NOT hooked ") + f)
    print(("present  " if os.path.exists(LIB_DST) else "MISSING  ") + LIB_DST)
    print(("present  " if os.path.exists(DU_DST + "/index.cgi") else "MISSING  ") + DU_DST)
    print(("registered " if root_acl_has_du() else "NOT registered ") + "disk-usage for root")
elif cmd == "check":
    print("anchors OK; would change: %s" % [f for f, s in new.items() if s is not None])
elif cmd == "install":
    stamp = time.strftime("%Y%m%d-%H%M%S")
    shutil.copy2(LIB_SRC, LIB_DST)
    os.chmod(LIB_DST, 0o644)
    print("installed", LIB_DST)
    install_modules(stamp)
    for f, s in new.items():
        if s is None:
            print("already hooked", f)
            continue
        bak = f + ".before-collectfs-" + stamp
        shutil.copy2(f, bak)
        with open(f, "r+") as fh:
            fh.seek(0)
            fh.write(s)
            fh.truncate()
        print("backed up to", bak, "and hooked", f)
