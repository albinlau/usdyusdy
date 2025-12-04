// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

contract ERC20Faucet is ERC20, Ownable {
    uint256 public claimAmount;
    uint256 public claimPeriod;

    mapping(address => uint256) public lastClaimTimestamp;

    constructor(
        string memory _name,
        string memory _symbol,
        uint256 _claimAmount,
        uint256 _claimPeriod,
        address _owner
    ) ERC20(_name, _symbol) Ownable(_owner) {
        claimAmount = _claimAmount;
        claimPeriod = _claimPeriod;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function claim() external {
        require(
            block.timestamp >= lastClaimTimestamp[msg.sender] + claimPeriod,
            "Claim period not reached"
        );

        lastClaimTimestamp[msg.sender] = block.timestamp;
        _mint(msg.sender, claimAmount);
    }

    function setClaimAmount(uint256 _claimAmount) external onlyOwner {
        claimAmount = _claimAmount;
    }

    function setClaimPeriod(uint256 _claimPeriod) external onlyOwner {
        claimPeriod = _claimPeriod;
    }
}
