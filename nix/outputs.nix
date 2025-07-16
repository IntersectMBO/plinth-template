{ inputs, system }:

let
  inherit (pkgs) lib;

  pkgs = import ./pkgs.nix { inherit inputs system; };

  utils = import ./utils.nix { inherit pkgs lib; };

  project = import ./project.nix { inherit inputs pkgs lib; };

  mkShell = ghc: import ./shell.nix { inherit inputs pkgs lib project utils ghc; };

  devShells.default = mkShell "ghc966"; 

  projectFlake = project.flake {};

  defaultHydraJobs = { 
    ghc966 = projectFlake.hydraJobs.ghc966;
    inherit packages; 
    inherit devShells;
    required = utils.makeHydraRequiredJob hydraJobs; 
  };

  hydraJobsPerSystem = {
    "x86_64-linux" = defaultHydraJobs; 
    "x86_64-darwin" = defaultHydraJobs;
    "aarch64-linux" = defaultHydraJobs; 
    "aarch64-darwin" = defaultHydraJobs;
  };

  hydraJobs = utils.flattenDerivationTree "-" hydraJobsPerSystem.${system};

  packages = { };

in

{
  inherit packages;
  inherit devShells;
  inherit hydraJobs;
}
