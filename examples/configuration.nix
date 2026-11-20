{ inputs, pkgs, ... }:

{
  imports = [ inputs.visor-nix.nixosModules.default ];

  boot.loader = {
    efi.canTouchEfiVariables = true; # register Visor in UEFI NVRAM via efibootmgr
    efi.efiSysMountPoint = "/boot";  # FAT32 ESP mount point
    timeout = 5;                     # seconds before auto-boot (null = wait forever, 0 = instant)
  };

  boot.loader.visor = {
    enable = true;
    # package = ...;                     # override Visor package built from visor-src
    configurationLimit = 10;             # max NixOS generations in menu and /boot/EFI/nixos/
    defaultEntry = 0;                    # 0-based default boot entry index
    entryName = "NixOS #{gen} ({date})"; # placeholders: {gen}, {date}, {label}
    windowsChainload = true;             # auto-add Windows if found on the same ESP (/boot)

    clockSync = {
      enable = true;  # systemd timer writing \EFI\visor\time.sync (adds local TZ offset if RTC is UTC)
      syncRtc = false; # also run `hwclock --systohc` during sync
    };

    # Optional: EfiFs drivers for Btrfs snapshot auto-detect and rescue file browser
    # ("ext2", "ext3", "ext4", "btrfs", "xfs", "ntfs", "exfat", "f2fs", "zfs", "iso9660", "squash4")
    # drivers = [ "btrfs" "ext4" ];
    # driversPackage = ...;
    # extraDrivers = {
    #   "btrfs_x64.efi" = pkgs.fetchurl {
    #     url = "https://github.com/pbatard/EfiFs/releases/download/v1.13/btrfs_x64.efi";
    #     hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    #   };
    # };

    # Optional: declarative media, icons, themes & companion files
    # wallpaper = ./assets/wallpaper.png; # background image/video (PNG, BMP, GIF, MJPEG MP4, VBG)
    # splashImage = ./assets/splash.png;  # still splash frame during autoboot handoff
    # logo = ./assets/logo.png;           # header logo (PNG, BMP)
    # introMedia = ./assets/intro.gif;    # one-shot boot intro media
    # cursor = ./assets/breeze.png;       # custom square mouse pointer image (PNG, BMP)
    # menuSound = ./assets/startup.wav;   # startup 16-bit PCM WAV (up to 4s)
    # snapshotsFile = ./assets/snapshots.conf; # Btrfs snapshot manifest (\EFI\visor\snapshots.conf)
    # extraFiles = { "rec.arm" = pkgs.emptyFile; };

    # icons = {
    #   nixos = ./assets/icons/nixos.png;
    #   windows = ./assets/icons/windows.png;
    #   power_shutdown = ./assets/icons/shutdown.png;
    #   power_reboot = ./assets/icons/reboot.png;
    #   power_firmware = ./assets/icons/firmware.png;
    # };

    # themes = {
    #   catppuccin = ''
    #     title_color=#CBA6F7
    #     name_color=#CDD6F4
    #     highlight_color=#CBA6F7
    #     bg_color=#1E1E2E
    #     blur=1
    #   '';
    # };
    # theme = "catppuccin"; # active theme name, "random", or "cycle"

    nixosEntry = {
      priority = 0;                        # menu order priority (lower appears first)
      color = "#7AA2F7";                   # per-entry label color (#RRGGBB or #RRGGBBAA)
      # iconSize = 128;                    # per-entry icon size in px
      # uuid = "xxxx-xxxx-...";            # pin ESP partition PARTUUID
      pinSha256 = false;                   # compute and pin SHA-256 hash of each NixOS kernel
      luks = false;                        # prompt for LUKS passphrase and inject as initrd keyfile
      # luksKeyPath = "/crypto_keyfile.bin";
      # luksPreset = "systemd";            # "systemd" | "mkinitcpio" | "arch" | "dracut"
      # luksCmdline = null;                # manual kernel option (overrides luksPreset)
      # luksConfirm = false;               # ask for passphrase twice
      # luksVerbose = false;               # strip quiet/splash so retry prompts are visible
    };

    windowsEntry = {
      priority = 100;                      # set < 0 (e.g. -10) to place Windows before NixOS
      name = "Windows 11";
      # color = "#00A4EF";
      # iconSize = 128;
      # uuid = "xxxx-xxxx-...";
      # pinSha256 = false;
    };

    # Custom boot entries (Windows on a separate ESP, other distros, UKIs, Memtest86+, etc.)
    extraEntries = [
      # {
      #   priority = -10;                  # negative priority places this entry before NixOS (0)
      #   name = "Windows 11";
      #   icon = "\\EFI\\visor\\icons\\windows.png";
      #   kernel = "\\EFI\\Microsoft\\Boot\\bootmgfw.efi";
      #   uuid = "57dbb402-1302-4ef2-b613-e03b6eee1fa4"; # target ESP PARTUUID
      #   color = "#00A4EF";
      # }
      # {
      #   name = "Arch Linux";
      #   icon = "\\EFI\\visor\\icons\\arch.png";
      #   iconSize = 128;
      #   color = "#1793D1";
      #   kernel = "\\vmlinuz-linux";
      #   initrd = "\\initramfs-linux.img";
      #   cmdline = "root=PARTUUID=xxxx-xxxx-... rw quiet";
      #   uuid = "yyyy-yyyy-...";
      #   sha256 = null;
      #   encrypted = false;      # true if kernel and initrd are .venc containers
      #   kernelEncrypted = null; # override for kernel only
      #   initrdEncrypted = null; # override for initrd only
      #   luks = false;
      #   luksKeyPath = "/crypto_keyfile.bin";
      #   luksPreset = "mkinitcpio";
      #   luksCmdline = null;
      #   luksConfirm = false;
      #   luksVerbose = false;
      # }
    ];

    settings = {
      # Boot behaviour & self-heal
      autoboot = false;            # skip menu unless autoboot_key is pressed
      autoboot_key = "any";        # key to interrupt autoboot ("any", "V", "F2", "Esc", etc.)
      remember_last = false;       # remember last booted entry in NVRAM (overrides defaultEntry)
      quiet = true;                # hide "Booting..." and console log text during OS handoff
      editor = false;              # allow pressing 'e' to edit kernel cmdline for one boot
      windows_bootnext = false;    # boot Windows via firmware BootNext + reboot (BitLocker friendly)
      selfheal = true;             # repair missing NVRAM entry and \EFI\BOOT\BOOTX64.EFI fallback
      boot_order = "ensure";       # "off" | "ensure" | "first"
      restore_fallback = true;     # restore fallback binary if overwritten by Windows updates

      # Splash & discovery
      splash = false;              # paint still splash frame during autoboot handoff
      hotplug = true;              # live-detect bootable USB drives plugged in at the menu
      scan_existing = false;       # scan other already-plugged volumes when boot.conf has entries
      recovery_entries = false;    # auto-add "<name> (recovery)" entry for each Linux entry
      snapshots = 1;               # 1 = auto, "manifest" = snapshots.conf only, 0 = off

      # Display, layout & input
      text_menu = false;           # force plain text-console UI
      resolution = "native";       # "native", "max", or "WxH" (e.g. "1920x1080", "2560x1440")
      title = "Visor";             # header title ("none" to hide)
      show_names = true;           # show entry label under each icon
      center_info = true;          # show selected entry info/path at the bottom
      entries_per_page = 4;        # icons per page
      box_radius = 14;             # selection box corner radius in px
      mouse = true;                # enable mouse / touchpad / touchscreen pointer
      mouse_speed = 4;             # pointer speed (1..20)
      cursor_size = 24;            # custom cursor size in px (8..128, 0 = image width)
      cursor_hotspot = "0,0";      # click hotspot ("X,Y", "center", "topleft")
      log = true;                  # write diagnostics to \EFI\visor\boot.log

      # Logo, font & icon sizes
      logo_mode = "title";         # "title" | "only" | "above" | "none"
      logo_size = 96;              # logo size in px (0 = scale with title)
      logo_gap = 24;               # gap between logo and title in px
      title_size = 0;              # title font height in px (0 = auto)
      name_size = 28;              # entry label font height in px
      icon_size = 128;             # global icon size in px
      icon_spacing = 80;           # horizontal gap between icons in px

      # Selection underline & power actions
      underline_thickness = 6;     # selection bar height in px
      underline_length = 180;      # selection bar width in px
      power_position = "bottomright"; # "bottomright" | "bottomleft" | "topright" | "topleft"
      power_icon_size = 44;        # graphical power icon size in px

      # Blur, animation & intro
      blur = "clear";              # "0" (flat), "1" (frosted tint), or "clear" (glass blur)
      blur_title = false;          # blurred backing behind header title
      blur_color = "#FFFFFF";      # tint color for frosted blur
      animation = true;            # enable GUI fades and selection slides
      anim_speed = 8;              # selection animation speed (1..10)
      fade_speed = 10;             # screen fade-in / fade-out speed (1..10)
      intro_duration = 2000;       # intro duration in ms (max 5000)
      intro_loop = false;          # loop intro clip until intro_duration
      intro_auto_continue = true;  # false = wait for keypress after intro
      intro_action = "menu";       # "menu" | "boot"

      # Material You dynamic palette & colors
      accent = true;               # derive Material You palette from wallpaper
      accent_variant = "tonal";    # "tonal" | "neutral" | "content" | "fidelity" | "vibrant" | "expressive" | "monochrome"
      accent_underline = true;     # tint underline/highlight from palette
      accent_icons = true;         # tint power icons from palette
      accent_text = false;         # tint title/entry text from palette
      accent_os_icons = false;     # flatten OS icons to primary color
      accent_logo = "tertiary";    # tint logo with palette role or "#RRGGBB"
      # title_color = "#7AA2F7";
      # name_color = "#C0CAF5";
      # highlight_color = "#7AA2F7";
      # info_color = "on_surface_variant";
      # bg_color = "#1A1A2E";

      # Clock
      clock = true;                # enable clock (true/false, palette role, or "#RRGGBB")
      accent_clock = true;         # tint clock from palette
      clock_size = 48;             # clock height in px (0 = scale with title)
      clock_format = "24h";        # "24h" | "12h"
      clock_seconds = false;       # show seconds
      clock_position = "topright"; # "topright", "topleft", "topcenter", "bottomright", etc.
      clock_date = "iso";          # false/0, true/1, or "long" | "iso" | "dmy" | "mdy"
      clock_blur = false;          # frosted backing behind clock
      clock_shadow = true;         # drop shadow behind clock

      # Screensaver, recording, sound, TPM2 & systemd Boot Loader Interface
      screensaver = 60;            # idle seconds before dimming (0 = off)
      screensaver_blank = 600;     # idle seconds before blanking to black (0 = dim only)
      screensaver_clock = true;    # keep clock visible while dimmed
      record_seconds = 3;          # F10 GIF screen recording length in seconds (1..12)
      menu_sound_volume = 60;      # startup WAV volume percentage (0..100)
      tpm = true;                  # measure config and cmdline into TPM2 PCRs
      tpm_pcr_config = 5;          # PCR for boot.conf bytes
      tpm_pcr_cmdline = 12;        # PCR for kernel command line
      loader_vars = true;          # export/honor systemd Boot Loader Interface EFI variables
    };

    extraConfig = ""; # raw extra lines appended to boot.conf
  };
}