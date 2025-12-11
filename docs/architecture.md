# Architecture

This repository defines the core flash arbitrage contracts and off-chain tooling.

```mermaid
flowchart TD
    C[Contracts] --> |calls| E[Executor]
    E --> |flash loan| A[Aave V3]
