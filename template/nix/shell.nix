{ inputs, pkgs, lib, project, utils, ghc }:

let

  variant = project.projectVariants.${ghc};

  tools = {
    cabal                   = variant.tool "cabal" "latest";
    haskell-language-server = variant.tool "haskell-language-server" "latest";
    cabal-fmt               = project.tool "cabal-fmt" "latest";
    stylish-haskell         = project.tool "stylish-haskell" "latest";
    fourmolu                = project.tool "fourmolu" "latest";
    hlint                   = project.tool "hlint" "latest";
  };

  preCommitCheck = inputs.pre-commit-hooks.lib.${pkgs.system}.run {

    src = lib.cleanSources ../.;

    hooks = {
      shellcheck = {
        enable = false;
        package = pkgs.shellcheck;
      };
      nixpkgs-fmt = {
        enable = false;
        package = pkgs.nixpkgs-fmt;
      };
      cabal-fmt = {
        enable = false;
        package = tools.cabal-fmt;
      };
      stylish-haskell = {
        enable = false;
        package = tools.stylish-haskell;
        args = [ "--config" ".stylish-haskell.yaml" ];
      };
      fourmolu = {
        enable = false;
        package = tools.fourmolu;
        args = [ "--mode" "inplace" ];
      };
      hlint = {
        enable = false;
        package = tools.hlint;
        args = [ "--hint" ".hlint.yaml" ];
      };
    };
  };

  linuxPkgs = lib.optionals pkgs.hostPlatform.isLinux [
  ];

  darwinPkgs = lib.optionals pkgs.hostPlatform.isDarwin [
  ];

  commonPkgs = [
    tools.haskell-language-server
    tools.stylish-haskell
    tools.fourmolu
    tools.cabal
    tools.hlint
    tools.cabal-fmt

    pkgs.shellcheck
    pkgs.nixpkgs-fmt
    pkgs.github-cli
    pkgs.act
    pkgs.bzip2
    pkgs.gawk
    pkgs.zlib
    pkgs.cacert
    pkgs.curl
    pkgs.bash
    pkgs.git
    pkgs.which
  ];

  shell = variant.shellFor {
    name = "plinth-${variant.args.compiler-nix-name}";

    buildInputs = lib.concatLists [
      commonPkgs
      darwinPkgs
      linuxPkgs
    ];

    withHoogle = true;

    shellHook = ''
      ${preCommitCheck.shellHook}
      export PS1="\n\[\033[1;32m\][nix-shell:\w]\$\[\033[0m\] "
    '';
  };

in

shell
