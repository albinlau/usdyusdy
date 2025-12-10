// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.28;

import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import "openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import "./Interfaces/IBorrowerOperations.sol";
import "./Interfaces/IAddressesRegistry.sol";
import "./Interfaces/ITroveManager.sol";
import "./Interfaces/IUSDXToken.sol";
import "./Interfaces/ICollSurplusPool.sol";
import "./Interfaces/ISortedTroves.sol";
import "./Interfaces/ICollateralConfig.sol";
import "./Dependencies/LiquityBase.sol";
import "./Dependencies/AddRemoveManagers.sol";
import "./Types/LatestTroveData.sol";

contract BorrowerOperations is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    LiquityBase,
    AddRemoveManagers,
    IBorrowerOperations
{
    using SafeERC20 for IERC20;

    // --- Connected contract declarations ---

    IERC20 internal immutable collToken;
    ITroveManager internal troveManager;
    address internal gasPoolAddress;
    ICollSurplusPool internal collSurplusPool;
    IUSDXToken internal usdxToken;
    // A doubly linked list of Troves, sorted by their collateral ratios
    ISortedTroves internal sortedTroves;
    // Collateral configuration (freeze, pause, protocol interest, treasury)
    ICollateralConfig internal collateralConfig;
    // Wrapped ETH for liquidation reserve (gas compensation)
    IWETH internal immutable WETH;

    // Critical system collateral ratio. If the system's total collateral ratio (TCR) falls below the CCR, some borrowing operation restrictions are applied
    uint256 public immutable CCR;

    // Shutdown system collateral ratio. If the system's total collateral ratio (TCR) for a given collateral falls below the SCR,
    // the protocol triggers the shutdown of the borrow market and permanently disables all borrowing operations except for closing Troves.
    uint256 public immutable SCR;
    bool public hasBeenShutDown;

    // Minimum collateral ratio for individual troves
    uint256 public immutable MCR;

    /* --- Variable container structs  ---

    Used to hold, return and assign variables inside a function, in order to avoid the error:
    "CompilerError: Stack too deep". */

    struct OpenTroveVars {
        ITroveManager troveManager;
        uint256 troveId;
        TroveChange change;
    }

    struct LocalVariables_openTrove {
        ITroveManager troveManager;
        IActivePool activePool;
        IUSDXToken usdxToken;
        uint256 troveId;
        uint256 price;
        uint256 avgInterestRate;
        uint256 entireDebt;
        uint256 ICR;
        uint256 newTCR;
        bool newOracleFailureDetected;
    }

    struct LocalVariables_adjustTrove {
        IActivePool activePool;
        IUSDXToken usdxToken;
        LatestTroveData trove;
        uint256 price;
        bool isBelowCriticalThreshold;
        uint256 newICR;
        uint256 newDebt;
        uint256 newColl;
        bool newOracleFailureDetected;
    }

    error IsShutDown();
    error TCRNotBelowSCR();
    error ZeroAdjustment();
    error InterestNotInRange();
    error TroveExists();
    error TroveNotOpen();
    error TroveNotActive();
    error TroveNotZombie();
    error TroveWithZeroDebt();
    error ICRBelowMCR();
    error ICRBelowMCRPlusBCR();
    error RepaymentNotMatchingCollWithdrawal();
    error TCRBelowCCR();
    error DebtBelowMin();
    error CollWithdrawalTooHigh();
    error NotEnoughUSDXBalance();
    error InterestRateTooLow();
    error InterestRateTooHigh();
    error InterestRateNotNew();
    error NewFeeNotLower();
    error CallerNotTroveManager();
    error CallerNotPriceFeed();
    error MinGeMax();
    error AnnualManagementFeeTooHigh();
    error MinInterestRateChangePeriodTooLow();
    error NewOracleFailureDetected();

    event TroveManagerAddressChanged(address _newTroveManagerAddress);
    event GasPoolAddressChanged(address _gasPoolAddress);
    event CollSurplusPoolAddressChanged(address _collSurplusPoolAddress);
    event SortedTrovesAddressChanged(address _sortedTrovesAddress);
    event USDXTokenAddressChanged(address _usdxTokenAddress);

    event ShutDown(uint256 _tcr);

    constructor(
        IAddressesRegistry _addressesRegistry
    ) {
        _disableInitializers();

        // This makes impossible to open a trove with zero withdrawn USDX
        assert(MIN_DEBT > 0);

        collToken = _addressesRegistry.collToken();

        WETH = _addressesRegistry.WETH();

        CCR = _addressesRegistry.CCR();
        SCR = _addressesRegistry.SCR();
        MCR = _addressesRegistry.MCR();

//        troveManager = _addressesRegistry.troveManager();
//        gasPoolAddress = _addressesRegistry.gasPoolAddress();
//        collSurplusPool = _addressesRegistry.collSurplusPool();
//        sortedTroves = _addressesRegistry.sortedTroves();
//        usdxToken = _addressesRegistry.usdxToken();
//        collateralConfig = _addressesRegistry.collateralConfig();
//
//        emit TroveManagerAddressChanged(address(troveManager));
//        emit GasPoolAddressChanged(gasPoolAddress);
//        emit CollSurplusPoolAddressChanged(address(collSurplusPool));
//        emit SortedTrovesAddressChanged(address(sortedTroves));
//        emit USDXTokenAddressChanged(address(usdxToken));
    }

    function initialize(address initialOwner, IAddressesRegistry _addressesRegistry) public initializer {
        __Ownable_init();
        __LiquityBase_init(_addressesRegistry);
        __AddRemoveManagers_init(_addressesRegistry);
        transferOwnership(initialOwner);
        // Allow funds movements between Liquity contracts
        collToken.approve(address(activePool), type(uint256).max);
    }

    function updateByAddressRegistry(
        IAddressesRegistry _addressesRegistry
    ) external onlyOwner {
        activePool = _addressesRegistry.activePool();
        defaultPool = _addressesRegistry.defaultPool();
        priceFeed = _addressesRegistry.priceFeed();

        emit ActivePoolAddressChanged(address(activePool));
        emit DefaultPoolAddressChanged(address(defaultPool));
        emit PriceFeedAddressChanged(address(priceFeed));

        troveNFT = _addressesRegistry.troveNFT();
        emit TroveNFTAddressChanged(address(troveNFT));

        troveManager = _addressesRegistry.troveManager();
        gasPoolAddress = _addressesRegistry.gasPoolAddress();
        collSurplusPool = _addressesRegistry.collSurplusPool();
        sortedTroves = _addressesRegistry.sortedTroves();
        usdxToken = _addressesRegistry.usdxToken();
        collateralConfig = _addressesRegistry.collateralConfig();

        emit TroveManagerAddressChanged(address(troveManager));
        emit GasPoolAddressChanged(gasPoolAddress);
        emit CollSurplusPoolAddressChanged(address(collSurplusPool));
        emit SortedTrovesAddressChanged(address(sortedTroves));
        emit USDXTokenAddressChanged(address(usdxToken));
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    // --- Borrower Trove Operations ---

    function openTrove(
        address _owner,
        uint256 _ownerIndex,
        uint256 _collAmount,
        uint256 _usdxAmount,
        uint256 _upperHint,
        uint256 _lowerHint,
        address _addManager,
        address _removeManager,
        address _receiver
    ) external override returns (uint256) {
        OpenTroveVars memory vars;

        vars.troveId = _openTrove(
            _owner,
            _ownerIndex,
            _collAmount,
            _usdxAmount,
            _addManager,
            _removeManager,
            _receiver,
            vars.change
        );

        // Set the stored Trove properties and mint the NFT
        troveManager.onOpenTrove(_owner, vars.troveId, vars.change);

        // Use NCR (Nominal Collateral Ratio) for sorting
        uint256 ncr = LiquityMath._computeNominalCR(
            vars.change.collIncrease,
            vars.change.debtIncrease
        );
        sortedTroves.insert(vars.troveId, ncr, _upperHint, _lowerHint);

        return vars.troveId;
    }

    function _openTrove(
        address _owner,
        uint256 _ownerIndex,
        uint256 _collAmount,
        uint256 _usdxAmount,
        address _addManager,
        address _removeManager,
        address _receiver,
        TroveChange memory _change
    ) internal returns (uint256) {
        _requireIsNotShutDown();
        // Check collateral is not paused or frozen for new operations
        collateralConfig.requireNotPausedOrFrozen(true);

        LocalVariables_openTrove memory vars;

        // stack too deep not allowing to reuse troveManager from outer functions
        vars.troveManager = troveManager;
        vars.activePool = activePool;
        vars.usdxToken = usdxToken;

        vars.price = _requireOraclesLive();

        // --- Checks ---

        vars.troveId = uint256(
            keccak256(abi.encode(msg.sender, _owner, _ownerIndex))
        );
        _requireTroveDoesNotExist(vars.troveManager, vars.troveId);

        _change.collIncrease = _collAmount;
        _change.debtIncrease = _usdxAmount;

        vars.avgInterestRate = vars
            .activePool
            .getNewApproxAvgInterestRateFromTroveChange(_change);

        vars.entireDebt = _change.debtIncrease;
        _requireAtLeastMinDebt(vars.entireDebt);

        vars.ICR = LiquityMath._computeCR(
            _collAmount,
            vars.entireDebt,
            vars.price
        );

        // ICR is based on the requested USDX amount.
        _requireICRisAboveMCR(vars.ICR);

        vars.newTCR = _getNewTCRFromTroveChange(_change, vars.price);
        _requireNewTCRisAboveCCR(vars.newTCR);

        // --- Effects & interactions ---

        // Set add/remove managers
        _setAddManager(vars.troveId, _addManager);
        _setRemoveManagerAndReceiver(vars.troveId, _removeManager, _receiver);

        vars.activePool.mintAggInterestAndAccountForTroveChange(_change);

        // Pull coll tokens from sender and move them to the Active Pool
        _pullCollAndSendToActivePool(vars.activePool, _collAmount);

        // Calculate borrow fee and mint tokens
        uint256 borrowRatio = collateralConfig.getBorrowRatio();
        uint256 borrowFee = 0;
        address treasury = collateralConfig.getTreasury();
        if (borrowRatio > 0 && treasury != address(0)) {
            borrowFee = (_usdxAmount * borrowRatio) / DECIMAL_PRECISION;
            // Mint fee to treasury
            if (borrowFee > 0) {
                vars.usdxToken.mint(treasury, borrowFee);
            }
        }

        // Mint the requested _usdxAmount (minus fee) to the borrower and mint the gas comp to the GasPool
        vars.usdxToken.mint(msg.sender, _usdxAmount - borrowFee);
        WETH.transferFrom(msg.sender, gasPoolAddress, ETH_GAS_COMPENSATION);

        return vars.troveId;
    }

    // Send collateral to a trove
    function addColl(uint256 _troveId, uint256 _collAmount) external override {
        ITroveManager troveManagerCached = troveManager;
        _requireTroveIsActive(troveManagerCached, _troveId);

        TroveChange memory troveChange;
        troveChange.collIncrease = _collAmount;

        _adjustTrove(troveManagerCached, _troveId, troveChange);
    }

    // Withdraw collateral from a trove
    function withdrawColl(
        uint256 _troveId,
        uint256 _collWithdrawal
    ) external override {
        ITroveManager troveManagerCached = troveManager;
        _requireTroveIsActive(troveManagerCached, _troveId);

        TroveChange memory troveChange;
        troveChange.collDecrease = _collWithdrawal;

        _adjustTrove(troveManagerCached, _troveId, troveChange);
    }

    // Withdraw USDX tokens from a trove: mint new USDX tokens to the owner, and increase the trove's debt accordingly
    function withdrawUSDX(
        uint256 _troveId,
        uint256 _usdxAmount
    ) external override {
        ITroveManager troveManagerCached = troveManager;
        _requireTroveIsActive(troveManagerCached, _troveId);

        TroveChange memory troveChange;
        troveChange.debtIncrease = _usdxAmount;
        _adjustTrove(troveManagerCached, _troveId, troveChange);
    }

    // Repay USDX tokens to a Trove: Burn the repaid USDX tokens, and reduce the trove's debt accordingly
    function repayUSDX(
        uint256 _troveId,
        uint256 _usdxAmount
    ) external override {
        ITroveManager troveManagerCached = troveManager;
        _requireTroveIsActive(troveManagerCached, _troveId);

        TroveChange memory troveChange;
        troveChange.debtDecrease = _usdxAmount;

        _adjustTrove(troveManagerCached, _troveId, troveChange);
    }

    function _initTroveChange(
        TroveChange memory _troveChange,
        uint256 _collChange,
        bool _isCollIncrease,
        uint256 _usdxChange,
        bool _isDebtIncrease
    ) internal pure {
        if (_isCollIncrease) {
            _troveChange.collIncrease = _collChange;
        } else {
            _troveChange.collDecrease = _collChange;
        }

        if (_isDebtIncrease) {
            _troveChange.debtIncrease = _usdxChange;
        } else {
            _troveChange.debtDecrease = _usdxChange;
        }
    }

    function adjustTrove(
        uint256 _troveId,
        uint256 _collChange,
        bool _isCollIncrease,
        uint256 _usdxChange,
        bool _isDebtIncrease
    ) external override {
        ITroveManager troveManagerCached = troveManager;
        _requireTroveIsActive(troveManagerCached, _troveId);

        TroveChange memory troveChange;
        _initTroveChange(
            troveChange,
            _collChange,
            _isCollIncrease,
            _usdxChange,
            _isDebtIncrease
        );
        _adjustTrove(troveManagerCached, _troveId, troveChange);
    }

    function adjustZombieTrove(
        uint256 _troveId,
        uint256 _collChange,
        bool _isCollIncrease,
        uint256 _usdxChange,
        bool _isDebtIncrease,
        uint256 _upperHint,
        uint256 _lowerHint
    ) external override {
        ITroveManager troveManagerCached = troveManager;
        _requireTroveIsZombie(troveManagerCached, _troveId);

        TroveChange memory troveChange;
        _initTroveChange(
            troveChange,
            _collChange,
            _isCollIncrease,
            _usdxChange,
            _isDebtIncrease
        );
        _adjustTrove(troveManagerCached, _troveId, troveChange);

        troveManagerCached.setTroveStatusToActive(_troveId);

        // Calculate NCR for reinsertion
        LatestTroveData memory trove = troveManagerCached.getLatestTroveData(
            _troveId
        );
        uint256 ncr = LiquityMath._computeNominalCR(
            trove.entireColl,
            trove.entireDebt
        );

        _reInsertIntoSortedTroves(_troveId, ncr, _upperHint, _lowerHint);
    }

    /*
     * _adjustTrove(): Alongside a debt change, this function can perform either a collateral top-up or a collateral withdrawal.
     */
    function _adjustTrove(
        ITroveManager _troveManager,
        uint256 _troveId,
        TroveChange memory _troveChange
    ) internal {
        _requireIsNotShutDown();

        // Check collateral config based on operation type
        // Increase operations: adding collateral or borrowing more debt
        bool isIncrease = _troveChange.collIncrease > 0 ||
            _troveChange.debtIncrease > 0;
        collateralConfig.requireNotPausedOrFrozen(isIncrease);

        LocalVariables_adjustTrove memory vars;
        vars.activePool = activePool;
        vars.usdxToken = usdxToken;

        vars.price = _requireOraclesLive();
        vars.isBelowCriticalThreshold = _checkBelowCriticalThreshold(
            vars.price,
            CCR
        );

        // --- Checks ---

        _requireTroveIsOpen(_troveManager, _troveId);

        address owner = troveNFT.ownerOf(_troveId);
        address receiver = owner; // If it’s a withdrawal, and remove manager privilege is set, a different receiver can be defined

        if (_troveChange.collDecrease > 0 || _troveChange.debtIncrease > 0) {
            receiver = _requireSenderIsOwnerOrRemoveManagerAndGetReceiver(
                _troveId,
                owner
            );
        } else {
            // RemoveManager assumes AddManager, so if the former is set, there's no need to check the latter
            _requireSenderIsOwnerOrAddManager(_troveId, owner);
            // No need to check the type of trove change for two reasons:
            // - If the check above fails, it means sender is not owner, nor AddManager, nor RemoveManager.
            //   An independent 3rd party should not be allowed here.
            // - If it's not collIncrease or debtDecrease, _requireNonZeroAdjustment would revert
        }

        vars.trove = _troveManager.getLatestTroveData(_troveId);

        // When the adjustment is a debt repayment, check it's a valid amount and that the caller has enough USDX
        if (_troveChange.debtDecrease > 0) {
            uint256 maxRepayment = vars.trove.entireDebt > MIN_DEBT
                ? vars.trove.entireDebt - MIN_DEBT
                : 0;
            if (_troveChange.debtDecrease > maxRepayment) {
                _troveChange.debtDecrease = maxRepayment;
            }
            _requireSufficientUSDXBalance(
                vars.usdxToken,
                msg.sender,
                _troveChange.debtDecrease
            );
        }

        _requireNonZeroAdjustment(_troveChange);

        // When the adjustment is a collateral withdrawal, check that it's no more than the Trove's entire collateral
        if (_troveChange.collDecrease > 0) {
            _requireValidCollWithdrawal(
                vars.trove.entireColl,
                _troveChange.collDecrease
            );
        }

        vars.newColl =
            vars.trove.entireColl +
            _troveChange.collIncrease -
            _troveChange.collDecrease;
        vars.newDebt =
            vars.trove.entireDebt +
            _troveChange.debtIncrease -
            _troveChange.debtDecrease;

        _troveChange.appliedRedistUSDXDebtGain = vars.trove.redistUSDXDebtGain;
        _troveChange.appliedRedistCollGain = vars.trove.redistCollGain;

        // Make sure the Trove doesn't end up zombie
        // Now the max repayment is capped to stay above MIN_DEBT, so this only applies to adjustZombieTrove
        _requireAtLeastMinDebt(vars.newDebt);

        vars.newICR = LiquityMath._computeCR(
            vars.newColl,
            vars.newDebt,
            vars.price
        );

        // Check the adjustment satisfies all conditions for the current system mode
        _requireValidAdjustmentInCurrentMode(_troveChange, vars);

        // --- Effects and interactions ---

        _troveManager.onAdjustTrove(
            _troveId,
            vars.newColl,
            vars.newDebt,
            _troveChange
        );

        vars.activePool.mintAggInterestAndAccountForTroveChange(_troveChange);
        _moveTokensFromAdjustment(
            receiver,
            _troveChange,
            vars.usdxToken,
            vars.activePool
        );
    }

    function closeTrove(uint256 _troveId) external override {
        ITroveManager troveManagerCached = troveManager;
        IActivePool activePoolCached = activePool;
        IUSDXToken usdxTokenCached = usdxToken;

        // --- Checks ---

        address owner = troveNFT.ownerOf(_troveId);
        address receiver = _requireSenderIsOwnerOrRemoveManagerAndGetReceiver(
            _troveId,
            owner
        );
        _requireTroveIsOpen(troveManagerCached, _troveId);

        LatestTroveData memory trove = troveManagerCached.getLatestTroveData(
            _troveId
        );

        // The borrower must repay their entire debt including accrued interest and redist. gains
        _requireSufficientUSDXBalance(
            usdxTokenCached,
            msg.sender,
            trove.entireDebt
        );

        TroveChange memory troveChange;
        troveChange.appliedRedistUSDXDebtGain = trove.redistUSDXDebtGain;
        troveChange.appliedRedistCollGain = trove.redistCollGain;
        troveChange.collDecrease = trove.entireColl;
        troveChange.debtDecrease = trove.entireDebt;

        (uint256 price, ) = priceFeed.fetchPrice();
        uint256 newTCR = _getNewTCRFromTroveChange(troveChange, price);
        if (!hasBeenShutDown) _requireNewTCRisAboveCCR(newTCR);

        troveManagerCached.onCloseTrove(_troveId, troveChange);

        activePoolCached.mintAggInterestAndAccountForTroveChange(troveChange);

        // Return ETH gas compensation
        WETH.transferFrom(gasPoolAddress, receiver, ETH_GAS_COMPENSATION);
        // Burn the remainder of the Trove's entire debt from the user
        usdxTokenCached.burn(msg.sender, trove.entireDebt);

        // Send the collateral back to the user
        activePoolCached.sendColl(receiver, trove.entireColl);

        _wipeTroveMappings(_troveId);
    }

    function applyPendingDebt(
        uint256 _troveId,
        uint256 _lowerHint,
        uint256 _upperHint
    ) public {
        _requireIsNotShutDown();

        ITroveManager troveManagerCached = troveManager;

        _requireTroveIsOpen(troveManagerCached, _troveId);

        LatestTroveData memory trove = troveManagerCached.getLatestTroveData(
            _troveId
        );
        _requireNonZeroDebt(trove.entireDebt);

        TroveChange memory change;
        change.appliedRedistUSDXDebtGain = trove.redistUSDXDebtGain;
        change.appliedRedistCollGain = trove.redistCollGain;

        troveManagerCached.onApplyTroveInterest(
            _troveId,
            trove.entireColl,
            trove.entireDebt,
            change
        );
        activePool.mintAggInterestAndAccountForTroveChange(change);

        // If the trove was zombie, and now it’s not anymore, put it back in the list
        if (
            _checkTroveIsZombie(troveManagerCached, _troveId) &&
            trove.entireDebt >= MIN_DEBT
        ) {
            troveManagerCached.setTroveStatusToActive(_troveId);
            _reInsertIntoSortedTroves(
                _troveId,
                LiquityMath._computeNominalCR(
                    trove.entireColl,
                    trove.entireDebt
                ),
                _upperHint,
                _lowerHint
            );
        }
    }

    // Call from TM to clean state here
    function onLiquidateTrove(uint256 _troveId) external {
        _requireCallerIsTroveManager();

        _wipeTroveMappings(_troveId);
    }

    function _wipeTroveMappings(uint256 _troveId) internal {
        _wipeAddRemoveManagers(_troveId);
    }

    /**
     * Claim remaining collateral from a liquidation with ICR exceeding the liquidation penalty
     */
    function claimCollateral() external override {
        // send coll from CollSurplus Pool to owner
        collSurplusPool.claimColl(msg.sender);
    }

    function shutdown() external {
        if (hasBeenShutDown) revert IsShutDown();

        uint256 totalColl = getEntireBranchColl();
        uint256 totalDebt = getEntireBranchDebt();
        (uint256 price, bool newOracleFailureDetected) = priceFeed.fetchPrice();
        // If the oracle failed, the above call to PriceFeed will have shut this branch down
        if (newOracleFailureDetected) return;

        // Otherwise, proceed with the TCR check:
        uint256 TCR = LiquityMath._computeCR(totalColl, totalDebt, price);
        if (TCR >= SCR) revert TCRNotBelowSCR();

        _applyShutdown();

        emit ShutDown(TCR);
    }

    // Not technically a "Borrower op", but seems best placed here given current shutdown logic.
    function shutdownFromOracleFailure() external {
        _requireCallerIsPriceFeed();

        // No-op rather than revert here, so that the outer function call which fetches the price does not revert
        // if the system is already shut down.
        if (hasBeenShutDown) return;

        _applyShutdown();
    }

    function _applyShutdown() internal {
        activePool.mintAggInterest();
        hasBeenShutDown = true;
        troveManager.shutdown();
    }

    // --- Helper functions ---

    function _reInsertIntoSortedTroves(
        uint256 _troveId,
        uint256 _ncr,
        uint256 _upperHint,
        uint256 _lowerHint
    ) internal {
        sortedTroves.insert(_troveId, _ncr, _upperHint, _lowerHint);
    }

    // This function mints the USDX corresponding to the borrower's chosen debt increase
    // (it does not mint the accrued interest).
    function _moveTokensFromAdjustment(
        address withdrawalReceiver,
        TroveChange memory _troveChange,
        IUSDXToken _usdxToken,
        IActivePool _activePool
    ) internal {
        if (_troveChange.debtIncrease > 0) {
            // Calculate borrow fee for debt increase
            uint256 borrowRatio = collateralConfig.getBorrowRatio();
            uint256 borrowFee = 0;
            address treasury = collateralConfig.getTreasury();
            if (borrowRatio > 0 && treasury != address(0)) {
                borrowFee =
                    (_troveChange.debtIncrease * borrowRatio) /
                    DECIMAL_PRECISION;
                // Mint fee to treasury
                if (borrowFee > 0) {
                    _usdxToken.mint(treasury, borrowFee);
                }
            }
            // Mint the debt increase (minus fee) to the withdrawal receiver
            _usdxToken.mint(
                withdrawalReceiver,
                _troveChange.debtIncrease - borrowFee
            );
        } else if (_troveChange.debtDecrease > 0) {
            _usdxToken.burn(msg.sender, _troveChange.debtDecrease);
        }

        if (_troveChange.collIncrease > 0) {
            // Pull coll tokens from sender and move them to the Active Pool
            _pullCollAndSendToActivePool(
                _activePool,
                _troveChange.collIncrease
            );
        } else if (_troveChange.collDecrease > 0) {
            // Pull Coll from Active Pool and decrease its recorded Coll balance
            _activePool.sendColl(withdrawalReceiver, _troveChange.collDecrease);
        }
    }

    function _pullCollAndSendToActivePool(
        IActivePool _activePool,
        uint256 _amount
    ) internal {
        // Send Coll tokens from sender to active pool
        collToken.safeTransferFrom(msg.sender, address(_activePool), _amount);
        // Make sure Active Pool accountancy is right
        _activePool.accountForReceivedColl(_amount);
    }

    // --- 'Require' wrapper functions ---

    function _requireIsNotShutDown() internal view {
        if (hasBeenShutDown) {
            revert IsShutDown();
        }
    }

    function _requireNonZeroAdjustment(
        TroveChange memory _troveChange
    ) internal pure {
        if (
            _troveChange.collIncrease == 0 &&
            _troveChange.collDecrease == 0 &&
            _troveChange.debtIncrease == 0 &&
            _troveChange.debtDecrease == 0
        ) {
            revert ZeroAdjustment();
        }
    }

    function _requireTroveDoesNotExist(
        ITroveManager _troveManager,
        uint256 _troveId
    ) internal view {
        ITroveManager.Status status = _troveManager.getTroveStatus(_troveId);
        if (status != ITroveManager.Status.nonExistent) {
            revert TroveExists();
        }
    }

    function _requireTroveIsOpen(
        ITroveManager _troveManager,
        uint256 _troveId
    ) internal view {
        ITroveManager.Status status = _troveManager.getTroveStatus(_troveId);
        if (
            status != ITroveManager.Status.active &&
            status != ITroveManager.Status.zombie
        ) {
            revert TroveNotOpen();
        }
    }

    function _requireTroveIsActive(
        ITroveManager _troveManager,
        uint256 _troveId
    ) internal view {
        ITroveManager.Status status = _troveManager.getTroveStatus(_troveId);
        if (status != ITroveManager.Status.active) {
            revert TroveNotActive();
        }
    }

    function _requireTroveIsZombie(
        ITroveManager _troveManager,
        uint256 _troveId
    ) internal view {
        if (!_checkTroveIsZombie(_troveManager, _troveId)) {
            revert TroveNotZombie();
        }
    }

    function _checkTroveIsZombie(
        ITroveManager _troveManager,
        uint256 _troveId
    ) internal view returns (bool) {
        ITroveManager.Status status = _troveManager.getTroveStatus(_troveId);
        return status == ITroveManager.Status.zombie;
    }

    function _requireNonZeroDebt(uint256 _troveDebt) internal pure {
        if (_troveDebt == 0) {
            revert TroveWithZeroDebt();
        }
    }

    function _requireValidAdjustmentInCurrentMode(
        TroveChange memory _troveChange,
        LocalVariables_adjustTrove memory _vars
    ) internal view {
        /*
         * Below Critical Threshold, it is not permitted:
         *
         * - Borrowing, unless it brings TCR up to CCR again
         * - Collateral withdrawal except accompanied by a debt repayment of at least the same value
         *
         * In Normal Mode, ensure:
         *
         * - The adjustment won't pull the TCR below CCR
         *
         * In Both cases:
         * - The new ICR is above MCR
         */

        _requireICRisAboveMCR(_vars.newICR);

        uint256 newTCR = _getNewTCRFromTroveChange(_troveChange, _vars.price);
        if (_vars.isBelowCriticalThreshold) {
            _requireNoBorrowingUnlessNewTCRisAboveCCR(
                _troveChange.debtIncrease,
                newTCR
            );
            _requireDebtRepaymentGeCollWithdrawal(_troveChange, _vars.price);
        } else {
            // if Normal Mode
            _requireNewTCRisAboveCCR(newTCR);
        }
    }

    function _requireICRisAboveMCR(uint256 _newICR) internal view {
        if (_newICR < MCR) {
            revert ICRBelowMCR();
        }
    }

    function _requireNoBorrowingUnlessNewTCRisAboveCCR(
        uint256 _debtIncrease,
        uint256 _newTCR
    ) internal view {
        if (_debtIncrease > 0 && _newTCR < CCR) {
            revert TCRBelowCCR();
        }
    }

    function _requireDebtRepaymentGeCollWithdrawal(
        TroveChange memory _troveChange,
        uint256 _price
    ) internal pure {
        if (
            (_troveChange.debtDecrease * DECIMAL_PRECISION <
                _troveChange.collDecrease * _price)
        ) {
            revert RepaymentNotMatchingCollWithdrawal();
        }
    }

    function _requireNewTCRisAboveCCR(uint256 _newTCR) internal view {
        if (_newTCR < CCR) {
            revert TCRBelowCCR();
        }
    }

    function _requireAtLeastMinDebt(uint256 _debt) internal pure {
        if (_debt < MIN_DEBT) {
            revert DebtBelowMin();
        }
    }

    function _requireValidCollWithdrawal(
        uint256 _currentColl,
        uint256 _collWithdrawal
    ) internal pure {
        if (_collWithdrawal > _currentColl) {
            revert CollWithdrawalTooHigh();
        }
    }

    function _requireSufficientUSDXBalance(
        IUSDXToken _usdxToken,
        address _borrower,
        uint256 _debtRepayment
    ) internal view {
        if (_usdxToken.balanceOf(_borrower) < _debtRepayment) {
            revert NotEnoughUSDXBalance();
        }
    }

    function _requireValidAnnualInterestRate(
        uint256 _annualInterestRate
    ) internal pure {
        if (_annualInterestRate < MIN_ANNUAL_INTEREST_RATE) {
            revert InterestRateTooLow();
        }
        if (_annualInterestRate > MAX_ANNUAL_INTEREST_RATE) {
            revert InterestRateTooHigh();
        }
    }

    function _requireOrderedRange(
        uint256 _minInterestRate,
        uint256 _maxInterestRate
    ) internal pure {
        if (_minInterestRate >= _maxInterestRate) revert MinGeMax();
    }

    function _requireInterestRateInRange(
        uint256 _annualInterestRate,
        uint256 _minInterestRate,
        uint256 _maxInterestRate
    ) internal pure {
        if (
            _minInterestRate > _annualInterestRate ||
            _annualInterestRate > _maxInterestRate
        ) {
            revert InterestNotInRange();
        }
    }

    function _requireCallerIsTroveManager() internal view {
        if (msg.sender != address(troveManager)) {
            revert CallerNotTroveManager();
        }
    }

    function _requireCallerIsPriceFeed() internal view {
        if (msg.sender != address(priceFeed)) {
            revert CallerNotPriceFeed();
        }
    }

    function _requireOraclesLive() internal returns (uint256) {
        (uint256 price, bool newOracleFailureDetected) = priceFeed.fetchPrice();
        if (newOracleFailureDetected) {
            revert NewOracleFailureDetected();
        }

        return price;
    }

    // --- ICR and TCR getters ---

    function _getNewTCRFromTroveChange(
        TroveChange memory _troveChange,
        uint256 _price
    ) internal view returns (uint256 newTCR) {
        uint256 totalColl = getEntireBranchColl();
        totalColl += _troveChange.collIncrease;
        totalColl -= _troveChange.collDecrease;

        uint256 totalDebt = getEntireBranchDebt();
        totalDebt += _troveChange.debtIncrease;

        totalDebt -= _troveChange.debtDecrease;

        newTCR = LiquityMath._computeCR(totalColl, totalDebt, _price);
    }
}
