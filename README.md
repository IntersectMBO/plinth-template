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

<details>
  <summary> With Nix (<b>recommended</b>) </summary>

  1. Follow [these instructions](https://github.com/input-output-hk/iogx/blob/main/doc/nix-setup-guide.md) to install and configure nix, <b>even if you already have it installed</b>.
     
  2. Then enter the shell using `nix develop`.

  > NOTE:  
  > The nix files inside this template follow the [`iogx` template](https://github.com/input-output-hk/iogx), but you can delete and replace them with your own. In that case, you might want to include the [`devx` flake](https://github.com/input-output-hk/devx/issues) in your flake inputs as a starting point to supply all the necessary dependencies, making sure to use one of the `-iog` flavors.

  > NOTE (for Windows users):<br>
  > Make sure to have [WSL2](https://learn.microsoft.com/en-us/windows/wsl/install#upgrade-version-from-wsl-1-to-wsl-2) and the [WSL](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-wsl) VSCode extension (if using VSCode) installed before the Nix setup.
</details>

<details>
  <summary> With Docker / Devcontainer / Codespaces </summary>
  
  - **Docker + Codespaces:** From the [GitHub web page](https://github.com/IntersectMBO/plinth-template), click the top-right green button:

    `Use this template -> Open in a codespace`

  - **Docker + Devcontainer:**
    1. Make sure to have [VSCode](https://code.visualstudio.com/) installed with the [Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) extension.
    2. Open this project in VSCode and let it create a local codespace for you (See Dev Containers instructions, if needed).

  - **Stand-alone Docker:** Change the `/path/to/my-project` accordingly and run:

  ```
    docker run \
      -v /path/to/my-project:/workspaces/my-project \
      -it ghcr.io/input-output-hk/devx-devcontainer:x86_64-linux.ghc96-iog
  ```

  > NOTE:
  > You can modify your [`devcontainer.json`](./.devcontainer/devcontainer.json) file to customize the container (more info [here](https://github.com/input-output-hk/devx?tab=readme-ov-file#vscode-devcontainer--github-codespace-support)).

  > NOTE:  
  > When using this approach, you can ignore/delete/replace the Nix files entirely.

  > NOTE (for Windows users):<br>
  > It is recommended to install and run Docker on your native OS. If you want to run Docker Desktop inside a VM, read through [these notes](https://docs.docker.com/desktop/setup/vm-vdi/).
</details>

<details>
  <summary> With Demeter </summary>
  
  1. Create an account in [Demeter](https://demeter.run/).
  
  2. Follow [their instructions](https://docs.demeter.run/guides/getting-started) to setup a remote development environment.

  > IMPORTANT:  
  > Demeter uses its own infrastructure and packages. If something is not working correctly, please contact them before creating an issue.

  > NOTE:  
  > When using this approach, you can ignore/delete/replace the Nix files entirely.
</details>

<details>
  <summary> With manually-installed dependencies (<b>not recommended</b>) </summary>
  <br>
  
  Follow the instructions for [cardano-node](https://developers.cardano.org/docs/get-started/cardano-node/installing-cardano-node/) for a custom setup.

  > NOTE:  
  > When using this approach, you can ignore/delete/replace the Nix files entirely.
</details>

### 3. Run the example application

Run `cabal update` first, then read [Example: An Auction Smart Contract](https://plutus.cardano.intersectmbo.org/docs/category/example-an-auction-smart-contract) to get started.
