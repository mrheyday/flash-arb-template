#!/usr/bin/env bash
set -e

ROOT="$HOME/mrheyday/flash-arb-template"
echo "Generating full flash-arb project at $ROOT…"
mkdir -p "$ROOT"
cd "$ROOT"

# ====================
# ── Contracts/ -------
echo "Writing contracts…"
mkdir -p contracts contracts/interfaces

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
            abi.encode(order.solver, order.nonce, order.expiry, order.expectedProfitWei, order.actionsHash)
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

cat > contracts/interfaces/IERC3156FlashBorrower.sol << 'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
interface IERC3156FlashBorrower {
    function onFlashLoan(address initiator,address token,uint256 amount,uint256 fee,bytes calldata data)
        external returns (bytes32);
}
EOF

cat > contracts/interfaces/IERC3156FlashLender.sol << 'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
interface IERC3156FlashLender {
    function flashFee(address token,uint256 amount) external view returns (uint256);
    function maxFlashLoan(address token) external view returns (uint256);
    function flashLoan(
        IERC3156FlashBorrower receiver,address token,uint256 amount,bytes calldata data
    ) external returns (bool);
}
EOF

echo "Contracts written."

# ====================
# ── Foundry Test Suite
echo "Writing Foundry tests…"
mkdir -p test/Foundry

cat > test/Foundry/MultiPoolArbFuzzTest.t.sol << 'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../contracts/MultiDexArbExecutor.sol";
import "../../contracts/GaslessFlashArbAaveV3.sol";

contract MultiPoolArbFuzzTest is Test {
    MultiDexArbExecutor executor;
    uint256 constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    function setUp() public {
        executor = MultiDexArbExecutor(
            vm.envAddress("MULTI_EXECUTOR")
        );
    }

    function testFuzz_uniswapQuote(uint128 amountIn) public {
        vm.assume(amountIn > 0);
        uint256 quoted = executor.quoter().quoteExactInputSingle(
            DAI, address(0), 3000, amountIn, 0
        );
        assertGt(quoted, 0);
    }
}
EOF

echo "Foundry tests written."

# ====================
# ── TypeScript Off-Chain Helpers & Tests
echo "Writing TS helpers…"
mkdir -p ts/helpers ts/tests

cat > ts/helpers/quoter.ts << 'EOF'
import { JsonRpcProvider } from "ethers";
import { ethers } from "ethers";

export async function quoteUniswapV3(
  provider: JsonRpcProvider,
  quoterAddress: string,
  tokenIn: string,
  tokenOut: string,
  fee: number,
  amountIn: bigint
) {
  const quoter = new ethers.Contract(
    quoterAddress,
    ["function quoteExactInputSingle(address,address,uint24,uint256,uint160) view returns (uint256)"],
    provider
  );
  return quoter.quoteExactInputSingle(tokenIn, tokenOut, fee, amountIn, 0);
}
EOF

cat > ts/tests/flashArb.integration.test.ts << 'EOF'
import { assert } from "vitest";
import { ethers } from "ethers";
import { quoteUniswapV3 } from "../helpers/quoter";

const provider = new ethers.JsonRpcProvider(process.env.RPC_URL!);

describe("Integration", () => {
  it("uniswap quote", async () => {
    const result = await quoteUniswapV3(
      provider,
      process.env.UNISWAP_V3_QUOTER!,
      process.env.DAI!,
      process.env.WETH!,
      3000,
      ethers.parseUnits("1", 18)
    );
    assert(result > 0n);
  });
});
EOF

echo "TS helpers & tests written."

# ====================
# ── CI Workflows
echo "Writing GitHub CI workflows…"
mkdir -p .github/workflows

cat > .github/workflows/ci-foundry.yml << 'EOF'
name: Foundry CI
on: [push,pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: foundry-rs/foundry-toolchain@v1
      - run: forge test --fork-url ${{ secrets.RPC_URL }} -vv
EOF

cat > .github/workflows/ci-ts.yml << 'EOF'
name: TypeScript CI
on: [push,pull_request]
jobs:
  ts-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v3
        with: node-version: "20"
      - run: npm ci
      - run: npm test
        env:
          RPC_URL: ${{ secrets.RPC_URL }}
          UNISWAP_V3_QUOTER: ${{ secrets.UNISWAP_V3_QUOTER }}
EOF

cat > .github/workflows/pages-deploy.yml << 'EOF'
name: GitHub Pages Deploy
on:
  push:
    branches: ["main"]
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build Docs
        run: echo "Docs build placeholder"
      - uses: peaceiris/actions-gh-pages@v3
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
          publish_dir: ./docs
EOF

echo "CI workflows written."

# ====================
# ── Docs + Mermaid Setup
echo "Writing docs scaffolding…"
mkdir -p docs _layouts _includes docs/diagrams

cat > docs/architecture.md << 'EOF'
# Architecture

This repository defines the core flash arbitrage contracts and off-chain tooling.

```mermaid
flowchart TD
    C[Contracts] --> |calls| E[Executor]
    E --> |flash loan| A[Aave V3]
EOF

cat > _layouts/default.html << 'EOF'
<!DOCTYPE html>
<html><head><meta charset="UTF-8"><title>{{ page.title }}</title></head><body>
{{ content }}
{% if page.mermaid %}{% include mermaid.html %}{% endif %}
</body></html>
EOF

cat > _includes/mermaid.html << 'EOF'
<script type="module">
document.addEventListener("DOMContentLoaded", () => {
  document.querySelectorAll('pre > code.language-mermaid').forEach(codeBlock => {
    const wrapper = document.createElement("div");
    wrapper.classList.add("mermaid");
    wrapper.textContent = codeBlock.textContent;
    codeBlock.parentElement.replaceWith(wrapper);
  });
  import('https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs')
    .then(({ default: mermaid }) => mermaid.initialize({ startOnLoad:true }));
});
</script>
EOF

echo "Docs scaffolding created."

# ====================
# ── Root config + package.json
echo "Writing root configs…"

cat > foundry.toml << 'EOF'
solc_version = "0.8.28"
evm_version = "cancun"
EOF

cat > package.json << 'EOF'
{
  "name": "flash-arb-template",
  "scripts": {
    "anvil": "anvil --fork-url $RPC_URL",
    "test": "vitest"
  },
  "devDependencies": {
    "ethers": "^6.8.0",
    "vitest": "^0.31.0"
  }
}
EOF

cat > tsconfig.json << 'EOF'
{
  "compilerOptions": {
    "target": "es2020",
    "module": "commonjs",
    "strict": true,
    "esModuleInterop": true
  }
}
EOF

echo "Root configs written."

# ====================
# ── GitHub template file
mkdir -p .github
cat > .github/templaterepo.yml << 'EOF'
name: Flash Arbitrage Full Stack
about: Full flash arbitrage template with tests, CI, docs
documentation: README.md
features:
  - Core contracts
  - Foundry tests
  - TypeScript helpers/tests
  - CI workflows
  - Docs
EOF

echo "Full project generation complete."
