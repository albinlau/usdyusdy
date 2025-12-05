// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IHintHelpers {
    function getApproxHint(
        uint256 _collIndex,
        uint256 _ncr,
        uint256 _numTrials,
        uint256 _inputRandomSeed
    )
        external
        view
        returns (uint256 hintId, uint256 diff, uint256 latestRandomSeed);
}
