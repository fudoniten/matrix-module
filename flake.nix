{
  description = "Matrix configuration module.";

  inputs = { nixpkgs.url = "nixpkgs/nixos-23.05"; };

  outputs = { self, nixpkgs, ... }: {
    nixosModules = rec {
      default = matrix;
      matrix = { ... }: { imports = [ ./matrix-module.nix ]; };
    };
  };
}
