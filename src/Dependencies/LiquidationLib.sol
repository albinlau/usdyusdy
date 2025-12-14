// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "./LiquityMath.sol";
import {DECIMAL_PRECISION, COLL_GAS_COMPENSATION_CAP} from "./Constants.sol";

library LiquidationLib {
    using LiquityMath for uint256;

    // Return the amount of Coll to be drawn from a trove's collateral and sent as gas compensation.
    function _getCollGasCompensation(
        uint256 _coll,
        uint256 liquidationPenaltyLiquidator
    ) public pure returns (uint256) {
        return LiquityMath._min(
            _coll * liquidationPenaltyLiquidator / DECIMAL_PRECISION,
            COLL_GAS_COMPENSATION_CAP
        );
    }

    function _getOffsetAndRedistributionVals(
        uint256 _entireTroveDebt,
        uint256 _entireTroveColl,
        uint256 _usdxInSPForOffsets,
        uint256 _price,
        uint256 liquidationPenaltySp,
        uint256 liquidationPenaltyLiquidator,
        uint256 liquidationPenaltyDao
    ) public pure returns (
        uint256 debtToOffset,
        uint256 collToSendToSP,
        uint256 collGasCompensation,
        uint256 debtToRedistribute,
        uint256 collToRedistribute,
        uint256 collToDao,
        uint256 collSurplus
    ) {
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

            collGasCompensation = _getCollGasCompensation(
                collSPPortion,
                liquidationPenaltyLiquidator
            );

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
    }

    function _getCollPenaltyAndSurplus(
        uint256 _collToLiquidate,
        uint256 _debtToLiquidate,
        uint256 _penaltyRatio,
        uint256 _price
    ) public pure returns (uint256 seizedColl, uint256 collSurplus) {
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
}