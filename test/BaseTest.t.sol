// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/LendingPool.sol";
import "../src/PriceOracle.sol";
import "../src/InterestRateModel.sol";
import "../src/AToken.sol";
import "../src/DebtToken.sol";
import "../src/mocks/MockERC20.sol";

/// @notice Shared fixtures and helpers for all test contracts.
abstract contract BaseTest is Test {
    // ── Protocol contracts ──────────────────────────────────────────────────
    LendingPool       pool;
    PriceOracle       oracle;
    InterestRateModel irm;

    // ── Mock tokens ─────────────────────────────────────────────────────────
    MockERC20 weth;   // collateral  – price $2,000
    MockERC20 usdc;   // borrow asset – price $1

    // ── Test accounts ───────────────────────────────────────────────────────
    address alice   = makeAddr("alice");
    address bob     = makeAddr("bob");
    address charlie = makeAddr("charlie"); // liquidator

    // ── Price constants (18-decimal USD) ────────────────────────────────────
    uint256 constant WETH_PRICE = 2_000e18;
    uint256 constant USDC_PRICE = 1e18;

    // ── IRM: 2% base | 20% slope | 10% reserve factor ───────────────────────
    uint256 constant BASE_RATE      = 0.02e27;
    uint256 constant SLOPE          = 0.20e27;
    uint256 constant RESERVE_FACTOR = 0.10e27;

    // ── Reserve risk params ──────────────────────────────────────────────────
    uint256 constant WETH_LTV           = 0.75e18; // 75%
    uint256 constant WETH_LIQ_THRESHOLD = 0.80e18; // 80%
    uint256 constant USDC_LTV           = 0.85e18; // 85%
    uint256 constant USDC_LIQ_THRESHOLD = 0.90e18; // 90%

    uint256 constant RAY = 1e27;
    uint256 constant WAD = 1e18;

    // ────────────────────────────────────────────────────────────────────────

    function setUp() public virtual {
        // 1. Deploy infrastructure
        oracle = new PriceOracle();
        irm    = new InterestRateModel(BASE_RATE, SLOPE, RESERVE_FACTOR);
        pool   = new LendingPool(address(oracle), address(irm));

        // 2. Deploy mock tokens (usdc uses 6 decimals like real USDC)
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin",       "USDC", 6);

        // 3. Set oracle prices
        oracle.setManualPrice(address(weth), WETH_PRICE);
        oracle.setManualPrice(address(usdc), USDC_PRICE);

        // 4. Initialise reserves
        pool.initReserve(address(weth), WETH_LTV, WETH_LIQ_THRESHOLD, "Aave WETH", "aWETH");
        pool.initReserve(address(usdc), USDC_LTV, USDC_LIQ_THRESHOLD, "Aave USDC", "aUSDC");

        // 5. Fund actors with plenty of tokens
        weth.mint(alice,   100 ether);
        weth.mint(bob,     100 ether);
        weth.mint(charlie, 100 ether);
        usdc.mint(alice,   200_000e6);
        usdc.mint(bob,     200_000e6);
        usdc.mint(charlie, 200_000e6);
    }

    // ── Action helpers ───────────────────────────────────────────────────────

    function _deposit(address actor, MockERC20 token, uint256 amount) internal {
        vm.startPrank(actor);
        token.approve(address(pool), amount);
        pool.deposit(address(token), amount);
        vm.stopPrank();
    }

    function _withdraw(address actor, MockERC20 token, uint256 amount) internal {
        vm.startPrank(actor);
        pool.withdraw(address(token), amount);
        vm.stopPrank();
    }

    function _borrow(address actor, MockERC20 token, uint256 amount) internal {
        vm.startPrank(actor);
        pool.borrow(address(token), amount);
        vm.stopPrank();
    }

    function _repay(address actor, MockERC20 token, uint256 amount) internal {
        vm.startPrank(actor);
        token.approve(address(pool), amount);
        pool.repay(address(token), amount);
        vm.stopPrank();
    }

    function _warp(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
    }

    // ── Query helpers ────────────────────────────────────────────────────────

    function _hf(address user) internal view returns (uint256) {
        return pool.getHealthFactor(user);
    }

    /// @dev Reads the aToken from the public reserves mapping.
    ///      pool.reserves(asset) returns the full ReserveData struct as a tuple.
    function _aToken(address asset) internal view returns (AToken at) {
        (at,,,,,,,,,,) = pool.reserves(asset);
    }

    function _debtToken(address asset) internal view returns (DebtToken dt) {
        (, dt,,,,,,,,,) = pool.reserves(asset);
    }

    function _supplyIndex(address asset) internal view returns (uint256 si) {
        (,, si,,,,,,,,) = pool.reserves(asset);
    }

    function _borrowIndex(address asset) internal view returns (uint256 bi) {
        (,,, bi,,,,,,,) = pool.reserves(asset);
    }

    function _totalDeposits(address asset) internal view returns (uint256 td) {
        (,,,,, td,,,,,) = pool.reserves(asset);
    }

    function _totalBorrows(address asset) internal view returns (uint256 tb) {
        (,,,,,, tb,,,,) = pool.reserves(asset);
    }

    /// @dev Actual (index-adjusted) deposit balance.
    function _actualDeposit(address asset, address user) internal view returns (uint256) {
        return pool.getSupplyBalance(asset, user);
    }

    /// @dev Actual (index-adjusted) debt.
    function _actualDebt(address asset, address user) internal view returns (uint256) {
        return pool.getDebtBalance(asset, user);
    }
}
