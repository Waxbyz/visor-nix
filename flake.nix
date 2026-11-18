{
  description = "NixOS module and installer for Visor BootManager";

  outputs = { self }: {
    nixosModules = {
      default = import ./visor.nix;
      visor = import ./visor.nix;
    };
  };
}
