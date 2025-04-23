# Haskell Consensus Protocols

A repository of distributed consensus protocol implementations in Haskell.

## Overview

This repository contains implementations of several distributed consensus algorithms, designed to study and compare their performance characteristics, fault tolerance, and behavior in various network conditions. The implementations focus on modern blockchain-style consensus protocols.

The following consensus protocols are implemented:

- **sleepyBlockDAG**: A directed acyclic graph (DAG) based consensus mechanism
- **Hotstuff**: A leader-based Byzantine Fault Tolerant (BFT) consensus protocol with linear communication complexity
- **Graded Proposal Election**: A multi-phase consensus protocol using graded consensus
- **GCP (Graded Consensus Protocol)**: A consensus protocol based on graded agreement

## Repository Structure
file:///home/asahi/Documents/Hans Dynamic DAG Meta-review.zip
The repository is organized into separate directories for each consensus protocol implementation:

```
.
├── bingbong/             # Simple ping-pong sample distributed application
├── gcp/                  # Graded Consensus Protocol implementation
├── gradedProposalElection/ # Multi-phase consensus protocol
├── hotstuff/             # Leader-based BFT consensus protocol
├── sleepyBlockDAG/       # DAG-based consensus protocol
├── cabal.project         # Project configuration for building
├── run.py                # Python script for running experiments
├── runGCP.py             # Python script for GCP protocol experiments
├── plot.py               # Python script for plotting results
└── plotGCP.py            # Python script for plotting GCP results
```

Each protocol implementation consists of:
- **[Protocol].hs**: Main implementation file
- **ConsensusLogic.hs**: Core consensus algorithm logic
- **ConsensusDataTypes.hs**: Data structures for the consensus protocol
- **ParseOptions.hs**: Command-line argument parsing

## Protocol Details

### sleepyBlockDAG

A directed acyclic graph (DAG) based consensus protocol that allows for higher throughput by organizing blocks in a DAG structure rather than a linear chain. Nodes propose blocks that reference multiple parent blocks, allowing for parallel block creation.

### Hotstuff

A state-of-the-art BFT consensus protocol designed for blockchain systems with the following key features:
- Linear communication complexity (O(n))
- Three-phase commit process (prepare, pre-commit, commit)
- Leader-based block proposal
- View synchronization for leader rotation

### Graded Proposal Election

A multi-phase consensus protocol using graded agreement with the following phases:
1. Proposal phase
2. Echo phase
3. Tally phase
4. Vote phase
5. Decision phase

### GCP (Graded Consensus Protocol)

A consensus protocol based on graded agreement concepts with a simplified design compared to the full graded proposal election.

## Getting Started

### Prerequisites

- [GHC](https://www.haskell.org/ghc/) (Glasgow Haskell Compiler)
- [Cabal](https://www.haskell.org/cabal/) (Common Architecture for Building Applications and Libraries)
- [GHCup](https://www.haskell.org/ghcup/) (recommended for installing and managing GHC and Cabal)

### Installation

1. Clone the repository:
```bash
git clone https://github.com/hans-repo/haskell-consensus/
cd haskell-consensus
```

2. Install GHC and Cabal using GHCup:
```bash
curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh
ghcup install ghc --set recommended
ghcup install cabal latest
cabal update
```

### Building

Build all protocol implementations:
```bash
cabal v2-build all
```

Or build a specific protocol:
```bash
cabal v2-build sleepyBlockDAG
```

### Running Protocols

Run a specific protocol implementation:
```bash
cabal v2-run <protocol-name> -- [options]
```

For example:
```bash
cabal v2-run sleepyBlockDAG -- --replicas 10 --crashes 0 --time 10 --batchSize 2
```

Available options for each protocol include:
- `--replicas` or `-r`: Number of replicas in the network
- `--crashes` or `-c`: Number of faulty/crashed nodes to simulate
- `--time` or `-t`: Duration of the experiment in seconds
- `--batchSize` or `-b`: Number of commands per block
- `--host` or `-h`: Host address (default: "localhost")
- `--port` or `-p`: Port number (default: "4444")
- `--masterorslave` or `-m`: Run as master or slave (default: "slave")

## Distributed Execution

The protocols can be run in a distributed manner using the master/slave setup:

1. Start slave nodes on different machines:
```bash
cabal v2-run <protocol-name> -- -m slave --host <host-address> --port <port>
```

2. Start the master node:
```bash
cabal v2-run <protocol-name> -- -m master --host <master-address> --port <port> --replicas <num-replicas> --crashes <num-crashes> --time <experiment-time> --batchSize <batch-size>
```

## Running Experiments

The repository includes Python scripts for running automated experiments and plotting results:

### Running Batch Experiments
```bash
python run.py       # For sleepyBlockDAG experiments
python runGCP.py    # For GCP experiments
```

These scripts run multiple experiments with varying parameters (e.g., number of nodes, batch sizes) and save the results to log files.

### Plotting Results
```bash
python plot.py      # Plot results from sleepyBlockDAG and graded protocols
python plotGCP.py   # Plot results from GCP protocol
```

The plotting scripts analyze the log files and generate graphs comparing performance metrics like throughput and latency.

## Research Results

The implementations in this repository can be used to study and compare different consensus protocols. Key metrics that can be evaluated include:

- **Throughput**: Number of commands/transactions processed per second
- **Latency**: Time from command proposal to commit
- **Scalability**: How performance scales with increasing number of nodes
- **Fault Tolerance**: How the protocol performs under node failures

Experiment results are saved in the `results` directory under each protocol's folder.

## Contributing

Contributions to improve the implementations or add new consensus protocols are welcome. Please feel free to submit pull requests or open issues for discussion.

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Acknowledgments

The implementations in this repository are based on academic research papers on distributed consensus protocols.
