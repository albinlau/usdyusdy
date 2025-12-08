// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/PriceFeeds/WXOCPriceFeed.sol";

contract DeployWXOCPriceFeed is Script {
    function run() external {
        // Read deployment parameters (can also be hardcoded or passed via environment variables)
        address priceFeeder = vm.envAddress("PRICE_FEEDER"); // Price feeder address
        uint256 signatureValidity = vm.envUint("SIGNATURE_VALIDITY"); // Signature validity period (seconds)
        uint256 minUpdateInterval = vm.envUint("MIN_UPDATE_INTERVAL"); // Minimum update interval (seconds)
        uint256 stalenessThreshold = vm.envUint("STALENESS_THRESHOLD"); // Price staleness threshold (seconds)
        address borrowerOperations = vm.envAddress("BORROWER_OPERATIONS"); // Borrower operations contract address

        // Start transaction broadcast
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        // Deploy contract
        WXOCPriceFeed priceFeed = new WXOCPriceFeed(
            priceFeeder,
            signatureValidity,
            minUpdateInterval,
            stalenessThreshold,
            borrowerOperations
        );

        // Stop transaction broadcast
        vm.stopBroadcast();

        // Print contract address
        console.log("WXOCPriceFeed deployed to:", address(priceFeed));
    }
}