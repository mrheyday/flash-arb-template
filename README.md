# Flash Arbitrage Template

A comprehensive Foundry-based flash arbitrage template for multi-DEX arbitrage between Uniswap V3 and Balancer.

## Features

- ✅ **Flash Loan Integration**: Uses Balancer's zero-fee flash loans
- ✅ **Multi-DEX Support**: Integrates Uniswap V3 and Balancer
- ✅ **Comprehensive Testing**: Fork fuzz tests with failure cases and profit assertions
- ✅ **Uniswap V3 Quoting**: Real-time price quotes using QuoterV2
- ✅ **Balancer Dry-Run**: Query swap amounts without execution using queryBatchSwap
- ✅ **Safety Checks**: Minimum profit requirements and authorization controls

## Project Structure

```
flash-arb-template/
├── src/
│   ├── FlashArbitrage.sol          # Main arbitrage contract
│   └── interfaces/
│       ├── IERC20.sol               # ERC20 token interface
│       ├── IUniswapV3.sol           # Uniswap V3 interfaces
│       └── IBalancer.sol            # Balancer Vault interfaces
├── test/
│   └── FlashArbitrage.t.sol         # Comprehensive fuzz tests
├── foundry.toml                     # Foundry configuration
└── remappings.txt                   # Import remappings
```

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Ethereum RPC endpoint (Alchemy, Infura, or local node)

## Installation

```bash
# Clone the repository
git clone https://github.com/mrheyday/flash-arb-template.git
cd flash-arb-template

# Install Foundry if not already installed
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Install dependencies (forge-std will be installed automatically)
forge install
```

## Configuration

Create a `.env` file in the root directory:

```bash
# RPC URL for forking mainnet
RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_API_KEY

# Optional: Alchemy API key
ALCHEMY_API_KEY=YOUR_API_KEY
```

## Testing

### Run All Tests

```bash
forge test --fork-url $RPC_URL -vv
```

### Run Fuzz Tests

```bash
# Run with verbose output
forge test --fork-url $RPC_URL -vvv

# Run with gas reporting
forge test --fork-url $RPC_URL --gas-report

# Run specific test
forge test --fork-url $RPC_URL --match-test testFuzz_UniswapV3Quoting -vvv
```

### Test Coverage

The test suite includes:

1. **Uniswap V3 Quoting Tests**
   - `testFuzz_UniswapV3Quoting`: Tests QuoterV2 with various amounts
   - `testFuzz_UniswapFeeTierComparison`: Compares quotes across fee tiers

2. **Balancer Dry-Run Tests**
   - `testFuzz_BalancerDryRunCheck`: Verifies queryBatchSwap without execution
   - `test_BalancerPoolTokens`: Validates pool token configuration

3. **Profit Assertion Tests**
   - `testFuzz_ProfitCalculation`: Calculates expected profits from round-trip swaps
   - `testFuzz_ArbitrageDirection`: Tests both buy/sell directions

4. **Failure Case Tests**
   - `testFuzz_FailureInsufficientProfit`: Expects revert when profit too low
   - `test_FailureZeroFlashAmount`: Expects revert with zero amount
   - `test_FailureZeroAddressToken`: Expects revert with invalid token
   - `testFuzz_FailureUnauthorized`: Expects revert from non-owner

5. **Multi-Scenario Tests**
   - `testFuzz_MultipleTokenPairs`: Tests various token combinations
   - `testFuzz_ExtremeAmounts`: Tests boundary conditions

## Contract Overview

### FlashArbitrage.sol

The main contract implements:

- **Flash Loan Execution**: Borrows tokens via Balancer flash loans
- **Multi-DEX Trading**: Executes swaps on both Uniswap V3 and Balancer
- **Profit Verification**: Ensures minimum profit requirements are met
- **Quote Functions**: Retrieves price quotes without executing trades

#### Key Functions

```solidity
// Execute arbitrage with flash loan
function executeArbitrage(ArbitrageParams calldata params) external onlyOwner

// Get Uniswap V3 quote
function getUniswapQuote(address tokenIn, address tokenOut, uint256 amountIn, uint24 fee) 
    external returns (uint256 amountOut)

// Get Balancer quote (dry-run)
function getBalancerQuote(bytes32 poolId, address tokenIn, address tokenOut, uint256 amountIn) 
    external returns (uint256 amountOut)
```

## Usage Example

```solidity
// Setup arbitrage parameters
FlashArbitrage.ArbitrageParams memory params = FlashArbitrage.ArbitrageParams({
    tokenIn: WETH,
    tokenOut: USDC,
    uniswapPool: uniswapPoolAddress,
    uniswapFee: 3000, // 0.3%
    balancerPoolId: balancerPoolId,
    flashLoanAmount: 10 ether,
    minProfitAmount: 0.01 ether,
    buyOnBalancer: true
});

// Execute the arbitrage
arbitrage.executeArbitrage(params);
```

## Security Considerations

- ✅ Owner-only execution
- ✅ Minimum profit requirements
- ✅ Flash loan repayment guaranteed
- ✅ Comprehensive input validation
- ⚠️ **This is a template for educational purposes**
- ⚠️ **Always audit before mainnet deployment**
- ⚠️ **Test thoroughly on testnet first**

## Deployment

```bash
# Deploy to mainnet (example)
forge create --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY \
    src/FlashArbitrage.sol:FlashArbitrage \
    --constructor-args $BALANCER_VAULT $UNISWAP_QUOTER

# Verify on Etherscan
forge verify-contract \
    --chain-id 1 \
    --constructor-args $(cast abi-encode "constructor(address,address)" $BALANCER_VAULT $UNISWAP_QUOTER) \
    $CONTRACT_ADDRESS \
    src/FlashArbitrage.sol:FlashArbitrage \
    $ETHERSCAN_API_KEY
```

## Mainnet Addresses

```
Balancer Vault:       0xBA12222222228d8Ba445958a75a0704d566BF2C8
Uniswap Quoter V2:    0x61fFE014bA17989E743c5F6cB21bF9697530B21e
Uniswap V3 Factory:   0x1F98431c8aD98523631AE4a59f267346ea31F984
```

## License

MIT License - see LICENSE file for details

## Contributing

Contributions are welcome! Please open an issue or submit a pull request.

## Disclaimer

This code is provided as-is for educational purposes. Flash loan arbitrage involves significant risks including:
- Smart contract risk
- Market risk
- MEV competition
- Gas cost considerations

Always perform thorough testing and audits before deploying to mainnet.