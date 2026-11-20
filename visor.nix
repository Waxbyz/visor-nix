{ visor-src, efifs-src }:
{ config, lib, pkgs, ... }:

let
  cfg = config.boot.loader.visor;

  hp = pkgs.stdenv.hostPlatform;
  efiArch = hp.efiArch;
  cpu = hp.parsed.cpu.name;

  driverFile = fs: if builtins.elem fs [ "ext3" "ext4" ] then "ext2" else fs;
  efifsNames = lib.unique (map driverFile cfg.drivers);

  visorPackage = pkgs.stdenv.mkDerivation {
    pname = "visor-bootmanager";
    version = visor-src.shortRev or "git";
    src = visor-src;

    nativeBuildInputs = [ pkgs.python3 pkgs.python3Packages.pillow ];
    buildInputs = [ pkgs.gnu-efi ];

    hardeningDisable = [ "all" ];

    postPatch = ''
      for p in tools visor install.sh; do
        [ -e "$p" ] && patchShebangs "$p"
      done
    '';

    makeFlags = [
      "ARCH=${cpu}"
      "PREFIX=${pkgs.gnu-efi}"
      "GNU_EFI_INC=${pkgs.gnu-efi}/include/efi"
      "GNU_EFI_LIB=${pkgs.gnu-efi}/lib"
      "GNU_EFI_CRT0=${pkgs.gnu-efi}/lib/crt0-efi-${cpu}.o"
      "GNU_EFI_LDS=${pkgs.gnu-efi}/lib/elf_${cpu}_efi.lds"
      "EFIINC=${pkgs.gnu-efi}/include/efi"
      "EFILIB=${pkgs.gnu-efi}/lib"
      "CRT0=${pkgs.gnu-efi}/lib/crt0-efi-${cpu}.o"
      "LDSCRIPT=${pkgs.gnu-efi}/lib/elf_${cpu}_efi.lds"
    ];

    installPhase = ''
      runHook preInstall

      mkdir -p $out/lib/visor $out/bin $out/share/visor/assets $out/share/visor/tools
      cp visor_${efiArch}.efi $out/lib/visor/

      [ -d assets ] && cp -r assets/* $out/share/visor/assets/
      [ -d tools ] && cp -r tools/* $out/share/visor/tools/
      [ -f boot.conf.example ] && cp boot.conf.example $out/share/visor/
      [ -f visor ] && install -Dm755 visor $out/bin/visor

      runHook postInstall
    '';

    meta = with lib; {
      description = "Minimal, fast, graphical UEFI boot manager written in C";
      homepage = "https://github.com/IO-ZetZor/Visor-BootManager";
      license = licenses.bsd2;
      platforms = [ "x86_64-linux" "aarch64-linux" ];
    };
  };

  efifsPackage = pkgs.stdenv.mkDerivation {
    pname = "efifs-drivers";
    version = efifs-src.shortRev or "git";
    src = efifs-src;

    nativeBuildInputs = [
      pkgs.git
      pkgs.python3
      pkgs.which
      pkgs.bison
      pkgs.flex
      pkgs.gettext
    ] ++ lib.optionals (efiArch == "x64") [
      pkgs.pkgsCross.mingwW64.stdenv.cc
    ];
    buildInputs = [ pkgs.gnu-efi ];
    hardeningDisable = [ "all" ];

    postPatch = ''
      patchShebangs .
      if [ -f 0001-GRUB-fixes.patch ] && [ -d grub ]; then
        patch -p1 -d grub < 0001-GRUB-fixes.patch
      fi
    '';

    buildPhase = ''
      runHook preBuild
      ./set_grub_cpu.sh ${efiArch}
      make ARCH=${efiArch}
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/efifs
      find . -maxdepth 3 -name "*_${efiArch}.efi" -exec cp {} $out/lib/efifs/ \;
      for fs in ${lib.concatStringsSep " " efifsNames}; do
        test -f "$out/lib/efifs/''${fs}_${efiArch}.efi" \
          || { echo "EfiFs driver $fs was not built" >&2; exit 1; }
      done
      runHook postInstall
    '';

    meta = with lib; {
      description = "Standalone UEFI file system drivers based on GRUB";
      homepage = "https://github.com/pbatard/EfiFs";
      license = licenses.gpl3Plus;
      platforms = [ "x86_64-linux" "aarch64-linux" ];
    };
  };

  resolvedDrivers =
    let
      fromPkg = lib.listToAttrs (map
        (fs: {
          name = "${fs}_${efiArch}.efi";
          value = "${cfg.driversPackage}/lib/efifs/${fs}_${efiArch}.efi";
        })
        efifsNames);
      fromCustom = lib.mapAttrs'
        (name: path: {
          name = if lib.hasSuffix ".efi" name then name else "${name}_${efiArch}.efi";
          value = "${path}";
        })
        cfg.extraDrivers;
    in
    fromPkg // fromCustom;

  mediaAsset = p: {
    src = "${p}";
    ext = lib.last (lib.splitString "." (baseNameOf (toString p)));
  };
  optionalMedia = p: if p == null then null else mediaAsset p;

  themeIsFile = v:
    builtins.typeOf v == "path"
    || lib.isDerivation v
    || (lib.isString v && lib.hasPrefix "/" v && !(lib.hasInfix "\n" v));

  effectiveSettings =
    {
      editor = false;
      show_names = true;
      center_info = true;
      accent = true;
      blur = "clear";
      clock = true;
      clock_format = "24h";
    }
    // lib.optionalAttrs cfg.clockSync.enable { clock_sync = true; }
    // cfg.settings;

  extraFilesMap =
    lib.mapAttrs (_: p: "${p}") cfg.extraFiles
    // lib.optionalAttrs (cfg.snapshotsFile != null) {
      "snapshots.conf" = "${cfg.snapshotsFile}";
    };

  builderConfig = {
    esp = config.boot.loader.efi.efiSysMountPoint;
    package = "${cfg.package}";
    inherit efiArch;
    configurationLimit = cfg.configurationLimit;
    timeout = if config.boot.loader.timeout == null then -1 else config.boot.loader.timeout;
    defaultEntry = cfg.defaultEntry;
    windowsChainload = cfg.windowsChainload;
    touchEfiVars = config.boot.loader.efi.canTouchEfiVariables;
    entryName = cfg.entryName;
    nixosEntry = cfg.nixosEntry;
    windowsEntry = cfg.windowsEntry;
    extraEntries = cfg.extraEntries;
    settings = effectiveSettings;
    extraConfig = cfg.extraConfig;
    efibootmgr = "${pkgs.efibootmgr}/bin/efibootmgr";
    findmnt = "${pkgs.util-linux}/bin/findmnt";

    assets = {
      wallpaper = optionalMedia cfg.wallpaper;
      splashImage = optionalMedia cfg.splashImage;
      logo = optionalMedia cfg.logo;
      introMedia = optionalMedia cfg.introMedia;
      cursor = optionalMedia cfg.cursor;
      menuSound = if cfg.menuSound != null then "${cfg.menuSound}" else null;
      icons = lib.mapAttrs (_: p: "${p}") cfg.icons;
      themes = lib.mapAttrs
        (name: val:
          if themeIsFile val then "${val}"
          else "${pkgs.writeText "visor-theme-${name}.conf" val}")
        cfg.themes;
      activeTheme = cfg.theme;
      drivers = resolvedDrivers;
      extraFiles = extraFilesMap;
    };
  };

  configFile = pkgs.writeText "visor-install-config.json" (builtins.toJSON builderConfig);

  visorInstaller = pkgs.writeShellScript "visor-install-wrapper" ''
    exec ${pkgs.python3}/bin/python3 ${./installer/visor_install.py} ${configFile} "$@"
  '';

  timeSyncScript = pkgs.writeShellScript "visor-time-sync" ''
    set -euo pipefail
    esp=${lib.escapeShellArg config.boot.loader.efi.efiSysMountPoint}
    target="$esp/EFI/visor/time.sync"
    ${lib.optionalString cfg.clockSync.syncRtc ''
      ${pkgs.util-linux}/bin/hwclock --systohc || true
    ''}
    ${pkgs.python3}/bin/python3 - "$target" <<'PY'
    import os, sys, time
    from pathlib import Path

    target = Path(sys.argv[1])
    rtc_epoch_file = Path("/sys/class/rtc/rtc0/since_epoch")
    if not rtc_epoch_file.exists():
        sys.exit(0)

    rtc_epoch = int(rtc_epoch_file.read_text(encoding="utf-8").strip())
    tz_offset = ${if config.time.hardwareClockInLocalTime then "0" else "time.localtime().tm_gmtoff"}
    offset = int(round(time.time() - rtc_epoch)) + tz_offset
    if abs(offset) >= 86400:
        sys.exit(0)

    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_name(target.name + ".tmp")
    tmp.write_text(f"offset={offset}\n", encoding="utf-8")
    os.replace(tmp, target)
    PY
  '';

  commonEntryOptions = {
    iconSize = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = "Optional per-entry icon size in pixels.";
    };
    color = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional per-entry name color (`#RRGGBB` or `#RRGGBBAA`).";
    };
    uuid = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional partition PARTUUID pinning where the boot image lives.";
    };
  };

  luksEntryOptions = {
    luks = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Prompt for a LUKS passphrase and inject it as an initrd keyfile.";
    };
    luksKeyPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Path of the injected keyfile inside initramfs (e.g. `/crypto_keyfile.bin`).";
    };
    luksPreset = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "mkinitcpio" "arch" "dracut" "systemd" ]);
      default = null;
      description = "Initramfs preset for auto-generating the LUKS keyfile kernel option.";
    };
    luksCmdline = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Manual kernel command-line option for the LUKS keyfile (overrides `luksPreset`).";
    };
    luksConfirm = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Ask for the LUKS passphrase twice to prevent typos.";
    };
    luksVerbose = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Strip `quiet` and `splash` from cmdline so initramfs retry prompts remain visible.";
    };
  };

  extraEntryType = lib.types.submodule {
    options = commonEntryOptions // luksEntryOptions // {
      name = lib.mkOption {
        type = lib.types.str;
        description = "Display name of the boot entry.";
      };
      kernel = lib.mkOption {
        type = lib.types.str;
        description = "Path to kernel, UKI, or EFI executable relative to filesystem root (e.g. `\\vmlinuz-linux`).";
      };
      initrd = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional initrd path relative to filesystem root.";
      };
      cmdline = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional kernel command line.";
      };
      icon = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional icon path (e.g. `\\EFI\\visor\\icons\\arch.png`).";
      };
      sha256 = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional 64-character SHA-256 hash pinning the boot image.";
      };
      encrypted = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Set true if both kernel and initrd are Visor encrypted containers (`.venc`).";
      };
      kernelEncrypted = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Override encryption flag for kernel only.";
      };
      initrdEncrypted = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Override encryption flag for initrd only.";
      };
    };
  };
in
{
  options.boot.loader.visor = {
    enable = lib.mkEnableOption "Visor Graphical UEFI Boot Manager";

    package = lib.mkOption {
      type = lib.types.package;
      default = visorPackage;
      description = "Visor-BootManager package to deploy to the ESP.";
    };

    configurationLimit = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = "Maximum number of NixOS generations to include in the boot menu.";
    };

    defaultEntry = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 0;
      description = "0-based index of the default boot entry.";
    };

    entryName = lib.mkOption {
      type = lib.types.str;
      default = "NixOS #{gen}";
      description = "Entry display name template. Placeholders: {gen}, {date}, {label}.";
    };

    windowsChainload = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Automatically add a Windows Boot Manager entry if found on the ESP.";
    };

    nixosEntry = lib.mkOption {
      description = "Optional per-entry attributes applied to generated NixOS boot entries.";
      default = { };
      type = lib.types.submodule {
        options = commonEntryOptions // luksEntryOptions // {
          pinSha256 = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Automatically compute and pin the SHA-256 hash of each deployed NixOS kernel.";
          };
        };
      };
    };

    windowsEntry = lib.mkOption {
      description = "Customization options for the auto-detected Windows Boot Manager entry.";
      default = { };
      type = lib.types.submodule {
        options = commonEntryOptions // {
          name = lib.mkOption {
            type = lib.types.str;
            default = "Windows 11";
            description = "Display name for the Windows Boot Manager entry.";
          };
          pinSha256 = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Compute and pin the SHA-256 hash of `bootmgfw.efi` (forces chainloading).";
          };
        };
      };
    };

    extraEntries = lib.mkOption {
      type = lib.types.listOf extraEntryType;
      default = [ ];
      example = lib.literalExpression ''
        [
          {
            name = "Arch Linux";
            kernel = "\\vmlinuz-linux";
            initrd = "\\initramfs-linux.img";
            cmdline = "root=PARTUUID=... rw quiet";
            color = "#1793D1";
          }
        ]
      '';
      description = "Additional custom `entry { ... }` blocks appended after NixOS generations.";
    };

    drivers = lib.mkOption {
      type = lib.types.listOf (lib.types.enum [
        "ext2"
        "ext3"
        "ext4"
        "btrfs"
        "xfs"
        "ntfs"
        "exfat"
        "f2fs"
        "zfs"
        "iso9660"
        "squash4"
      ]);
      default = [ ];
      example = [ "btrfs" "ext4" ];
      description = ''
        EfiFs UEFI filesystem drivers to install into `\EFI\visor\drivers\`.
        Used by Visor's file browser and Btrfs snapshot auto-detection.
        `ext4` and `ext3` use the `ext2` driver.
      '';
    };

    driversPackage = lib.mkOption {
      type = lib.types.package;
      default = efifsPackage;
      description = "Package providing EfiFs filesystem driver binaries.";
    };

    extraDrivers = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      example = lib.literalExpression ''
        {
          "btrfs_x64.efi" = pkgs.fetchurl {
            url = "https://github.com/pbatard/EfiFs/releases/download/v1.13/btrfs_x64.efi";
            hash = "sha256-...";
          };
        }
      '';
      description = "Prebuilt `.efi` drivers to copy into `\\EFI\\visor\\drivers\\`.";
    };

    wallpaper = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "./assets/wallpaper.png";
      description = "Background image or video (PNG, BMP, GIF, MJPEG MP4, VBG) copied to `\\EFI\\visor\\backgrounds\\custom.<ext>`.";
    };

    splashImage = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "./assets/splash.png";
      description = "Still splash frame image copied to `\\EFI\\visor\\backgrounds\\splash.<ext>` (`splash_image`).";
    };

    logo = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "./assets/my-logo.png";
      description = "Header logo (PNG or BMP) copied to `\\EFI\\visor\\custom_logo.<ext>`.";
    };

    introMedia = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "./assets/intro.gif";
      description = "Boot intro media (PNG, BMP, GIF, MJPEG MP4, VBG) copied to `\\EFI\\visor\\backgrounds\\intro.<ext>`.";
    };

    cursor = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "./assets/breeze.png";
      description = "Custom pointer cursor image (PNG or BMP) copied to `\\EFI\\visor\\cursors\\custom.<ext>`.";
    };

    menuSound = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "./assets/startup.wav";
      description = "Startup WAV audio (16-bit PCM, up to 4s) copied to `\\EFI\\visor\\bootsound.wav`.";
    };

    icons = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      example = lib.literalExpression ''
        {
          nixos = ./assets/icons/nixos.png;
          windows = ./assets/icons/windows11.png;
          power_shutdown = ./assets/icons/shutdown.png;
        }
      '';
      description = ''
        PNG icons mapped from `<name> = <path>` to `\EFI\visor\icons\<name>.png`.
        Keys `power_shutdown`, `power_reboot`, and `power_firmware` enable graphical power action icons.
      '';
    };

    themes = lib.mkOption {
      type = lib.types.attrsOf (lib.types.either lib.types.path lib.types.lines);
      default = { };
      example = lib.literalExpression ''
        {
          catppuccin = '''
            title_color=#CBA6F7
            name_color=#CDD6F4
            highlight_color=#CBA6F7
            bg_color=#1E1E2E
            blur=1
          ''';
        }
      '';
      description = "Theme definitions written to `\\EFI\\visor\\themes\\<name>.conf`.";
    };

    theme = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "catppuccin";
      description = "Active theme name (or `random` / `cycle`).";
    };

    snapshotsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Optional manifest file copied to `\\EFI\\visor\\snapshots.conf`.";
    };

    extraFiles = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      example = lib.literalExpression ''{ "cursors/breeze.png" = ./assets/breeze.png; }'';
      description = "Additional files copied to relative paths under `\\EFI\\visor\\`.";
    };

    clockSync = {
      enable = lib.mkEnableOption "periodic systemd service writing `\\EFI\\visor\\time.sync` and enabling `clock_sync=1`";
      syncRtc = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Also synchronize the hardware RTC (`hwclock --systohc`) during time sync.";
      };
    };

    settings = lib.mkOption {
      type = with lib.types; attrsOf (oneOf [ bool int str ]);
      default = { };
      example = lib.literalExpression ''{ entries_per_page = 4; resolution = "1920x1080"; editor = true; }'';
      description = "Global `boot.conf` key-value settings.";
    };

    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      example = ''
        windows_bootnext=1
        resolution=1920x1080
      '';
      description = "Extra configuration lines appended to `boot.conf`.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !config.boot.loader.systemd-boot.enable && !config.boot.loader.grub.enable;
        message = "Visor BootManager cannot be enabled alongside systemd-boot or GRUB.";
      }
    ];

    boot.loader.supportsInitrdSecrets = true;

    environment.systemPackages = [ cfg.package pkgs.efibootmgr ];

    system.build.installBootLoader = visorInstaller;
    system.boot.loader.id = "visor";

    systemd.services.visor-time-sync = lib.mkIf cfg.clockSync.enable {
      description = "Sync Visor BootManager clock offset to ESP";
      after = [ "time-sync.target" "local-fs.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${timeSyncScript}";
      };
    };

    systemd.timers.visor-time-sync = lib.mkIf cfg.clockSync.enable {
      description = "Periodic Visor BootManager clock offset sync";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2m";
        OnUnitActiveSec = "6h";
      };
    };
  };
}
