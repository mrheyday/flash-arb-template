# Testing Guide

This guide explains the comprehensive test suite for the Flash Arbitrage contract.

## Test Overview

The test suite (`test/FlashArbitrage.t.sol`) includes **fork-based fuzz tests** that test the contract against real mainnet data at block 18,500,000.

## Test Categories

### 1. Uniswap V3 Quoting Tests

#### `testFuzz_UniswapV3Quoting`
- **Purpose**: Validates Uniswap V3 QuoterV2 integration
- **Fuzzing**: Tests with random input amounts (1 to 1000 tokens)
- **Checks**:
  - Quote returns positive values
  - Sanity checks on exchange rates
  - QuoterV2 behaves correctly for various amounts

#### `testFuzz_UniswapFeeTierComparison`
- **Purpose**: Compares quotes across different fee tiers
- **Fee Tiers Tested**:
  - 0.05% (500)
  - 0.3% (3000)
  - 1% (10000)
- **Checks**: All fee tiers return valid quotes

### 2. Balancer Dry-Run Tests

#### `testFuzz_BalancerDryRunCheck`
- **Purpose**: Tests Balancer's queryBatchSwap (dry-run) functionality
- **Key Feature**: Verifies no state changes occur during quote
- **Checks**:
  - Query returns positive amounts
  - No tokens transferred during query
  - Contract balances unchanged

#### `test_BalancerPoolTokens`
- **Purpose**: Validates Balancer pool configuration
- **Checks**:
  - Pool contains expected tokens
  - All tokens have liquidity
  - Token/balance arrays match

### 3. Profit Assertion Tests

#### `testFuzz_ProfitCalculation`
- **Purpose**: Calculates expected profits from round-trip swaps
- **Process**:
  1. Quote WETH -> USDC on Uniswap
  2. Quote USDC -> WETH back on Uniswap
  3. Calculate profit/loss percentage
- **Checks**:
  - Round-trip loss is reasonable (<10%)
  - Profit calculations are accurate

#### `testFuzz_ArbitrageDirection`
- **Purpose**: Tests both arbitrage directions
- **Scenarios**:
  - Buy on Balancer, sell on Uniswap
  - Buy on Uniswap, sell on Balancer
- **Checks**: Both directions produce valid quotes

### 4. Failure Case Tests

#### `testFuzz_FailureInsufficientProfit`
- **Purpose**: Tests that arbitrage reverts when profit is too low
- **Setup**: Creates impossible profit requirement (200% profit)
- **Expected**: Transaction reverts with InsufficientProfit error

#### `test_FailureZeroFlashAmount`
- **Purpose**: Tests validation of flash loan amount
- **Setup**: Attempts arbitrage with zero flash amount
- **Expected**: Transaction reverts with InvalidParams error

#### `test_FailureZeroAddressToken`
- **Purpose**: Tests validation of token addresses
- **Setup**: Attempts arbitrage with zero address token
- **Expected**: Transaction reverts with InvalidParams error

#### `testFuzz_FailureUnauthorized`
- **Purpose**: Tests access control
- **Setup**: Random address attempts to execute arbitrage
- **Expected**: Transaction reverts with Unauthorized error

### 5. Multi-Scenario Tests

#### `testFuzz_MultipleTokenPairs`
- **Purpose**: Tests various token combinations
- **Pairs Tested**:
  - WETH/USDC
  - WETH/DAI
  - USDC/DAI
- **Checks**: All pairs return valid quotes

#### `testFuzz_ExtremeAmounts`
- **Purpose**: Tests boundary conditions
- **Scenarios**:
  - Minimum amount (1 token)
  - Maximum amount (1000 tokens)
- **Checks**: System handles extremes gracefully

## Running Tests

### All Tests
```bash
forge test --fork-url $RPC_URL -vv
```

### Specific Test
```bash
forge test --fork-url $RPC_URL --match-test testFuzz_UniswapV3Quoting -vvv
```

### With Gas Report
```bash
forge test --fork-url $RPC_URL --gas-report
```

### Filter by Category
```bash
# Run only failure tests
forge test --fork-url $RPC_URL --match-test Failure -vv

# Run only fuzz tests
forge test --fork-url $RPC_URL --match-test Fuzz -vv
```

## Verbosity Levels

- `-v`: Show test results
- `-vv`: Show test results + logs
- `-vvv`: Show test results + logs + execution traces
- `-vvvv`: Show test results + logs + execution traces + setup traces
- `-vvvvv`: Show everything including storage changes

## Interpreting Results

### Successful Test Output
```
[PASS] testFuzz_UniswapV3Quoting(uint256) (runs: 256, μ: 123456, ~: 123456)
```

- `PASS`: Test passed
- `runs: 256`: Number of fuzz runs completed
- `μ`: Mean gas used
- `~`: Median gas used

### Failed Test Output
```
[FAIL. Reason: InsufficientProfit(100, 1000)] testFuzz_FailureInsufficientProfit(uint256)
```

- `FAIL`: Test failed
- `Reason`: Custom error or revert reason
- Parameters shown after test name

## Coverage

Get test coverage report:

```bash
forge coverage --fork-url $RPC_URL
```

Generate detailed HTML report:

```bash
forge coverage --fork-url $RPC_URL --report lcov
genhtml lcov.info -o coverage
open coverage/index.html
```

## Debugging Failed Tests

### View Full Traces
```bash
forge test --fork-url $RPC_URL --match-test testName -vvvv
```

### Debug Specific Run
```bash
# Use a specific seed for reproducible fuzz tests
forge test --fork-url $RPC_URL --fuzz-seed 42 -vvv
```

### Inspect State Changes
```bash
# Show all storage changes
forge test --fork-url $RPC_URL --match-test testName -vvvvv
```

## Fuzz Test Configuration

Configuration in `foundry.toml`:

```toml
[profile.default.fuzz]
runs = 256                  # Number of test cases per fuzz test
max_test_rejects = 65536    # Max rejections before giving up
seed = '0x1'                # Seed for reproducibility
```

Increase runs for more thorough testing:

```bash
forge test --fork-url $RPC_URL --fuzz-runs 10000
```

## Test Data

### Mainnet Addresses Used

```solidity
BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8
UNISWAP_QUOTER_V2 = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e
UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984

WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F
```

### Fork Block Number

Tests run at block **18,500,000** for consistency.

## Continuous Integration

Example GitHub Actions workflow:

```yaml
name: Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: foundry-rs/foundry-toolchain@v1
      - name: Run tests
        run: forge test --fork-url ${{ secrets.RPC_URL }}
        env:
          RPC_URL: ${{ secrets.RPC_URL }}
```

## Best Practices

1. **Always fork test**: Use `--fork-url` to test against real mainnet state
2. **Check gas costs**: Use `--gas-report` to monitor gas usage
3. **Test edge cases**: Fuzz tests help find unexpected behaviors
4. **Verify reverts**: Always test failure cases
5. **Document findings**: Add comments for unusual test results

## Troubleshooting

### RPC Rate Limits
If you hit rate limits:
- Use a paid RPC provider
- Add delays between tests
- Cache fork data with `--cache-path`

### Fork Sync Issues
If fork data is stale:
```bash
forge clean
forge test --fork-url $RPC_URL --force
```

### Test Timeouts
Increase timeout:
```bash
forge test --fork-url $RPC_URL --timeout 300
```

## Adding New Tests

Template for new fuzz test:

```solidity
function testFuzz_YourTestName(uint256 param1, address param2) public {
    // Bound parameters
    param1 = bound(param1, MIN_VALUE, MAX_VALUE);
    vm.assume(param2 != address(0));
    
    // Setup
    // ...
    
    // Execute
    // ...
    
    // Assert
    assertGt(result, 0, "Result should be positive");
}
```

## Resources

- [Foundry Book - Testing](https://book.getfoundry.sh/forge/tests)
- [Foundry Book - Fuzz Testing](https://book.getfoundry.sh/forge/fuzz-testing)
- [Foundry Book - Forking](https://book.getfoundry.sh/forge/fork-testing)
