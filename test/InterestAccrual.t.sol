// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./BaseTest.t.sol";

contract InterestAccrualTest is BaseTest {

    // ── Setup: Alice supplies, Bob borrows ───────────────────────────────────

    function _fullSetup() internal {
        _deposit(alice, usdc, 10_000e6);   // Alice is liquidity provider
        _deposit(bob,   weth, 10 ether);   // Bob's collateral
        _borrow(bob,    usdc, 5_000e6);    // 50% utilization
    }

    // ─────────────────────── Borrow index grows ──────────────────────────────

    function test_borrowIndex_increasesOverTime() public {
        _fullSetup();
        uint256 idxBefore = _borrowIndex(address(usdc));

        _warp(30 days);

        // Trigger update by any interaction
        vm.prank(charlie);
        usdc.approve(address(pool), 1);
        // Any state-touching call will update; we use getDebtBalance (view) to preview
        uint256 debtNow = pool.getDebtBalance(address(usdc), bob);
        uint256 debtThen = 5_000e6;

        assertGt(debtNow, debtThen, "borrow balance should have grown");
        // Directly check after triggering state update
        _deposit(charlie, usdc, 1e6);
        uint256 idxAfter = _borrowIndex(address(usdc));
        assertGt(idxAfter, idxBefore, "borrowIndex should increase");
    }

    function test_supplyIndex_increasesOverTime() public {
        _fullSetup();
        uint256 idxBefore = _supplyIndex(address(usdc));

        _warp(90 days);
        _deposit(charlie, usdc, 1e6);  // force index update

        uint256 idxAfter = _supplyIndex(address(usdc));
        assertGt(idxAfter, idxBefore, "supplyIndex should increase");
    }

    // ─────────────────────── Debt grows correctly ────────────────────────────

    function test_debtBalance_growsWithBorrowRate() public {
        _fullSetup();

        uint256 d0 = pool.getDebtBalance(address(usdc), bob);

        _warp(365 days);

        uint256 d1 = pool.getDebtBalance(address(usdc), bob);
        uint256 growth = d1 - d0;

        // At 50% utilization: rate = 2% + 20%*50% = 12% p.a.
        // Expected growth ≈ 5000e6 * 0.12 = 600e6
        // Allow ±2% tolerance for linearisation
        assertApproxEqRel(growth, 600e6, 0.02e18, "annual borrow interest off");
    }

    // ─────────────────────── Supply balance grows ────────────────────────────

    function test_supplyBalance_growsLessThanDebt() public {
        _fullSetup();

        uint256 s0 = pool.getSupplyBalance(address(usdc), alice);

        _warp(365 days);

        uint256 s1 = pool.getSupplyBalance(address(usdc), alice);
        uint256 d1 = pool.getDebtBalance(address(usdc), bob);

        // Supply interest < borrow interest (reserve factor takes a cut)
        assertGt(s1, s0,  "supply balance should grow");
        assertLt(s1 - s0, d1 - 5_000e6, "supply growth < borrow growth (reserve factor)");
    }

    // ─────────────────── Multiple time jumps compound ────────────────────────

    function test_multipleTimeJumps_compoundCorrectly() public {
        _fullSetup();

        // Accrue over 4 quarters
        for (uint256 i = 0; i < 4; i++) {
            _warp(91 days);
            _deposit(charlie, usdc, 1e6); // heartbeat to persist indexes
        }

        uint256 annualDebt = pool.getDebtBalance(address(usdc), bob);
        assertGt(annualDebt, 5_000e6);
    }

    // ─────────────────────── Zero utilisation ────────────────────────────────

    function test_zeroUtilization_supplyIndexStatic() public {
        // Deposit but nobody borrows
        _deposit(alice, usdc, 10_000e6);

        uint256 idxBefore = _supplyIndex(address(usdc));
        _warp(365 days);
        _deposit(charlie, usdc, 1e6);    // force update
        uint256 idxAfter = _supplyIndex(address(usdc));

        // With 0 utilization, supply rate = 0 → index unchanged
        assertEq(idxAfter, idxBefore, "supply index should not move at 0 utilization");
    }

    function test_zeroUtilization_borrowIndexOnlyGrowsIfBorrowed() public {
        _deposit(alice, usdc, 10_000e6);

        uint256 idxBefore = _borrowIndex(address(usdc));
        _warp(365 days);
        _deposit(charlie, usdc, 1e6);
        uint256 idxAfter = _borrowIndex(address(usdc));

        // Base borrow rate still exists (2% p.a.) but no borrows so totalBorrows=0
        // index technically grows but totalBorrows stays 0
        assertGe(idxAfter, idxBefore);
    }

    // ─────────────────── Reserve treasury accumulates ────────────────────────

    function test_reserveTreasury_accumulates() public {
        _fullSetup();
        _warp(365 days);
        _deposit(charlie, usdc, 1e6);  // persist

        (, , , , , , , uint256 treasury, , ,) = pool.reserves(address(usdc));
        assertGt(treasury, 0, "protocol treasury should accumulate");
    }

    // ─────────────────── IRM rate parameters ────────────────────────────────

    function test_irm_borrowRate_atFullUtilization() public view {
        // 100% utilization: rate = 2% + 20% = 22%
        uint256 rate = irm.getBorrowRate(1_000e6, 1_000e6);
        uint256 expected = uint256(22e25) / uint256(365 days);
        assertApproxEqRel(rate, expected, 0.01e18);
    }

    function test_irm_supplyRate_atHalfUtilization() public view {
        // util=50%, borrow_rate=12%, supply_rate=12%*50%*90%=5.4%
        uint256 rate = irm.getSupplyRate(500e6, 1_000e6);
        uint256 expected = uint256(54e24) / uint256(365 days);
        assertApproxEqRel(rate, expected, 0.01e18);
    }

    function test_irm_zeroSupply_returnsZeroRate() public view {

        assertEq(irm.getBorrowRate(0, 0), uint256(2e25) / uint256(365 days));
        assertEq(irm.getSupplyRate(0, 0), 0);
    }
}
