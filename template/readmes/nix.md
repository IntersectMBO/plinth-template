# Plinth Template (Nix edition)

A template for your Plinth smart contract project, set up for **Nix**.

Plinth currently supports GHC `9.6.x` and `9.12.x`.

## 1. Set up Nix

Follow [these instructions](https://github.com/input-output-hk/iogx/blob/main/doc/nix-setup-guide.md)
to install and configure nix, **even if you already have it installed** — the
configuration step enables IOG's binary caches, without which the first build
compiles GHC from source and takes hours.

> NOTE (for Windows users):
> Make sure to have [WSL2](https://learn.microsoft.com/en-us/windows/wsl/install#upgrade-version-from-wsl-1-to-wsl-2)
> and the [WSL](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-wsl)
> VSCode extension (if using VSCode) installed before the Nix setup.

## 2. Enter the shell and build

```
nix develop
cabal build all
```

GHC 9.6 is the default. For GHC 9.12 use `nix develop .#ghc912`.

The three Cardano crypto C libraries the project needs — `libsodium`
(VRF-patched), `libsecp256k1` and `libblst` — are provided automatically by
the nix shell; there is nothing to install on your system.

> NOTE:
> The nix files inside this template follow the [`iogx` template](https://github.com/input-output-hk/iogx),
> but you can delete and replace them with your own. In that case, you might
> want to include the [`devx` flake](https://github.com/input-output-hk/devx)
> in your flake inputs as a starting point to supply all the necessary
> dependencies, making sure to use one of the `-iog` flavors.

## 3. Run the example application

Read [Example: An Auction Smart Contract](https://plutus.cardano.intersectmbo.org/docs/category/example-an-auction-smart-contract)
to get started.
