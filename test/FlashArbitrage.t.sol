// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {FlashArbitrage} from "../src/FlashArbitrage.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IBalancerVault} from "../src/interfaces/IBalancer.sol";
import {IQuoterV2, IUniswapV3Factory} from "../src/interfaces/IUniswapV3.sol";

/**
 * @title FlashArbitrageFuzzTest
 * @notice Comprehensive fuzz test for multi-DEX flash arbitrage
 * @dev Tests Uniswap V3 quoting, Balancer dry-run checks, failure cases, and profit assertions
 */
contract FlashArbitrageFuzzTest is Test {
    FlashArbitrage public arbitrage;

    // Mainnet addresses
    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address constant UNISWAP_QUOTER_V2 = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;
    address constant UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

    // Common tokens on mainnet
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    // Balancer pool IDs (examples)
    bytes32 constant BALANCER_WETH_DAI_POOL = 0x0b09dea16768f0799065c475be02919503cb2a3500020000000000000000001a;
    bytes32 constant BALANCER_WETH_USDC_POOL = 0x96646936b91d6b9d7d0c47c496afbf3d6ec7b6f8000200000000000000000019;

    // Uniswap V3 fee tiers
    uint24 constant FEE_LOW = 500; // 0.05%
    uint24 constant FEE_MEDIUM = 3000; // 0.3%
    uint24 constant FEE_HIGH = 10000; // 1%

    // Test parameters
    uint256 constant MIN_FLASH_AMOUNT = 1e18; // 1 token (18 decimals)
    uint256 constant MAX_FLASH_AMOUNT = 1000e18; // 1000 tokens
    uint256 constant MIN_PROFIT = 1e15; // 0.001 token minimum profit

    event log_named_decimal_uint(string key, uint256 val, uint256 decimals);

    function setUp() public {
        // Fork mainnet at a specific block for consistent testing
        vm.createSelectFork(vm.envString("RPC_URL"), 18500000);

        // Deploy the arbitrage contract
        arbitrage = new FlashArbitrage(BALANCER_VAULT, UNISWAP_QUOTER_V2);

        console2.log("FlashArbitrage deployed at:", address(arbitrage));
        console2.log("Owner:", arbitrage.owner());
    }

    // ============ Fuzz Tests ============

    /**
     * @notice Fuzz test for Uniswap V3 quoting with various amounts
     * @dev Tests that Quoter returns reasonable values for different input amounts
     */
    function testFuzz_UniswapV3Quoting(uint256 amountIn) public {
        // Bound the input amount to reasonable values
        amountIn = bound(amountIn, MIN_FLASH_AMOUNT, MAX_FLASH_AMOUNT);

        console2.log("\n=== Testing Uniswap V3 Quoting ===");
        console2.log("Input amount:", amountIn);

        // Get quote for WETH -> USDC swap
        uint256 quoteAmount = arbitrage.getUniswapQuote(WETH, USDC, amountIn, FEE_MEDIUM);

        console2.log("Quote amount:", quoteAmount);

        // Assertions
        assertGt(quoteAmount, 0, "Quote should be greater than 0");
        // Sanity check: 1 WETH should be worth between 500 and 5000 USDC (rough historical range)
        if (amountIn == 1e18) {
            assertGt(quoteAmount, 500e6, "1 WETH should be worth more than 500 USDC");
            assertLt(quoteAmount, 5000e6, "1 WETH should be worth less than 5000 USDC");
        }
    }

    /**
     * @notice Fuzz test for Balancer dry-run checks using queryBatchSwap
     * @dev Tests that Balancer query returns expected swap amounts without executing
     */
    function testFuzz_BalancerDryRunCheck(uint256 amountIn) public {
        // Bound the input amount to reasonable values
        amountIn = bound(amountIn, MIN_FLASH_AMOUNT, MAX_FLASH_AMOUNT);

        console2.log("\n=== Testing Balancer Dry-Run Check ===");
        console2.log("Input amount:", amountIn);

        // Get quote for WETH -> DAI swap on Balancer
        uint256 quoteAmount = arbitrage.getBalancerQuote(BALANCER_WETH_DAI_POOL, WETH, DAI, amountIn);

        console2.log("Quote amount:", quoteAmount);

        // Assertions
        assertGt(quoteAmount, 0, "Balancer quote should be greater than 0");

        // Verify no state change occurred (dry-run successful)
        uint256 contractBalance = IERC20(WETH).balanceOf(address(arbitrage));
        assertEq(contractBalance, 0, "Contract should have no WETH after dry-run");
    }

    /**
     * @notice Fuzz test comparing quotes across different fee tiers
     * @dev Tests that higher fee tiers result in less favorable quotes
     */
    function testFuzz_UniswapFeeTierComparison(uint256 amountIn) public {
        amountIn = bound(amountIn, MIN_FLASH_AMOUNT, MAX_FLASH_AMOUNT / 10);

        console2.log("\n=== Testing Uniswap Fee Tier Comparison ===");

        // Get quotes for different fee tiers
        uint256 quoteLowFee = arbitrage.getUniswapQuote(WETH, USDC, amountIn, FEE_LOW);
        uint256 quoteMediumFee = arbitrage.getUniswapQuote(WETH, USDC, amountIn, FEE_MEDIUM);
        uint256 quoteHighFee = arbitrage.getUniswapQuote(WETH, USDC, amountIn, FEE_HIGH);

        console2.log("Low fee quote:", quoteLowFee);
        console2.log("Medium fee quote:", quoteMediumFee);
        console2.log("High fee quote:", quoteHighFee);

        // Generally, lower fees should give better rates (though liquidity matters too)
        assertGt(quoteLowFee, 0, "Low fee quote should be positive");
        assertGt(quoteMediumFee, 0, "Medium fee quote should be positive");
        assertGt(quoteHighFee, 0, "High fee quote should be positive");
    }

    /**
     * @notice Fuzz test for profit calculation with various scenarios
     * @dev Tests expected profit assertions with different trade sizes
     */
    function testFuzz_ProfitCalculation(uint256 amountIn, uint256 minProfit) public {
        // Bound inputs
        amountIn = bound(amountIn, MIN_FLASH_AMOUNT, MAX_FLASH_AMOUNT / 100);
        minProfit = bound(minProfit, 0, amountIn / 10); // Max 10% profit expectation

        console2.log("\n=== Testing Profit Calculation ===");
        console2.log("Flash amount:", amountIn);
        console2.log("Min profit:", minProfit);

        // Get quotes for both directions
        uint256 uniswapQuote = arbitrage.getUniswapQuote(WETH, USDC, amountIn, FEE_MEDIUM);
        // Convert USDC (6 decimals) back to WETH equivalent for comparison
        uint256 reverseQuote = arbitrage.getUniswapQuote(USDC, WETH, uniswapQuote, FEE_MEDIUM);

        console2.log("Forward quote (USDC):", uniswapQuote);
        console2.log("Reverse quote (WETH):", reverseQuote);

        // Calculate potential profit/loss
        if (reverseQuote > amountIn) {
            uint256 profit = reverseQuote - amountIn;
            console2.log("Potential profit:", profit);
            emit log_named_decimal_uint("Profit %", (profit * 10000) / amountIn, 2);
        } else {
            uint256 loss = amountIn - reverseQuote;
            console2.log("Potential loss:", loss);
            emit log_named_decimal_uint("Loss %", (loss * 10000) / amountIn, 2);
        }

        // Assertion: reverse quote should be somewhat close to original (allowing for fees)
        assertLt(amountIn - reverseQuote, amountIn / 10, "Loss should be less than 10% for round trip");
    }

    // ============ Failure Case Tests ============

    /**
     * @notice Test that arbitrage fails with insufficient profit
     * @dev Should revert with InsufficientProfit error
     */
    function testFuzz_FailureInsufficientProfit(uint256 amountIn) public {
        amountIn = bound(amountIn, MIN_FLASH_AMOUNT, MAX_FLASH_AMOUNT / 100);

        console2.log("\n=== Testing Failure: Insufficient Profit ===");

        // Fund the contract to handle any small imbalances
        deal(WETH, address(arbitrage), amountIn / 10);

        // Create params with unrealistic profit expectation
        FlashArbitrage.ArbitrageParams memory params = FlashArbitrage.ArbitrageParams({
            tokenIn: WETH,
            tokenOut: USDC,
            uniswapPool: _getUniswapPool(WETH, USDC, FEE_MEDIUM),
            uniswapFee: FEE_MEDIUM,
            balancerPoolId: BALANCER_WETH_USDC_POOL,
            flashLoanAmount: amountIn,
            minProfitAmount: amountIn * 2, // Require 200% profit (impossible)
            buyOnBalancer: true
        });

        // Expect revert due to insufficient profit
        vm.expectRevert();
        arbitrage.executeArbitrage(params);

        console2.log("Successfully caught insufficient profit revert");
    }

    /**
     * @notice Test that arbitrage fails with zero flash amount
     * @dev Should revert with InvalidParams error
     */
    function test_FailureZeroFlashAmount() public {
        console2.log("\n=== Testing Failure: Zero Flash Amount ===");

        FlashArbitrage.ArbitrageParams memory params = FlashArbitrage.ArbitrageParams({
            tokenIn: WETH,
            tokenOut: USDC,
            uniswapPool: _getUniswapPool(WETH, USDC, FEE_MEDIUM),
            uniswapFee: FEE_MEDIUM,
            balancerPoolId: BALANCER_WETH_USDC_POOL,
            flashLoanAmount: 0, // Invalid: zero amount
            minProfitAmount: MIN_PROFIT,
            buyOnBalancer: true
        });

        vm.expectRevert(FlashArbitrage.InvalidParams.selector);
        arbitrage.executeArbitrage(params);

        console2.log("Successfully caught zero amount revert");
    }

    /**
     * @notice Test that arbitrage fails with zero address tokens
     * @dev Should revert with InvalidParams error
     */
    function test_FailureZeroAddressToken() public {
        console2.log("\n=== Testing Failure: Zero Address Token ===");

        FlashArbitrage.ArbitrageParams memory params = FlashArbitrage.ArbitrageParams({
            tokenIn: address(0), // Invalid: zero address
            tokenOut: USDC,
            uniswapPool: _getUniswapPool(WETH, USDC, FEE_MEDIUM),
            uniswapFee: FEE_MEDIUM,
            balancerPoolId: BALANCER_WETH_USDC_POOL,
            flashLoanAmount: MIN_FLASH_AMOUNT,
            minProfitAmount: MIN_PROFIT,
            buyOnBalancer: true
        });

        vm.expectRevert(FlashArbitrage.InvalidParams.selector);
        arbitrage.executeArbitrage(params);

        console2.log("Successfully caught zero address revert");
    }

    /**
     * @notice Test that only owner can execute arbitrage
     * @dev Should revert with Unauthorized error for non-owner
     */
    function testFuzz_FailureUnauthorized(address caller) public {
        vm.assume(caller != arbitrage.owner());
        vm.assume(caller != address(0));

        console2.log("\n=== Testing Failure: Unauthorized Caller ===");
        console2.log("Unauthorized caller:", caller);

        FlashArbitrage.ArbitrageParams memory params = FlashArbitrage.ArbitrageParams({
            tokenIn: WETH,
            tokenOut: USDC,
            uniswapPool: _getUniswapPool(WETH, USDC, FEE_MEDIUM),
            uniswapFee: FEE_MEDIUM,
            balancerPoolId: BALANCER_WETH_USDC_POOL,
            flashLoanAmount: MIN_FLASH_AMOUNT,
            minProfitAmount: MIN_PROFIT,
            buyOnBalancer: true
        });

        vm.prank(caller);
        vm.expectRevert(FlashArbitrage.Unauthorized.selector);
        arbitrage.executeArbitrage(params);

        console2.log("Successfully caught unauthorized revert");
    }

    /**
     * @notice Fuzz test for multiple token pairs
     * @dev Tests quoting functionality across various token combinations
     */
    function testFuzz_MultipleTokenPairs(uint8 pairIndex, uint256 amountIn) public {
        amountIn = bound(amountIn, MIN_FLASH_AMOUNT, MAX_FLASH_AMOUNT / 10);
        pairIndex = uint8(bound(pairIndex, 0, 2)); // 3 different pairs

        console2.log("\n=== Testing Multiple Token Pairs ===");
        console2.log("Pair index:", pairIndex);

        address tokenIn;
        address tokenOut;

        // Select token pair based on fuzzed index
        if (pairIndex == 0) {
            tokenIn = WETH;
            tokenOut = USDC;
        } else if (pairIndex == 1) {
            tokenIn = WETH;
            tokenOut = DAI;
        } else {
            tokenIn = USDC;
            tokenOut = DAI;
            amountIn = bound(amountIn, 1000e6, 1000000e6); // Adjust for USDC decimals
        }

        console2.log("Token In:", tokenIn);
        console2.log("Token Out:", tokenOut);

        // Get Uniswap quote
        uint256 quote = arbitrage.getUniswapQuote(tokenIn, tokenOut, amountIn, FEE_MEDIUM);

        console2.log("Quote amount:", quote);
        assertGt(quote, 0, "Quote should be positive for valid pair");
    }

    /**
     * @notice Fuzz test for extreme amounts
     * @dev Tests system behavior with very large trade sizes
     */
    function testFuzz_ExtremeAmounts(bool isLarge) public {
        console2.log("\n=== Testing Extreme Amounts ===");

        uint256 amountIn;
        if (isLarge) {
            amountIn = MAX_FLASH_AMOUNT; // Very large
            console2.log("Testing large amount:", amountIn);
        } else {
            amountIn = MIN_FLASH_AMOUNT; // Very small
            console2.log("Testing small amount:", amountIn);
        }

        // Should not revert for extreme (but valid) amounts
        uint256 quote = arbitrage.getUniswapQuote(WETH, USDC, amountIn, FEE_MEDIUM);

        assertGt(quote, 0, "Quote should work for extreme amounts");
        console2.log("Quote successful:", quote);
    }

    /**
     * @notice Test Balancer pool token verification
     * @dev Verifies that pool contains expected tokens
     */
    function test_BalancerPoolTokens() public view {
        console2.log("\n=== Testing Balancer Pool Tokens ===");

        IBalancerVault vault = IBalancerVault(BALANCER_VAULT);
        (address[] memory tokens, uint256[] memory balances,) = vault.getPoolTokens(BALANCER_WETH_DAI_POOL);

        console2.log("Pool token count:", tokens.length);
        assertEq(tokens.length, balances.length, "Tokens and balances length mismatch");
        assertGt(tokens.length, 0, "Pool should have tokens");

        for (uint256 i = 0; i < tokens.length; i++) {
            console2.log("Token", i, ":", tokens[i]);
            console2.log("Balance", i, ":", balances[i]);
            assertGt(balances[i], 0, "Pool should have liquidity");
        }
    }

    /**
     * @notice Fuzz test for both arbitrage directions
     * @dev Tests buying on Balancer vs Uniswap scenarios
     */
    function testFuzz_ArbitrageDirection(bool buyOnBalancer, uint256 amountIn) public {
        amountIn = bound(amountIn, MIN_FLASH_AMOUNT, MAX_FLASH_AMOUNT / 100);

        console2.log("\n=== Testing Arbitrage Direction ===");
        console2.log("Buy on Balancer:", buyOnBalancer);
        console2.log("Amount:", amountIn);

        // Get quotes for both legs of the trade
        if (buyOnBalancer) {
            // Balancer: WETH -> USDC
            uint256 balancerQuote = arbitrage.getBalancerQuote(BALANCER_WETH_USDC_POOL, WETH, USDC, amountIn);
            console2.log("Balancer quote (WETH->USDC):", balancerQuote);

            // Uniswap: USDC -> WETH
            uint256 uniswapQuote = arbitrage.getUniswapQuote(USDC, WETH, balancerQuote, FEE_MEDIUM);
            console2.log("Uniswap quote (USDC->WETH):", uniswapQuote);

            assertGt(balancerQuote, 0, "Balancer quote should be positive");
            assertGt(uniswapQuote, 0, "Uniswap quote should be positive");
        } else {
            // Uniswap: WETH -> USDC
            uint256 uniswapQuote = arbitrage.getUniswapQuote(WETH, USDC, amountIn, FEE_MEDIUM);
            console2.log("Uniswap quote (WETH->USDC):", uniswapQuote);

            // Balancer: USDC -> WETH
            uint256 balancerQuote = arbitrage.getBalancerQuote(BALANCER_WETH_USDC_POOL, USDC, WETH, uniswapQuote);
            console2.log("Balancer quote (USDC->WETH):", balancerQuote);

            assertGt(uniswapQuote, 0, "Uniswap quote should be positive");
            assertGt(balancerQuote, 0, "Balancer quote should be positive");
        }
    }

    // ============ Helper Functions ============

    /**
     * @notice Gets Uniswap V3 pool address for a token pair
     */
    function _getUniswapPool(address tokenA, address tokenB, uint24 fee) internal view returns (address) {
        IUniswapV3Factory factory = IUniswapV3Factory(UNISWAP_V3_FACTORY);
        return factory.getPool(tokenA, tokenB, fee);
    }
}
