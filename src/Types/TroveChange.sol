// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

struct TroveChange {
    uint256 appliedRedistUSDXDebtGain;
    uint256 appliedRedistCollGain;
    uint256 collIncrease;
    uint256 collDecrease;
    uint256 debtIncrease;
    uint256 debtDecrease;
}
