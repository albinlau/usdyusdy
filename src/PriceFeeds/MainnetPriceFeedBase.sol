// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.28;

import "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import "openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import "../Interfaces/IMainnetPriceFeed.sol";
import "../BorrowerOperations.sol";

// import "forge-std/console2.sol";

abstract contract MainnetPriceFeedBase is Initializable, OwnableUpgradeable, UUPSUpgradeable, IMainnetPriceFeed  {
    // Determines where the PriceFeed sources data from. Possible states:
    // - primary: Uses the primary price calculation, which depends on the specific feed
    // - lastGoodPrice: the last good price recorded by this PriceFeed.
    PriceSource public priceSource;

    // Last good price tracker for the derived USD price
    uint256 public lastGoodPrice;

    uint256 public stalenessThreshold;

    error InsufficientGasForExternalCall();

    event ShutDownFromOracleFailure(address _failedOracleAddr);

    IBorrowerOperations borrowerOperations;

    function __MainnetPriceFeedBase_init(
        uint256 _xocUsdStalenessThreshold,
        address _borrowOperationsAddress
    ) internal onlyInitializing {
        stalenessThreshold = _xocUsdStalenessThreshold;
        borrowerOperations = IBorrowerOperations(_borrowOperationsAddress);
    }

    function _shutDownAndSwitchToLastGoodPrice(address _failedOracleAddr) internal returns (uint256) {
        // Shut down the branch
        borrowerOperations.shutdownFromOracleFailure();

        priceSource = PriceSource.lastGoodPrice;

        emit ShutDownFromOracleFailure(_failedOracleAddr);
        return lastGoodPrice;
    }

    function _fetchPricePrimary() internal virtual returns (uint256, bool);
}
