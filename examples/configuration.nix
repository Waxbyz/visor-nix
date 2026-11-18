{ config, pkgs, ... }:

{
  # Import the module directly, or use inputs.visor-nixos.nixosModules.default in a flake
  imports = [ ../visor.nix ];

  # Disable other bootloaders before enabling Visor
  boot.loader.systemd-boot.enable = false;
  boot.loader.grub.enable = false;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.timeout = 5;

  boot.loader.visor = {
    enable = true;
    configurationLimit = 10;
    entryName = "NixOS #{gen} ({date})";
    windowsChainload = true;

    # Optional: build EfiFs drivers for Visor's file browser or Btrfs snapshot auto-detection
    # drivers = [ "btrfs" "ext4" ];

    # Optional: declarative media assets (paths are copied to the Nix store automatically)
    # wallpaper = ./assets/wallpaper.png;
    # logo = ./assets/logo.png;
    # introMedia = ./assets/intro.gif;
    # menuSound = ./assets/startup.wav;

    # Optional: custom PNG icons -> \EFI\visor\icons\<name>.png
    # icons = {
    #   nixos = ./assets/icons/nixos.png;
    #   windows = ./assets/icons/windows11.png;
    #   power_shutdown = ./assets/icons/shutdown.png;
    #   power_reboot = ./assets/icons/reboot.png;
    #   power_firmware = ./assets/icons/uefi.png;
    # };

    # Declarative themes -> \EFI\visor\themes\<name>.conf
    themes = {
      tokyo-night = ''
        title_color=#7AA2F7
        name_color=#C0CAF5
        highlight_color=#7AA2F7
        bg_color=#1A1B26
        blur=clear
        blur_title=1
        box_radius=14
      '';
    };
    theme = "tokyo-night";

    # Typed global boot.conf settings (booleans convert to 1/0)
    settings = {
      resolution = "1920x1080";
      show_names = true;
      center_info = true;
      accent = true;
      clock = true;
      clock_format = "24h";
      editor = false;
    };

    # Extra raw lines appended to boot.conf
    extraConfig = ''
      windows_bootnext=1
    '';
  };
}
