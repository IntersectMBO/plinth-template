# Plinth Template (Demeter edition)

A template for your Plinth smart contract project, set up for
**[Demeter](https://demeter.run)**, a hosted Cardano development platform.

Demeter workspaces are cloud VSCode environments that come with **nix**
preinstalled. This project's own nix shell provides the entire toolchain,
including the three Cardano crypto C libraries it needs — `libsodium`
(VRF-patched), `libsecp256k1` and `libblst` — so there is nothing to
install on your machine.

## 1. Set up a workspace

1. Push this project to a GitHub repository.
2. Create an account at [demeter.run](https://demeter.run), create a
   Project, and add a **Workspace** resource pointing at your repository
   (pick the Haskell/Plutus stack). See
   [their documentation](https://docs.demeter.run) for details. You can
   also link directly to a workspace for your repository with:

   ```
   https://demeter.run/code?repository=<your-repo-url>&template=plutus
   ```

3. Press "Open VS Code".

> IMPORTANT:
> Demeter uses its own infrastructure and packages. If something is not
> working correctly, please contact them before creating an issue.

## 2. Build

In the workspace's terminal, enter this project's nix shell and build:

```
nix develop --accept-flake-config
cabal update      # first time only: fetches the hackage and CHaP package indexes
cabal build all
```

The first `nix develop` downloads the toolchain from IOG's binary cache
(`cache.iog.io`) and can take a while; afterwards it is instant. GHC 9.6 is
the default; `nix develop .#ghc912` gives you GHC 9.12.

> NOTE:
> Workspace files outside your home directory are lost when the workspace
> restarts; keep your work inside the cloned repository and push often.

## 3. Run the example application

Read [Example: An Auction Smart Contract](https://plutus.cardano.intersectmbo.org/docs/category/example-an-auction-smart-contract)
to get started.
