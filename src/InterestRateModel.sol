// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";

/// @title InterestRateModel
/// @notice Implements a utilization-based interest rate model.
///         borrow_rate = base_rate + slope * utilization
///         supply_rate = borrow_rate * utilization * (1 - reserve_factor)
///         All rates are expressed in ray (1e27) per second.
contract InterestRateModel is Ownable {
    uint256 public constant RAY = 1e27;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    /// @notice Base annual borrow rate in ray (e.g. 2% = 0.02e27)
    uint256 public baseRatePerYear;

    /// @notice Slope of the rate model in ray (e.g. 20% slope = 0.20e27)
    uint256 public slopePerYear;

    /// @notice Reserve factor: fraction of interest kept as protocol reserve (e.g. 10% = 0.10e27)
    uint256 public reserveFactor;

    event RateParametersUpdated(uint256 baseRate, uint256 slope, uint256 reserveFactor);

    constructor(
        uint256 _baseRatePerYear, // e.g. 0.02e27 = 2%
        uint256 _slopePerYear,    // e.g. 0.20e27 = 20%
        uint256 _reserveFactor    // e.g. 0.10e27 = 10%
    ) Ownable(msg.sender) {
        require(_reserveFactor < RAY, "IRM: reserve factor >= 1");
        baseRatePerYear = _baseRatePerYear;
        slopePerYear    = _slopePerYear;
        reserveFactor   = _reserveFactor;
    }

    /// @notice Returns the current per-second borrow rate given utilization.
    /// @param totalBorrow  Total tokens currently borrowed (scaled to token decimals).
    /// @param totalSupply  Total tokens supplied to the pool (scaled to token decimals).
    /// @return borrowRatePerSecond  Ray-scaled per-second borrow rate.
    function getBorrowRate(
        uint256 totalBorrow,
        uint256 totalSupply
    ) external view returns (uint256 borrowRatePerSecond) {
        uint256 utilization = _getUtilization(totalBorrow, totalSupply);
        uint256 annualRate = baseRatePerYear + (slopePerYear * utilization) / RAY;
        borrowRatePerSecond = annualRate / SECONDS_PER_YEAR;
    }

    /// @notice Returns the current per-second supply rate given utilization.
    /// @param totalBorrow  Total tokens currently borrowed.
    /// @param totalSupply  Total tokens supplied.
    /// @return supplyRatePerSecond  Ray-scaled per-second supply rate.
    function getSupplyRate(
        uint256 totalBorrow,
        uint256 totalSupply
    ) external view returns (uint256 supplyRatePerSecond) {
        uint256 utilization = _getUtilization(totalBorrow, totalSupply);
        uint256 annualBorrowRate = baseRatePerYear + (slopePerYear * utilization) / RAY;
        // supply_rate = borrow_rate * utilization * (1 - reserve_factor)
        uint256 annualSupplyRate = (annualBorrowRate * utilization / RAY)
            * (RAY - reserveFactor) / RAY;
        supplyRatePerSecond = annualSupplyRate / SECONDS_PER_YEAR;
    }

    /// @notice Update model parameters (owner only).
    function setRateParameters(
        uint256 _baseRatePerYear,
        uint256 _slopePerYear,
        uint256 _reserveFactor
    ) external onlyOwner {
        require(_reserveFactor < RAY, "IRM: reserve factor >= 1");
        baseRatePerYear = _baseRatePerYear;
        slopePerYear    = _slopePerYear;
        reserveFactor   = _reserveFactor;
        emit RateParametersUpdated(_baseRatePerYear, _slopePerYear, _reserveFactor);
    }

    // ─────────────────────────────── Internal ───────────────────────────────

    function _getUtilization(
        uint256 totalBorrow,
        uint256 totalSupply
    ) internal pure returns (uint256) {
        if (totalSupply == 0) return 0;
        // utilization is in ray (1e27)
        return (totalBorrow * RAY) / totalSupply;
    }
}
