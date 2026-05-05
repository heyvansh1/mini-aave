// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title AToken
/// @notice Interest-bearing receipt token minted 1-to-1 on deposit.
///         The real value of 1 aToken grows over time via the supplyIndex stored
///         in the LendingPool; this contract only tracks "scaled" balances.
///
///         Scaled balance = actual_balance / supplyIndex
///         Actual balance = scaled_balance * supplyIndex
///
///         This way we never need to iterate over all holders – balances
///         simply increase as the index grows.
contract AToken is ERC20, Ownable {
    /// @notice The underlying ERC20 that this aToken represents.
    address public immutable underlyingAsset;

    /// @notice Only the LendingPool can mint/burn.
    address public lendingPool;

    modifier onlyLendingPool() {
        require(msg.sender == lendingPool, "AToken: caller not LendingPool");
        _;
    }

    constructor(
        address _underlyingAsset,
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol) Ownable(msg.sender) {
        underlyingAsset = _underlyingAsset;
    }

    /// @notice Sets the LendingPool address (called once during deployment).
    function setLendingPool(address _lendingPool) external onlyOwner {
        require(_lendingPool != address(0), "AToken: zero address");
        lendingPool = _lendingPool;
    }

    /// @notice Mints scaled aTokens to `to`.
    ///         The LendingPool passes in the *scaled* amount
    ///         (= depositAmount * RAY / currentSupplyIndex).
    function mint(address to, uint256 scaledAmount) external onlyLendingPool {
        require(to != address(0), "AToken: mint to zero");
        require(scaledAmount > 0, "AToken: zero amount");
        _mint(to, scaledAmount);
    }

    /// @notice Burns scaled aTokens from `from`.
    function burn(address from, uint256 scaledAmount) external onlyLendingPool {
        require(from != address(0), "AToken: burn from zero");
        require(scaledAmount > 0, "AToken: zero amount");
        _burn(from, scaledAmount);
    }
}
