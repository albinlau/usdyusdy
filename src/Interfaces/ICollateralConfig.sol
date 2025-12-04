// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.28;

interface ICollateralConfig {
    // --- Structs ---

    struct Config {
        bool isFrozen; // Freeze new operations (open, adjust up)
        bool isPaused; // Pause all operations except close
        uint256 annualInterestRate; // Annual collateral interest rate (18 decimals)
        address treasury; // Treasury address for protocol revenue
    }

    // --- Events ---

    event ConfigUpdated(
        bool isFrozen,
        bool isPaused,
        uint256 annualInterestRate,
        address treasury
    );

    event Frozen(bool frozen);
    event Paused(bool paused);
    event AnnualInterestRateUpdated(uint256 newRate);
    event TreasuryUpdated(address newTreasury);

    // --- Errors ---

    error InvalidAddress();
    error InvalidInterestRate();
    error CollateralPaused();
    error CollateralFrozen();

    // --- Setter Functions ---

    /**
     * @notice Set complete config
     */
    function setConfig(
        bool _isFrozen,
        bool _isPaused,
        uint256 _collAnnualInterestRate,
        address _treasury
    ) external;

    /**
     * @notice Freeze/unfreeze collateral (prevents new operations)
     */
    function setFrozen(bool _frozen) external;

    /**
     * @notice Pause/unpause collateral (prevents all operations except close)
     */
    function setPaused(bool _paused) external;

    /**
     * @notice Update collateral annual interest rate
     * @param _rate Annual interest rate in 18 decimals (e.g., 5e16 = 5%)
     */
    function setCollAnnualInterestRate(uint256 _rate) external;

    /**
     * @notice Update treasury address
     */
    function setTreasury(address _treasury) external;

    // --- Getter Functions ---

    function getConfig() external view returns (Config memory);

    function isFrozen() external view returns (bool);

    function isPaused() external view returns (bool);

    function getCollAnnualInterestRate() external view returns (uint256);

    function getTreasury() external view returns (address);

    // --- Check Functions ---

    /**
     * @notice Check if operations are allowed
     * @param _isIncrease True for operations that increase exposure (open, add collateral/debt)
     */
    function requireNotPausedOrFrozen(bool _isIncrease) external view;
}
