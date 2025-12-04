// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "openzeppelin-contracts-upgradeable/contracts/token/ERC721/extensions/IERC721MetadataUpgradeable.sol";

import "./ITroveManager.sol";

interface ITroveNFT is IERC721MetadataUpgradeable {
    function mint(address _owner, uint256 _troveId) external;

    function burn(uint256 _troveId) external;
}
