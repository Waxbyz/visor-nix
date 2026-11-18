{
  description = "NixOS module and installer for Visor BootManager";

  inputs = {
    visor-src = {
      url = "github:IO-ZetZor/Visor-BootManager";
      flake = false;
    };
    efifs-src = {
      url = "git+https://github.com/pbatard/EfiFs.git?submodules=1";
      flake = false;
    };
  };

  outputs = { self, visor-src, efifs-src }:
    let
      module = import ./visor.nix { inherit visor-src efifs-src; };
    in
    {
      nixosModules = {
        default = module;
        visor = module;
      };
    };
}
