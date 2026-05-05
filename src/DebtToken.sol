// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";

/// @title DebtToken
/// @notice Non-transferable token that tracks a user's scaled borrow balance.
///         Actual debt = scaledBalance * borrowIndex / RAY
///
///         Debt tokens are intentionally non-transferable because debt cannot
///         be assigned to another party without their consent.
contract DebtToken is Ownable {
    uint256 public constant RAY = 1e27;

    /// @notice Underlying asset that was borrowed.
    address public immutable underlyingAsset;

    /// @notice Only the LendingPool can mint/burn.
    address public lendingPool;

    /// @notice Scaled borrow balance per user.
    mapping(address => uint256) private _scaledBalances;

    /// @notice Total scaled supply (sum of all scaled balances).
    uint256 private _totalScaledSupply;

    string public name;
    string public symbol;

    event Mint(address indexed user, uint256 scaledAmount);
    event Burn(address indexed user, uint256 scaledAmount);

    modifier onlyLendingPool() {
        require(msg.sender == lendingPool, "DebtToken: caller not LendingPool");
        _;
    }

    constructor(
        address _underlyingAsset,
        string memory _name,
        string memory _symbol
    ) Ownable(msg.sender) {
        underlyingAsset = _underlyingAsset;
        name            = _name;
        symbol          = _symbol;
    }

    /// @notice Sets the LendingPool address (called once during deployment).
    function setLendingPool(address _lendingPool) external onlyOwner {
        require(_lendingPool != address(0), "DebtToken: zero address");
        lendingPool = _lendingPool;
    }

    // ──────────────────────────── Mint / Burn ────────────────────────────

    /// @notice Mints scaled debt to `user`.
    ///         scaledAmount = borrowAmount * RAY / currentBorrowIndex
    function mint(address user, uint256 scaledAmount) external onlyLendingPool {
        require(user         != address(0), "DebtToken: mint to zero");
        require(scaledAmount > 0,           "DebtToken: zero amount");
        _scaledBalances[user] += scaledAmount;
        _totalScaledSupply    += scaledAmount;
        emit Mint(user, scaledAmount);
    }

    /// @notice Burns scaled debt from `user`.
    function burn(address user, uint256 scaledAmount) external onlyLendingPool {
        require(user         != address(0), "DebtToken: burn from zero");
        require(scaledAmount > 0,           "DebtToken: zero amount");
        require(_scaledBalances[user] >= scaledAmount, "DebtToken: burn exceeds balance");
        _scaledBalances[user] -= scaledAmount;
        _totalScaledSupply    -= scaledAmount;
        emit Burn(user, scaledAmount);
    }

    // ──────────────────────────── View helpers ───────────────────────────

    /// @notice Returns the *scaled* debt balance (not yet multiplied by index).
    function scaledBalanceOf(address user) external view returns (uint256) {
        return _scaledBalances[user];
    }

    /// @notice Total scaled supply across all borrowers.
    function totalScaledSupply() external view returns (uint256) {
        return _totalScaledSupply;
    }
}
