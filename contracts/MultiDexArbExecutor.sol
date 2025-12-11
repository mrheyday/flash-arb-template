// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@aave/core-v3/contracts/flashloan/base/FlashLoanSimpleReceiverBase.sol";
import "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ICurvePool {
    function get_dy(int128, int128, uint256) external view returns (uint256);
}

struct BalancerStep {
    bytes32 poolId;
    uint256 assetInIndex;
    uint256 assetOutIndex;
    uint256 amount;
    bytes userData;
}

interface IBalancerVault {
    enum SwapKind { GIVEN_IN, GIVEN_OUT }
    function queryBatchSwap(
        SwapKind,
        BalancerStep[] calldata,
        address[] calldata,
        bytes calldata
    ) external returns (int256[] memory);
}

contract MultiDexArbExecutor is FlashLoanSimpleReceiverBase {
    IQuoter public immutable quoter;
    ISwapRouter public immutable uniRouter;
    IBalancerVault public immutable balancer;
    uint24 public constant UNI_FEE = 3000;
    uint256 public slippageBp;

    constructor(
        address provider,
        address _quoter,
        address _uniRouter,
        address _balancer,
        uint256 _slippageBp
    ) FlashLoanSimpleReceiverBase(IPoolAddressesProvider(provider)) {
        quoter = IQuoter(_quoter);
        uniRouter = ISwapRouter(_uniRouter);
        balancer = IBalancerVault(_balancer);
        slippageBp = _slippageBp;
    }

    function setSlippage(uint256 bp) external {
        slippageBp = bp;
    }

    function requestFlashArb(address asset, uint256 amount) external {
        bytes memory params = abi.encode(asset, amount);
        POOL.flashLoanSimple(address(this), asset, amount, params, 0);
    }

    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address,
        bytes calldata params
    ) external override returns (bool) {
        (address inToken, uint256 inAmount) = abi.decode(params, (address, uint256));
        uint256 uniOut = quoter.quoteExactInputSingle(
            inToken, address(0), UNI_FEE, inAmount, 0
        );
        uint256 uniMin = (uniOut * (10000 - slippageBp)) / 10000;
        IERC20(inToken).approve(address(uniRouter), inAmount);
        ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
            tokenIn: inToken,
            tokenOut: address(0),
            fee: UNI_FEE,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: inAmount,
            amountOutMinimum: uniMin,
            sqrtPriceLimitX96: 0
        });
        uniRouter.exactInputSingle(swapParams);
        uint256 repay = amount + premium;
        IERC20(asset).approve(address(POOL), repay);
        return true;
    }
}
