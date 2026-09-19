#!/usr/bin/env python3
"""Personalizza le cartelle ios/ macos/ windows/ appena generate da
`flutter create`. Idempotente: ogni patch controlla se è già applicata.

Solo libreria standard (nessuna dipendenza), così gira identica su runner
macOS e Windows. Modifiche volutamente minime e reversibili.
"""
import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP_NAME = "Scripta"
BUNDLE_ID = "io.github.scripta"
MIN_IOS = (13, 0)   # non abbassa mai il valore scelto da Flutter, lo alza soltanto
MIN_MACOS = (10, 15)


def log(msg):
    print(f"   [patch] {msg}")


def parse_ver(s):
    parts = [int(x) for x in re.findall(r"\d+", s)]
    return tuple((parts + [0, 0])[:2])


def fmt_ver(v):
    return f"{v[0]}.{v[1]}"


def read(p):
    return p.read_text(encoding="utf-8")


def write_if_changed(p, new, old):
    if new != old:
        p.write_text(new, encoding="utf-8")
        log(f"aggiornato {p.relative_to(ROOT)}")
        return True
    return False


# ---------------------------------------------------------------- versioni --
def raise_min_in_pbxproj(pbx, key, minimum):
    """Alza (mai abbassa) <key> = X; nel project.pbxproj."""
    if not pbx.exists():
        log(f"ATTENZIONE: {pbx.relative_to(ROOT)} non trovato")
        return
    old = read(pbx)

    def repl(m):
        cur = parse_ver(m.group(2))
        return f"{m.group(1)}{fmt_ver(max(cur, minimum))};"

    new = re.sub(rf"({key} = )([0-9.]+);", repl, old)
    write_if_changed(pbx, new, old)


def raise_min_in_podfile(podfile, os_name, minimum):
    """Se il Podfile esiste, imposta/alza `platform :os, 'X'`."""
    if not podfile.exists():
        return  # verrà generato da Flutter al primo build con i valori giusti
    old = read(podfile)
    m = re.search(rf"^\s*#?\s*platform :{os_name}, '([0-9.]+)'", old, re.M)
    if not m:
        return
    target = max(parse_ver(m.group(1)), minimum)
    new = re.sub(rf"^\s*#?\s*platform :{os_name}, '[0-9.]+'",
                 f"platform :{os_name}, '{fmt_ver(target)}'", old, count=1, flags=re.M)
    write_if_changed(podfile, new, old)


# --------------------------------------------------------------------- iOS --
def patch_ios():
    d = ROOT / "ios"
    if not d.exists():
        return
    log("iOS")
    info = d / "Runner" / "Info.plist"
    if info.exists():
        with open(info, "rb") as f:
            data = plistlib.load(f)
        changed = False
        for k in ("CFBundleDisplayName", "CFBundleName"):
            if data.get(k) != APP_NAME:
                data[k] = APP_NAME
                changed = True
        if changed:
            with open(info, "wb") as f:
                plistlib.dump(data, f, sort_keys=False)
            log("aggiornato ios/Runner/Info.plist (nome visualizzato)")
    raise_min_in_pbxproj(d / "Runner.xcodeproj" / "project.pbxproj",
                         "IPHONEOS_DEPLOYMENT_TARGET", MIN_IOS)
    # AppFrameworkInfo.plist: presente nei template più vecchi
    afi = d / "Flutter" / "AppFrameworkInfo.plist"
    if afi.exists():
        old = read(afi)
        m = re.search(r"(<key>MinimumOSVersion</key>\s*<string>)([0-9.]+)(</string>)", old)
        if m:
            v = max(parse_ver(m.group(2)), MIN_IOS)
            new = old[:m.start(2)] + fmt_ver(v) + old[m.end(2):]
            write_if_changed(afi, new, old)
    raise_min_in_podfile(d / "Podfile", "ios", MIN_IOS)


# ------------------------------------------------------------------- macOS --
ENTITLEMENTS = {
    # Sync HTTP(S) verso il server dell'utente + font di google_fonts scaricati
    # a runtime: il sandbox macOS blocca di default ogni connessione in uscita.
    "com.apple.security.network.client": True,
    # file_picker (importazione/esportazione): accesso ai soli file/cartelle
    # scelti dall'utente tramite i pannelli di sistema.
    "com.apple.security.files.user-selected.read-write": True,
}
# NOTA — NON aggiungiamo volutamente 'keychain-access-groups': è un
# entitlement "ristretto" che richiede un provisioning profile dello
# sviluppatore; in una build con firma ad-hoc (o senza firma) macOS può
# terminare l'app all'avvio. Il Keychain viene usato senza gruppo esplicito e,
# se rifiutato, SecureStorageService ripiega su SharedPreferences.


def patch_macos():
    d = ROOT / "macos"
    if not d.exists():
        return
    log("macOS")
    for name in ("DebugProfile.entitlements", "Release.entitlements"):
        f = d / "Runner" / name
        if not f.exists():
            log(f"ATTENZIONE: {f.relative_to(ROOT)} non trovato")
            continue
        with open(f, "rb") as fh:
            data = plistlib.load(fh)
        changed = False
        for k, v in ENTITLEMENTS.items():
            if data.get(k) != v:
                data[k] = v
                changed = True
        if changed:
            with open(f, "wb") as fh:
                plistlib.dump(data, fh, sort_keys=False)
            log(f"aggiornato macos/Runner/{name}")

    xc = d / "Runner" / "Configs" / "AppInfo.xcconfig"
    if xc.exists():
        old = read(xc)
        new = re.sub(r"^PRODUCT_NAME\s*=.*$", f"PRODUCT_NAME = {APP_NAME}", old, flags=re.M)
        new = re.sub(r"^PRODUCT_BUNDLE_IDENTIFIER\s*=.*$",
                     f"PRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID}", new, flags=re.M)
        write_if_changed(xc, new, old)
    raise_min_in_pbxproj(d / "Runner.xcodeproj" / "project.pbxproj",
                         "MACOSX_DEPLOYMENT_TARGET", MIN_MACOS)
    raise_min_in_podfile(d / "Podfile", "osx", MIN_MACOS)


# ----------------------------------------------------------------- Windows --
def patch_windows():
    d = ROOT / "windows"
    if not d.exists():
        return
    log("Windows")
    main_cpp = d / "runner" / "main.cpp"
    if main_cpp.exists():
        old = read(main_cpp)
        new = re.sub(r'(window\.Create\(L")[^"]*(")', rf"\g<1>{APP_NAME}\g<2>", old)
        write_if_changed(main_cpp, new, old)
    rc = d / "runner" / "Runner.rc"
    if rc.exists():
        old = read(rc)
        new = old
        for key in ("FileDescription", "ProductName"):
            new = re.sub(rf'(VALUE "{key}", ")[^"]*(")', rf"\g<1>{APP_NAME}\g<2>", new)
        write_if_changed(rc, new, old)


def main():
    targets = sys.argv[1:] or ["all"]
    if "all" in targets:
        targets = ["ios", "macos", "windows"]
    for t in targets:
        {"ios": patch_ios, "macos": patch_macos, "windows": patch_windows}[t]()


if __name__ == "__main__":
    main()
