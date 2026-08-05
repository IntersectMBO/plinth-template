# Plinth Template (Docker edition)

A template for your Plinth smart contract project, set up for **Docker**
(VSCode devcontainers, GitHub Codespaces, or a standalone container).

The container image (`ghcr.io/input-output-hk/devx-devcontainer`) ships the
full toolchain, including the three Cardano crypto C libraries the project
needs — `libsodium` (VRF-patched), `libsecp256k1` and `libblst` — all
provided via nix inside the image; there is nothing to install on your
system besides Docker itself.

## 1. Choose how to run it

- **Devcontainer:**
  1. Make sure to have [VSCode](https://code.visualstudio.com/) installed with
     the [Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)
     extension.
  2. Open this project in VSCode and accept "Reopen in Container".

- **Codespaces:** push this project to GitHub, then:
  `Code -> Codespaces -> Create codespace`.

- **Standalone Docker:** from the project directory, run:

  ```
  docker run \
    -v "$PWD:/workspaces/my-project" \
    -w /workspaces/my-project \
    -it ghcr.io/input-output-hk/devx-devcontainer:x86_64-linux.ghc96-iog
  ```

  Before running the command, you may want to replace `my-project` (in both
  places) with your actual project name; it is only the name of the folder
  the project is mounted under inside the container.

> NOTE:
> You can modify your [`devcontainer.json`](./.devcontainer/devcontainer.json)
> file to customize the container (more info
> [here](https://github.com/input-output-hk/devx?tab=readme-ov-file#vscode-devcontainer--github-codespace-support)).

> NOTE (for Linux users):
> If `docker run` fails with "permission denied while trying to connect to the
> Docker daemon socket", your user is not in the `docker` group. Rather than
> falling back to `sudo docker`, follow Docker's
> [post-installation steps](https://docs.docker.com/engine/install/linux-postinstall/):
> `sudo usermod -aG docker $USER`, then log out and back in.

> NOTE (for Windows users):
> It is recommended to install and run Docker on your native OS. If you want
> to run Docker Desktop inside a VM, read through
> [these notes](https://docs.docker.com/desktop/setup/vm-vdi/).

> NOTE:
> The devcontainer image is currently published for **x86_64-linux with
> GHC 9.6 only**. It runs on Apple Silicon through Docker's emulation
> (slower). For GHC 9.12 or native ARM, use the Nix setup instead.

## 2. Build

In the container's terminal:

```
cabal update
cabal build all
```

## 3. Run the example application

Read [Example: An Auction Smart Contract](https://plutus.cardano.intersectmbo.org/docs/category/example-an-auction-smart-contract)
to get started.
