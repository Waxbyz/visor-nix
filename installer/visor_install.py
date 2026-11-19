#!/usr/bin/env python3
from __future__ import annotations

import filecmp
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path, PurePosixPath

STORE = Path("/nix/store")
PROFILES = Path("/nix/var/nix/profiles")

BOOTSPEC = "org.nixos.bootspec.v1"
SPECIALISATION = "org.nixos.specialisation.v1"

MAIN_GEN_RE = re.compile(r"^system-(\d+)-link$")
PROFILE_GEN_RE = re.compile(r"^(.+)-(\d+)-link$")
SAFE_NAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")
HEX_COLOR_RE = re.compile(r"^#[0-9A-Fa-f]{6}(?:[0-9A-Fa-f]{2})?(?=$|\s)")

POWER_ICON_KEYS = {
    "power_shutdown": "shutdown_icon",
    "power_reboot": "reboot_icon",
    "power_firmware": "firmware_icon",
}


class TargetGenerationError(RuntimeError):
    pass


def warn(msg: str) -> None:
    print(f"[visor-install] {msg}", file=sys.stderr)


def fmt_value(v) -> str:
    if isinstance(v, bool):
        return "1" if v else "0"
    s = str(v)
    if '"' in s:
        warn(f"value contains a double quote (replacing with single quote): {s!r}")
        s = s.replace('"', "'")
    if s == "" or re.search(r"\s", s):
        return f'"{s}"'
    return s


def render_kv(d: dict) -> list[str]:
    return [f"{k}={fmt_value(v)}" for k, v in d.items()]


def _split_value_and_comment(rhs: str) -> tuple[str, str]:
    rhs = rhs.strip()
    if not rhs:
        return "", ""

    if rhs.startswith('"'):
        end_quote = rhs.find('"', 1)
        if end_quote != -1:
            val = rhs[: end_quote + 1]
            rest = rhs[end_quote + 1 :].strip()
            if rest.startswith("#"):
                return val, rest
            return rhs, ""
        return rhs, ""

    start_idx = 0
    if rhs.startswith("#"):
        m_hex = HEX_COLOR_RE.match(rhs)
        if m_hex:
            start_idx = m_hex.end()
        else:
            return "", rhs

    m = re.search(r"\s+#", rhs[start_idx:])
    if m:
        cut = start_idx + m.start()
        val = rhs[:cut].rstrip()
        comment = rhs[cut:].lstrip()
        return val, comment

    return rhs, ""


def normalize_conf(text: str) -> str:
    out = []
    for line in text.splitlines():
        m = re.match(r"^(\s*)([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$", line)
        if not m:
            out.append(line.rstrip())
            continue
        indent, key, rhs = m[1], m[2], m[3]
        val, comment = _split_value_and_comment(rhs)
        if val == "" and comment:
            out.append(f"{indent}{key}= {comment}")
        elif comment:
            out.append(f"{indent}{key}={val} {comment}")
        else:
            out.append(f"{indent}{key}={val}")
    return "\n".join(out).strip("\n") + "\n"


def render_entry(attrs: dict, comment: str | None = None) -> list[str]:
    out = []
    if comment:
        out.append(f"# {comment}")
    out.append("entry {")
    out += [f"    {line}" for line in render_kv(attrs)]
    out.append("}")
    return out


def _fsync_path(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_write(dst: Path, data: bytes) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_name(dst.name + ".tmp")
    try:
        with open(tmp, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, dst)
    finally:
        tmp.unlink(missing_ok=True)


def copy_to(src: Path, tmp: Path) -> None:
    tmp.parent.mkdir(parents=True, exist_ok=True)
    with open(src, "rb") as s, open(tmp, "wb") as d:
        shutil.copyfileobj(s, d)
        d.flush()
        os.fsync(d.fileno())


def atomic_copy(src, dst: Path, compare: str = "content") -> bool:
    src = Path(src)
    if dst.exists():
        if compare == "size" and dst.stat().st_size == src.stat().st_size:
            return False
        if compare == "content" and filecmp.cmp(src, dst, shallow=False):
            return False
    tmp = dst.with_name(dst.name + ".tmp")
    try:
        copy_to(src, tmp)
        os.replace(tmp, dst)
    finally:
        tmp.unlink(missing_ok=True)
    return True


def file_sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()


def sanitize_ext(ext, default: str = "png") -> str:
    ext = (ext or "").lower()
    return ext if re.fullmatch(r"[a-z0-9]{1,5}", ext) else default


def efi_path(*parts: str) -> str:
    return "\\" + "\\".join(parts)


def apply_entry_opts(attrs: dict, opts: dict, kernel_path: Path | None = None) -> None:
    mapping = [
        ("iconSize", "icon_size"),
        ("color", "color"),
        ("uuid", "uuid"),
        ("sha256", "sha256"),
        ("luksKeyPath", "luks_key_path"),
        ("luksPreset", "luks_preset"),
        ("luksCmdline", "luks_cmdline"),
    ]
    for src_key, dst_key in mapping:
        val = opts.get(src_key)
        if val is not None:
            attrs[dst_key] = val

    for src_key, dst_key in [
        ("encrypted", "encrypted"),
        ("luks", "luks"),
        ("luksConfirm", "luks_confirm"),
        ("luksVerbose", "luks_verbose"),
    ]:
        if opts.get(src_key):
            attrs[dst_key] = True

    for src_key, dst_key in [
        ("kernelEncrypted", "kernel_encrypted"),
        ("initrdEncrypted", "initrd_encrypted"),
    ]:
        val = opts.get(src_key)
        if val is not None:
            attrs[dst_key] = val

    if opts.get("pinSha256") and kernel_path is not None and kernel_path.exists():
        attrs["sha256"] = file_sha256(kernel_path)


def spec_from_bootspec(bs: dict) -> dict:
    return {
        "label": bs.get("label", "NixOS"),
        "kernel": Path(bs["kernel"]),
        "initrd": Path(bs["initrd"]) if bs.get("initrd") else None,
        "params": list(bs.get("kernelParams", [])),
        "init": bs["init"],
        "secrets": bs.get("initrdSecrets"),
    }


def read_generation(gen_path: Path) -> tuple[dict, dict]:
    bj = gen_path / "boot.json"
    if bj.exists():
        doc = json.loads(bj.read_text(encoding="utf-8"))
        if BOOTSPEC not in doc:
            raise ValueError(f"missing {BOOTSPEC} key in {bj}")
        specs = {
            name: s.get(BOOTSPEC, s)
            for name, s in (doc.get(SPECIALISATION) or {}).items()
        }
        return spec_from_bootspec(doc[BOOTSPEC]), specs

    params_file = gen_path / "kernel-params"
    version_file = gen_path / "nixos-version"
    return {
        "label": version_file.read_text(encoding="utf-8").strip() if version_file.exists() else "NixOS",
        "kernel": (gen_path / "kernel").resolve(),
        "initrd": (gen_path / "initrd").resolve() if (gen_path / "initrd").exists() else None,
        "params": params_file.read_text(encoding="utf-8").split() if params_file.exists() else [],
        "init": str((gen_path / "init").resolve()),
        "secrets": None,
    }, {}


def find_generations(default_top: Path | None) -> list[dict]:
    gens = []

    def add(p: Path, profile, number: int):
        try:
            gens.append({"profile": profile, "number": number,
                         "path": p.resolve(), "mtime": p.lstat().st_mtime})
        except OSError as e:
            warn(f"{p}: {e}, skipped")

    if PROFILES.is_dir():
        for p in PROFILES.iterdir():
            m = MAIN_GEN_RE.match(p.name)
            if m:
                add(p, None, int(m[1]))
    sub = PROFILES / "system-profiles"
    if sub.is_dir():
        for p in sub.iterdir():
            m = PROFILE_GEN_RE.match(p.name)
            if m:
                add(p, m[1], int(m[2]))

    gens.sort(key=lambda g: (g["path"] != default_top, -g["mtime"], -g["number"]))
    return gens


class Installer:
    def __init__(self, cfg: dict, default_top: Path | None):
        self.cfg = cfg
        self.default_top = default_top
        self.esp = Path(cfg["esp"])
        self.visor_dir = self.esp / "EFI" / "visor"
        self.nixos_dir = self.esp / "EFI" / "nixos"
        self.fallback_dir = self.esp / "EFI" / "BOOT"
        self.arch = cfg["efiArch"]
        self.efi_name = f"visor_{self.arch}.efi"
        self.keep: set[str] = set()
        self.managed_assets: set[str] = set()

    def _track_asset(self, dst: Path) -> None:
        try:
            rel = dst.relative_to(self.visor_dir).as_posix()
            self.managed_assets.add(rel)
        except ValueError:
            pass

    def deploy_binaries(self) -> None:
        pkg = self.cfg.get("package")
        if not pkg or not Path(pkg).exists():
            warn(f"Visor package not found ({pkg!r}), skipping binary deployment")
            return
        src = Path(pkg) / "lib" / "visor" / self.efi_name
        if not src.exists():
            warn(f"{src} not found")
            return
        atomic_copy(src, self.visor_dir / self.efi_name)
        atomic_copy(src, self.fallback_dir / f"BOOT{self.arch.upper()}.EFI")

        assets = Path(pkg) / "share" / "visor" / "assets"
        if assets.is_dir():
            for root, _, files in os.walk(assets):
                rel = Path(root).relative_to(assets)
                for fname in files:
                    try:
                        dst = self.visor_dir / rel / fname
                        atomic_copy(Path(root) / fname, dst)
                        self._track_asset(dst)
                    except OSError as e:
                        warn(f"asset {fname}: {e}")

    def deploy_assets(self) -> dict:
        a = self.cfg.get("assets") or {}
        d = self.visor_dir
        ov: dict[str, str] = {}

        def media(key: str, subdir: str, stem: str, conf_key: str, relative_to_visor: bool = False):
            m = a.get(key)
            if not m or not m.get("src"):
                return
            name = f"{stem}.{sanitize_ext(m.get('ext'))}"
            dst = d / subdir / name if subdir else d / name
            try:
                atomic_copy(m["src"], dst)
                self._track_asset(dst)
            except OSError as e:
                warn(f"{key}: {e}")
                return
            if relative_to_visor:
                ov[conf_key] = f"{subdir}/{name}" if subdir else name
            else:
                ov[conf_key] = efi_path("EFI", "visor", *([subdir] if subdir else []), name)

        media("wallpaper", "backgrounds", "custom", "background")
        if "background" not in ov and (d / "backgrounds" / "default.png").exists():
            ov["background"] = efi_path("EFI", "visor", "backgrounds", "default.png")
        media("splashImage", "backgrounds", "splash", "splash_image")
        media("logo", "", "custom_logo", "logo")
        media("introMedia", "backgrounds", "intro", "intro_media")
        media("cursor", "cursors", "custom", "cursor", relative_to_visor=True)

        sound = a.get("menuSound")
        if sound:
            try:
                dst = d / "bootsound.wav"
                atomic_copy(sound, dst)
                self._track_asset(dst)
                ov["menu_sound"] = efi_path("EFI", "visor", "bootsound.wav")
            except OSError as e:
                warn(f"menuSound: {e}")

        for name, src in (a.get("icons") or {}).items():
            if not SAFE_NAME_RE.match(name):
                warn(f"invalid icon name {name!r}, skipped")
                continue
            dst = d / "icons" / f"{name}.png"
            try:
                atomic_copy(src, dst)
                self._track_asset(dst)
            except OSError as e:
                warn(f"icon {name}: {e}")
                continue
            if name in POWER_ICON_KEYS:
                ov[POWER_ICON_KEYS[name]] = efi_path("EFI", "visor", "icons", f"{name}.png")
                ov["power_icons"] = "1"

        for name, src in (a.get("themes") or {}).items():
            if not SAFE_NAME_RE.match(name):
                warn(f"invalid theme name {name!r}, skipped")
                continue
            dst = d / "themes" / f"{name}.conf"
            try:
                text = Path(src).read_text(encoding="utf-8")
                atomic_write(dst, normalize_conf(text).encode())
                self._track_asset(dst)
            except (OSError, UnicodeDecodeError) as e:
                warn(f"theme {name}: {e}")
        if a.get("activeTheme"):
            ov["theme"] = a["activeTheme"]

        ddir = d / "drivers"
        ddir.mkdir(parents=True, exist_ok=True)
        active: set[str] = set()
        for name, src in (a.get("drivers") or {}).items():
            if not SAFE_NAME_RE.match(name) or not Path(src).exists():
                warn(f"driver {name!r} ({src}) skipped")
                continue
            try:
                atomic_copy(src, ddir / name)
                active.add(name)
            except OSError as e:
                warn(f"driver {name}: {e}")
        for f in ddir.iterdir():
            if f.is_file() and f.suffix.lower() == ".efi" and f.name not in active:
                try:
                    f.unlink()
                except OSError as e:
                    warn(f"failed to remove stale driver {f}: {e}")

        for rel_path, src in (a.get("extraFiles") or {}).items():
            rel = PurePosixPath(rel_path.replace("\\", "/").lstrip("/"))
            if not rel.parts or ".." in rel.parts or rel == PurePosixPath("boot.conf"):
                warn(f"extraFiles: unsafe relative path {rel_path!r}, skipped")
                continue
            dst = d.joinpath(*rel.parts)
            try:
                atomic_copy(src, dst)
                self._track_asset(dst)
            except OSError as e:
                warn(f"extraFiles {rel_path}: {e}")

        manifest = d / ".managed-assets.json"
        if manifest.exists():
            try:
                prev = set(json.loads(manifest.read_text(encoding="utf-8")))
            except (OSError, ValueError, TypeError):
                prev = set()
            for stale_rel in prev - self.managed_assets:
                stale_path = d / PurePosixPath(stale_rel)
                if stale_path.is_file():
                    try:
                        stale_path.unlink()
                    except OSError as e:
                        warn(f"failed to remove stale asset {stale_path}: {e}")
        try:
            atomic_write(manifest, json.dumps(sorted(self.managed_assets)).encode("utf-8"))
        except OSError as e:
            warn(f"failed to write asset manifest: {e}")

        return ov

    @staticmethod
    def _base_name(p: Path) -> str:
        try:
            top = p.relative_to(STORE).parts[0]
        except ValueError:
            top = p.parent.name
        return re.sub(r"[^a-zA-Z0-9._-]", "_", top)

    def install_kernel(self, src: Path) -> tuple[str, Path]:
        name = f"{self._base_name(src)}-{src.name}.efi"
        self.keep.add(name)
        dst = self.nixos_dir / name
        atomic_copy(src, dst, compare="size")
        return efi_path("EFI", "nixos", name), dst

    def install_initrd(self, src: Path, secrets: str | None) -> str:
        if not secrets:
            name = f"{self._base_name(src)}-{src.name}.img"
            self.keep.add(name)
            atomic_copy(src, self.nixos_dir / name, compare="size")
            return efi_path("EFI", "nixos", name)

        sec_tag = hashlib.sha256(secrets.encode("utf-8")).hexdigest()[:12]
        name = f"{self._base_name(src)}-{sec_tag}-{src.name}.img"
        self.keep.add(name)
        dst = self.nixos_dir / name
        tmp = dst.with_name(dst.name + ".tmp")
        try:
            copy_to(src, tmp)
            r = subprocess.run([secrets, str(tmp)])
            if r.returncode != 0:
                raise RuntimeError(
                    f"append-initrd-secrets exited with code {r.returncode} for {name}"
                )
            _fsync_path(tmp)
            os.replace(tmp, dst)
        finally:
            tmp.unlink(missing_ok=True)
        return efi_path("EFI", "nixos", name)

    def make_entry(self, gen: dict, spec_name, spec: dict):
        kernel, kernel_dst = self.install_kernel(spec["kernel"])
        initrd = self.install_initrd(spec["initrd"], spec["secrets"]) if spec["initrd"] else None

        date = time.strftime("%Y-%m-%d", time.localtime(gen["mtime"]))
        if gen["number"] is None:
            name = "NixOS (current)"
        else:
            name = self.cfg["entryName"]
            for key, val in (("{gen}", gen["number"]), ("{date}", date), ("{label}", spec["label"])):
                name = name.replace(key, str(val))
        if gen["profile"]:
            name = f"{gen['profile']}: {name}"
        if spec_name:
            name += f" [{spec_name}]"

        attrs = {"name": name}
        if (self.visor_dir / "icons" / "nixos.png").exists():
            attrs["icon"] = efi_path("EFI", "visor", "icons", "nixos.png")
        attrs["kernel"] = kernel
        if initrd:
            attrs["initrd"] = initrd
        attrs["cmdline"] = " ".join([f"init={spec['init']}", *spec["params"]])

        apply_entry_opts(attrs, self.cfg.get("nixosEntry") or {}, kernel_path=kernel_dst)
        return attrs, f"{spec['label']} ({date})"

    def build_entries(self) -> list[tuple[dict, str]]:
        gens = find_generations(self.default_top)
        if self.default_top and all(g["path"] != self.default_top for g in gens):
            gens.insert(0, {"profile": None, "number": None,
                            "path": self.default_top, "mtime": time.time()})
        limit = self.cfg.get("configurationLimit")
        if limit:
            gens = gens[:limit]

        entries = []
        for g in gens:
            is_target = self.default_top is not None and g["path"] == self.default_top
            try:
                base, specs = read_generation(g["path"])
            except (OSError, KeyError, ValueError, RuntimeError) as e:
                warn(f"{g['path']}: {e}, generation skipped")
                if is_target:
                    raise TargetGenerationError(f"failed to read target generation {g['path']}: {e}") from e
                continue
            variants = [(None, lambda: base)]
            variants += [(n, (lambda raw=raw: spec_from_bootspec(raw))) for n, raw in specs.items()]
            for sname, get_spec in variants:
                try:
                    entries.append(self.make_entry(g, sname, get_spec()))
                except (OSError, KeyError, ValueError, RuntimeError) as e:
                    warn(f"{g['path']}{' [' + sname + ']' if sname else ''}: {e}, entry skipped")
                    if is_target:
                        raise TargetGenerationError(
                            f"failed to install target generation {g['path']}"
                            f"{' [' + sname + ']' if sname else ''}: {e}"
                        ) from e
        return entries

    def render_conf(self, overrides: dict, entries) -> str:
        c = self.cfg
        lines = [
            f"timeout={c['timeout']}",
            f"default={c.get('defaultEntry', 0)}",
        ]
        lines += render_kv(overrides)
        lines += render_kv(c.get("settings") or {})
        if (c.get("extraConfig") or "").strip():
            lines += ["", normalize_conf(c["extraConfig"]).rstrip("\n")]
        lines.append("")
        for attrs, comment in entries:
            lines += render_entry(attrs, comment)
            lines.append("")

        for extra in (c.get("extraEntries") or []):
            ea: dict = {"name": extra["name"]}
            if extra.get("icon"):
                ea["icon"] = extra["icon"]
            ea["kernel"] = extra["kernel"]
            if extra.get("initrd"):
                ea["initrd"] = extra["initrd"]
            if extra.get("cmdline"):
                ea["cmdline"] = extra["cmdline"]
            apply_entry_opts(ea, extra)
            lines += render_entry(ea)
            lines.append("")

        win = self.esp / "EFI" / "Microsoft" / "Boot" / "bootmgfw.efi"
        if c.get("windowsChainload") and win.exists():
            win_opts = c.get("windowsEntry") or {}
            w: dict = {"name": win_opts.get("name", "Windows 11")}
            if (self.visor_dir / "icons" / "windows.png").exists():
                w["icon"] = efi_path("EFI", "visor", "icons", "windows.png")
            w["kernel"] = efi_path("EFI", "Microsoft", "Boot", "bootmgfw.efi")
            apply_entry_opts(w, win_opts, kernel_path=win)
            lines += render_entry(w)
            lines.append("")
        return "\n".join(lines)

    def collect_garbage(self) -> None:
        for f in self.nixos_dir.iterdir():
            if f.is_file() and f.name not in self.keep:
                try:
                    f.unlink()
                except OSError as e:
                    warn(f"failed to remove {f}: {e}")

    def esp_disk_and_part(self) -> tuple[str, str]:
        src = subprocess.run(
            [self.cfg["findmnt"], "-n", "-o", "SOURCE", "--target", str(self.esp)],
            capture_output=True, text=True, check=True).stdout.strip()
        src = re.sub(r"\[.*\]$", "", src)
        sysdir = Path(os.path.realpath(f"/sys/class/block/{os.path.basename(os.path.realpath(src))}"))
        part = (sysdir / "partition").read_text().strip()
        return "/dev/" + sysdir.parent.name, part

    def ensure_nvram(self) -> None:
        if not self.cfg.get("touchEfiVars"):
            return
        if not Path("/sys/firmware/efi").exists():
            warn("not booted in EFI mode, skipping NVRAM registration")
            return
        try:
            efibootmgr = self.cfg["efibootmgr"]
            out = subprocess.run([efibootmgr, "-v"], capture_output=True, text=True)
            if out.returncode == 0 and self.efi_name.lower() in out.stdout.lower():
                return
            disk, part = self.esp_disk_and_part()
            r = subprocess.run(
                [efibootmgr, "--create", "--disk", disk, "--part", part,
                 "--label", "Visor BootManager", "--loader", efi_path("EFI", "visor", self.efi_name)],
                capture_output=True, text=True)
            if r.returncode != 0:
                warn(f"efibootmgr: {r.stderr.strip()}")
        except Exception as e:
            warn(f"failed to update NVRAM: {e}")

    def run(self) -> int:
        self.nixos_dir.mkdir(parents=True, exist_ok=True)
        self.visor_dir.mkdir(parents=True, exist_ok=True)

        self.deploy_binaries()
        overrides = self.deploy_assets()
        try:
            entries = self.build_entries()
        except TargetGenerationError as e:
            warn(f"{e}; leaving boot.conf untouched")
            return 1
        if not entries:
            warn("no bootable NixOS entries found, leaving boot.conf untouched")
            return 1

        conf = self.visor_dir / "boot.conf"
        atomic_write(conf, self.render_conf(overrides, entries).encode("utf-8"))
        self.collect_garbage()
        self.ensure_nvram()
        print(f"[visor-install] wrote {conf} ({len(entries)} NixOS entries)")
        return 0


def main(args=None) -> int:
    args = sys.argv[1:] if args is None else args
    if not args:
        print("usage: visor-install.py <config.json> [<toplevel>]", file=sys.stderr)
        return 2
    cfg = json.loads(Path(args[0]).read_text(encoding="utf-8"))
    default_top = Path(args[1]).resolve() if len(args) > 1 else None
    return Installer(cfg, default_top).run()


if __name__ == "__main__":
    sys.exit(main())