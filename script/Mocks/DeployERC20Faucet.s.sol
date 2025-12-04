// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ERC20Faucet} from "../../src/Mocks/ERC20Faucet.sol";

contract DeployERC20Faucet is Script {
    function run() public {
        string memory name = "Mock Token";
        string memory symbol = "MOCK";
        uint256 claimAmount = 100 ether;
        uint256 claimPeriod = 1 days;
        address owner = msg.sender;

        vm.startBroadcast();

        // Deploy the ERC20Faucet contract
        ERC20Faucet faucet = new ERC20Faucet(
            name,
            symbol,
            claimAmount,
            claimPeriod,
            owner
        );

        vm.stopBroadcast();

        console.log("ERC20Faucet deployed at:", address(faucet));
    }
}
