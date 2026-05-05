// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "./AToken.sol";
import "./DebtToken.sol";
import "./PriceOracle.sol";
import "./InterestRateModel.sol";

contract LendingPool is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ─────────────────────────────── Constants ───────────────────────────────

    uint256 public constant RAY      = 1e27;
    uint256 public constant WAD      = 1e18;
    uint256 public constant LIQUIDATION_BONUS = 0.05e18; 
    uint256 public constant HF_PRECISION = 1e18;

    // ────────────────────────────── Data types ───────────────────────────────

    struct ReserveData {
        AToken    aToken;
        DebtToken debtToken;
        uint256   supplyIndex;
        uint256   borrowIndex;
        uint256   lastUpdateTimestamp;
        uint256   totalDeposits; 
        uint256   totalBorrows;  
        uint256   reserveTreasury;
        uint256   ltv;                  
        uint256   liquidationThreshold; 
        bool      active;
    }

    // ─────────────────────────────── State ───────────────────────────────────

    mapping(address => ReserveData) public reserves;
    address[] public reserveList;
    PriceOracle public oracle;
    InterestRateModel public irm;

    // ─────────────────────────────── Events ──────────────────────────────────

    event ReserveInitialized(address indexed asset, address aToken, address debtToken);
    event Deposit(address indexed asset, address indexed user, uint256 amount);
    event Withdraw(address indexed asset, address indexed user, uint256 amount);
    event Borrow(address indexed asset, address indexed user, uint256 amount);
    event Repay(address indexed asset, address indexed user, uint256 amount);
    event Liquidation(
        address indexed collateralAsset,
        address indexed debtAsset,
        address indexed user,
        uint256 debtRepaid,
        uint256 collateralSeized
    );
    event ReserveUpdated(address indexed asset, uint256 supplyIndex, uint256 borrowIndex);

    // ─────────────────────────────── Constructor ─────────────────────────────

    constructor(address _oracle, address _irm) Ownable(msg.sender) {
        require(_oracle != address(0), "LP: zero oracle");
        require(_irm    != address(0), "LP: zero IRM");
        oracle = PriceOracle(_oracle);
        irm    = InterestRateModel(_irm);
    }

    // ─────────────────────────── Admin: init reserve ─────────────────────────

    function initReserve(
        address asset,
        uint256 ltv,
        uint256 liquidationThreshold,
        string calldata aTokenName,
        string calldata aTokenSymbol
    ) external onlyOwner {
        require(asset != address(0),                              "LP: zero asset");
        require(!reserves[asset].active,                          "LP: already initialized");
        require(ltv < liquidationThreshold,                       "LP: ltv >= threshold");
        require(liquidationThreshold <= WAD,                      "LP: threshold > 1");

        AToken    aToken    = new AToken(asset, aTokenName, aTokenSymbol);
        DebtToken debtToken = new DebtToken(
            asset,
            string(abi.encodePacked("Debt-", aTokenName)),
            string(abi.encodePacked("d", aTokenSymbol))
        );

        aToken.setLendingPool(address(this));
        debtToken.setLendingPool(address(this));

        reserves[asset] = ReserveData({
            aToken               : aToken,
            debtToken            : debtToken,
            supplyIndex          : RAY,
            borrowIndex          : RAY,
            lastUpdateTimestamp  : block.timestamp,
            totalDeposits        : 0,
            totalBorrows         : 0,
            reserveTreasury      : 0,
            ltv                  : ltv,
            liquidationThreshold : liquidationThreshold,
            active               : true
        });
        reserveList.push(asset);

        emit ReserveInitialized(asset, address(aToken), address(debtToken));
    }

    function _normalizeToWad(address asset, uint256 amount) internal view returns (uint256) {
        uint8 decimals = IERC20Metadata(asset).decimals();
        if (decimals < 18) {
            return amount * (10 ** (18 - decimals));
        } else {
            return amount;
        }
    }

    // ────────────────────────────── Deposit ──────────────────────────────────

    function deposit(address asset, uint256 amount) external nonReentrant {
        require(amount > 0, "LP: zero amount");
        ReserveData storage reserve = _getActiveReserve(asset);

        _updateReserveIndexes(asset, reserve);

        uint256 scaledAmount = (amount * RAY) / reserve.supplyIndex;
        reserve.totalDeposits += amount;

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        reserve.aToken.mint(msg.sender, scaledAmount);

        emit Deposit(asset, msg.sender, amount);
    }

    // ────────────────────────────── Withdraw ─────────────────────────────────

    function withdraw(address asset, uint256 amount) external nonReentrant {
        ReserveData storage reserve = _getActiveReserve(asset);

        _updateReserveIndexes(asset, reserve);

        uint256 userActualBalance = _getActualSupplyBalance(reserve, msg.sender);
        if (amount == type(uint256).max) {
            amount = userActualBalance;
        }
        require(amount > 0,                      "LP: zero amount");
        require(amount <= userActualBalance,      "LP: exceeds balance");
        
        // Strict physical liquidity check to prevent ERC20 insufficient balance panics
        uint256 poolBalance = IERC20(asset).balanceOf(address(this));
        require(poolBalance >= amount, "LP: insufficient liquidity");

        uint256 scaledAmount = (amount * RAY) / reserve.supplyIndex;
        if (scaledAmount > reserve.aToken.balanceOf(msg.sender)) {
            scaledAmount = reserve.aToken.balanceOf(msg.sender);
        }

        _requireHealthyAfterWithdraw(asset, msg.sender, amount);
        reserve.totalDeposits -= amount;

        reserve.aToken.burn(msg.sender, scaledAmount);

        IERC20(asset).safeTransfer(msg.sender, amount);
        emit Withdraw(asset, msg.sender, amount);
    }

    // ─────────────────────────────── Borrow ──────────────────────────────────

    function borrow(address asset, uint256 amount) external nonReentrant {
        require(amount > 0, "LP: zero amount");
        ReserveData storage reserve = _getActiveReserve(asset);

        _updateReserveIndexes(asset, reserve);

        uint256 availableLiquidity = reserve.totalDeposits - reserve.totalBorrows;
        require(amount <= availableLiquidity, "LP: insufficient liquidity");

        // Unused local variable prevBorrows removed to clear compiler warning
        reserve.totalBorrows += amount; 

        uint256 scaledDebt = (amount * RAY) / reserve.borrowIndex;
        reserve.debtToken.mint(msg.sender, scaledDebt);

        _requireSufficientCollateral(msg.sender, asset, amount);

        IERC20(asset).safeTransfer(msg.sender, amount);

        emit Borrow(asset, msg.sender, amount);
    }

    // ──────────────────────────────── Repay ──────────────────────────────────

    function repay(address asset, uint256 amount) external nonReentrant {
        ReserveData storage reserve = _getActiveReserve(asset);

        _updateReserveIndexes(asset, reserve);

        uint256 actualDebt = _getActualDebt(reserve, msg.sender);
        require(actualDebt > 0, "LP: no debt to repay");

        if (amount == type(uint256).max || amount > actualDebt) {
            amount = actualDebt;
        }
        require(amount > 0, "LP: zero amount");

        uint256 scaledBurn = (amount * RAY) / reserve.borrowIndex;
        uint256 scaledBal  = reserve.debtToken.scaledBalanceOf(msg.sender);
        if (scaledBurn > scaledBal) scaledBurn = scaledBal;

        reserve.totalBorrows -= amount;

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        reserve.debtToken.burn(msg.sender, scaledBurn);

        emit Repay(asset, msg.sender, amount);
    }

    // ─────────────────────────────── Liquidate ───────────────────────────────

    function liquidate(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover
    ) external nonReentrant {
        require(user       != address(0), "LP: zero user");
        require(user       != msg.sender, "LP: self liquidation");
        require(debtToCover > 0,          "LP: zero debt");

        ReserveData storage collReserve = _getActiveReserve(collateralAsset);
        ReserveData storage debtReserve = _getActiveReserve(debtAsset);
        _updateReserveIndexes(collateralAsset, collReserve);
        _updateReserveIndexes(debtAsset, debtReserve);

        uint256 hf = getHealthFactor(user);
        require(hf < HF_PRECISION, "LP: position healthy");

        uint256 totalDebt = _getActualDebt(debtReserve, user);
        require(totalDebt > 0, "LP: user has no debt in this asset");
        uint256 maxCover = totalDebt / 2;
        if (debtToCover > maxCover) debtToCover = maxCover;

        uint256 collateralToSeize = _calculateCollateralToSeize(
            collateralAsset,
            debtAsset,
            debtToCover
        );

        uint256 userCollateral = _getActualSupplyBalance(collReserve, user);
        require(collateralToSeize <= userCollateral, "LP: insufficient collateral to seize");

        uint256 scaledDebtBurn = (debtToCover * RAY) / debtReserve.borrowIndex;
        uint256 scaledDebtBal  = debtReserve.debtToken.scaledBalanceOf(user);
        if (scaledDebtBurn > scaledDebtBal) scaledDebtBurn = scaledDebtBal;

        debtReserve.totalBorrows -= debtToCover;

        uint256 scaledCollBurn = (collateralToSeize * RAY) / collReserve.supplyIndex;
        uint256 scaledCollBal  = collReserve.aToken.balanceOf(user);
        if (scaledCollBurn > scaledCollBal) scaledCollBurn = scaledCollBal;

        collReserve.totalDeposits -= collateralToSeize;

        IERC20(debtAsset).safeTransferFrom(msg.sender, address(this), debtToCover);
        debtReserve.debtToken.burn(user, scaledDebtBurn);

        collReserve.aToken.burn(user, scaledCollBurn);
        IERC20(collateralAsset).safeTransfer(msg.sender, collateralToSeize);

        emit Liquidation(collateralAsset, debtAsset, user, debtToCover, collateralToSeize);
    }

    // ──────────────────────────── View functions ─────────────────────────────

    function getSupplyBalance(address asset, address user) external view returns (uint256) {
        ReserveData storage reserve = reserves[asset];
        require(reserve.active, "LP: inactive reserve");
        (, uint256 newSupplyIndex,) = _previewIndexes(asset, reserve);
        uint256 scaledBal = reserve.aToken.balanceOf(user);
        return (scaledBal * newSupplyIndex) / RAY;
    }

    function getDebtBalance(address asset, address user) external view returns (uint256) {
        ReserveData storage reserve = reserves[asset];
        require(reserve.active, "LP: inactive reserve");
        (uint256 newBorrowIndex,,) = _previewIndexes(asset, reserve);
        uint256 scaledBal = reserve.debtToken.scaledBalanceOf(user);
        return (scaledBal * newBorrowIndex) / RAY;
    }

    function getHealthFactor(address user) public view returns (uint256) {
        uint256 totalCollateralUSD = 0;
        uint256 totalDebtUSD       = 0;

        for (uint256 i = 0; i < reserveList.length; i++) {
            address asset = reserveList[i];
            ReserveData storage reserve = reserves[asset];
            if (!reserve.active) continue;

            (uint256 newBorrowIndex, uint256 newSupplyIndex,) = _previewIndexes(asset, reserve);
            uint256 assetPrice = oracle.getPrice(asset);

            uint256 scaledSupply = reserve.aToken.balanceOf(user);
            if (scaledSupply > 0) {
                uint256 actualSupply = (scaledSupply * newSupplyIndex) / RAY;
                uint256 normalizedSupply = _normalizeToWad(asset, actualSupply);
                uint256 valueUSD = (normalizedSupply * assetPrice) / WAD;
                totalCollateralUSD += (valueUSD * reserve.liquidationThreshold) / WAD;
            }

            uint256 scaledDebt = reserve.debtToken.scaledBalanceOf(user);
            if (scaledDebt > 0) {
                uint256 actualDebt = (scaledDebt * newBorrowIndex) / RAY;
                uint256 normalizedDebt = _normalizeToWad(asset, actualDebt);
                totalDebtUSD += (normalizedDebt * assetPrice) / WAD;
            }
        }

        if (totalDebtUSD == 0) return type(uint256).max;
        return (totalCollateralUSD * HF_PRECISION) / totalDebtUSD;
    }

    function getReserveData(address asset)
        external
        view
        returns (
            uint256 totalDeposits,
            uint256 totalBorrows,
            uint256 supplyIndex,
            uint256 borrowIndex,
            uint256 utilizationRate,
            uint256 borrowRatePerSecond,
            uint256 supplyRatePerSecond
        )
    {
        ReserveData storage r = reserves[asset];
        require(r.active, "LP: inactive reserve");
        (uint256 newBorrowIndex, uint256 newSupplyIndex,) = _previewIndexes(asset, r);
        totalDeposits       = r.totalDeposits;
        totalBorrows        = r.totalBorrows;
        supplyIndex         = newSupplyIndex;
        borrowIndex         = newBorrowIndex;
        utilizationRate     = r.totalDeposits == 0 ? 0 : (r.totalBorrows * RAY) / r.totalDeposits;
        borrowRatePerSecond = irm.getBorrowRate(r.totalBorrows, r.totalDeposits);
        supplyRatePerSecond = irm.getSupplyRate(r.totalBorrows, r.totalDeposits);
    }

    // ─────────────────────────── Internal helpers ────────────────────────────

    function _updateReserveIndexes(address asset, ReserveData storage reserve) internal {
        if (reserve.lastUpdateTimestamp == block.timestamp) return;

        uint256 elapsed = block.timestamp - reserve.lastUpdateTimestamp;

        uint256 borrowRate = irm.getBorrowRate(reserve.totalBorrows, reserve.totalDeposits);
        uint256 supplyRate = irm.getSupplyRate(reserve.totalBorrows, reserve.totalDeposits);

        uint256 borrowFactor = RAY + (borrowRate * elapsed);
        uint256 supplyFactor = RAY + (supplyRate * elapsed);

        uint256 prevBorrowIndex = reserve.borrowIndex;
        uint256 prevSupplyIndex = reserve.supplyIndex;

        reserve.borrowIndex = (reserve.borrowIndex * borrowFactor) / RAY;
        reserve.supplyIndex = (reserve.supplyIndex * supplyFactor) / RAY;

        if (reserve.totalBorrows > 0) {
            uint256 prevTotalBorrows = reserve.totalBorrows;
            reserve.totalBorrows = (reserve.totalBorrows * reserve.borrowIndex) / prevBorrowIndex;
            uint256 interestAccrued  = reserve.totalBorrows - prevTotalBorrows;
            uint256 supplyInterest   = reserve.totalDeposits > 0
                ? (reserve.totalDeposits * reserve.supplyIndex) / prevSupplyIndex - reserve.totalDeposits
                : 0;
            if (interestAccrued > supplyInterest) {
                reserve.reserveTreasury += interestAccrued - supplyInterest;
            }
        }

        if (reserve.totalDeposits > 0) {
            reserve.totalDeposits = (reserve.totalDeposits * reserve.supplyIndex) / prevSupplyIndex;
        }

        reserve.lastUpdateTimestamp = block.timestamp;
        emit ReserveUpdated(asset, reserve.supplyIndex, reserve.borrowIndex);
    }

    // Commented out unused asset parameter to silence compiler warning
    function _previewIndexes(address /* asset */, ReserveData storage reserve)
        internal
        view
        returns (
            uint256 newBorrowIndex,
            uint256 newSupplyIndex,
            uint256 elapsed
        )
    {
        elapsed         = block.timestamp - reserve.lastUpdateTimestamp;
        uint256 bRate   = irm.getBorrowRate(reserve.totalBorrows, reserve.totalDeposits);
        uint256 sRate   = irm.getSupplyRate(reserve.totalBorrows, reserve.totalDeposits);
        newBorrowIndex  = (reserve.borrowIndex * (RAY + bRate * elapsed)) / RAY;
        newSupplyIndex  = (reserve.supplyIndex * (RAY + sRate * elapsed)) / RAY;
    }

    function _getActualSupplyBalance(ReserveData storage reserve, address user)
        internal
        view
        returns (uint256)
    {
        uint256 scaledBal = reserve.aToken.balanceOf(user);
        return (scaledBal * reserve.supplyIndex) / RAY;
    }

    function _getActualDebt(ReserveData storage reserve, address user)
        internal
        view
        returns (uint256)
    {
        uint256 scaledBal = reserve.debtToken.scaledBalanceOf(user);
        return (scaledBal * reserve.borrowIndex) / RAY;
    }

    // Commented out unused borrowAsset and borrowAmount parameters to silence warnings
    function _requireSufficientCollateral(
        address user,
        address /* borrowAsset */,
        uint256 /* borrowAmount */
    ) internal view {
        uint256 hf = getHealthFactor(user);
        require(hf >= HF_PRECISION, "LP: insufficient collateral");
    }

    function _requireHealthyAfterWithdraw(
        address asset,
        address user,
        uint256 amount
    ) internal view {
        uint256 totalCollateralUSD = 0;
        uint256 totalDebtUSD       = 0;

        for (uint256 i = 0; i < reserveList.length; i++) {
            address a = reserveList[i];
            ReserveData storage r = reserves[a];
            if (!r.active) continue;

            (uint256 newBorrowIndex, uint256 newSupplyIndex,) = _previewIndexes(a, r);
            uint256 price = oracle.getPrice(a);

            uint256 scaledSupply = r.aToken.balanceOf(user);
            uint256 actualSupply = (scaledSupply * newSupplyIndex) / RAY;

            if (a == asset) {
                if (amount >= actualSupply) actualSupply = 0;
                else actualSupply -= amount;
            }

            uint256 normalizedSupply = _normalizeToWad(a, actualSupply);
            uint256 valueUSD = (normalizedSupply * price) / WAD;

            totalCollateralUSD += (valueUSD * r.liquidationThreshold) / WAD;

            uint256 scaledDebt = r.debtToken.scaledBalanceOf(user);
            if (scaledDebt > 0) {
                uint256 actualDebt = (scaledDebt * newBorrowIndex) / RAY;
                uint256 normalizedDebt = _normalizeToWad(a, actualDebt);
                totalDebtUSD += (normalizedDebt * price) / WAD;
            }
        }

        if (totalDebtUSD == 0) return;

        uint256 hf = (totalCollateralUSD * HF_PRECISION) / totalDebtUSD;
        require(hf >= HF_PRECISION, "LP: withdraw breaks health factor");
    }

    function _calculateCollateralToSeize(
        address collateralAsset,
        address debtAsset,
        uint256 debtToCover
    ) internal view returns (uint256 collateralAmount) {
        uint256 debtPrice        = oracle.getPrice(debtAsset);
        uint256 collateralPrice  = oracle.getPrice(collateralAsset);
        require(collateralPrice  > 0, "LP: zero collateral price");

        uint256 normalizedDebt = _normalizeToWad(debtAsset, debtToCover);
        uint256 debtValueUSD = (normalizedDebt * debtPrice) / WAD;

        collateralAmount =
            (debtValueUSD * (WAD + LIQUIDATION_BONUS)) / collateralPrice;
    }

    function _getActiveReserve(address asset) internal view returns (ReserveData storage) {
        ReserveData storage reserve = reserves[asset];
        require(reserve.active, "LP: inactive reserve");
        return reserve;
    }
}