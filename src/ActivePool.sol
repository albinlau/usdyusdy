// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.28;

import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/utils/math/Math.sol";
import "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import "openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import "./Dependencies/Constants.sol";
import "./Interfaces/IActivePool.sol";
import "./Interfaces/IAddressesRegistry.sol";
import "./Interfaces/IUSDXToken.sol";
import "./Interfaces/IInterestRouter.sol";
import "./Interfaces/IDefaultPool.sol";
import "./Interfaces/ICollateralConfig.sol";

/*
 * The Active Pool holds the collateral and USDX debt (but not USDX tokens) for all active troves.
 *
 * When a trove is liquidated, it's Coll and USDX debt are transferred from the Active Pool, to either the
 * Stability Pool, the Default Pool, or both, depending on the liquidation conditions.
 *
 */
contract ActivePool is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    IActivePool
{
    using SafeERC20 for IERC20;

    string public constant NAME = "ActivePool";

    IERC20 public immutable collToken;
    address public borrowerOperationsAddress;
    address public troveManagerAddress;
    address public defaultPoolAddress;

    IUSDXToken public usdxToken;

    IInterestRouter public interestRouter;
    IUSDXRewardsReceiver public stabilityPool;
    ICollateralConfig public collateralConfig;

    uint256 internal collBalance; // deposited coll tracker

    // Aggregate recorded debt tracker. Updated whenever a Trove's debt is touched AND whenever the aggregate pending interest is minted.
    // "D" in the spec.
    uint256 public aggRecordedDebt;

    // Last time at which the aggregate recorded debt was updated
    uint256 public lastAggUpdateTime;

    // Timestamp at which branch was shut down. 0 if not shut down.
    uint256 public shutdownTime;

    // --- Events ---

    event CollTokenAddressChanged(address _newCollTokenAddress);
    event BorrowerOperationsAddressChanged(
        address _newBorrowerOperationsAddress
    );
    event TroveManagerAddressChanged(address _newTroveManagerAddress);
    event DefaultPoolAddressChanged(address _newDefaultPoolAddress);
    event StabilityPoolAddressChanged(address _newStabilityPoolAddress);
    event ActivePoolUSDXDebtUpdated(uint256 _recordedDebtSum);
    event ActivePoolCollBalanceUpdated(uint256 _collBalance);

    constructor(IAddressesRegistry _addressesRegistry) {
        _disableInitializers();
        collToken = _addressesRegistry.collToken();
        borrowerOperationsAddress = address(
            _addressesRegistry.borrowerOperations()
        );
        troveManagerAddress = address(_addressesRegistry.troveManager());
        stabilityPool = IUSDXRewardsReceiver(
            _addressesRegistry.stabilityPool()
        );
        collateralConfig = _addressesRegistry.collateralConfig();
        defaultPoolAddress = address(_addressesRegistry.defaultPool());
        interestRouter = _addressesRegistry.interestRouter();
        usdxToken = _addressesRegistry.usdxToken();

        emit CollTokenAddressChanged(address(collToken));
        emit BorrowerOperationsAddressChanged(borrowerOperationsAddress);
        emit TroveManagerAddressChanged(troveManagerAddress);
        emit StabilityPoolAddressChanged(address(stabilityPool));
        emit DefaultPoolAddressChanged(defaultPoolAddress);
    }

    function initialize(address initialOwner) public initializer {
        __Ownable_init();
        transferOwnership(initialOwner);

        // Allow funds movements between Liquity contracts
        collToken.approve(defaultPoolAddress, type(uint256).max);
    }

    function updateByAddressRegistry(
        IAddressesRegistry _addressesRegistry
    ) external onlyOwner {
        borrowerOperationsAddress = address(
            _addressesRegistry.borrowerOperations()
        );
        troveManagerAddress = address(_addressesRegistry.troveManager());
        stabilityPool = IUSDXRewardsReceiver(
            _addressesRegistry.stabilityPool()
        );
        collateralConfig = _addressesRegistry.collateralConfig();
        defaultPoolAddress = address(_addressesRegistry.defaultPool());
        interestRouter = _addressesRegistry.interestRouter();
        usdxToken = _addressesRegistry.usdxToken();

        emit CollTokenAddressChanged(address(collToken));
        emit BorrowerOperationsAddressChanged(borrowerOperationsAddress);
        emit TroveManagerAddressChanged(troveManagerAddress);
        emit StabilityPoolAddressChanged(address(stabilityPool));
        emit DefaultPoolAddressChanged(defaultPoolAddress);
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    // --- Getters for public variables. Required by IPool interface ---

    /*
     * Returns the Coll state variable.
     *
     *Not necessarily equal to the contract's raw Coll balance - ether can be forcibly sent to contracts.
     */
    function getCollBalance() external view override returns (uint256) {
        return collBalance;
    }

    /**
     * @notice Calculate pending aggregate interest
     * @dev Uses unified interest rate from CollateralConfig
     */
    function calcPendingAggInterest() public view returns (uint256) {
        if (shutdownTime != 0) return 0;

        // Retrieve unified interest rate
        uint256 annualInterestRate = collateralConfig.getAnnualInterestRate();
        uint256 timePeriod = block.timestamp - lastAggUpdateTime;

        // We use the ceiling of the division here to ensure positive error
        // This ensures that `system debt >= sum(trove debt)` always holds
        return
            Math.ceilDiv(
                aggRecordedDebt * annualInterestRate * timePeriod,
                ONE_YEAR * DECIMAL_PRECISION
            );
    }

    function calcPendingSPYield() external view returns (uint256) {
        return (calcPendingAggInterest() * SP_YIELD_SPLIT) / DECIMAL_PRECISION;
    }

    /**
     * @notice Get new approximate average interest rate
     * @dev Now simply returns the unified rate from Config
     */
    function getNewApproxAvgInterestRateFromTroveChange(
        TroveChange calldata _troveChange
    ) external view returns (uint256) {
        if (shutdownTime != 0) return 0;

        // Return unified interest rate
        return collateralConfig.getAnnualInterestRate();
    }

    // Returns sum of agg.recorded debt plus agg. pending interest
    function getUSDXDebt() external view returns (uint256) {
        return aggRecordedDebt + calcPendingAggInterest();
    }

    // --- Pool functionality ---

    function sendColl(address _account, uint256 _amount) external override {
        _requireCallerIsBOorTroveMorSP();

        _accountForSendColl(_amount);

        collToken.safeTransfer(_account, _amount);
    }

    function sendCollToDefaultPool(uint256 _amount) external override {
        _requireCallerIsTroveManager();

        _accountForSendColl(_amount);

        IDefaultPool(defaultPoolAddress).receiveColl(_amount);
    }

    function _accountForSendColl(uint256 _amount) internal {
        uint256 newCollBalance = collBalance - _amount;
        collBalance = newCollBalance;
        emit ActivePoolCollBalanceUpdated(newCollBalance);
    }

    function receiveColl(uint256 _amount) external {
        _requireCallerIsBorrowerOperationsOrDefaultPool();

        _accountForReceivedColl(_amount);

        // Pull Coll tokens from sender
        collToken.safeTransferFrom(msg.sender, address(this), _amount);
    }

    function accountForReceivedColl(uint256 _amount) public {
        _requireCallerIsBorrowerOperationsOrDefaultPool();

        _accountForReceivedColl(_amount);
    }

    function _accountForReceivedColl(uint256 _amount) internal {
        uint256 newCollBalance = collBalance + _amount;
        collBalance = newCollBalance;

        emit ActivePoolCollBalanceUpdated(newCollBalance);
    }

    // --- Aggregate interest operations ---

    // This function is called inside all state-changing user ops: borrower ops, liquidations, redemptions and SP deposits/withdrawals.
    // Some user ops trigger debt changes to Trove(s), in which case _troveDebtChange will be non-zero.
    // The aggregate recorded debt is incremented by the aggregate pending interest, plus the net Trove debt change.
    // The net Trove debt change consists of the sum of a) any debt issued/repaid and b) any redistribution debt gain applied in the encapsulating operation.
    // It does *not* include the Trove's individual accrued interest - this gets accounted for in the aggregate accrued interest.
    // The net Trove debt change could be positive or negative in a repayment (depending on whether its redistribution gain or repayment amount is larger),
    // so this function accepts both the increase and the decrease to avoid using (and converting to/from) signed ints.
    function mintAggInterestAndAccountForTroveChange(
        TroveChange calldata _troveChange
    ) external {
        _requireCallerIsBOorTroveM();

        // Do the arithmetic in 2 steps here to avoid underflow from the decrease
        uint256 newAggRecordedDebt = aggRecordedDebt; // 1 SLOAD
        newAggRecordedDebt += _mintAggInterest(); // adds minted agg. interest
        newAggRecordedDebt += _troveChange.appliedRedistUSDXDebtGain;
        newAggRecordedDebt += _troveChange.debtIncrease;
        newAggRecordedDebt -= _troveChange.debtDecrease;
        aggRecordedDebt = newAggRecordedDebt; // 1 SSTORE
    }

    function mintAggInterest() external override {
        _requireCallerIsBOorSP();
        aggRecordedDebt += _mintAggInterest();
    }

    function _mintAggInterest() internal returns (uint256 mintedAmount) {
        mintedAmount = calcPendingAggInterest();

        // Mint part of the USDX interest to the SP and part to the router for LPs.
        if (mintedAmount > 0) {
            uint256 spYield = (SP_YIELD_SPLIT * mintedAmount) /
                DECIMAL_PRECISION;
            uint256 remainderToLPs = mintedAmount - spYield;

            usdxToken.mint(address(interestRouter), remainderToLPs);

            if (spYield > 0) {
                usdxToken.mint(address(stabilityPool), spYield);
                stabilityPool.triggerUSDXRewards(spYield);
            }
        }

        lastAggUpdateTime = block.timestamp;
    }

    // --- Shutdown ---

    function setShutdownFlag() external {
        _requireCallerIsTroveManager();
        shutdownTime = block.timestamp;
    }

    function hasBeenShutDown() external view returns (bool) {
        return shutdownTime != 0;
    }

    // --- 'require' functions ---

    function _requireCallerIsBorrowerOperationsOrDefaultPool() internal view {
        require(
            msg.sender == borrowerOperationsAddress ||
                msg.sender == defaultPoolAddress,
            "ActivePool: Caller is neither BO nor Default Pool"
        );
    }

    function _requireCallerIsBOorTroveMorSP() internal view {
        require(
            msg.sender == borrowerOperationsAddress ||
                msg.sender == troveManagerAddress ||
                msg.sender == address(stabilityPool),
            "ActivePool: Caller is neither BorrowerOperations nor TroveManager nor StabilityPool"
        );
    }

    function _requireCallerIsBOorSP() internal view {
        require(
            msg.sender == borrowerOperationsAddress ||
                msg.sender == address(stabilityPool),
            "ActivePool: Caller is not BorrowerOperations nor StabilityPool"
        );
    }

    function _requireCallerIsBOorTroveM() internal view {
        require(
            msg.sender == borrowerOperationsAddress ||
                msg.sender == troveManagerAddress,
            "ActivePool: Caller is neither BorrowerOperations nor TroveManager"
        );
    }

    function _requireCallerIsTroveManager() internal view {
        require(
            msg.sender == troveManagerAddress,
            "ActivePool: Caller is not TroveManager"
        );
    }
}
