// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ICollateralRegistry} from "./ICollateralRegistry.sol";
import {IHintHelpers} from "./IHintHelpers.sol";

interface IDebtInFrontHelper {
    function collateralRegistry() external view returns (ICollateralRegistry);

    function hintHelpers() external view returns (IHintHelpers);

    function getDebtBetweenNCRs(
        uint256 _collIndex,
        uint256 _ncrLo, // inclusive (lower NCR, further down the list)
        uint256 _ncrHi, // exclusive (higher NCR, closer to head)
        uint256 _excludedTroveId,
        uint256 _hintId,
        uint256 _numTrials
    ) external view returns (uint256 debt, uint256 blockTimestamp);

    function getDebtBetweenNCRAndTrove(
        uint256 _collIndex,
        uint256 _ncrLo, // inclusive (lower NCR, further down the list)
        uint256 _ncrHi, // exclusive (higher NCR, closer to head)
        uint256 _troveIdToStopAt, // excluded
        uint256 _hintId,
        uint256 _numTrials
    ) external view returns (uint256 debt, uint256 blockTimestamp);
}
