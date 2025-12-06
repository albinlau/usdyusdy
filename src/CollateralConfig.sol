// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.28;

import "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import "openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "./Interfaces/ICollateralConfig.sol";
import "./Interfaces/IActivePool.sol";

/**
 * @title CollateralConfig
 * @notice Manages configuration parameters for a specific collateral type
 * @dev Each collateral has its own instance of this contract
 */
contract CollateralConfig is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ICollateralConfig
{
    // --- State Variables ---

    Config private config;
    IActivePool public activePool;

    // Constants
    uint256 private constant DECIMAL_PRECISION = 1e18;
    uint256 private constant MAX_COLL_ANNUAL_INTEREST_RATE = 1e18; // 100%
    uint256 private constant MAX_BORROW_RATIO = 1e17; // 10% max borrow fee

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the CollateralConfig contract
     * @param _initialOwner Owner address (typically governance or multisig)
     * @param _treasury Initial treasury address
     * @param _activePool ActivePool contract address
     */
    function initialize(
        address _initialOwner,
        address _treasury,
        address _activePool
    ) public initializer {
        __Ownable_init();
        transferOwnership(_initialOwner);

        _requireValidAddress(_treasury);
        _requireValidAddress(_activePool);

        activePool = IActivePool(_activePool);

        config = Config({
            isFrozen: false,
            isPaused: false,
            annualInterestRate: 0,
            treasury: _treasury,
            borrowRatio: 1e16 // 1%
        });

        emit ConfigUpdated(false, false, 0, _treasury, 1e16);
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    // --- Setter Functions (Owner only) ---

    /**
     * @notice Set complete config
     */
    function setConfig(
        bool _isFrozen,
        bool _isPaused,
        uint256 _annualInterestRate,
        address _treasury,
        uint256 _borrowRatio
    ) external override onlyOwner {
        _requireValidAddress(_treasury);
        _requireValidInterestRate(_annualInterestRate);
        _requireValidBorrowRatio(_borrowRatio);

        config.isFrozen = _isFrozen;
        config.isPaused = _isPaused;
        config.annualInterestRate = _annualInterestRate;
        config.treasury = _treasury;
        config.borrowRatio = _borrowRatio;

        emit ConfigUpdated(
            _isFrozen,
            _isPaused,
            _annualInterestRate,
            _treasury,
            _borrowRatio
        );
    }

    /**
     * @notice Freeze/unfreeze collateral (prevents new operations)
     */
    function setFrozen(bool _frozen) external override onlyOwner {
        config.isFrozen = _frozen;
        emit Frozen(_frozen);
    }

    /**
     * @notice Pause/unpause collateral (prevents all operations except close)
     */
    function setPaused(bool _paused) external override onlyOwner {
        config.isPaused = _paused;
        emit Paused(_paused);
    }

    /**
     * @notice Update collateral annual interest rate
     * @param _rate Annual interest rate in 18 decimals (e.g., 5e16 = 5%)
     * @dev Triggers mintAggInterest before updating rate to settle old rate's interest
     */
    function setAnnualInterestRate(uint256 _rate) external override onlyOwner {
        _requireValidInterestRate(_rate);

        uint256 oldRate = config.annualInterestRate;
        if (oldRate == _rate) return;

        // This ensures historical interest is calculated at the old rate
        activePool.mintAggInterest();

        config.annualInterestRate = _rate;
        emit AnnualInterestRateUpdated(_rate);
    }

    /**
     * @notice Update treasury address
     */
    function setTreasury(address _treasury) external override onlyOwner {
        _requireValidAddress(_treasury);
        config.treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    /**
     * @notice Update borrow fee ratio
     * @param _ratio Borrow fee ratio in 18 decimals (e.g., 5e15 = 0.5%)
     */
    function setBorrowRatio(uint256 _ratio) external override onlyOwner {
        _requireValidBorrowRatio(_ratio);
        config.borrowRatio = _ratio;
        emit BorrowRatioUpdated(_ratio);
    }

    // --- Getter Functions (View) ---

    function getConfig() external view override returns (Config memory) {
        return config;
    }

    function isFrozen() external view override returns (bool) {
        return config.isFrozen;
    }

    function isPaused() external view override returns (bool) {
        return config.isPaused;
    }

    function getAnnualInterestRate() external view override returns (uint256) {
        return config.annualInterestRate;
    }

    function getTreasury() external view override returns (address) {
        return config.treasury;
    }

    function getBorrowRatio() external view override returns (uint256) {
        return config.borrowRatio;
    }

    // --- Check Functions ---

    /**
     * @notice Check if operations are allowed
     * @param _isIncrease True for operations that increase exposure (open, add collateral/debt)
     * @dev Reverts if:
     *      - Collateral is paused (all operations blocked except close)
     *      - Collateral is frozen and operation increases exposure
     */
    function requireNotPausedOrFrozen(bool _isIncrease) external view override {
        if (config.isPaused) {
            revert CollateralPaused();
        }

        if (_isIncrease && config.isFrozen) {
            revert CollateralFrozen();
        }
    }

    // --- Internal Functions ---

    function _requireValidAddress(address _address) internal pure {
        if (_address == address(0)) {
            revert InvalidAddress();
        }
    }

    function _requireValidInterestRate(uint256 _rate) internal pure {
        // Max 100% annual rate (1e18 = 100%)
        if (_rate > MAX_COLL_ANNUAL_INTEREST_RATE) {
            revert InvalidInterestRate();
        }
    }

    function _requireValidBorrowRatio(uint256 _ratio) internal pure {
        // Max 10% borrow fee (1e17 = 10%)
        if (_ratio > MAX_BORROW_RATIO) {
            revert InvalidBorrowRatio();
        }
    }
}
