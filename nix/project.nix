{ inputs, pkgs, lib }:

let
  cabalProject = pkgs.haskell-nix.cabalProject' (
    
    { config, pkgs, ... }:

    {
      name = "my-project";

      compiler-nix-name = lib.mkDefault "ghc967";

      # BEGIN union source only
      # (install.sh replaces this whole block with a plain
      # `src = lib.cleanSource ../.;` for Nix/Demeter projects, which carry
      # neither the pkg-config stanza in cabal.project nor a shim to strip)
      src = lib.cleanSourceWith {
        src = lib.cleanSource ../.;
        filter = path: type: baseNameOf path != "cabal.project.local";
      };

      cabalProject = builtins.replaceStrings
        [ "program-locations\n  pkg-config-location: ./scripts/pkg-config" ]
        [ "" ]
        (builtins.readFile ../cabal.project);
      # END union source only

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
