// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import "openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import "./Interfaces/IAddressesRegistry.sol";
import "./Interfaces/IBorrowerOperations.sol";
import "./Interfaces/ITroveManager.sol";

/**
 * The purpose of this contract is to hold WETH tokens for gas compensation.
 * When a borrower opens a trove, an additional amount of WETH is pulled,
 * and sent to this contract.
 * When a borrower closes their active trove, this gas compensation is refunded
 * When a trove is liquidated, this gas compensation is paid to liquidator
 */
contract GasPool is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    IWETH public immutable WETH;
    address public immutable borrowerOperationsAddress;
    address public immutable troveManagerAddress;

    constructor(IAddressesRegistry _addressesRegistry) {
        _disableInitializers();

        WETH = _addressesRegistry.WETH();
        borrowerOperationsAddress = address(
            _addressesRegistry.borrowerOperations()
        );
        troveManagerAddress = address(_addressesRegistry.troveManager());
    }

    function initialize(address initialOwner) public initializer {
        __Ownable_init();
        transferOwnership(initialOwner);
        // Allow BorrowerOperations to refund gas compensation
        WETH.approve(borrowerOperationsAddress, type(uint256).max);
        // Allow TroveManager to pay gas compensation to liquidator
        WETH.approve(troveManagerAddress, type(uint256).max);
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
