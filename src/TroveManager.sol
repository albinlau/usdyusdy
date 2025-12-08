// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.28;

import "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import "openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import "./Interfaces/ITroveManager.sol";
import "./Interfaces/IAddressesRegistry.sol";
import "./Interfaces/IStabilityPool.sol";
import "./Interfaces/ICollSurplusPool.sol";
import "./Interfaces/IUSDXToken.sol";
import "./Interfaces/ISortedTroves.sol";
import "./Interfaces/ITroveEvents.sol";
import "./Interfaces/ITroveNFT.sol";
import "./Interfaces/ICollateralRegistry.sol";
import "./Interfaces/ICollateralConfig.sol";
import "./Interfaces/IWETH.sol";
import "./Dependencies/LiquityBase.sol";

contract TroveManager is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    LiquityBase,
    ITroveManager,
    ITroveEvents
{
    // --- Connected contract declarations ---

    ITroveNFT public troveNFT;
    IBorrowerOperations public borrowerOperations;
    IStabilityPool public stabilityPool;
    address internal gasPoolAddress;
    ICollSurplusPool internal collSurplusPool;
    IUSDXToken internal usdxToken;
    // A doubly linked list of Troves, sorted by their interest rate
    ISortedTroves public sortedTroves;
    ICollateralRegistry internal collateralRegistry;
    ICollateralConfig public collateralConfig;
    // Wrapped ETH for liquidation reserve (gas compensation)
    IWETH internal immutable WETH;

    // Critical system collateral ratio. If the system's total collateral ratio (TCR) falls below the CCR, some borrowing operation restrictions are applied
    uint256 public immutable CCR;

    // Minimum collateral ratio for individual troves
    uint256 internal immutable MCR;
    // Shutdown system collateral ratio. If the system's total collateral ratio (TCR) for a given collateral falls below the SCR,
    // the protocol triggers the shutdown of the borrow market and permanently disables all borrowing operations except for closing Troves.
    uint256 internal immutable SCR;

    // Liquidation penalty for troves liquidator
    uint256 public liquidationPenaltyLiquidator;
    // Liquidation penalty for troves offset to the SP
    uint256 public liquidationPenaltySp;
    // Liquidation penalty for troves dao
    uint256 public liquidationPenaltyDao;
    // Address of Liquidation dao penalty recipient address
    address public liquidationPenaltyDaoRecipient;

    // --- Data structures ---

    // Store the necessary data for a trove
    struct Trove {
        uint256 debt;
        uint256 coll;
        uint256 stake;
        Status status;
        uint64 arrayIndex;
        uint64 lastDebtUpdateTime;
    }

    mapping(uint256 => Trove) public Troves;

    uint256 internal totalStakes;

    // Snapshot of the value of totalStakes, taken immediately after the latest liquidation
    uint256 internal totalStakesSnapshot;

    // Snapshot of the total collateral across the ActivePool and DefaultPool, immediately after the latest liquidation.
    uint256 internal totalCollateralSnapshot;

    /*
     * L_coll and L_usdxDebt track the sums of accumulated liquidation rewards per unit staked. During its lifetime, each stake earns:
     *
     * An Coll gain of ( stake * [L_coll - L_coll(0)] )
     * A usdxDebt increase  of ( stake * [L_usdxDebt - L_usdxDebt(0)] )
     *
     * Where L_coll(0) and L_usdxDebt(0) are snapshots of L_coll and L_usdxDebt for the active Trove taken at the instant the stake was made
     */
    uint256 internal L_coll;
    uint256 internal L_usdxDebt;

    // Map active troves to their RewardSnapshot
    mapping(uint256 => RewardSnapshot) public rewardSnapshots;

    // Object containing the Coll and USDX snapshots for a given active trove
    struct RewardSnapshot {
        uint256 coll;
        uint256 usdxDebt;
    }

    // Array of all active trove addresses - used to compute an approximate hint off-chain, for the sorted list insertion
    uint256[] internal TroveIds;

    uint256 public lastZombieTroveId;

    // Error trackers for the trove redistribution calculation
    uint256 internal lastCollError_Redistribution;
    uint256 internal lastUSDXDebtError_Redistribution;

    // Timestamp at which branch was shut down. 0 if not shut down.
    uint256 public shutdownTime;

    /*
     * --- Variable container structs for liquidations ---
     *
     * These structs are used to hold, return and assign variables inside the liquidation functions,
     * in order to avoid the error: "CompilerError: Stack too deep".
     **/

    struct LiquidationValues {
        uint256 collGasCompensation;
        uint256 debtToOffset;
        uint256 collToSendToSP;
        uint256 debtToRedistribute;
        uint256 collToRedistribute;
        uint256 collToDao;
        uint256 collSurplus;
        uint256 ETHGasCompensation;
    }

    // --- Variable container structs for redemptions ---

    struct RedeemCollateralValues {
        uint256 totalCollFee;
        uint256 remainingUSDX;
        uint256 nextUserToCheck;
    }

    struct SingleRedemptionValues {
        uint256 troveId;
        uint256 usdxLot;
        uint256 collLot;
        uint256 collFee;
        uint256 appliedRedistUSDXDebtGain;
        uint256 newStake;
        bool isZombieTrove;
        LatestTroveData trove;
    }

    // --- Errors ---

    error EmptyData();
    error NothingToLiquidate();
    error CallerNotBorrowerOperations();
    error CallerNotCollateralRegistry();
    error OnlyOneTroveLeft();
    error NotShutDown();
    error ZeroAmount();
    error NotEnoughUSDXBalance();
    error MinCollNotReached(uint256 _coll);

    // --- Events ---

    event TroveNFTAddressChanged(address _newTroveNFTAddress);
    event BorrowerOperationsAddressChanged(
        address _newBorrowerOperationsAddress
    );
    event USDXTokenAddressChanged(address _newUSDXTokenAddress);
    event StabilityPoolAddressChanged(address _stabilityPoolAddress);
    event GasPoolAddressChanged(address _gasPoolAddress);
    event CollSurplusPoolAddressChanged(address _collSurplusPoolAddress);
    event SortedTrovesAddressChanged(address _sortedTrovesAddress);
    event CollateralRegistryAddressChanged(address _collateralRegistryAddress);
    event LiquidationPenaltyLiquidatorChanged(uint256 _liquidationPenaltyLiquidator);
    event LiquidationPenaltySpChanged(uint256 _liquidationPenaltySp);
    event LiquidationPenaltyDaoChanged(uint256 _liquidationPenaltyDao);
    event LiquidationPenaltyDaoRecipientChanged(address _liquidationPenaltyDaoRecipient);

    constructor(
        IAddressesRegistry _addressesRegistry
    ) LiquityBase(_addressesRegistry) {
        _disableInitializers();

        CCR = _addressesRegistry.CCR();
        MCR = _addressesRegistry.MCR();
        SCR = _addressesRegistry.SCR();

        WETH = _addressesRegistry.WETH();
    }

    function initialize(
        address initialOwner,
        IAddressesRegistry _addressesRegistry
    ) public initializer {
        __Ownable_init();
        transferOwnership(initialOwner);

        troveNFT = _addressesRegistry.troveNFT();
        borrowerOperations = _addressesRegistry.borrowerOperations();
        stabilityPool = _addressesRegistry.stabilityPool();
        gasPoolAddress = _addressesRegistry.gasPoolAddress();
        collSurplusPool = _addressesRegistry.collSurplusPool();
        usdxToken = _addressesRegistry.usdxToken();
        sortedTroves = _addressesRegistry.sortedTroves();
        collateralRegistry = _addressesRegistry.collateralRegistry();
        collateralConfig = _addressesRegistry.collateralConfig();

        liquidationPenaltySp = _addressesRegistry.liquidationPenaltySp();
        liquidationPenaltyLiquidator = _addressesRegistry
            .liquidationPenaltyLiquidator();
        liquidationPenaltyDao = _addressesRegistry.liquidationPenaltyDao();
        liquidationPenaltyDaoRecipient = _addressesRegistry.liquidationPenaltyDaoRecipient();

        emit TroveNFTAddressChanged(address(troveNFT));
        emit BorrowerOperationsAddressChanged(address(borrowerOperations));
        emit StabilityPoolAddressChanged(address(stabilityPool));
        emit GasPoolAddressChanged(gasPoolAddress);
        emit CollSurplusPoolAddressChanged(address(collSurplusPool));
        emit USDXTokenAddressChanged(address(usdxToken));
        emit SortedTrovesAddressChanged(address(sortedTroves));
        emit CollateralRegistryAddressChanged(address(collateralRegistry));
        emit LiquidationPenaltyLiquidatorChanged(liquidationPenaltyLiquidator);
        emit LiquidationPenaltySpChanged(liquidationPenaltySp);
        emit LiquidationPenaltyDaoChanged(liquidationPenaltyDao);
        emit LiquidationPenaltyDaoRecipientChanged(liquidationPenaltyDaoRecipient);
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    // --- Getters ---

    function getTroveIdsCount() external view override returns (uint256) {
        return TroveIds.length;
    }

    function getTroveFromTroveIdsArray(
        uint256 _index
    ) external view override returns (uint256) {
        return TroveIds[_index];
    }

    // --- Trove Liquidation functions ---

    // --- Inner single liquidation functions ---

    // Liquidate one trove
    function _liquidate(
        IDefaultPool _defaultPool,
        uint256 _troveId,
        uint256 _usdxInSPForOffsets,
        uint256 _price,
        LatestTroveData memory trove,
        LiquidationValues memory singleLiquidation
    ) internal {
        address owner = troveNFT.ownerOf(_troveId);

        _getLatestTroveData(_troveId, trove);

        _movePendingTroveRewardsToActivePool(
            _defaultPool,
            trove.redistUSDXDebtGain,
            trove.redistCollGain
        );

        (
            singleLiquidation.debtToOffset,
            singleLiquidation.collToSendToSP,
            singleLiquidation.collGasCompensation,
            singleLiquidation.debtToRedistribute,
            singleLiquidation.collToRedistribute,
            singleLiquidation.collToDao,
            singleLiquidation.collSurplus
        ) = _getOffsetAndRedistributionVals(
            trove.entireDebt,
            trove.entireColl,
            _usdxInSPForOffsets,
            _price
        );

        TroveChange memory troveChange;
        troveChange.collDecrease = trove.entireColl;
        troveChange.debtDecrease = trove.entireDebt;
        troveChange.appliedRedistCollGain = trove.redistCollGain;
        troveChange.appliedRedistUSDXDebtGain = trove.redistUSDXDebtGain;
        _closeTrove(_troveId, troveChange, Status.closedByLiquidation);

        // Difference between liquidation penalty and liquidation threshold
        if (singleLiquidation.collSurplus > 0) {
            collSurplusPool.accountSurplus(
                owner,
                singleLiquidation.collSurplus
            );
        }

        // Wipe out state in BO
        borrowerOperations.onLiquidateTrove(_troveId);

        emit TroveUpdated({
            _troveId: _troveId,
            _debt: 0,
            _coll: 0,
            _stake: 0,
            _annualInterestRate: 0,
            _snapshotOfTotalCollRedist: 0,
            _snapshotOfTotalDebtRedist: 0
        });

        emit TroveOperation({
            _troveId: _troveId,
            _operation: Operation.liquidate,
            _annualInterestRate: 0,
            _debtIncreaseFromRedist: trove.redistUSDXDebtGain,
            _debtChangeFromOperation: -int256(trove.entireDebt),
            _collIncreaseFromRedist: trove.redistCollGain,
            _collChangeFromOperation: -int256(trove.entireColl)
        });
    }

    // Return the amount of Coll to be drawn from a trove's collateral and sent as gas compensation.
    function _getCollGasCompensation(
        uint256 _coll
    ) internal view returns (uint256) {
        // _entireDebt should never be zero, but we add the condition defensively to avoid an unexpected revert
        return
            LiquityMath._min(
                _coll * liquidationPenaltyLiquidator / DECIMAL_PRECISION,
                COLL_GAS_COMPENSATION_CAP
            );
    }

    /* In a full liquidation, returns the values for a trove's coll and debt to be offset, and coll and debt to be
     * redistributed to active troves.
     */
    function _getOffsetAndRedistributionVals(
        uint256 _entireTroveDebt,
        uint256 _entireTroveColl,
        uint256 _usdxInSPForOffsets,
        uint256 _price
    )
        internal
        view
        returns (
            uint256 debtToOffset,
            uint256 collToSendToSP,
            uint256 collGasCompensation,
            uint256 debtToRedistribute,
            uint256 collToRedistribute,
            uint256 collToDao,
            uint256 collSurplus
        )
    {
        uint256 collSPPortion;
        /*
         * Offset as much debt & collateral as possible against the Stability Pool, and redistribute the remainder
         * between all active troves.
         *
         *  If the trove's debt is larger than the deposited USDX in the Stability Pool:
         *
         *  - Offset an amount of the trove's debt equal to the USDX in the Stability Pool
         *  - Send a fraction of the trove's collateral to the Stability Pool, equal to the fraction of its offset debt
         *
         */
        if (_usdxInSPForOffsets > 0) {
            debtToOffset = LiquityMath._min(
                _entireTroveDebt,
                _usdxInSPForOffsets
            );
            collSPPortion =
                (_entireTroveColl * debtToOffset) /
                _entireTroveDebt;

            collGasCompensation = _getCollGasCompensation(collSPPortion);

            (collToSendToSP, collSurplus) = _getCollPenaltyAndSurplus(
                collSPPortion,
                debtToOffset,
                liquidationPenaltySp,
                _price
            );
        }

        // Redistribution
        debtToRedistribute = _entireTroveDebt - debtToOffset;
        if (debtToRedistribute > 0) {
            uint256 collRedistributionPortion = _entireTroveColl -
                collSPPortion;
            if (collRedistributionPortion > 0) {
                (collToRedistribute, collSurplus) = _getCollPenaltyAndSurplus(
                    collRedistributionPortion + collSurplus, // Coll surplus from offset can be eaten up by red. penalty
                    debtToRedistribute,
                    liquidationPenaltyLiquidator + liquidationPenaltySp, // _penaltyRatio
                    _price
                );
            }
        }

        if (collSurplus > 0) {
            uint256 collToDaoNeed = _entireTroveDebt * liquidationPenaltyDao / _price;
            collToDao = LiquityMath._min(
                collToDaoNeed,
                collSurplus
            );
            collSurplus = collSurplus - collToDao;
        }
        // assert(_collToLiquidate == collToSendToSP + collToRedistribute + collSurplus);
    }

    function _getCollPenaltyAndSurplus(
        uint256 _collToLiquidate,
        uint256 _debtToLiquidate,
        uint256 _penaltyRatio,
        uint256 _price
    ) internal pure returns (uint256 seizedColl, uint256 collSurplus) {
        uint256 maxSeizedColl = (_debtToLiquidate *
            (DECIMAL_PRECISION + _penaltyRatio)) / _price;
        if (_collToLiquidate > maxSeizedColl) {
            seizedColl = maxSeizedColl;
            collSurplus = _collToLiquidate - maxSeizedColl;
        } else {
            seizedColl = _collToLiquidate;
            collSurplus = 0;
        }
    }

    /*
     * Attempt to liquidate a custom list of troves provided by the caller.
     */
    function batchLiquidateTroves(
        uint256[] memory _troveArray
    ) public override {
        if (_troveArray.length == 0) {
            revert EmptyData();
        }

        IActivePool activePoolCached = activePool;
        IDefaultPool defaultPoolCached = defaultPool;
        IStabilityPool stabilityPoolCached = stabilityPool;

        TroveChange memory troveChange;
        LiquidationValues memory totals;

        (uint256 price, ) = priceFeed.fetchPrice();

        // - If the SP has total deposits >= 1e18, we leave 1e18 in it untouched.
        // - If it has 0 < x < 1e18 total deposits, we leave x in it.
        uint256 totalUSDXDeposits = stabilityPoolCached.getTotalUSDXDeposits();
        uint256 usdxToLeaveInSP = LiquityMath._min(
            MIN_USDX_IN_SP,
            totalUSDXDeposits
        );
        uint256 usdxInSPForOffsets = totalUSDXDeposits - usdxToLeaveInSP;

        // Perform the appropriate liquidation sequence - tally values and obtain their totals.
        _batchLiquidateTroves(
            defaultPoolCached,
            price,
            usdxInSPForOffsets,
            _troveArray,
            totals,
            troveChange
        );

        if (troveChange.debtDecrease == 0) {
            revert NothingToLiquidate();
        }

        activePoolCached.mintAggInterestAndAccountForTroveChange(troveChange);

        // Move liquidated Coll and USDX to the appropriate pools
        if (totals.debtToOffset > 0 || totals.collToSendToSP > 0) {
            stabilityPoolCached.offset(
                totals.debtToOffset,
                totals.collToSendToSP
            );
        }
        // we check amount is not zero inside
        _redistributeDebtAndColl(
            activePoolCached,
            defaultPoolCached,
            totals.debtToRedistribute,
            totals.collToRedistribute
        );
        if (totals.collSurplus > 0) {
            activePoolCached.sendColl(
                address(collSurplusPool),
                totals.collSurplus
            );
        }

        if (totals.collToDao > 0) {
            activePoolCached.sendColl(
                liquidationPenaltyDaoRecipient,
                totals.collToDao
            );
        }

        // Update system snapshots
        _updateSystemSnapshots_excludeCollRemainder(
            activePoolCached,
            totals.collGasCompensation
        );

        emit Liquidation(
            totals.debtToOffset,
            totals.debtToRedistribute,
            totals.ETHGasCompensation,
            totals.collGasCompensation,
            totals.collToSendToSP,
            totals.collToRedistribute,
            totals.collToDao,
            totals.collSurplus,
            L_coll,
            L_usdxDebt,
            price
        );

        // Send gas compensation to caller
        _sendGasCompensation(
            activePoolCached,
            msg.sender,
            totals.ETHGasCompensation,
            totals.collGasCompensation
        );
    }

    function _isActiveOrZombie(Status _status) internal pure returns (bool) {
        return _status == Status.active || _status == Status.zombie;
    }

    function _batchLiquidateTroves(
        IDefaultPool _defaultPool,
        uint256 _price,
        uint256 _usdxInSPForOffsets,
        uint256[] memory _troveArray,
        LiquidationValues memory totals,
        TroveChange memory troveChange
    ) internal {
        uint256 remainingUSDXInSPForOffsets = _usdxInSPForOffsets;

        for (uint256 i = 0; i < _troveArray.length; i++) {
            uint256 troveId = _troveArray[i];

            // Skip non-liquidatable troves
            if (!_isActiveOrZombie(Troves[troveId].status)) continue;

            uint256 ICR = getCurrentICR(troveId, _price);

            if (ICR < MCR) {
                LiquidationValues memory singleLiquidation;
                LatestTroveData memory trove;

                _liquidate(
                    _defaultPool,
                    troveId,
                    remainingUSDXInSPForOffsets,
                    _price,
                    trove,
                    singleLiquidation
                );
                remainingUSDXInSPForOffsets -= singleLiquidation.debtToOffset;

                // Add liquidation values to their respective running totals
                _addLiquidationValuesToTotals(
                    trove,
                    singleLiquidation,
                    totals,
                    troveChange
                );
            }
        }
    }

    // --- Liquidation helper functions ---

    // Adds all values from `singleLiquidation` to their respective totals in `totals` in-place
    function _addLiquidationValuesToTotals(
        LatestTroveData memory _trove,
        LiquidationValues memory _singleLiquidation,
        LiquidationValues memory totals,
        TroveChange memory troveChange
    ) internal pure {
        // Tally all the values with their respective running totals
        totals.collGasCompensation += _singleLiquidation.collGasCompensation;
        totals.ETHGasCompensation += ETH_GAS_COMPENSATION;
        troveChange.debtDecrease += _trove.entireDebt;
        troveChange.collDecrease += _trove.entireColl;
        troveChange.appliedRedistUSDXDebtGain += _trove.redistUSDXDebtGain;
        totals.debtToOffset += _singleLiquidation.debtToOffset;
        totals.collToSendToSP += _singleLiquidation.collToSendToSP;
        totals.debtToRedistribute += _singleLiquidation.debtToRedistribute;
        totals.collToRedistribute += _singleLiquidation.collToRedistribute;
        totals.collToDao += _singleLiquidation.collToDao;
        totals.collSurplus += _singleLiquidation.collSurplus;
    }

    function _sendGasCompensation(
        IActivePool _activePool,
        address _liquidator,
        uint256 _eth,
        uint256 _coll
    ) internal {
        if (_eth > 0) {
            WETH.transferFrom(gasPoolAddress, _liquidator, _eth);
        }

        if (_coll > 0) {
            _activePool.sendColl(_liquidator, _coll);
        }
    }

    // Move a Trove's pending debt and collateral rewards from distributions, from the Default Pool to the Active Pool
    function _movePendingTroveRewardsToActivePool(
        IDefaultPool _defaultPool,
        uint256 _usdx,
        uint256 _coll
    ) internal {
        if (_usdx > 0) {
            _defaultPool.decreaseUSDXDebt(_usdx);
        }

        if (_coll > 0) {
            _defaultPool.sendCollToActivePool(_coll);
        }
    }

    // --- Redemption functions ---

    function _applySingleRedemption(
        IDefaultPool _defaultPool,
        SingleRedemptionValues memory _singleRedemption
    ) internal returns (uint256) {
        // Decrease the debt and collateral of the current Trove according to the USDX lot and corresponding ETH to send
        uint256 newDebt = _singleRedemption.trove.entireDebt -
            _singleRedemption.usdxLot;
        uint256 newColl = _singleRedemption.trove.entireColl -
            _singleRedemption.collLot;

        _singleRedemption.appliedRedistUSDXDebtGain = _singleRedemption
            .trove
            .redistUSDXDebtGain;

        Troves[_singleRedemption.troveId].debt = newDebt;
        Troves[_singleRedemption.troveId].coll = newColl;
        Troves[_singleRedemption.troveId].lastDebtUpdateTime = uint64(
            block.timestamp
        );

        _singleRedemption.newStake = _updateStakeAndTotalStakes(
            _singleRedemption.troveId,
            newColl
        );
        _movePendingTroveRewardsToActivePool(
            _defaultPool,
            _singleRedemption.trove.redistUSDXDebtGain,
            _singleRedemption.trove.redistCollGain
        );
        _updateTroveRewardSnapshots(_singleRedemption.troveId);

        emit TroveUpdated({
            _troveId: _singleRedemption.troveId,
            _debt: newDebt,
            _coll: newColl,
            _stake: _singleRedemption.newStake,
            _annualInterestRate: _singleRedemption.trove.annualInterestRate,
            _snapshotOfTotalCollRedist: L_coll,
            _snapshotOfTotalDebtRedist: L_usdxDebt
        });

        emit TroveOperation({
            _troveId: _singleRedemption.troveId,
            _operation: Operation.redeemCollateral,
            _annualInterestRate: _singleRedemption.trove.annualInterestRate,
            _debtIncreaseFromRedist: _singleRedemption.trove.redistUSDXDebtGain,
            _debtChangeFromOperation: -int256(_singleRedemption.usdxLot),
            _collIncreaseFromRedist: _singleRedemption.trove.redistCollGain,
            _collChangeFromOperation: -int256(_singleRedemption.collLot)
        });

        emit RedemptionFeePaidToTrove(
            _singleRedemption.troveId,
            _singleRedemption.collFee
        );

        return newDebt;
    }

    // Redeem as much collateral as possible from _borrower's Trove in exchange for USDX up to _maxUSDXamount
    function _redeemCollateralFromTrove(
        IDefaultPool _defaultPool,
        SingleRedemptionValues memory _singleRedemption,
        uint256 _maxUSDXamount,
        uint256 _redemptionPrice,
        uint256 _redemptionRate
    ) internal {
        _getLatestTroveData(_singleRedemption.troveId, _singleRedemption.trove);

        // Determine the remaining amount (lot) to be redeemed, capped by the entire debt of the Trove
        _singleRedemption.usdxLot = LiquityMath._min(
            _maxUSDXamount,
            _singleRedemption.trove.entireDebt
        );

        // Get the amount of Coll equal in USD value to the usdxLot redeemed
        uint256 correspondingColl = (_singleRedemption.usdxLot *
            DECIMAL_PRECISION) / _redemptionPrice;
        // Calculate the collFee separately (for events)
        _singleRedemption.collFee =
            (correspondingColl * _redemptionRate) /
            DECIMAL_PRECISION;
        // Get the final collLot to send to redeemer, leaving the fee in the Trove
        _singleRedemption.collLot =
            correspondingColl -
            _singleRedemption.collFee;

        uint256 newDebt = _applySingleRedemption(
            _defaultPool,
            _singleRedemption
        );

        // Make Trove zombie if it's tiny (and it wasn’t already), in order to prevent griefing future (normal, sequential) redemptions
        if (newDebt < MIN_DEBT) {
            if (!_singleRedemption.isZombieTrove) {
                Troves[_singleRedemption.troveId].status = Status.zombie;
                sortedTroves.remove(_singleRedemption.troveId);
                // If it’s a partial redemption, let’s store a pointer to it so it’s used first in the next one
                if (newDebt > 0) {
                    lastZombieTroveId = _singleRedemption.troveId;
                }
            } else if (newDebt == 0) {
                // Reset last zombie trove pointer if the previous one was fully redeemed now
                lastZombieTroveId = 0;
            }
        }
        // Note: technically, it could happen that the Trove pointed to by `lastZombieTroveId` ends up with
        // newDebt >= MIN_DEBT thanks to USDX debt redistribution, which means it _could_ be made active again,
        // however we don't do that here, as it would require hints for re-insertion into `SortedTroves`.
    }

    /* Send _usdxamount USDX to the system and redeem the corresponding amount of collateral from as many Troves as are needed to fill the redemption
     * request.  Applies redistribution gains to a Trove before reducing its debt and coll.
     *
     * Note that if _amount is very large, this function can run out of gas, specially if traversed troves are small. This can be easily avoided by
     * splitting the total _amount in appropriate chunks and calling the function multiple times.
     *
     * Param `_maxIterations` can also be provided, so the loop through Troves is capped (if it’s zero, it will be ignored).This makes it easier to
     * avoid OOG for the frontend, as only knowing approximately the average cost of an iteration is enough, without needing to know the “topology”
     * of the trove list. It also avoids the need to set the cap in stone in the contract, nor doing gas calculations, as both gas price and opcode
     * costs can vary.
     *
     * All Troves that are redeemed from -- with the likely exception of the last one -- will end up with no debt left, and therefore in “zombie” state
     */
    function redeemCollateral(
        address _redeemer,
        uint256 _usdxamount,
        uint256 _price,
        uint256 _redemptionRate,
        uint256 _maxIterations
    ) external override returns (uint256 _redeemedAmount) {
        _requireCallerIsCollateralRegistry();

        IActivePool activePoolCached = activePool;
        ISortedTroves sortedTrovesCached = sortedTroves;

        TroveChange memory totalsTroveChange;
        RedeemCollateralValues memory vars;

        vars.remainingUSDX = _usdxamount;

        SingleRedemptionValues memory singleRedemption;
        // Let’s check if there’s a pending zombie trove from previous redemption
        if (lastZombieTroveId != 0) {
            singleRedemption.troveId = lastZombieTroveId;
            singleRedemption.isZombieTrove = true;
        } else {
            singleRedemption.troveId = sortedTrovesCached.getLast();
        }

        // Get the price to use for the redemption collateral calculations
        (uint256 redemptionPrice, ) = priceFeed.fetchRedemptionPrice();

        // Loop through the Troves starting from the one with lowest interest rate until _amount of USDX is exchanged for collateral
        if (_maxIterations == 0) _maxIterations = type(uint256).max;
        while (
            singleRedemption.troveId != 0 &&
            vars.remainingUSDX > 0 &&
            _maxIterations > 0
        ) {
            _maxIterations--;
            // Save the uint256 of the Trove preceding the current one
            if (singleRedemption.isZombieTrove) {
                vars.nextUserToCheck = sortedTrovesCached.getLast();
            } else {
                vars.nextUserToCheck = sortedTrovesCached.getPrev(
                    singleRedemption.troveId
                );
            }

            // Skip if ICR < 100%, to make sure that redemptions don’t decrease the CR of hit Troves.
            // Use the normal price for the ICR check.
            if (getCurrentICR(singleRedemption.troveId, _price) < _100pct) {
                singleRedemption.troveId = vars.nextUserToCheck;
                singleRedemption.isZombieTrove = false;
                continue;
            }

            _redeemCollateralFromTrove(
                defaultPool,
                singleRedemption,
                vars.remainingUSDX,
                redemptionPrice,
                _redemptionRate
            );

            totalsTroveChange.collDecrease += singleRedemption.collLot;
            totalsTroveChange.debtDecrease += singleRedemption.usdxLot;
            totalsTroveChange.appliedRedistUSDXDebtGain += singleRedemption
                .appliedRedistUSDXDebtGain;

            vars.totalCollFee += singleRedemption.collFee;
            vars.remainingUSDX -= singleRedemption.usdxLot;

            singleRedemption.troveId = vars.nextUserToCheck;
            singleRedemption.isZombieTrove = false;
        }

        // We are removing this condition to prevent blocking redemptions
        //require(totals.totalCollDrawn > 0, "TroveManager: Unable to redeem any amount");

        emit Redemption(
            _usdxamount,
            totalsTroveChange.debtDecrease,
            totalsTroveChange.collDecrease,
            vars.totalCollFee,
            _price,
            redemptionPrice
        );

        activePoolCached.mintAggInterestAndAccountForTroveChange(
            totalsTroveChange
        );

        // Send the redeemed Coll to sender
        activePoolCached.sendColl(_redeemer, totalsTroveChange.collDecrease);
        // We’ll burn all the USDX together out in the CollateralRegistry, to save gas

        return totalsTroveChange.debtDecrease;
    }

    // Redeem as much collateral as possible from _borrower's Trove in exchange for USDX up to _maxUSDXamount
    function _urgentRedeemCollateralFromTrove(
        IDefaultPool _defaultPool,
        uint256 _maxUSDXamount,
        uint256 _price,
        SingleRedemptionValues memory _singleRedemption
    ) internal {
        // Determine the remaining amount (lot) to be redeemed, capped by the entire debt of the Trove minus the liquidation reserve
        _singleRedemption.usdxLot = LiquityMath._min(
            _maxUSDXamount,
            _singleRedemption.trove.entireDebt
        );

        // Get the amount of ETH equal in USD value to the USDX lot redeemed
        _singleRedemption.collLot =
            (_singleRedemption.usdxLot *
                (DECIMAL_PRECISION + URGENT_REDEMPTION_BONUS)) /
            _price;
        // As here we can redeem when CR < 101% (accounting for 1% bonus), we need to cap by collateral too
        if (_singleRedemption.collLot > _singleRedemption.trove.entireColl) {
            _singleRedemption.collLot = _singleRedemption.trove.entireColl;
            _singleRedemption.usdxLot =
                (_singleRedemption.trove.entireColl * _price) /
                (DECIMAL_PRECISION + URGENT_REDEMPTION_BONUS);
        }

        _applySingleRedemption(_defaultPool, _singleRedemption);

        // No need to make this Trove zombie if it has tiny debt, since:
        // - This collateral branch has shut down and urgent redemptions are enabled
        // - Urgent redemptions aren't sequential, so they can't be griefed by tiny Troves.
    }

    function urgentRedemption(
        uint256 _usdxAmount,
        uint256[] calldata _troveIds,
        uint256 _minCollateral
    ) external {
        _requireIsShutDown();
        _requireAmountGreaterThanZero(_usdxAmount);
        _requireUSDXBalanceCoversRedemption(usdxToken, msg.sender, _usdxAmount);

        IActivePool activePoolCached = activePool;
        TroveChange memory totalsTroveChange;

        // Use the standard fetchPrice here, since if branch has shut down we don't worry about small redemption arbs
        (uint256 price, ) = priceFeed.fetchPrice();

        uint256 remainingUSDX = _usdxAmount;
        for (uint256 i = 0; i < _troveIds.length; i++) {
            if (remainingUSDX == 0) break;

            SingleRedemptionValues memory singleRedemption;
            singleRedemption.troveId = _troveIds[i];
            _getLatestTroveData(
                singleRedemption.troveId,
                singleRedemption.trove
            );

            if (
                !_isActiveOrZombie(Troves[singleRedemption.troveId].status) ||
                singleRedemption.trove.entireDebt == 0
            ) {
                continue;
            }

            _urgentRedeemCollateralFromTrove(
                defaultPool,
                remainingUSDX,
                price,
                singleRedemption
            );

            totalsTroveChange.collDecrease += singleRedemption.collLot;
            totalsTroveChange.debtDecrease += singleRedemption.usdxLot;
            totalsTroveChange.appliedRedistUSDXDebtGain += singleRedemption
                .appliedRedistUSDXDebtGain;

            remainingUSDX -= singleRedemption.usdxLot;
        }

        if (totalsTroveChange.collDecrease < _minCollateral) {
            revert MinCollNotReached(totalsTroveChange.collDecrease);
        }

        emit Redemption(
            _usdxAmount,
            totalsTroveChange.debtDecrease,
            totalsTroveChange.collDecrease,
            0,
            price,
            price
        );

        // Since this branch is shut down, this will mint 0 interest.
        // We call this only to update the aggregate debt and weighted debt trackers.
        activePoolCached.mintAggInterestAndAccountForTroveChange(
            totalsTroveChange
        );

        // Send the redeemed coll to caller
        activePoolCached.sendColl(msg.sender, totalsTroveChange.collDecrease);
        // Burn usdx
        usdxToken.burn(msg.sender, totalsTroveChange.debtDecrease);
    }

    function shutdown() external {
        _requireCallerIsBorrowerOperations();
        shutdownTime = block.timestamp;
        activePool.setShutdownFlag();
    }

    // --- Helper functions ---

    // Return the current collateral ratio (ICR) of a given Trove. Takes a trove's pending coll and debt rewards from redistributions into account.
    function getCurrentICR(
        uint256 _troveId,
        uint256 _price
    ) public view override returns (uint256) {
        LatestTroveData memory trove;
        _getLatestTroveData(_troveId, trove);
        return
            LiquityMath._computeCR(trove.entireColl, trove.entireDebt, _price);
    }

    // Return the Nominal Collateral Ratio (NCR) of a given Trove. Takes a trove's pending coll and debt rewards from redistributions into account.
    function getTroveNominalCR(
        uint256 _troveId
    ) public view override returns (uint256) {
        LatestTroveData memory trove;
        _getLatestTroveData(_troveId, trove);
        return
            LiquityMath._computeNominalCR(trove.entireColl, trove.entireDebt);
    }

    function _updateTroveRewardSnapshots(uint256 _troveId) internal {
        rewardSnapshots[_troveId].coll = L_coll;
        rewardSnapshots[_troveId].usdxDebt = L_usdxDebt;
    }

    // Return the Troves entire debt and coll, including redistribution gains from redistributions.
    function _getLatestTroveData(
        uint256 _troveId,
        LatestTroveData memory trove
    ) internal view {
        uint256 stake = Troves[_troveId].stake;
        trove.redistUSDXDebtGain =
            (stake * (L_usdxDebt - rewardSnapshots[_troveId].usdxDebt)) /
            DECIMAL_PRECISION;
        trove.redistCollGain =
            (stake * (L_coll - rewardSnapshots[_troveId].coll)) /
            DECIMAL_PRECISION;

        trove.recordedDebt = Troves[_troveId].debt;
        trove.annualInterestRate = collateralConfig.getAnnualInterestRate();

        uint256 period = _getInterestPeriod(
            Troves[_troveId].lastDebtUpdateTime
        );
        trove.accruedInterest = _calcInterest(
            trove.recordedDebt * trove.annualInterestRate,
            period
        );

        trove.entireDebt =
            trove.recordedDebt +
            trove.redistUSDXDebtGain +
            trove.accruedInterest;
        trove.entireColl = Troves[_troveId].coll + trove.redistCollGain;
    }

    function getLatestTroveData(
        uint256 _troveId
    ) external view returns (LatestTroveData memory trove) {
        _getLatestTroveData(_troveId, trove);
    }

    function getTroveAnnualInterestRate(
        uint256 /* _troveId */
    ) external view returns (uint256) {
        // All troves now use unified rate from CollateralConfig
        return collateralConfig.getAnnualInterestRate();
    }

    // Update borrower's stake based on their latest collateral value
    function _updateStakeAndTotalStakes(
        uint256 _troveId,
        uint256 _coll
    ) internal returns (uint256 newStake) {
        newStake = _computeNewStake(_coll);
        uint256 oldStake = Troves[_troveId].stake;
        Troves[_troveId].stake = newStake;

        totalStakes = totalStakes - oldStake + newStake;
    }

    // Calculate a new stake based on the snapshots of the totalStakes and totalCollateral taken at the last liquidation
    function _computeNewStake(uint256 _coll) internal view returns (uint256) {
        uint256 stake;
        if (totalCollateralSnapshot == 0) {
            stake = _coll;
        } else {
            /*
             * The following assert() holds true because:
             * - The system always contains >= 1 trove
             * - When we close or liquidate a trove, we redistribute the redistribution gains, so if all troves were closed/liquidated,
             * rewards would’ve been emptied and totalCollateralSnapshot would be zero too.
             */
            // assert(totalStakesSnapshot > 0);
            stake = (_coll * totalStakesSnapshot) / totalCollateralSnapshot;
        }
        return stake;
    }

    function _redistributeDebtAndColl(
        IActivePool _activePool,
        IDefaultPool _defaultPool,
        uint256 _debtToRedistribute,
        uint256 _collToRedistribute
    ) internal {
        if (_debtToRedistribute == 0) return; // Otherwise _collToRedistribute > 0 too

        /*
         * Add distributed coll and debt rewards-per-unit-staked to the running totals. Division uses a "feedback"
         * error correction, to keep the cumulative error low in the running totals L_coll and L_usdxDebt:
         *
         * 1) Form numerators which compensate for the floor division errors that occurred the last time this
         * function was called.
         * 2) Calculate "per-unit-staked" ratios.
         * 3) Multiply each ratio back by its denominator, to reveal the current floor division error.
         * 4) Store these errors for use in the next correction when this function is called.
         * 5) Note: static analysis tools complain about this "division before multiplication", however, it is intended.
         */
        uint256 collNumerator = _collToRedistribute *
            DECIMAL_PRECISION +
            lastCollError_Redistribution;
        uint256 usdxDebtNumerator = _debtToRedistribute *
            DECIMAL_PRECISION +
            lastUSDXDebtError_Redistribution;

        // Get the per-unit-staked terms
        uint256 collRewardPerUnitStaked = collNumerator / totalStakes;
        uint256 usdxDebtRewardPerUnitStaked = usdxDebtNumerator / totalStakes;

        lastCollError_Redistribution =
            collNumerator -
            collRewardPerUnitStaked *
            totalStakes;
        lastUSDXDebtError_Redistribution =
            usdxDebtNumerator -
            usdxDebtRewardPerUnitStaked *
            totalStakes;

        // Add per-unit-staked terms to the running totals
        L_coll = L_coll + collRewardPerUnitStaked;
        L_usdxDebt = L_usdxDebt + usdxDebtRewardPerUnitStaked;

        _defaultPool.increaseUSDXDebt(_debtToRedistribute);
        _activePool.sendCollToDefaultPool(_collToRedistribute);
    }

    /*
     * Updates snapshots of system total stakes and total collateral, excluding a given collateral remainder from the calculation.
     * Used in a liquidation sequence.
     */
    function _updateSystemSnapshots_excludeCollRemainder(
        IActivePool _activePool,
        uint256 _collRemainder
    ) internal {
        totalStakesSnapshot = totalStakes;

        uint256 activeColl = _activePool.getCollBalance();
        uint256 liquidatedColl = defaultPool.getCollBalance();
        totalCollateralSnapshot = activeColl - _collRemainder + liquidatedColl;
    }

    /*
     * Remove a Trove owner from the TroveIds array, not preserving array order. Removing owner 'B' does the following:
     * [A B C D E] => [A E C D], and updates E's Trove struct to point to its new array index.
     */
    function _removeTroveId(
        uint256 _troveId,
        uint256 TroveIdsArrayLength
    ) internal {
        uint64 index = Troves[_troveId].arrayIndex;
        uint256 idxLast = TroveIdsArrayLength - 1;

        // assert(index <= idxLast);

        uint256 idToMove = TroveIds[idxLast];

        TroveIds[index] = idToMove;
        Troves[idToMove].arrayIndex = index;

        TroveIds.pop();
    }

    function getTroveStatus(
        uint256 _troveId
    ) external view override returns (Status) {
        return Troves[_troveId].status;
    }

    // --- Interest rate calculations ---

    function _getInterestPeriod(
        uint256 _lastDebtUpdateTime
    ) internal view returns (uint256) {
        if (shutdownTime == 0) {
            // If branch is not shut down, interest is earned up to now.
            return block.timestamp - _lastDebtUpdateTime;
        } else if (shutdownTime > 0 && _lastDebtUpdateTime < shutdownTime) {
            // If branch is shut down and the Trove was not updated since shut down, interest is earned up to the shutdown time.
            return shutdownTime - _lastDebtUpdateTime;
        } else {
            // if (shutdownTime > 0 && _lastDebtUpdateTime >= shutdownTime)
            // If branch is shut down and the Trove was updated after shutdown, no interest is earned since.
            return 0;
        }
    }

    // --- 'require' wrapper functions ---

    function _requireCallerIsBorrowerOperations() internal view {
        if (msg.sender != address(borrowerOperations)) {
            revert CallerNotBorrowerOperations();
        }
    }

    function _requireCallerIsCollateralRegistry() internal view {
        if (msg.sender != address(collateralRegistry)) {
            revert CallerNotCollateralRegistry();
        }
    }

    function _requireMoreThanOneTroveInSystem(
        uint256 TroveIdsArrayLength
    ) internal pure {
        if (TroveIdsArrayLength == 1) {
            revert OnlyOneTroveLeft();
        }
    }

    function _requireIsShutDown() internal view {
        if (shutdownTime == 0) {
            revert NotShutDown();
        }
    }

    function _requireAmountGreaterThanZero(uint256 _amount) internal pure {
        if (_amount == 0) {
            revert ZeroAmount();
        }
    }

    function _requireUSDXBalanceCoversRedemption(
        IUSDXToken _usdxToken,
        address _redeemer,
        uint256 _amount
    ) internal view {
        uint256 usdxBalance = _usdxToken.balanceOf(_redeemer);
        if (usdxBalance < _amount) {
            revert NotEnoughUSDXBalance();
        }
    }

    // --- Trove property getters ---

    function getUnbackedPortionPriceAndRedeemability()
        external
        returns (uint256, uint256, bool)
    {
        uint256 totalDebt = getEntireBranchDebt();
        uint256 spSize = stabilityPool.getTotalUSDXDeposits();
        uint256 unbackedPortion = totalDebt > spSize ? totalDebt - spSize : 0;

        (uint256 price, ) = priceFeed.fetchPrice();
        // It's redeemable if the TCR is above the shutdown threshold, and branch has not been shut down.
        // Use the normal price for the TCR check.
        bool redeemable = _getTCR(price) >= SCR && shutdownTime == 0;

        return (unbackedPortion, price, redeemable);
    }

    // --- Trove property setters, called by BorrowerOperations ---

    function onOpenTrove(
        address _owner,
        uint256 _troveId,
        TroveChange memory _troveChange
    ) external {
        _requireCallerIsBorrowerOperations();

        uint256 newStake = _computeNewStake(_troveChange.collIncrease);

        // Trove memory newTrove;
        Troves[_troveId].debt = _troveChange.debtIncrease;
        Troves[_troveId].coll = _troveChange.collIncrease;
        Troves[_troveId].stake = newStake;
        Troves[_troveId].status = Status.active;
        Troves[_troveId].arrayIndex = uint64(TroveIds.length);
        Troves[_troveId].lastDebtUpdateTime = uint64(block.timestamp);

        // Push the trove's id to the Trove list
        TroveIds.push(_troveId);

        uint256 newTotalStakes = totalStakes + newStake;
        totalStakes = newTotalStakes;

        // mint ERC721
        troveNFT.mint(_owner, _troveId);

        _updateTroveRewardSnapshots(_troveId);

        uint256 interestRate = collateralConfig.getAnnualInterestRate();

        emit TroveUpdated({
            _troveId: _troveId,
            _debt: _troveChange.debtIncrease,
            _coll: _troveChange.collIncrease,
            _stake: newStake,
            _annualInterestRate: interestRate,
            _snapshotOfTotalCollRedist: L_coll,
            _snapshotOfTotalDebtRedist: L_usdxDebt
        });

        emit TroveOperation({
            _troveId: _troveId,
            _operation: Operation.openTrove,
            _annualInterestRate: interestRate,
            _debtIncreaseFromRedist: 0,
            _debtChangeFromOperation: int256(_troveChange.debtIncrease),
            _collIncreaseFromRedist: 0,
            _collChangeFromOperation: int256(_troveChange.collIncrease)
        });
    }

    function setTroveStatusToActive(uint256 _troveId) external {
        _requireCallerIsBorrowerOperations();
        Troves[_troveId].status = Status.active;
        if (lastZombieTroveId == _troveId) {
            lastZombieTroveId = 0;
        }
    }

    function onAdjustTrove(
        uint256 _troveId,
        uint256 _newColl,
        uint256 _newDebt,
        TroveChange calldata _troveChange
    ) external {
        _requireCallerIsBorrowerOperations();

        Troves[_troveId].coll = _newColl;
        Troves[_troveId].debt = _newDebt;
        Troves[_troveId].lastDebtUpdateTime = uint64(block.timestamp);

        _movePendingTroveRewardsToActivePool(
            defaultPool,
            _troveChange.appliedRedistUSDXDebtGain,
            _troveChange.appliedRedistCollGain
        );

        uint256 newStake = _updateStakeAndTotalStakes(_troveId, _newColl);
        _updateTroveRewardSnapshots(_troveId);

        uint256 annualInterestRate = collateralConfig.getAnnualInterestRate();

        emit TroveUpdated({
            _troveId: _troveId,
            _debt: _newDebt,
            _coll: _newColl,
            _stake: newStake,
            _annualInterestRate: annualInterestRate,
            _snapshotOfTotalCollRedist: L_coll,
            _snapshotOfTotalDebtRedist: L_usdxDebt
        });

        emit TroveOperation({
            _troveId: _troveId,
            _operation: Operation.adjustTrove,
            _annualInterestRate: annualInterestRate,
            _debtIncreaseFromRedist: _troveChange.appliedRedistUSDXDebtGain,
            _debtChangeFromOperation: int256(_troveChange.debtIncrease) -
                int256(_troveChange.debtDecrease),
            _collIncreaseFromRedist: _troveChange.appliedRedistCollGain,
            _collChangeFromOperation: int256(_troveChange.collIncrease) -
                int256(_troveChange.collDecrease)
        });
    }

    function onCloseTrove(
        uint256 _troveId,
        TroveChange memory _troveChange // decrease vars: entire, with interest and redistribution
    ) external override {
        _requireCallerIsBorrowerOperations();
        _closeTrove(_troveId, _troveChange, Status.closedByOwner);
        _movePendingTroveRewardsToActivePool(
            defaultPool,
            _troveChange.appliedRedistUSDXDebtGain,
            _troveChange.appliedRedistCollGain
        );

        emit TroveUpdated({
            _troveId: _troveId,
            _debt: 0,
            _coll: 0,
            _stake: 0,
            _annualInterestRate: 0,
            _snapshotOfTotalCollRedist: 0,
            _snapshotOfTotalDebtRedist: 0
        });

        emit TroveOperation({
            _troveId: _troveId,
            _operation: Operation.closeTrove,
            _annualInterestRate: 0,
            _debtIncreaseFromRedist: _troveChange.appliedRedistUSDXDebtGain,
            _debtChangeFromOperation: int256(_troveChange.debtIncrease) -
                int256(_troveChange.debtDecrease),
            _collIncreaseFromRedist: _troveChange.appliedRedistCollGain,
            _collChangeFromOperation: int256(_troveChange.collIncrease) -
                int256(_troveChange.collDecrease)
        });
    }

    function _closeTrove(
        uint256 _troveId,
        TroveChange memory _troveChange, // decrease vars: entire, with interest and redistribution
        Status closedStatus
    ) internal {
        // assert(closedStatus == Status.closedByLiquidation || closedStatus == Status.closedByOwner);

        uint256 TroveIdsArrayLength = TroveIds.length;
        // If branch has not been shut down, or it's a liquidation,
        // require at least 1 trove in the system
        if (shutdownTime == 0 || closedStatus == Status.closedByLiquidation) {
            _requireMoreThanOneTroveInSystem(TroveIdsArrayLength);
        }

        _removeTroveId(_troveId, TroveIdsArrayLength);

        Trove memory trove = Troves[_troveId];

        if (trove.status == Status.active) {
            sortedTroves.remove(_troveId);
        } else if (
            trove.status == Status.zombie && lastZombieTroveId == _troveId
        ) {
            lastZombieTroveId = 0;
        }

        uint256 newTotalStakes = totalStakes - trove.stake;
        totalStakes = newTotalStakes;

        // Zero Trove properties
        delete Troves[_troveId];
        Troves[_troveId].status = closedStatus;

        // Zero Trove snapshots
        delete rewardSnapshots[_troveId];

        // burn ERC721
        troveNFT.burn(_troveId);
    }

    function onApplyTroveInterest(
        uint256 _troveId,
        uint256 _newTroveColl,
        uint256 _newTroveDebt,
        TroveChange calldata _troveChange
    ) external {
        _requireCallerIsBorrowerOperations();

        Troves[_troveId].coll = _newTroveColl;

        Troves[_troveId].debt = _newTroveDebt;
        Troves[_troveId].lastDebtUpdateTime = uint64(block.timestamp);

        _movePendingTroveRewardsToActivePool(
            defaultPool,
            _troveChange.appliedRedistUSDXDebtGain,
            _troveChange.appliedRedistCollGain
        );

        _updateTroveRewardSnapshots(_troveId);

        uint256 interestRate = collateralConfig.getAnnualInterestRate();

        emit TroveUpdated({
            _troveId: _troveId,
            _debt: _newTroveDebt,
            _coll: _newTroveColl,
            _stake: Troves[_troveId].stake,
            _annualInterestRate: interestRate,
            _snapshotOfTotalCollRedist: L_coll,
            _snapshotOfTotalDebtRedist: L_usdxDebt
        });

        emit TroveOperation({
            _troveId: _troveId,
            _operation: Operation.applyPendingDebt,
            _annualInterestRate: interestRate,
            _debtIncreaseFromRedist: _troveChange.appliedRedistUSDXDebtGain,
            _debtChangeFromOperation: int256(_troveChange.debtIncrease) -
                int256(_troveChange.debtDecrease),
            _collIncreaseFromRedist: _troveChange.appliedRedistCollGain,
            _collChangeFromOperation: int256(_troveChange.collIncrease) -
                int256(_troveChange.collDecrease)
        });
    }

    // ============ Liquidation Penalty Update Functions ============

    /**
    * @dev Updates the liquidation penalty percentage for the liquidator
    * @param _newLiquidationPenaltyLiquidator New liquidation penalty percentage for liquidator (in 1e18 precision)
    */
    function updateLiquidationPenaltyLiquidator(uint256 _newLiquidationPenaltyLiquidator) external onlyOwner {
        // Validate the new penalty value
        require(
            _newLiquidationPenaltyLiquidator <= DECIMAL_PRECISION,
            "TroveManager: Liquidator penalty cannot exceed 100%"
        );

        liquidationPenaltyLiquidator = _newLiquidationPenaltyLiquidator;

        emit LiquidationPenaltyLiquidatorChanged(_newLiquidationPenaltyLiquidator);
    }

    /**
    * @dev Updates the liquidation penalty percentage for the Stability Pool
    * @param _newLiquidationPenaltySp New liquidation penalty percentage for Stability Pool (in 1e18 precision)
    */
    function updateLiquidationPenaltySp(uint256 _newLiquidationPenaltySp) external onlyOwner {
        // Validate the new penalty value
        require(
            _newLiquidationPenaltySp <= DECIMAL_PRECISION,
            "TroveManager: SP penalty cannot exceed 100%"
        );

        liquidationPenaltySp = _newLiquidationPenaltySp;

        emit LiquidationPenaltySpChanged(_newLiquidationPenaltySp);
    }

    /**
    * @dev Updates the liquidation penalty percentage for the DAO
    * @param _newLiquidationPenaltyDao New liquidation penalty percentage for DAO (in 1e18 precision)
    */
    function updateLiquidationPenaltyDao(uint256 _newLiquidationPenaltyDao) external onlyOwner {
        // Validate the new penalty value
        require(
            _newLiquidationPenaltyDao <= DECIMAL_PRECISION,
            "TroveManager: DAO penalty cannot exceed 100%"
        );

        liquidationPenaltyDao = _newLiquidationPenaltyDao;

        emit LiquidationPenaltyDaoChanged(_newLiquidationPenaltyDao);
    }

    /**
    * @dev Updates the DAO penalty recipient address
    * @param _newLiquidationPenaltyDaoRecipient New address to receive DAO liquidation penalties
    */
    function updateLiquidationPenaltyDaoRecipient(address _newLiquidationPenaltyDaoRecipient) external onlyOwner {
        // Validate the new address
        require(
            _newLiquidationPenaltyDaoRecipient != address(0),
            "TroveManager: DAO recipient cannot be zero address"
        );

        liquidationPenaltyDaoRecipient = _newLiquidationPenaltyDaoRecipient;

        emit LiquidationPenaltyDaoRecipientChanged(_newLiquidationPenaltyDaoRecipient);
    }

    // ============ Batch Update Function ============

    /**
    * @dev Updates multiple liquidation penalty parameters in a single transaction
    * @param _newLiquidationPenaltyLiquidator New liquidator penalty percentage
    * @param _newLiquidationPenaltySp New Stability Pool penalty percentage
    * @param _newLiquidationPenaltyDao New DAO penalty percentage
    * @param _newLiquidationPenaltyDaoRecipient New DAO penalty recipient address
    */
    function updateLiquidationParameters(
        uint256 _newLiquidationPenaltyLiquidator,
        uint256 _newLiquidationPenaltySp,
        uint256 _newLiquidationPenaltyDao,
        address _newLiquidationPenaltyDaoRecipient
    ) external onlyOwner {
        // Validate all parameters
        require(
            _newLiquidationPenaltyLiquidator <= DECIMAL_PRECISION &&
            _newLiquidationPenaltySp <= DECIMAL_PRECISION &&
            _newLiquidationPenaltyDao <= DECIMAL_PRECISION,
            "TroveManager: Penalty cannot exceed 100%"
        );
        require(
            _newLiquidationPenaltyDaoRecipient != address(0),
            "TroveManager: DAO recipient cannot be zero address"
        );

        // Store old values for events
        uint256 oldPenaltyLiquidator = liquidationPenaltyLiquidator;
        uint256 oldPenaltySp = liquidationPenaltySp;
        uint256 oldPenaltyDao = liquidationPenaltyDao;
        address oldRecipient = liquidationPenaltyDaoRecipient;

        // Update values
        liquidationPenaltyLiquidator = _newLiquidationPenaltyLiquidator;
        liquidationPenaltySp = _newLiquidationPenaltySp;
        liquidationPenaltyDao = _newLiquidationPenaltyDao;
        liquidationPenaltyDaoRecipient = _newLiquidationPenaltyDaoRecipient;

        // Emit events
        if (oldPenaltyLiquidator != _newLiquidationPenaltyLiquidator) {
            emit LiquidationPenaltyLiquidatorChanged(_newLiquidationPenaltyLiquidator);
        }
        if (oldPenaltySp != _newLiquidationPenaltySp) {
            emit LiquidationPenaltySpChanged(_newLiquidationPenaltySp);
        }
        if (oldPenaltyDao != _newLiquidationPenaltyDao) {
            emit LiquidationPenaltyDaoChanged(_newLiquidationPenaltyDao);
        }
        if (oldRecipient != _newLiquidationPenaltyDaoRecipient) {
            emit LiquidationPenaltyDaoRecipientChanged(_newLiquidationPenaltyDaoRecipient);
        }
    }
}
