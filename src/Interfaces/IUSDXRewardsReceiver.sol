// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IUSDXRewardsReceiver {
    function triggerUSDXRewards(uint256 _usdxYield) external;
}
