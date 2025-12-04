// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

interface IRETHToken {
    function getExchangeRate() external view returns (uint256);
}
