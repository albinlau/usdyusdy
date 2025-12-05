// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./ILiquityBase.sol";
import "./IAddRemoveManagers.sol";
import "./IUSDXToken.sol";
import "./IPriceFeed.sol";
import "./ISortedTroves.sol";
import "./ITroveManager.sol";
import "./IWETH.sol";

// Common interface for the Borrower Operations.
interface IBorrowerOperations is ILiquityBase, IAddRemoveManagers {
    function CCR() external view returns (uint256);

    function MCR() external view returns (uint256);

    function SCR() external view returns (uint256);

    function openTrove(
        address _owner,
        uint256 _ownerIndex,
        uint256 _ETHAmount,
        uint256 _usdxAmount,
        uint256 _upperHint,
        uint256 _lowerHint,
        address _addManager,
        address _removeManager,
        address _receiver
    ) external returns (uint256);

    function addColl(uint256 _troveId, uint256 _ETHAmount) external;

    function withdrawColl(uint256 _troveId, uint256 _amount) external;

    function withdrawUSDX(uint256 _troveId, uint256 _amount) external;

    function repayUSDX(uint256 _troveId, uint256 _amount) external;

    function closeTrove(uint256 _troveId) external;

    function adjustTrove(
        uint256 _troveId,
        uint256 _collChange,
        bool _isCollIncrease,
        uint256 _debtChange,
        bool isDebtIncrease
    ) external;

    function adjustZombieTrove(
        uint256 _troveId,
        uint256 _collChange,
        bool _isCollIncrease,
        uint256 _usdxChange,
        bool _isDebtIncrease,
        uint256 _upperHint,
        uint256 _lowerHint
    ) external;

    function applyPendingDebt(
        uint256 _troveId,
        uint256 _lowerHint,
        uint256 _upperHint
    ) external;

    function onLiquidateTrove(uint256 _troveId) external;

    function claimCollateral() external;

    function hasBeenShutDown() external view returns (bool);

    function shutdown() external;

    function shutdownFromOracleFailure() external;
}
