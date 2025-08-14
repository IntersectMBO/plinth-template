# Plinth Template - Plutus Smart Contract Development

**ALWAYS follow these instructions first and only fallback to search or additional context gathering if the information here is incomplete or found to be in error.**

This is a template repository for Plutus smart contract development using Haskell. It provides example auction smart contracts and tools for generating Plutus script blueprints.

## Working Effectively

### Prerequisites and Setup
Use one of these development environments (listed in order of preference):

#### Option 1: Nix (Recommended)
- Install and configure Nix following [these instructions](https://github.com/input-output-hk/iogx/blob/main/doc/nix-setup-guide.md)
- Enter the development shell: `nix develop`
- **CRITICAL**: Initial Nix setup can take 30-60 minutes for downloading and building dependencies. NEVER CANCEL. Set timeout to 90+ minutes.

#### Option 2: Docker/Devcontainer
- Use the provided devcontainer: `ghcr.io/input-output-hk/devx-devcontainer:x86_64-linux.ghc96-iog`
- For VSCode: Install Dev Containers extension and open project in devcontainer
- For standalone Docker:
  ```bash
  docker run \
    -v /path/to/your-project:/workspaces/plinth-template \
    -w /workspaces/plinth-template \
    -it ghcr.io/input-output-hk/devx-devcontainer:x86_64-linux.ghc96-iog
  ```

#### Option 3: Manual Setup (Not Recommended)
- Requires GHC 9.6.x and Cabal 3.8+
- Follow [cardano-node installation instructions](https://developers.cardano.org/docs/get-started/cardano-node/installing-cardano-node/)

### Essential Build Commands

#### Bootstrap and Build
1. **Update package index** (requires network access to CHaP repository):
   ```bash
   cabal update
   ```
   - **TIMING**: Usually takes 1-3 minutes
   - **NOTE**: Requires access to `chap.intersectmbo.org`. If network access is limited, this step may fail with DNS resolution errors.

2. **Build all components**:
   ```bash
   cabal build all
   ```
   - **CRITICAL**: Build time ranges from 15-45 minutes depending on cache state. NEVER CANCEL. Set timeout to 60+ minutes.
   - **NEVER CANCEL**: First builds take significantly longer as dependencies are compiled.

3. **Build specific executables**:
   ```bash
   cabal build gen-auction-validator-blueprint
   cabal build gen-minting-policy-blueprint
   ```

#### Docker-based Build (Alternative)
If local environment has issues, use the Docker approach from CI:
```bash
docker run \
  -v ./.:/workspaces/plinth-template \
  -w /workspaces/plinth-template \
  -i ghcr.io/input-output-hk/devx-devcontainer:x86_64-linux.ghc96-iog \
  bash -ic "cabal update && cabal build all"
```
- **CRITICAL**: Total time including Docker image pull: 10-50 minutes. NEVER CANCEL. Set timeout to 75+ minutes.

## Testing and Validation

### No Unit Tests Available
- This template repository does not include automated test suites
- Validation is done through successful compilation and blueprint generation

### Manual Validation Scenarios
After making any changes, ALWAYS perform these validation steps:

#### 1. Compilation Validation
```bash
cabal build all
```
Ensure all components compile without errors.

#### 2. Blueprint Generation Validation
```bash
# Generate auction validator blueprint
cabal run gen-auction-validator-blueprint -- auction-validator.json

# Generate minting policy blueprint  
cabal run gen-minting-policy-blueprint -- minting-policy.json

# Verify generated files
ls -la auction-validator.json minting-policy.json
head -20 auction-validator.json  # Should show JSON with validator metadata
```
- **Expected Output**: JSON blueprint files should be created successfully in the current directory
- **File Size**: Each blueprint file should be several KB (typically 2-10 KB)
- **Content Validation**: Files should contain JSON with fields like "contractId", "preamble", "validators"
- **Example Content**: Blueprint should include "auction-validator" contract ID and Plutus script metadata

#### 3. Smart Contract Code Validation
- Review changes to `src/AuctionValidator.hs` and `src/AuctionMintingPolicy.hs`
- Ensure Plutus compiler pragmas are preserved (essential for on-chain compilation):
  ```haskell
  {-# OPTIONS_GHC -fplugin-opt PlutusTx.Plugin:target-version=1.0.0 #-}
  {-# OPTIONS_GHC -fno-unbox-strict-fields #-}
  ```
- Verify that any changes maintain the validator logic integrity
- Check that Template Haskell compilation markers remain intact:
  ```haskell
  $$(PlutusTx.compile [||auctionUntypedValidator||])
  ```

#### 4. Docker Environment Validation
```bash
# Test Docker environment has correct GHC version
docker run \
  -v ./.:/workspaces/plinth-template \
  -w /workspaces/plinth-template \
  -i ghcr.io/input-output-hk/devx-devcontainer:x86_64-linux.ghc96-iog \
  bash -ic "ghc --version"
```
- **Expected Output**: "The Glorious Glasgow Haskell Compilation System, version 9.6.6"

## Linting and Code Quality

### Available Linting Tools
The project includes configuration for:
- **HLint**: Haskell linter (`.hlint.yaml` - currently empty, uses defaults)
- **stylish-haskell**: Code formatter (`.stylish-haskell.yaml`)
- **fourmolu**: Alternative formatter (via Nix environment)

### Pre-commit Validation
```bash
# Format code (available in Nix environment)
stylish-haskell --config .stylish-haskell.yaml -i src/*.hs app/*.hs

# Lint code (available in Nix environment)  
hlint --hint .hlint.yaml src/ app/

# Alternative: Use fourmolu for formatting (Nix environment)
fourmolu --mode inplace src/ app/
```

**IMPORTANT**: These tools are primarily available in the Nix environment. In Docker/manual setups, they may not be available.

## Common Issues and Workarounds

## Common Issues and Workarounds

### Network Connectivity Issues
- **Problem**: `cabal update` fails with "Could not resolve host: chap.intersectmbo.org"
- **Root Cause**: CHaP (Cardano Haskell Packages) repository access required for Plutus dependencies
- **Primary Solution**: Use Docker-based build which may have better network access
- **Alternative**: Use Nix environment which may handle repository access more reliably
- **Document If Persistent**: If consistent failures occur, note in comments that CHaP access is required for builds

### GHC Version Compatibility  
- **Required**: GHC 9.6.x specifically (not 9.10.x or 9.12.x)
- **Problem**: System may have different GHC version installed
- **Solution**: Use Nix (`nix develop`) or Docker environments which provide correct GHC 9.6.6
- **Verification**: Run `ghc --version` in your environment - should show 9.6.x

### Build Cache Issues
- **Problem**: Builds taking excessively long (>60 minutes)
- **Solution**: Remove build cache and rebuild: `rm -rf dist-newstyle && cabal build all`
- **Prevention**: Use consistent build environment (Nix or Docker) to maintain cache

### Permission Denied Errors
- **Problem**: `cabal update` fails with "permission denied" on cache directories
- **Common Causes**: Running in restricted environments or mixed user permissions
- **Solution**: Use Docker environment which isolates filesystem permissions

### Docker Image Pull Issues
- **Problem**: Docker image pull hangs or fails
- **Solution**: Use explicit image pull: `docker pull ghcr.io/input-output-hk/devx-devcontainer:x86_64-linux.ghc96-iog`
- **Timing**: Initial image pull is ~2-5 GB, takes 5-15 minutes on good connections

## Common Tasks and Quick Reference

### Repo Exploration (Reference these outputs instead of running commands repeatedly)

#### Repository Root Structure
```
ls -la
total 144
drwxr-xr-x 8 runner docker  4096 .
drwxr-xr-x 3 runner docker  4096 ..
drwxr-xr-x 2 runner docker  4096 .devcontainer
drwxr-xr-x 7 runner docker  4096 .git
drwxr-xr-x 4 runner docker  4096 .github
-rw-r--r-- 1 runner docker    80 .gitignore
-rw-r--r-- 1 runner docker     0 .hlint.yaml
-rw-r--r-- 1 runner docker 17675 .stylish-haskell.yaml
-rw-r--r-- 1 runner docker    69 CHANGELOG.md
-rw-r--r-- 1 runner docker    45 CODEOWNERS.md
-rw-r--r-- 1 runner docker  5522 CODE_OF_CONDUCT.md
-rw-r--r-- 1 runner docker   162 CONTRIBUTING.md
-rw-r--r-- 1 runner docker   170 DESCRIPTION.md
-rw-r--r-- 1 runner docker 11356 LICENSE.md
-rw-r--r-- 1 runner docker   560 NOTICE.md
-rw-r--r-- 1 runner docker  4361 README.md
-rw-r--r-- 1 runner docker   875 SECURITY.md
drwxr-xr-x 2 runner docker  4096 app
-rw-r--r-- 1 runner docker   959 cabal.project
-rw-r--r-- 1 runner docker 23035 flake.lock
-rw-r--r-- 1 runner docker  1193 flake.nix
drwxr-xr-x 2 runner docker  4096 nix
-rw-r--r-- 1 runner docker  1196 plinth-template.cabal
drwxr-xr-x 2 runner docker  4096 src
```

#### Source Code Files
```
ls -la src/ app/
app/:
GenAuctionValidatorBlueprint.hs    # Executable: Generates auction validator blueprint
GenMintingPolicyBlueprint.hs       # Executable: Generates minting policy blueprint

src/:
AuctionMintingPolicy.hs            # Smart contract: Token minting policy
AuctionValidator.hs                # Smart contract: Main auction validator logic
```

#### Build Configuration Summary
- **Project Name**: plinth-template
- **GHC Version**: 9.6.x (enforced by Nix/Docker environments)  
- **Cabal Version**: 3.8+ recommended
- **Dependencies**: Plutus libraries (plutus-core, plutus-ledger-api, plutus-tx)
- **Repository Access**: Requires CHaP (chap.intersectmbo.org) for Plutus dependencies

## Repository Structure and Key Files

### Important Directories
```
├── src/                          # Haskell source files
│   ├── AuctionValidator.hs       # Main auction smart contract
│   └── AuctionMintingPolicy.hs   # Token minting policy
├── app/                          # Executable applications
│   ├── GenAuctionValidatorBlueprint.hs    # Blueprint generator
│   └── GenMintingPolicyBlueprint.hs       # Minting policy blueprint
├── nix/                          # Nix configuration
├── .devcontainer/                # Docker devcontainer setup
└── .github/workflows/            # CI pipeline definitions
```

### Key Configuration Files
- `plinth-template.cabal`: Project dependencies and build configuration
- `cabal.project`: Cabal project settings and package repositories
- `flake.nix`: Nix development environment definition
- `.devcontainer/devcontainer.json`: Docker development environment

### After Making Changes
1. **ALWAYS** build and validate using the steps above
2. **ALWAYS** test blueprint generation for affected smart contracts  
3. **NEVER** commit without ensuring compilation succeeds
4. Document any new dependencies or build requirements in these instructions

## Timing Expectations Summary

| Operation | Expected Time | Timeout Setting | Critical Notes |
|-----------|---------------|-----------------|----------------|
| `nix develop` (first time) | 30-60 minutes | 90+ minutes | NEVER CANCEL - Downloads entire toolchain |
| `cabal update` | 1-3 minutes | 10 minutes | Requires CHaP network access |
| `cabal build all` (first time) | 15-45 minutes | 60+ minutes | NEVER CANCEL - Compiles all dependencies |
| `cabal build all` (cached) | 2-10 minutes | 15 minutes | Much faster with existing cache |
| Docker image pull | 5-15 minutes | 30 minutes | One-time download |
| Blueprint generation | 30 seconds - 2 minutes | 5 minutes | Fast once dependencies built |

**CRITICAL REMINDER**: Plutus/Cardano builds are notoriously slow. Patience is essential. NEVER CANCEL long-running build operations.