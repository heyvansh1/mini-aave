// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import "../src/LendingPool.sol";
import "../src/PriceOracle.sol";
import "../src/InterestRateModel.sol";
import "../src/MockUSDC.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        // ✅ Deploy Mock USDC
        MockUSDC usdc = new MockUSDC();

        // ✅ Deploy Oracle
        PriceOracle oracle = new PriceOracle();

        // ✅ Deploy Interest Rate Model (FIXED: pass 3 params)
        InterestRateModel irm = new InterestRateModel(
            0.02e18, // base rate (2%)
            0.1e18,  // slope1 (10%)
            0.5e18   // slope2 (50%)
        );

        // ✅ Deploy Lending Pool
        LendingPool lendingPool = new LendingPool(
            address(oracle),
            address(irm)
        );

        // ✅ Initialize reserve (CRITICAL)
        lendingPool.initReserve(
            address(usdc),
            750000000000000000, // liquidation threshold (75%)
            800000000000000000, // LTV (80%)
            "Mock AToken",
            "aUSDC"
        );

        vm.stopBroadcast();

        // ✅ Print addresses (VERY useful)
        console.log("LendingPool:", address(lendingPool));
        console.log("USDC:", address(usdc));
        console.log("Oracle:", address(oracle));
    }
}