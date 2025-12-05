// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

struct LatestTroveData {
    uint256 entireDebt;
    uint256 entireColl;
    uint256 redistUSDXDebtGain;
    uint256 redistCollGain;
    uint256 accruedInterest;
    uint256 recordedDebt;
    uint256 annualInterestRate;
}
