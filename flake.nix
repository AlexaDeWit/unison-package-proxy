{
  description = "unison-proxy";

  nixConfig = {
    extra-substituters = [ "https://unison.cachix.org" ];
    extra-trusted-public-keys = [
      "unison.cachix.org-1:i1DUFkisRPVOyLp/vblDsbsObmyCviq/zs6eRuzth3k="
    ];
  };

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    unison-lang = {
      url = "github:ceedubs/unison-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, unison-lang }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        ucm = unison-lang.packages.${system}.ucm-bin;
      in {
        devShells.default = pkgs.mkShell {
          packages = [ ucm ];
        };
      }
    );
}
