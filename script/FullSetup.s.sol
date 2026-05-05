// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/LendingPool.sol";
import "../src/PriceOracle.sol";
import "../src/InterestRateModel.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FullSetup is Script {
    function run() external {
        // Pulling sensitive data from the .env file securely
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address account0 = vm.envAddress("ACCOUNT_0_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Infrastructure
        PriceOracle oracle = new PriceOracle();
        InterestRateModel irm = new InterestRateModel(0.02e18, 0.1e18, 0.8e18);
        LendingPool pool = new LendingPool(address(oracle), address(irm));

        // 2. Deploy & Setup Token
        MockUSDC usdc = new MockUSDC();
        oracle.setManualPrice(address(usdc), 1e18);
        pool.initReserve(address(usdc), 0.75e18, 0.80e18, "Aave Test USDC", "aUSDC");

        // 3. Mint, Approve, and Deposit!
        usdc.mint(account0, 10000 * 1e18);
        usdc.approve(address(pool), 1000 * 1e18);
        pool.deposit(address(usdc), 1000 * 1e18);

        vm.stopBroadcast();

        // Print out the addresses so you don't have to hunt for them
        console.log("--- DEPLOYMENT COMPLETE ---");
        console.log("Lending Pool Address:", address(pool));
        console.log("Mock USDC Address:   ", address(usdc));
    }
}