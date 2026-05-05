// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./BaseTest.t.sol";

contract LiquidationTest is BaseTest {

    // ── Helpers ──────────────────────────────────────────────────────────────

    /// @dev Puts alice into a liquidatable position:
    ///      1 WETH collateral ($2000), borrows $1499 USDC (max LTV),
    ///      then WETH price crashes to $1500 → HF < 1.
    function _setupUnhealthyPosition() internal {
        _deposit(alice, weth, 1 ether);
        _deposit(bob,   usdc, 10_000e6);
        _borrow(alice,  usdc, 1_499e6);   // very close to max LTV

        // WETH crashes from $2000 → $1500
        // HF = 1500 * 0.80 / 1499 = 0.8005 < 1 → liquidatable
        oracle.setManualPrice(address(weth), 1_500e18);
    }

    // ─────────────────────── HF calculation ─────────────────────────────────

    function test_healthFactor_noDebt_returnsMaxUint() public {
        _deposit(alice, weth, 1 ether);
        assertEq(_hf(alice), type(uint256).max);
    }

    function test_healthFactor_safe_aboveOne() public {
        _deposit(alice, weth, 1 ether);
        _deposit(bob,   usdc, 5_000e6);
        _borrow(alice,  usdc, 500e6);
        // HF = (2000 * 0.8) / 500 = 3.2
        assertApproxEqRel(_hf(alice), 3.2e18, 0.01e18);
    }

    function test_healthFactor_drops_belowOne_afterPriceCrash() public {
        _setupUnhealthyPosition();
        assertLt(_hf(alice), 1e18, "HF should be < 1 after crash");
    }

    // ─────────────────────────── Liquidation ─────────────────────────────────

    function test_liquidation_repaysDebt_and_seizes_collateral() public {
        _setupUnhealthyPosition();

        uint256 debtBefore      = _actualDebt(address(usdc), alice);
        uint256 collBefore      = _actualDeposit(address(weth), alice);
        uint256 liquidatorUsdc  = usdc.balanceOf(charlie);
        uint256 liquidatorWeth  = weth.balanceOf(charlie);

        // Cover 50% of debt (close factor)
        uint256 cover = debtBefore / 2;

        vm.startPrank(charlie);
        usdc.approve(address(pool), cover);
        pool.liquidate(address(weth), address(usdc), alice, cover);
        vm.stopPrank();

        // Debt reduced
        assertLt(_actualDebt(address(usdc), alice), debtBefore, "debt should decrease");

        // Collateral seized
        assertLt(_actualDeposit(address(weth), alice), collBefore, "collateral should decrease");

        // Liquidator spent USDC
        assertLt(usdc.balanceOf(charlie), liquidatorUsdc, "liquidator spent USDC");

        // Liquidator received WETH
        assertGt(weth.balanceOf(charlie), liquidatorWeth, "liquidator received WETH");
    }

    function test_liquidation_bonus_is_5_percent() public {
        _setupUnhealthyPosition();

        uint256 cover = _actualDebt(address(usdc), alice) / 2;

        // Compute expected collateral seized:
        // debtValueUSD = cover * $1 = cover / 1e6 (usdc 6 dec) * 1e18
        // collAmount = debtValueUSD * 1.05 / wethPrice
        uint256 debtValueUSD    = (cover * USDC_PRICE) / 1e6;  // 18-dec USD
        uint256 wethPrice       = 1_500e18;
        uint256 expectedSeized  = (debtValueUSD * 1.05e18) / wethPrice;

        uint256 wethBefore = weth.balanceOf(charlie);

        vm.startPrank(charlie);
        usdc.approve(address(pool), cover);
        pool.liquidate(address(weth), address(usdc), alice, cover);
        vm.stopPrank();

        uint256 actualSeized = weth.balanceOf(charlie) - wethBefore;
        assertApproxEqRel(actualSeized, expectedSeized, 0.01e18, "bonus should be ~5%");
    }

    function test_liquidation_healthyPosition_reverts() public {
        _deposit(alice, weth, 1 ether);
        _deposit(bob,   usdc, 5_000e6);
        _borrow(alice,  usdc, 500e6);  // very healthy

        vm.startPrank(charlie);
        usdc.approve(address(pool), 100e6);
        vm.expectRevert("LP: position healthy");
        pool.liquidate(address(weth), address(usdc), alice, 100e6);
        vm.stopPrank();
    }

    function test_liquidation_closeFactor_caps_at_50pct() public {
        _setupUnhealthyPosition();

        uint256 totalDebt = _actualDebt(address(usdc), alice);
        uint256 overCover = totalDebt;          // try to cover 100%

        // Give charlie enough
        usdc.mint(charlie, overCover);

        vm.startPrank(charlie);
        usdc.approve(address(pool), overCover);
        pool.liquidate(address(weth), address(usdc), alice, overCover);
        vm.stopPrank();

        // Remaining debt should be ~50%
        uint256 remainingDebt = _actualDebt(address(usdc), alice);
        assertApproxEqRel(remainingDebt, totalDebt / 2, 0.02e18, "close factor 50% not enforced");
    }

    function test_liquidation_selfLiquidation_reverts() public {
        _setupUnhealthyPosition();
        vm.startPrank(alice);
        usdc.approve(address(pool), 1_000e6);
        vm.expectRevert("LP: self liquidation");
        pool.liquidate(address(weth), address(usdc), alice, 100e6);
        vm.stopPrank();
    }

    function test_liquidation_zeroDebt_reverts() public {
        _setupUnhealthyPosition();
        vm.startPrank(charlie);
        usdc.approve(address(pool), 100e6);
        vm.expectRevert("LP: zero debt");
        pool.liquidate(address(weth), address(usdc), alice, 0);
        vm.stopPrank();
    }

    function test_liquidation_emitsEvent() public {
        _setupUnhealthyPosition();
        uint256 cover = _actualDebt(address(usdc), alice) / 2;

        vm.startPrank(charlie);
        usdc.approve(address(pool), cover);
        vm.expectEmit(true, true, true, false);
        emit LendingPool.Liquidation(address(weth), address(usdc), alice, cover, 0);
        pool.liquidate(address(weth), address(usdc), alice, cover);
        vm.stopPrank();
    }

    function test_liquidation_afterInterestAccrual_correctDebt() public {
        _deposit(alice, weth, 1 ether);
        _deposit(bob,   usdc, 10_000e6);
        _borrow(alice,  usdc, 1_000e6);

        _warp(365 days);
        oracle.setManualPrice(address(weth), 1_000e18);  // crash hard

        // HF < 1 now
        assertLt(_hf(alice), 1e18);

        uint256 debtWithInterest = _actualDebt(address(usdc), alice);
        assertGt(debtWithInterest, 1_000e6, "interest should have accrued");

        uint256 cover = debtWithInterest / 2;
        usdc.mint(charlie, cover);

        vm.startPrank(charlie);
        usdc.approve(address(pool), cover);
        pool.liquidate(address(weth), address(usdc), alice, cover);
        vm.stopPrank();

        assertLt(_actualDebt(address(usdc), alice), debtWithInterest);
    }
}
