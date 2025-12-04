// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IRedemptionHelper {
    struct SimulationContext {
        address troveManager;
        address sortedTroves;
        bool redeemable;
        uint256 price;
        uint256 proportion;
        uint256 attemptedUSDX;
        uint256 redeemedUSDX;
        uint256 iterations;
    }

    struct Redeemed {
        uint256 usdx;
        uint256 coll;
    }

    function simulateRedemption(
        uint256 _usdx,
        uint256 _maxIterationsPerCollateral
    )
        external
        returns (SimulationContext[] memory branch, uint256 totalProportions);

    // Find the maximal amount of USDX that can be redeemed proportionally within
    // a given iteration limit. This helps prevent the redeemer from overpaying on
    // the redemption fee.
    //
    // Also returns the expected fee that will be paid (as a percentage), and the
    // expected collateral amounts that will be paid out in exchange for the
    // redeemed USDX. The latter may be used to calculate the _minCollRedeemed
    // parameter passed to redeemCollateral().
    function truncateRedemption(
        uint256 _usdx,
        uint256 _maxIterationsPerCollateral
    )
        external
        returns (
            uint256 truncatedUSDX,
            uint256 feePct,
            Redeemed[] memory redeemed
        );

    // Wrapper around CollateralRegistry's redeemCollateral() that adds slippage
    // protection in the form of a minimum acceptable collateral amounts parameter.
    function redeemCollateral(
        uint256 _usdx,
        uint256 _maxIterationsPerCollateral,
        uint256 _maxFeePct,
        uint256[] memory _minCollRedeemed
    ) external;
}
