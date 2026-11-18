{ config, lib, pkgs, ... }:

let
  cfg = config.boot.loader.visor;

  hp = pkgs.stdenv.hostPlatform;
  efiArch = hp.efiArch;
  cpu = hp.parsed.cpu.name;

  driverFile = fs: if builtins.elem fs [ "ext3" "ext4" ] then "ext2" else fs;
  efifsNames = lib.unique (map driverFile cfg.drivers);

  visorPackage = pkgs.stdenv.mkDerivation rec {
    pname = "visor-bootmanager";
    version = "1.6.1";

    src = pkgs.fetchFromGitHub {
      owner = "IO-ZetZor";
      repo = "Visor-BootManager";
      rev = "v${version}";
      hash = lib.fakeHash;
    };

    nativeBuildInputs = [ pkgs.python3 pkgs.python3Packages.pillow ];
    buildInputs = [ pkgs.gnu-efi ];

    hardeningDisable = [ "all" ];

    postPatch = ''
      patchShebangs tools/ visor install.sh
    '';

    makeFlags = [
      "ARCH=${cpu}"
      "PREFIX=${pkgs.gnu-efi}"
      "EFIINC=${pkgs.gnu-efi}/include/efi"
      "EFILIB=${pkgs.gnu-efi}/lib"
      "CRT0=${pkgs.gnu-efi}/lib/crt0-efi-${cpu}.o"
      "LDSCRIPT=${pkgs.gnu-efi}/lib/elf_${cpu}_efi.lds"
    ];

    installPhase = ''
      runHook preInstall

      mkdir -p $out/lib/visor $out/bin $out/share/visor/assets
      cp visor_${efiArch}.efi $out/lib/visor/

      [ -d assets ] && cp -r assets/* $out/share/visor/assets/
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

  efifsPackage = pkgs.stdenv.mkDerivation rec {
    pname = "efifs-drivers";
    version = "1.13";

    src = pkgs.fetchFromGitHub {
      owner = "pbatard";
      repo = "EfiFs";
      rev = "v${version}";
      fetchSubmodules = true;
      hash = lib.fakeHash;
    };

    nativeBuildInputs = [ pkgs.git pkgs.python3 ];
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
      for fs in ${lib.concatStringsSep " " efifsNames}; do
        make ARCH=${efiArch} DRIVER="$fs" -j$NIX_BUILD_CORES \
          || make ARCH=${efiArch} -C src "$fs"
      done
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

  effectiveSettings = {
    editor = false;
    show_names = true;
    center_info = true;
    accent = true;
    blur = "clear";
    clock = true;
    clock_format = "24h";
  } // cfg.settings;

  builderConfig = {
    esp = config.boot.loader.efi.efiSysMountPoint;
    package = "${cfg.package}";
    inherit efiArch;
    configurationLimit = cfg.configurationLimit;
    timeout = if config.boot.loader.timeout == null then -1 else config.boot.loader.timeout;
    windowsChainload = cfg.windowsChainload;
    touchEfiVars = config.boot.loader.efi.canTouchEfiVariables;
    entryName = cfg.entryName;
    settings = effectiveSettings;
    extraConfig = cfg.extraConfig;
    efibootmgr = "${pkgs.efibootmgr}/bin/efibootmgr";
    findmnt = "${pkgs.util-linux}/bin/findmnt";

    assets = {
      wallpaper = optionalMedia cfg.wallpaper;
      logo = optionalMedia cfg.logo;
      introMedia = optionalMedia cfg.introMedia;
      menuSound = if cfg.menuSound != null then "${cfg.menuSound}" else null;
      icons = lib.mapAttrs (_: p: "${p}") cfg.icons;
      themes = lib.mapAttrs
        (name: val:
          if themeIsFile val then "${val}"
          else "${pkgs.writeText "visor-theme-${name}.conf" val}")
        cfg.themes;
      activeTheme = cfg.theme;
      drivers = resolvedDrivers;
      extraFiles = lib.mapAttrs (_: p: "${p}") cfg.extraFiles;
    };
  };

  configFile = pkgs.writeText "visor-install-config.json" (builtins.toJSON builderConfig);

  visorInstaller = pkgs.writeShellScript "visor-install-wrapper" ''
    exec ${pkgs.python3}/bin/python3 ${./visor-install.py} ${configFile} "$@"
  '';
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

    drivers = lib.mkOption {
      type = lib.types.listOf (lib.types.enum [
        "ext2"
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

    extraFiles = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      example = lib.literalExpression ''{ "cursors/breeze.png" = ./assets/breeze.png; }'';
      description = "Additional files copied to relative paths under `\\EFI\\visor\\`.";
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

    boot.bootspec.enable = lib.mkDefault true;
    boot.loader.supportsInitrdSecrets = true;

    environment.systemPackages = [ cfg.package pkgs.efibootmgr ];

    system.build.installBootLoader = visorInstaller;
    system.boot.loader.id = "visor";
    system.boot.loader.kernelFile = pkgs.stdenv.hostPlatform.linux-kernel.target;
  };
}