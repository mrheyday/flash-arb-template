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
