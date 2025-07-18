# Plinth Template Repository 

A template repository for your Plinth smart contract project.

Plinth currently supports GHC `v9.6.x`. Cabal `v3.8+` is recommended.

### 1. Create the repository

- From the command line:

  ```
  gh repo create my-project --private --template IntersectMBO/plinth-template
  ```

- Or from the [GitHub web page](https://github.com/IntersectMBO/plinth-template), click the top-right green button:

  `Use this template -> Create new repository`

- Or just fork/clone `plinth-template` (but note that this is a template repository)

  More information on GitHub template repositories can be found [here](https://docs.github.com/en/repositories/creating-and-managing-repositories/creating-a-repository-from-a-template).

### 2. Setup your development environment

- With Nix (**recommended**)

  Follow [these instructions](https://github.com/input-output-hk/iogx/blob/main/doc/nix-setup-guide.md) to install and configure nix, *even if you already have it installed*.

  Then enter the shell using `nix develop`.

  The nix files inside this template follow the [`iogx` template](https://github.com/input-output-hk/iogx), but you can delete and replace them with your own. In that case, you might want to include the [`devx` flake](https://github.com/input-output-hk/devx/issues) in your flake inputs as a starting point to supply all the necessary dependencies, making sure to use one of the `-iog` flavours.

- With Docker / Devcontainers / Codespaces

  From the [GitHub web page](https://github.com/IntersectMBO/plinth-template), click the top-right green button:

  `Use this template -> Open in a codespace`

  Or let VSCode create a local codespace for you when you open this project.

  You can modify your [`devcontainer.json`](./.devcontainer/devcontainer.json) file to customize the container (more info [here](https://github.com/input-output-hk/devx?tab=readme-ov-file#vscode-devcontainer--github-codespace-support)).

  Or using your local docker installation (change the `/path/to/my-project` accordingly):
  ```
  docker run \
    -v /path/to/my-project:/workspaces/my-project \
    -it ghcr.io/input-output-hk/devx-devcontainer:x86_64-linux.ghc96-iog
  ```

  When using this approach, you can ignore/delete/replace the nix files entirely.

- With manually-installed dependencies (**not recommended**)

  Follow the instructions for [cardano-node](https://developers.cardano.org/docs/get-started/cardano-node/installing-cardano-node/) for a custom setup.

  When using this approach, you can ignore/delete/replace the nix files entirely.

### 3. Run the example application

Run `cabal update` first, then read [Example: An Auction Smart Contract](https://plutus.cardano.intersectmbo.org/docs/category/example-an-auction-smart-contract) to get started.
