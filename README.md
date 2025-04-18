# Clone project
```
git clone https://github.com/hans-repo/haskell-consensus/
cd haskell-consensus
```

# Setting up the Environment
## Install GHC and Cabal:

Open a terminal and use `ghcup` to install the recommended version of GHC and the latest version of Cabal. Here are the detailed steps:

First, install GHCup itself. The following works on most Unix-like systems (Linux, macOS, WSL):

```
curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh
```

Then, follow the on-screen instructions provided by the installer. This usually involves closing and reopening your terminal.

Once ghcup is installed, you can install GHC and Cabal:

```
ghcup install ghc --set recommended
ghcup install cabal latest
```

`ghcup install ghc --set recommended` installs the GHC version that is currently recommended.

`ghcup install cabal latest` installs the latest version of Cabal.

Update Cabal Package List:

Update the list of available packages:

```
cabal update
```

# Build and run algorithms
Build all, or select specific algorithm to build.

```
cabal v2-build all
```
Run, here sleepyBlockDAG
```
cabal v2-run sleepyBlockDAG
```
