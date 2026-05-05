// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./BaseTest.t.sol";

contract DepositWithdrawTest is BaseTest {

    // ─────────────────────────────── Deposit ─────────────────────────────────

    function test_deposit_mintsATokensOneToOne() public {
        uint256 amount = 1 ether;
        _deposit(alice, weth, amount);

        AToken aWeth = _aToken(address(weth));
        // At deposit time supplyIndex == RAY, so scaled == amount
        assertEq(aWeth.balanceOf(alice), amount, "aToken balance mismatch");
    }

    function test_deposit_updatesPoolTotalDeposits() public {
        _deposit(alice, weth, 5 ether);
        assertEq(_totalDeposits(address(weth)), 5 ether);
    }

    function test_deposit_transfersTokensFromUser() public {
        uint256 before = weth.balanceOf(alice);
        _deposit(alice, weth, 3 ether);
        assertEq(weth.balanceOf(alice), before - 3 ether);
        assertEq(weth.balanceOf(address(pool)), 3 ether);
    }

    function test_deposit_multipleUsers_accountedSeparately() public {
        _deposit(alice, weth, 4 ether);
        _deposit(bob,   weth, 6 ether);

        AToken aWeth = _aToken(address(weth));
        assertEq(aWeth.balanceOf(alice), 4 ether);
        assertEq(aWeth.balanceOf(bob),   6 ether);
        assertEq(_totalDeposits(address(weth)), 10 ether);
    }

    function test_deposit_zeroReverts() public {
        vm.startPrank(alice);
        weth.approve(address(pool), 100 ether);
        vm.expectRevert("LP: zero amount");
        pool.deposit(address(weth), 0);
        vm.stopPrank();
    }

    function test_deposit_inactiveReserveReverts() public {
        MockERC20 rando = new MockERC20("X", "X", 18);
        vm.startPrank(alice);
        rando.approve(address(pool), 1 ether);
        vm.expectRevert("LP: inactive reserve");
        pool.deposit(address(rando), 1 ether);
        vm.stopPrank();
    }

    function test_deposit_emitsEvent() public {
        vm.startPrank(alice);
        weth.approve(address(pool), 1 ether);
        vm.expectEmit(true, true, false, true);
        emit LendingPool.Deposit(address(weth), alice, 1 ether);
        pool.deposit(address(weth), 1 ether);
        vm.stopPrank();
    }

    // ─────────────────────────────── Withdraw ────────────────────────────────

    function test_withdraw_burnsATokens() public {
        _deposit(alice, weth, 10 ether);
        AToken aWeth = _aToken(address(weth));
        uint256 scaledBefore = aWeth.balanceOf(alice);

        _withdraw(alice, weth, 4 ether);

        // Scaled burned ≈ 4e18 (index = RAY at this point)
        assertApproxEqAbs(aWeth.balanceOf(alice), scaledBefore - 4 ether, 1e9);
    }

    function test_withdraw_returnsTokensToUser() public {
        _deposit(alice, weth, 10 ether);
        uint256 before = weth.balanceOf(alice);
        _withdraw(alice, weth, 4 ether);
        assertEq(weth.balanceOf(alice), before + 4 ether);
    }

    function test_withdraw_fullBalance_typeMaxUint() public {
        _deposit(alice, weth, 7 ether);
        uint256 before = weth.balanceOf(alice);

        vm.prank(alice);
        pool.withdraw(address(weth), type(uint256).max);

        assertApproxEqAbs(weth.balanceOf(alice), before + 7 ether, 1e9);
        assertApproxEqAbs(_aToken(address(weth)).balanceOf(alice), 0, 1e9);
    }

    function test_withdraw_beyondBalanceReverts() public {
        _deposit(alice, weth, 5 ether);
        vm.prank(alice);
        vm.expectRevert("LP: exceeds balance");
        pool.withdraw(address(weth), 6 ether);
    }

    function test_withdraw_zeroReverts() public {
        _deposit(alice, weth, 5 ether);
        vm.prank(alice);
        vm.expectRevert("LP: zero amount");
        pool.withdraw(address(weth), 0);
    }

    function test_withdraw_withActiveBorrow_breaksHF_reverts() public {
        // Alice deposits 1 WETH ($2000), borrows 1500 USDC
        // LTV=75% → max borrow = 1500 USDC. Withdraw everything would HF < 1.
        _deposit(alice, weth,    1 ether);
        _deposit(bob,   usdc,    10_000e6);  // liquidity provider
        _borrow(alice,  usdc,    1_400e6);   // borrow $1400 against $2000

        vm.prank(alice);
        vm.expectRevert("LP: withdraw breaks health factor");
        pool.withdraw(address(weth), 1 ether);
    }

    function test_withdraw_partialOkWhenHFStaysHealthy() public {
        _deposit(alice, weth,  2 ether);      // $4000
        _deposit(bob,   usdc,  10_000e6);
        _borrow(alice,  usdc,  500e6);        // $500 – very safe

        // Withdraw 0.5 WETH ($1000 out) → remaining $3000 collateral, HF still fine
        _withdraw(alice, weth, 0.5 ether);
        assertGe(_hf(alice), 1e18);
    }

    function test_withdraw_emitsEvent() public {
        _deposit(alice, weth, 5 ether);
        vm.expectEmit(true, true, false, true);
        emit LendingPool.Withdraw(address(weth), alice, 5 ether);
        vm.prank(alice);
        pool.withdraw(address(weth), 5 ether);
    }

    // ─────────────────────────── Deposit with interest ───────────────────────

    // ─────────────────────────── Deposit with interest ───────────────────────

    function test_withdraw_afterInterestAccrual_moreTokensBack() public {
        // Alice and Bob both deposit. Bob borrows, generating yield for Alice.
        _deposit(alice, usdc, 10_000e6);
        _deposit(bob,   weth, 10 ether);
        _borrow(bob,    usdc, 5_000e6);    // 50% utilization

        // Fast-forward 1 year
        _warp(365 days);

        // FIX: Bob must repay his loan so the pool physically has the liquidity to pay Alice.
        // 1. Give Bob some extra USDC to cover the interest he now owes.
        deal(address(usdc), bob, 10_000e6); 
        
        // 2. Bob approves and repays his entire debt (principal + interest)
        vm.startPrank(bob);
        usdc.approve(address(pool), type(uint256).max);
        pool.repay(address(usdc), type(uint256).max);
        vm.stopPrank();

        uint256 before = usdc.balanceOf(alice);
        
        // 3. Now Alice can successfully withdraw her full deposit + interest
        vm.prank(alice);
        pool.withdraw(address(usdc), type(uint256).max);

        uint256 received = usdc.balanceOf(alice) - before;
        
        // Should be > 10_000e6 due to interest
        assertGt(received, 10_000e6, "no interest accrued");
    }
}