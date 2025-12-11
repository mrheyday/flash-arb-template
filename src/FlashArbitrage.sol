// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "./interfaces/IERC20.sol";
import {IBalancerVault, IFlashLoanRecipient} from "./interfaces/IBalancer.sol";
import {IUniswapV3Pool, IQuoterV2} from "./interfaces/IUniswapV3.sol";

/**
 * @title FlashArbitrage
 * @notice Flash loan arbitrage contract between Balancer and Uniswap V3
 * @dev Uses Balancer flash loans to execute arbitrage opportunities
 */
contract FlashArbitrage is IFlashLoanRecipient {
    address public immutable owner;
    IBalancerVault public immutable balancerVault;
    IQuoterV2 public immutable uniswapQuoter;

    // Uniswap V3 price limit constants (MIN_SQRT_RATIO + 1 and MAX_SQRT_RATIO - 1)
    uint160 private constant MIN_SQRT_PRICE_LIMIT = 4295128740;
    uint160 private constant MAX_SQRT_PRICE_LIMIT = 1461446703485210103287273052203988822378723970341;

    // Swap deadline buffer in seconds
    uint256 private constant SWAP_DEADLINE_BUFFER = 60;

    struct ArbitrageParams {
        address tokenIn;
        address tokenOut;
        address uniswapPool;
        uint24 uniswapFee;
        bytes32 balancerPoolId;
        uint256 flashLoanAmount;
        uint256 minProfitAmount;
        bool buyOnBalancer; // true = buy on Balancer, sell on Uniswap; false = opposite
    }

    event ArbitrageExecuted(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 flashAmount,
        uint256 profit,
        bool buyOnBalancer
    );

    event ArbitrageFailed(string reason);

    error Unauthorized();
    error InsufficientProfit(uint256 actual, uint256 minimum);
    error SwapFailed();
    error InvalidParams();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(address _balancerVault, address _uniswapQuoter) {
        owner = msg.sender;
        balancerVault = IBalancerVault(_balancerVault);
        uniswapQuoter = IQuoterV2(_uniswapQuoter);
    }

    /**
     * @notice Initiates a flash loan arbitrage
     * @param params Arbitrage parameters
     */
    function executeArbitrage(ArbitrageParams calldata params) external onlyOwner {
        if (params.flashLoanAmount == 0) revert InvalidParams();
        if (params.tokenIn == address(0) || params.tokenOut == address(0)) revert InvalidParams();

        address[] memory tokens = new address[](1);
        tokens[0] = params.tokenIn;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = params.flashLoanAmount;

        bytes memory userData = abi.encode(params);

        balancerVault.flashLoan(address(this), tokens, amounts, userData);
    }

    /**
     * @notice Callback function for Balancer flash loans
     * @param tokens Array of token addresses
     * @param amounts Array of loan amounts
     * @param feeAmounts Array of fee amounts (usually 0 for Balancer)
     * @param userData Encoded arbitrage parameters
     */
    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external override {
        if (msg.sender != address(balancerVault)) revert Unauthorized();

        ArbitrageParams memory params = abi.decode(userData, (ArbitrageParams));

        uint256 flashAmount = amounts[0];
        uint256 flashFee = feeAmounts[0];
        uint256 totalDebt = flashAmount + flashFee;

        // Execute the arbitrage
        uint256 finalBalance = _executeArbitrageLogic(params, flashAmount);

        // Check profitability
        if (finalBalance < totalDebt + params.minProfitAmount) {
            // Safe calculation: we know finalBalance < totalDebt here
            uint256 actualProfit = finalBalance > totalDebt ? finalBalance - totalDebt : 0;
            revert InsufficientProfit(actualProfit, params.minProfitAmount);
        }

        // Repay flash loan
        IERC20(tokens[0]).transfer(address(balancerVault), totalDebt);

        uint256 profit = finalBalance - totalDebt;

        emit ArbitrageExecuted(params.tokenIn, params.tokenOut, flashAmount, profit, params.buyOnBalancer);
    }

    /**
     * @notice Executes the arbitrage logic
     * @param params Arbitrage parameters
     * @param flashAmount Amount borrowed via flash loan
     * @return finalBalance Final balance of tokenIn after arbitrage
     */
    function _executeArbitrageLogic(ArbitrageParams memory params, uint256 flashAmount)
        internal
        returns (uint256 finalBalance)
    {
        if (params.buyOnBalancer) {
            // Strategy 1: Buy tokenOut on Balancer, sell on Uniswap
            // 1. Swap tokenIn -> tokenOut on Balancer
            uint256 tokenOutAmount = _swapOnBalancer(
                params.balancerPoolId, params.tokenIn, params.tokenOut, flashAmount
            );

            // 2. Swap tokenOut -> tokenIn on Uniswap
            finalBalance = _swapOnUniswap(params.uniswapPool, params.tokenOut, params.tokenIn, tokenOutAmount);
        } else {
            // Strategy 2: Buy tokenOut on Uniswap, sell on Balancer
            // 1. Swap tokenIn -> tokenOut on Uniswap
            uint256 tokenOutAmount =
                _swapOnUniswap(params.uniswapPool, params.tokenIn, params.tokenOut, flashAmount);

            // 2. Swap tokenOut -> tokenIn on Balancer
            finalBalance =
                _swapOnBalancer(params.balancerPoolId, params.tokenOut, params.tokenIn, tokenOutAmount);
        }
    }

    /**
     * @notice Swaps tokens on Balancer
     */
    function _swapOnBalancer(bytes32 poolId, address tokenIn, address tokenOut, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        IERC20(tokenIn).approve(address(balancerVault), amountIn);

        IBalancerVault.SingleSwap memory singleSwap = IBalancerVault.SingleSwap({
            poolId: poolId,
            kind: IBalancerVault.SwapKind.GIVEN_IN,
            assetIn: tokenIn,
            assetOut: tokenOut,
            amount: amountIn,
            userData: ""
        });

        IBalancerVault.FundManagement memory funds = IBalancerVault.FundManagement({
            sender: address(this),
            fromInternalBalance: false,
            recipient: payable(address(this)),
            toInternalBalance: false
        });

        amountOut = balancerVault.swap(singleSwap, funds, 0, block.timestamp + SWAP_DEADLINE_BUFFER);
    }

    /**
     * @notice Swaps tokens on Uniswap V3
     */
    function _swapOnUniswap(address pool, address tokenIn, address tokenOut, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        IERC20(tokenIn).approve(pool, amountIn);

        IUniswapV3Pool uniswapPool = IUniswapV3Pool(pool);
        bool zeroForOne = tokenIn < tokenOut;

        (int256 amount0, int256 amount1) = uniswapPool.swap(
            address(this),
            zeroForOne,
            int256(amountIn),
            zeroForOne ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT,
            ""
        );

        amountOut = uint256(-(zeroForOne ? amount1 : amount0));
    }

    /**
     * @notice Gets quote from Uniswap V3 Quoter
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Input amount
     * @param fee Pool fee tier
     * @return amountOut Expected output amount
     */
    function getUniswapQuote(address tokenIn, address tokenOut, uint256 amountIn, uint24 fee)
        external
        returns (uint256 amountOut)
    {
        IQuoterV2.QuoteExactInputSingleParams memory params = IQuoterV2.QuoteExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            fee: fee,
            sqrtPriceLimitX96: 0
        });

        (amountOut,,,) = uniswapQuoter.quoteExactInputSingle(params);
    }

    /**
     * @notice Gets quote from Balancer using queryBatchSwap
     * @param poolId Balancer pool ID
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Input amount
     * @return amountOut Expected output amount
     */
    function getBalancerQuote(bytes32 poolId, address tokenIn, address tokenOut, uint256 amountIn)
        external
        returns (uint256 amountOut)
    {
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = IBalancerVault.BatchSwapStep({
            poolId: poolId,
            assetInIndex: 0,
            assetOutIndex: 1,
            amount: amountIn,
            userData: ""
        });

        address[] memory assets = new address[](2);
        assets[0] = tokenIn;
        assets[1] = tokenOut;

        IBalancerVault.FundManagement memory funds = IBalancerVault.FundManagement({
            sender: address(this),
            fromInternalBalance: false,
            recipient: payable(address(this)),
            toInternalBalance: false
        });

        int256[] memory assetDeltas =
            balancerVault.queryBatchSwap(IBalancerVault.SwapKind.GIVEN_IN, swaps, assets, funds);

        // assetDeltas[1] is negative for output amount
        amountOut = uint256(-assetDeltas[1]);
    }

    /**
     * @notice Withdraws tokens from the contract
     * @param token Token address
     * @param amount Amount to withdraw
     */
    function withdraw(address token, uint256 amount) external onlyOwner {
        IERC20(token).transfer(owner, amount);
    }

    /**
     * @notice Withdraws ETH from the contract
     */
    function withdrawETH() external onlyOwner {
        payable(owner).transfer(address(this).balance);
    }

    receive() external payable {}
}
