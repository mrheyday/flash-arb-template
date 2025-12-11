#!/usr/bin/env bash
set -e

ROOT="$HOME/mrheyday/flash-arb-template"

echo "Creating project at $ROOT..."
mkdir -p "$ROOT"
cd "$ROOT"

# ------------------------------
# contracts/GaslessFlashArbAaveV3.sol
mkdir -p contracts
cat > contracts/GaslessFlashArbAaveV3.sol << 'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/draft-EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

interface IHook {
    function validate(address executor, uint256 expectedProfitWei, bytes32 actionsHash) external view returns (bool);
}

contract GaslessFlashArbAaveV3 is ReentrancyGuard, EIP712 {
    bytes32 public constant ORDER_TYPEHASH =
        keccak256("Order(address solver,uint256 nonce,uint256 expiry,uint256 expectedProfitWei,bytes32 actionsHash)");

    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant SOLVER_SHARE_BP = 9000;

    event OrderExecuted(bytes32 indexed digest, address indexed solver, uint256 profitWei);
    event Withdrawn(address indexed to, uint256 amount);

    struct SolverOrder {
        address solver;
        uint256 nonce;
        uint256 expiry;
        uint256 expectedProfitWei;
        bytes32 actionsHash;
    }

    address public immutable treasury;
    address public owner;
    IHook public hook;

    mapping(address => uint256) public nonces;
    mapping(bytes32 => bool) public executed;
    mapping(address => uint256) private _withdrawable;

    constructor(address _treasury, address _hook) EIP712("FlashArb", "1") {
        require(_treasury != address(0), "treasury zero");
        treasury = _treasury;
        owner = msg.sender;
        if (_hook != address(0)) hook = IHook(_hook);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    function _verifySignature(
        SolverOrder memory order,
        bytes calldata signature
    ) internal view returns (address) {
        bytes32 structHash = keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                order.solver,
                order.nonce,
                order.expiry,
                order.expectedProfitWei,
                order.actionsHash
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        return ECDSA.recover(digest, signature);
    }

    function submitOrderAndExecute(
        SolverOrder memory order,
        bytes calldata signature,
        bytes calldata
    ) external payable {
        require(order.solver != address(0), "solver zero");
        require(order.expiry > block.timestamp, "expired");

        address recovered = _verifySignature(order, signature);
        require(recovered == order.solver, "invalid signature");
        require(order.nonce == nonces[order.solver], "invalid nonce");

        bytes32 digest = keccak256(
            abi.encode(
                order.solver,
                order.nonce,
                order.expiry,
                order.expectedProfitWei,
                order.actionsHash
            )
        );
        require(!executed[digest], "already executed");

        if (address(hook) != address(0)) {
            require(hook.validate(order.solver, order.expectedProfitWei, order.actionsHash), "hook failed");
        }

        nonces[order.solver] ++;
        executed[digest] = true;

        require(msg.value == order.expectedProfitWei, "msg.value mismatch");

        uint256 solverShare = (order.expectedProfitWei * SOLVER_SHARE_BP) / BASIS_POINTS;
        uint256 treasuryShare = order.expectedProfitWei - solverShare;

        _withdrawable[order.solver] += solverShare;
        _withdrawable[treasury] += treasuryShare;

        emit OrderExecuted(digest, order.solver, order.expectedProfitWei);
    }

    function withdraw() external nonReentrant {
        uint256 amount = _withdrawable[msg.sender];
        require(amount > 0, "nothing to withdraw");
        _withdrawable[msg.sender] = 0;
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "withdraw failed");
        emit Withdrawn(msg.sender, amount);
    }

    function rescueETH(address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "zero to");
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "rescue failed");
    }

    receive() external payable {}
}
EOF

# ------------------------------
# contracts/MultiDexArbExecutor.sol
cat > contracts/MultiDexArbExecutor.sol << 'EOF'
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
EOF

# ------------------------------
# contracts/interfaces
mkdir -p contracts/interfaces
cat > contracts/interfaces/IERC3156FlashBorrower.sol << 'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IERC3156FlashBorrower {
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bytes32);
}
EOF

cat > contracts/interfaces/IERC3156FlashLender.sol << 'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IERC3156FlashLender {
    function flashFee(address token, uint256 amount) external view returns (uint256);
    function maxFlashLoan(address token) external view returns (uint256);
    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external returns (bool);
}
EOF

# ------------------------------
# GitHub template manifest
mkdir -p .github
cat > .github/templaterepo.yml << 'EOF'
name: Flash Arbitrage Full Stack
about: |
  A reusable template for a flash arbitrage repository containing:
  - Solidity smart contracts (Aave V3 flash loans, multi-DEX routing)
  - Foundry fork tests
  - TypeScript helpers + integration tests
  - Docs with Mermaid / static fallback SVGs
  - CI workflows (Foundry, TS, Pages with diagrams)
documentation: README.md
features:
  - Smart contract stack
  - Foundry and TS testing
  - Documentation with diagrams
  - GitHub Actions CI workflows
  - GitHub Pages provisioning
EOF

echo "Project scaffolding complete."
