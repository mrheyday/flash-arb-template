# Flash Arbitrage Makefile

-include .env

.PHONY: help install build test clean deploy verify

# Default target
help:
	@echo "Flash Arbitrage Template - Available Commands:"
	@echo ""
	@echo "  make install      - Install dependencies"
	@echo "  make build        - Build contracts"
	@echo "  make test         - Run all tests"
	@echo "  make test-v       - Run tests with verbose output"
	@echo "  make test-vv      - Run tests with more verbose output"
	@echo "  make test-gas     - Run tests with gas report"
	@echo "  make coverage     - Generate coverage report"
	@echo "  make clean        - Clean build artifacts"
	@echo "  make format       - Format code"
	@echo "  make lint         - Lint code"
	@echo ""
	@echo "Fuzz Test Commands:"
	@echo "  make test-uniswap        - Test Uniswap quoting"
	@echo "  make test-balancer       - Test Balancer dry-run"
	@echo "  make test-profit         - Test profit calculations"
	@echo "  make test-failures       - Test failure cases"
	@echo "  make test-multi          - Test multiple scenarios"
	@echo ""

# Install dependencies
install:
	forge install foundry-rs/forge-std --no-commit

# Build contracts
build:
	forge build

# Run all tests
test:
	forge test --fork-url $(RPC_URL)

# Run tests with verbose output
test-v:
	forge test --fork-url $(RPC_URL) -v

test-vv:
	forge test --fork-url $(RPC_URL) -vv

test-vvv:
	forge test --fork-url $(RPC_URL) -vvv

# Run tests with gas report
test-gas:
	forge test --fork-url $(RPC_URL) --gas-report

# Specific test categories
test-uniswap:
	forge test --fork-url $(RPC_URL) --match-test testFuzz_Uniswap -vv

test-balancer:
	forge test --fork-url $(RPC_URL) --match-test Balancer -vv

test-profit:
	forge test --fork-url $(RPC_URL) --match-test Profit -vv

test-failures:
	forge test --fork-url $(RPC_URL) --match-test Failure -vv

test-multi:
	forge test --fork-url $(RPC_URL) --match-test Multiple -vv

# Coverage
coverage:
	forge coverage --fork-url $(RPC_URL)

coverage-report:
	forge coverage --fork-url $(RPC_URL) --report lcov
	genhtml lcov.info -o coverage
	@echo "Coverage report generated in coverage/index.html"

# Clean
clean:
	forge clean
	rm -rf coverage lcov.info

# Format code
format:
	forge fmt

# Lint code
lint:
	forge fmt --check

# Snapshot gas usage
snapshot:
	forge snapshot --fork-url $(RPC_URL)

# Update dependencies
update:
	forge update

# Local deployment simulation
deploy-local:
	forge script script/Deploy.s.sol --fork-url $(RPC_URL) -vvv

# Deployment (uncomment when ready)
# deploy-mainnet:
# 	forge script script/Deploy.s.sol --rpc-url $(RPC_URL) --private-key $(PRIVATE_KEY) --broadcast --verify

# Verify contract
# verify:
# 	forge verify-contract $(CONTRACT_ADDRESS) src/FlashArbitrage.sol:FlashArbitrage --chain-id 1 --etherscan-api-key $(ETHERSCAN_API_KEY)
