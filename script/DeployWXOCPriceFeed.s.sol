// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/PriceFeeds/WXOCPriceFeed.sol";

contract UUPSProxy {
    bytes32 private constant _IMPLEMENTATION_SLOT =
    0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    constructor(address implementation, bytes memory data) {
        require(implementation != address(0), "Invalid implementation");
        assembly {
            sstore(_IMPLEMENTATION_SLOT, implementation)
        }

        if (data.length > 0) {
            (bool success, ) = implementation.delegatecall(data);
            require(success, "Initialization failed");
        }
    }

    fallback() external payable {
        _delegate(_implementation());
    }

    receive() external payable {
        _delegate(_implementation());
    }

    function _implementation() internal view returns (address impl) {
        assembly {
            impl := sload(_IMPLEMENTATION_SLOT)
        }
    }

    function _delegate(address implementation) internal {
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), implementation, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

contract DeployWXOCPriceFeed is Script {
    function run() external {
        // Read deployment parameters (can also be hardcoded or passed via environment variables)
        address priceFeeder = vm.envAddress("PRICE_FEEDER"); // Price feeder address
        uint256 signatureValidity = vm.envUint("SIGNATURE_VALIDITY"); // Signature validity period (seconds)
        uint256 minUpdateInterval = vm.envUint("MIN_UPDATE_INTERVAL"); // Minimum update interval (seconds)
        uint256 stalenessThreshold = vm.envUint("STALENESS_THRESHOLD"); // Price staleness threshold (seconds)
        address borrowerOperations = vm.envAddress("BORROWER_OPERATIONS"); // Borrower operations contract address
        uint256 initialPrice = vm.envUint("INITIAL_PRICE");

        // Start transaction broadcast
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        // Deploy contract
        WXOCPriceFeed logicContract = new WXOCPriceFeed();
        console.log("Logic contract deployed to:", address(logicContract));

        bytes memory initData = abi.encodeWithSelector(
            WXOCPriceFeed.initialize.selector,
            priceFeeder,
            signatureValidity,
            minUpdateInterval,
            stalenessThreshold,
            borrowerOperations,
            initialPrice,
            priceFeeder
        );

        UUPSProxy proxy = new UUPSProxy(
            address(logicContract),
            initData
        );

        // Stop transaction broadcast
        vm.stopBroadcast();

        // Print contract address
        console.log("=====================================");
        console.log("Deployment Summary:");
        console.log("Logic contract address:", address(logicContract));
        console.log("Proxy contract address:", address(proxy));
        console.log("=====================================");
    }
}