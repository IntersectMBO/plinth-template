{ inputs, pkgs, lib }:

let
  cabalProject = pkgs.haskell-nix.cabalProject' (

    { config, pkgs, ... }:

    {
      name = "my-project";

      compiler-nix-name = lib.mkDefault "ghc967";

      src = lib.cleanSource ../.;

      flake.variants = {
        ghc96 = {}; # Alias for the default variant
        ghc912 = { compiler-nix-name = "ghc9122"; };
      };

      inputMap = { "https://chap.intersectmbo.org/" = inputs.CHaP; };

      modules = [{
        packages = {};
      }];
    }
  );

in

cabalProject
