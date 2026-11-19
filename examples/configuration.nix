{ inputs, pkgs, ... }:

{
  imports = [ inputs.visor-nixos.nixosModules.default ];

  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.efi.efiSysMountPoint = "/boot";
  boot.loader.timeout = 5;

  boot.loader.visor = {
    enable = true;
    configurationLimit = 10;
    entryName = "NixOS #{gen} ({date})";
    windowsChainload = true;

    # Optional: EfiFs drivers for Btrfs snapshots / file browser
    drivers = [ "btrfs" "ext4" ];

    # Optional: media & theming
    # wallpaper = ./assets/wallpaper.png;
    # splashImage = ./assets/splash.png;
    # logo = ./assets/logo.png;
    # introMedia = ./assets/intro.gif;
    # cursor = ./assets/breeze.png;
    # menuSound = ./assets/startup.wav;
    # theme = "catppuccin";

    # Optional: sync firmware RTC drift via systemd timer
    clockSync.enable = true;

    # Optional: per-entry LUKS / styling / SHA-256 pinning for NixOS generations
    nixosEntry = {
      color = "#7AA2F7";
      # pinSha256 = true;
      # luks = true;
      # luksPreset = "systemd";
      # luksConfirm = true;
    };

    # Optional: customize Windows entry
    windowsEntry = {
      name = "Windows 11";
      # color = "#00A4EF";
    };

    # Optional: custom boot entries (other distros, UKIs, Memtest, etc.)
    # extraEntries = [
    #   {
    #     name = "Memtest86+";
    #     kernel = "\\EFI\\tools\\memtest86+.efi";
    #   }
    # ];

    settings = {
      resolution = "native";
      entries_per_page = 4;
      blur = "clear";
      accent = true;
      accent_variant = "tonal";
      clock = true;
      clock_format = "24h";
      clock_date = "iso";
      screensaver = 60;
      tpm = true;
      loader_vars = true;
    };
  };
}