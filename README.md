# visor-nix

NixOS module and declarative installer for [Visor-BootManager](https://github.com/IO-ZetZor/Visor-BootManager).

## Features

- **Flake-managed upstream sources:** Tracks `Visor-BootManager` and `EfiFs` via `flake.lock` with no manual hash pinning.
- **NixOS generation management:** Reads Bootspec (`boot.json`), `specialisations`, `system-profiles`, and `initrdSecrets`, deploys kernels/initrds atomically to `\EFI\nixos\`, and garbage-collects unreferenced files.
- **Full `boot.conf` coverage:** Configure any global Visor option through typed `settings` or `extraConfig`, plus `defaultEntry`, `entryName`, `configurationLimit`, `quiet`, `resolution`, `blur`, `accent`, `screensaver`, `tpm`, and `loader_vars`.
- **Media, icons & themes:** Declaratively deploy `wallpaper`, `splashImage`, `logo`, `introMedia`, `cursor`, `menuSound`, `icons` (including `power_shutdown`, `power_reboot`, `power_firmware`), `themes`, and `extraFiles` with automatic cleanup of removed assets.
- **Per-entry customization & security:** Configure `nixosEntry`, `windowsEntry`, and custom `extraEntries` with `color`, `iconSize`, `uuid` (PARTUUID), automatic `pinSha256`, `.venc` encryption flags, and LUKS keyfile injection (`luks`, `luksPreset`, `luksCmdline`, `luksConfirm`, `luksVerbose`).
- **EfiFs drivers & Btrfs snapshots:** Build drivers from source via `drivers` (e.g. `btrfs`, `ext4`, `ntfs`) or supply prebuilt `.efi` files via `extraDrivers`, plus optional `snapshotsFile` (`\EFI\visor\snapshots.conf`).
- **UTC-aware clock sync:** `clockSync.enable` runs a systemd timer writing `\EFI\visor\time.sync` (automatically accounting for `config.time.hardwareClockInLocalTime` so UTC BIOS clocks display local time in Visor).

## Installation

Add `visor-nix` to your system `flake.nix`:

```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    visor-nix.url = "github:Waxbyx/visor-nix";
  };

  outputs = { nixpkgs, visor-nix, ... }: {
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        visor-nix.nixosModules.default
      ];
    };
  };
}
```

> **Note:** `visor-nix` does not have a `nixpkgs` input, so you do not need `inputs.nixpkgs.follows = "nixpkgs";`.

## Configuration

Minimal setup in `configuration.nix`:

```nix
{
  boot.loader.visor = {
    enable = true;
    configurationLimit = 10;
    entryName = "NixOS #{gen} ({date})";
    windowsChainload = true;

    # Optional: media & theming
    wallpaper = ./assets/wallpaper.png;
    splashImage = ./assets/splash.png;
    logo = ./assets/logo.png;
    introMedia = ./assets/intro.gif;
    cursor = ./assets/breeze.png;
    menuSound = ./assets/startup.wav;
    theme = "catppuccin";

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
```

See [examples/configuration.nix](examlpes/configuration.nix) for a complete example covering themes, LUKS, SHA-256 pinning, and EfiFs drivers.