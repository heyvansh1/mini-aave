// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./BaseTest.t.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ── Malicious ERC20 that re-enters the pool on transfer ──────────────────────

contract ReentrantToken is ERC20 {
    LendingPool public pool;
    bool        public armed;
    address     public attacker;

    constructor() ERC20("Evil", "EVIL") {}

    function setPool(address _pool) external { pool = LendingPool(_pool); }
    function arm()   external { armed = true;  attacker = msg.sender; }
    function disarm() external { armed = false; }

    function mint(address to, uint256 amt) external { _mint(to, amt); }

    /// @dev On every transferFrom, if armed, re-enters pool.deposit
    function transferFrom(address from, address to, uint256 amount)
        public override returns (bool)
    {
        super.transferFrom(from, to, amount);
        if (armed && msg.sender == address(pool)) {
            armed = false; // prevent infinite recursion
            // Try re-entering deposit
            pool.deposit(address(this), 1);
        }
        return true;
    }
}

// ── Edge case & security test suite ─────────────────────────────────────────

contract EdgeCasesTest is BaseTest {

    // ── Zero-value guards ────────────────────────────────────────────────────

    function test_deposit_zero_reverts() public {
        vm.startPrank(alice);
        weth.approve(address(pool), 1 ether);
        vm.expectRevert("LP: zero amount");
        pool.deposit(address(weth), 0);
        vm.stopPrank();
    }

    function test_withdraw_zero_reverts() public {
        _deposit(alice, weth, 1 ether);
        vm.prank(alice);
        vm.expectRevert("LP: zero amount");
        pool.withdraw(address(weth), 0);
    }

    function test_borrow_zero_reverts() public {
        _deposit(alice, weth, 1 ether);
        vm.prank(alice);
        vm.expectRevert("LP: zero amount");
        pool.borrow(address(usdc), 0);
    }

    function test_repay_zero_reverts() public {
        _deposit(alice, weth, 1 ether);
        _deposit(bob,   usdc, 5_000e6);
        _borrow(alice,  usdc, 500e6);

        vm.startPrank(alice);
        usdc.approve(address(pool), 0);
        vm.expectRevert("LP: zero amount");
        pool.repay(address(usdc), 0);
        vm.stopPrank();
    }

    // ── Address-zero guards ──────────────────────────────────────────────────

    function test_liquidate_zeroUser_reverts() public {
        vm.prank(charlie);
        vm.expectRevert("LP: zero user");
        pool.liquidate(address(weth), address(usdc), address(0), 100e6);
    }

    // ── initReserve guards ───────────────────────────────────────────────────

    function test_initReserve_duplicate_reverts() public {
        vm.expectRevert("LP: already initialized");
        pool.initReserve(address(weth), WETH_LTV, WETH_LIQ_THRESHOLD, "X", "X");
    }

    function test_initReserve_zeroAsset_reverts() public {
        vm.expectRevert("LP: zero asset");
        pool.initReserve(address(0), 0.5e18, 0.8e18, "X", "X");
    }

    function test_initReserve_ltvGeThreshold_reverts() public {
        MockERC20 t = new MockERC20("T", "T", 18);
        vm.expectRevert("LP: ltv >= threshold");
        pool.initReserve(address(t), 0.9e18, 0.8e18, "T", "T");
    }

    function test_initReserve_onlyOwner() public {
        MockERC20 t = new MockERC20("T", "T", 18);
        vm.prank(alice);
        vm.expectRevert();
        pool.initReserve(address(t), 0.5e18, 0.8e18, "T", "T");
    }

    // ── Extreme price movements ──────────────────────────────────────────────

    function test_extremePriceIncrease_HFGoesUp() public {
        _deposit(alice, weth, 1 ether);
        _deposit(bob,   usdc, 10_000e6);
        _borrow(alice,  usdc, 1_000e6);

        uint256 hfBefore = _hf(alice);

        // WETH price 10×
        oracle.setManualPrice(address(weth), 20_000e18);
        uint256 hfAfter = _hf(alice);

        assertGt(hfAfter, hfBefore);
    }

    function test_extremePriceDrop_triggersLiquidation() public {
        _deposit(alice, weth, 1 ether);
        _deposit(bob,   usdc, 10_000e6);
        _borrow(alice,  usdc, 500e6);   // conservative borrow

        // WETH nukes to $1
        oracle.setManualPrice(address(weth), 1e18);
        assertLt(_hf(alice), 1e18, "should be liquidatable");
    }

    function test_oraclePrice_zeroReverts() public {
        _deposit(alice, weth, 1 ether);
        oracle.setManualPrice(address(weth), 0);

        // getHealthFactor calls oracle internally
        vm.expectRevert("Oracle: price not available");
        pool.getHealthFactor(alice);
    }

    // ── Reentrancy attack simulation ─────────────────────────────────────────

    function test_reentrancy_deposit_blocked() public {
        // Register a ReentrantToken reserve
        ReentrantToken evil = new ReentrantToken();
        oracle.setManualPrice(address(evil), 1e18);
        pool.initReserve(
            address(evil), 0.5e18, 0.8e18, "aEvil", "aEVIL"
        );
        evil.setPool(address(pool));

        evil.mint(alice, 1_000 ether);

        vm.startPrank(alice);
        evil.approve(address(pool), 1_000 ether);

        // Arm the re-entrancy hook
        evil.arm();

        // The re-entrant deposit inside transferFrom should revert
        // because ReentrancyGuard locks the mutex
        vm.expectRevert(); // ReentrancyGuardReentrantCall
        pool.deposit(address(evil), 100 ether);
        vm.stopPrank();
    }

    // ── Overflow / underflow ─────────────────────────────────────────────────

    function test_largeDeposit_noOverflow() public {
        // Mint a very large amount and deposit
        uint256 bigAmt = 1_000_000 ether;
        weth.mint(alice, bigAmt);
        _deposit(alice, weth, bigAmt);
        assertEq(_totalDeposits(address(weth)), bigAmt);
    }

    // ── DebtToken non-transferability ────────────────────────────────────────
    // DebtToken has no transfer function by design (not ERC20),
    // so we verify only the LendingPool can mint/burn.

    function test_debtToken_onlyLendingPoolCanMint() public {
        DebtToken dt = _debtToken(address(usdc));
        vm.prank(alice);
        vm.expectRevert("DebtToken: caller not LendingPool");
        dt.mint(alice, 1_000e6);
    }

    function test_aToken_onlyLendingPoolCanMint() public {
        AToken at = _aToken(address(weth));
        vm.prank(alice);
        vm.expectRevert("AToken: caller not LendingPool");
        at.mint(alice, 1 ether);
    }

    // ── IRM owner-only params update ─────────────────────────────────────────

    function test_irm_setParams_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        irm.setRateParameters(0.03e27, 0.25e27, 0.10e27);
    }

    function test_irm_setParams_reserveFactorGe1_reverts() public {
        vm.expectRevert("IRM: reserve factor >= 1");
        irm.setRateParameters(0.02e27, 0.20e27, 1e27);
    }

    // ── Oracle staleness ─────────────────────────────────────────────────────

    function test_oracle_stalePrice_reverts() public {
        // Deploy a Chainlink mock feed
        MockAggregator feed = new MockAggregator(2_000e8, 8);
        oracle.setFeed(address(weth), address(feed));

        // Warp beyond MAX_ORACLE_FRESHNESS (1 hour)
        vm.warp(block.timestamp + 2 hours);

        vm.expectRevert("Oracle: stale price");
        oracle.getPrice(address(weth));
    }

    function test_oracle_negativePrice_reverts() public {
        MockAggregator feed = new MockAggregator(-1, 8);
        oracle.setFeed(address(weth), address(feed));

        vm.expectRevert("Oracle: non-positive price");
        oracle.getPrice(address(weth));
    }

    function test_oracle_chainlinkNormalisesDecimals() public {
        // 8-decimal feed at $2000 = 2000_00000000 (8 dec)
        MockAggregator feed = new MockAggregator(2_000e8, 8);
        oracle.setFeed(address(weth), address(feed));

        uint256 price = oracle.getPrice(address(weth));
        assertEq(price, 2_000e18, "should normalise to 18 dec");
    }
}
