// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./ILiquityBase.sol";
import "./ITroveNFT.sol";
import "./IBorrowerOperations.sol";
import "./IStabilityPool.sol";
import "./IUSDXToken.sol";
import "./ISortedTroves.sol";
import "../Types/LatestTroveData.sol";

// Common interface for the Trove Manager.
interface ITroveManager is ILiquityBase {
    enum Status {
        nonExistent,
        active,
        closedByOwner,
        closedByLiquidation,
        zombie
    }

    function shutdownTime() external view returns (uint256);

    function troveNFT() external view returns (ITroveNFT);

    function stabilityPool() external view returns (IStabilityPool);

    //function usdxToken() external view returns (IUSDXToken);
    function sortedTroves() external view returns (ISortedTroves);

    function borrowerOperations() external view returns (IBorrowerOperations);

    function Troves(
        uint256 _id
    )
        external
        view
        returns (
            uint256 debt,
            uint256 coll,
            uint256 stake,
            Status status,
            uint64 arrayIndex,
            uint64 lastDebtUpdateTime
        );

    function rewardSnapshots(
        uint256 _id
    ) external view returns (uint256 coll, uint256 usdxDebt);

    function getTroveIdsCount() external view returns (uint256);

    function getTroveFromTroveIdsArray(
        uint256 _index
    ) external view returns (uint256);

    function getCurrentICR(
        uint256 _troveId,
        uint256 _price
    ) external view returns (uint256);

    function getTroveNominalCR(
        uint256 _troveId
    ) external view returns (uint256);

    function lastZombieTroveId() external view returns (uint256);

    function batchLiquidateTroves(uint256[] calldata _troveArray) external;

    function redeemCollateral(
        address _sender,
        uint256 _usdxAmount,
        uint256 _price,
        uint256 _redemptionRate,
        uint256 _maxIterations
    ) external returns (uint256 _redemeedAmount);

    function shutdown() external;

    function urgentRedemption(
        uint256 _usdxAmount,
        uint256[] calldata _troveIds,
        uint256 _minCollateral
    ) external;

    function getUnbackedPortionPriceAndRedeemability()
        external
        returns (uint256, uint256, bool);

    function getLatestTroveData(
        uint256 _troveId
    ) external view returns (LatestTroveData memory);

    function getTroveAnnualInterestRate(
        uint256 _troveId
    ) external view returns (uint256);

    function getTroveStatus(uint256 _troveId) external view returns (Status);

    function minDebt() external view returns (uint256);

    // -- permissioned functions called by BorrowerOperations

    function onOpenTrove(
        address _owner,
        uint256 _troveId,
        TroveChange memory _troveChange
    ) external;

    // Called from `adjustZombieTrove()`
    function setTroveStatusToActive(uint256 _troveId) external;

    function onAdjustTrove(
        uint256 _troveId,
        uint256 _newColl,
        uint256 _newDebt,
        TroveChange calldata _troveChange
    ) external;

    function onApplyTroveInterest(
        uint256 _troveId,
        uint256 _newTroveColl,
        uint256 _newTroveDebt,
        TroveChange calldata _troveChange
    ) external;

    function onCloseTrove(
        uint256 _troveId,
        TroveChange memory _troveChange // decrease vars: entire, with interest and redistribution
    ) external;

    // -- end of permissioned functions --
}
