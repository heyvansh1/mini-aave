// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/LendingPool.sol";
import "../src/PriceOracle.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// A quick fake token just for our local testing
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract SetupReserve is Script {
    function run() external {
        // Pulling sensitive data and addresses from the .env file securely
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        LendingPool pool = LendingPool(vm.envAddress("LENDING_POOL_ADDRESS"));
        PriceOracle oracle = PriceOracle(vm.envAddress("PRICE_ORACLE_ADDRESS"));
        address account0 = vm.envAddress("ACCOUNT_0_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy our Fake USDC
        MockUSDC usdc = new MockUSDC();

        // 2. Set its price in the Oracle to $1 (1e18)
        oracle.setManualPrice(address(usdc), 1e18);

        // 3. Initialize the reserve in the Lending Pool (LTV 75%, Threshold 80%)
        pool.initReserve(address(usdc), 0.75e18, 0.80e18, "Aave Test USDC", "aUSDC");

        // 4. Mint 10,000 Fake USDC to your test account so you have money to deposit!
        usdc.mint(account0, 10000 * 1e18);

        vm.stopBroadcast();
    }
}