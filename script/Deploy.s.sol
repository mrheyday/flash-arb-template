// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {FlashArbitrage} from "../src/FlashArbitrage.sol";

/**
 * @title Deploy
 * @notice Deployment script for FlashArbitrage contract
 * @dev Run with: forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
 */
contract Deploy is Script {
    // Mainnet addresses
    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address constant UNISWAP_QUOTER_V2 = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("Deploying FlashArbitrage...");
        console2.log("Deployer:", deployer);
        console2.log("Deployer balance:", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);

        FlashArbitrage arbitrage = new FlashArbitrage(BALANCER_VAULT, UNISWAP_QUOTER_V2);

        vm.stopBroadcast();

        console2.log("FlashArbitrage deployed at:", address(arbitrage));
        console2.log("Owner:", arbitrage.owner());
        console2.log("Balancer Vault:", address(arbitrage.balancerVault()));
        console2.log("Uniswap Quoter:", address(arbitrage.uniswapQuoter()));

        // Save deployment info
        console2.log("");
        console2.log("=== Deployment Complete ===");
        console2.log("Contract Address:", address(arbitrage));
        console2.log("");
        console2.log("Verify with:");
        console2.log(
            string.concat(
                "forge verify-contract ",
                vm.toString(address(arbitrage)),
                " src/FlashArbitrage.sol:FlashArbitrage ",
                "--chain-id 1 ",
                "--constructor-args $(cast abi-encode \"constructor(address,address)\" ",
                vm.toString(BALANCER_VAULT),
                " ",
                vm.toString(UNISWAP_QUOTER_V2),
                ")"
            )
        );
    }
}
