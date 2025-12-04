// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.28;

import "openzeppelin-contracts/contracts/access/Ownable.sol";
import "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Permit.sol";

import "./Interfaces/IUSDXToken.sol";

/*
 * --- Functionality added specific to the USDXToken ---
 *
 * 1) Transfer protection: blacklist of addresses that are invalid recipients (i.e. core Liquity contracts) in external
 * transfer() and transferFrom() calls. The purpose is to protect users from losing tokens by mistakenly sending USDX directly to a Liquity
 * core contract, when they should rather call the right function.
 *
 * 2) sendToPool() and returnFromPool(): functions callable only Liquity core contracts, which move USDX tokens between Liquity <-> user.
 */

contract USDXToken is Ownable, IUSDXToken, ERC20Permit {
    string internal constant _NAME = "USDX Stablecoin";
    string internal constant _SYMBOL = "USDX";

    // --- Addresses ---

    address public collateralRegistryAddress;
    mapping(address => bool) troveManagerAddresses;
    mapping(address => bool) stabilityPoolAddresses;
    mapping(address => bool) borrowerOperationsAddresses;
    mapping(address => bool) activePoolAddresses;

    // --- Events ---
    event CollateralRegistryAddressChanged(
        address _newCollateralRegistryAddress
    );
    event TroveManagerAddressAdded(address _newTroveManagerAddress);
    event StabilityPoolAddressAdded(address _newStabilityPoolAddress);
    event BorrowerOperationsAddressAdded(address _newBorrowerOperationsAddress);
    event ActivePoolAddressAdded(address _newActivePoolAddress);

    constructor(
        address _owner
    ) Ownable(_owner) ERC20(_NAME, _SYMBOL) ERC20Permit(_NAME) {}

    function setBranchAddresses(
        address _troveManagerAddress,
        address _stabilityPoolAddress,
        address _borrowerOperationsAddress,
        address _activePoolAddress
    ) external override onlyOwner {
        troveManagerAddresses[_troveManagerAddress] = true;
        emit TroveManagerAddressAdded(_troveManagerAddress);

        stabilityPoolAddresses[_stabilityPoolAddress] = true;
        emit StabilityPoolAddressAdded(_stabilityPoolAddress);

        borrowerOperationsAddresses[_borrowerOperationsAddress] = true;
        emit BorrowerOperationsAddressAdded(_borrowerOperationsAddress);

        activePoolAddresses[_activePoolAddress] = true;
        emit ActivePoolAddressAdded(_activePoolAddress);
    }

    function setCollateralRegistry(
        address _collateralRegistryAddress
    ) external override onlyOwner {
        collateralRegistryAddress = _collateralRegistryAddress;
        emit CollateralRegistryAddressChanged(_collateralRegistryAddress);
    }

    // --- Functions for intra-Liquity calls ---

    function mint(address _account, uint256 _amount) external override {
        _requireCallerIsBOorAP();
        _mint(_account, _amount);
    }

    function burn(address _account, uint256 _amount) external override {
        _requireCallerIsCRorBOorTMorSP();
        _burn(_account, _amount);
    }

    function sendToPool(
        address _sender,
        address _poolAddress,
        uint256 _amount
    ) external override {
        _requireCallerIsStabilityPool();
        _transfer(_sender, _poolAddress, _amount);
    }

    function returnFromPool(
        address _poolAddress,
        address _receiver,
        uint256 _amount
    ) external override {
        _requireCallerIsStabilityPool();
        _transfer(_poolAddress, _receiver, _amount);
    }

    // --- External functions ---

    function transfer(
        address recipient,
        uint256 amount
    ) public override(ERC20, IERC20) returns (bool) {
        _requireValidRecipient(recipient);
        return super.transfer(recipient, amount);
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override(ERC20, IERC20) returns (bool) {
        _requireValidRecipient(recipient);
        return super.transferFrom(sender, recipient, amount);
    }

    // --- 'require' functions ---

    function _requireValidRecipient(address _recipient) internal view {
        require(
            _recipient != address(0) && _recipient != address(this),
            "USDXToken: Cannot transfer tokens directly to the USDX token contract or the zero address"
        );
    }

    function _requireCallerIsBOorAP() internal view {
        require(
            borrowerOperationsAddresses[msg.sender] ||
                activePoolAddresses[msg.sender],
            "USDXToken: Caller is not BO or AP"
        );
    }

    function _requireCallerIsCRorBOorTMorSP() internal view {
        require(
            msg.sender == collateralRegistryAddress ||
                borrowerOperationsAddresses[msg.sender] ||
                troveManagerAddresses[msg.sender] ||
                stabilityPoolAddresses[msg.sender],
            "USDXToken: Caller is neither CR nor BorrowerOperations nor TroveManager nor StabilityPool"
        );
    }

    function _requireCallerIsStabilityPool() internal view {
        require(
            stabilityPoolAddresses[msg.sender],
            "USDXToken: Caller is not the StabilityPool"
        );
    }

    function nonces(
        address owner
    ) public view override(IERC20Permit, ERC20Permit) returns (uint256) {
        return super.nonces(owner);
    }
}
