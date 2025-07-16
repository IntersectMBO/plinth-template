{ inputs, pkgs, lib }:

let
  cabalProject = pkgs.haskell-nix.cabalProject' (
    
    { config, pkgs, ... }:

    {
      name = "my-project";

      compiler-nix-name = lib.mkDefault "ghc966";

      src = lib.cleanSource ../.;

      flake.variants = {
        ghc966 = {}; # Alias for the default variant
      };

      inputMap = { "https://chap.intersectmbo.org/" = inputs.CHaP; };

      modules = [{
        packages = {};
      }];
    }
  );

in

cabalProject
