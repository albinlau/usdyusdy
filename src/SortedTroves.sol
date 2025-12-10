// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import "openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import "./Interfaces/ISortedTroves.sol";
import "./Interfaces/IAddressesRegistry.sol";
import "./Interfaces/ITroveManager.sol";
import "./Interfaces/IBorrowerOperations.sol";

// ID of head & tail of the list. Callers should stop iterating with `getNext()` / `getPrev()`
// when encountering this node ID.
uint256 constant ROOT_NODE_ID = 0;

/*
 * A sorted doubly linked list with nodes sorted in descending order.
 *
 * Nodes map to active Troves in the system - the ID property is the address of a Trove owner.
 * Nodes are ordered according to their Nominal Collateral Ratio (NCR = collateral / debt).
 *
 * The list optionally accepts insert position hints.
 *
 * The NCR is calculated from the Trove struct in TroveManager, not directly on the Node.
 *
 * A node need only be re-inserted when the borrower adjusts their collateral or debt. NCR order is preserved
 * under all other system operations.
 *
 * The list is a modification of the following audited SortedDoublyLinkedList:
 * https://github.com/livepeer/protocol/blob/master/contracts/libraries/SortedDoublyLL.sol
 *
 * Changes made in the USDX implementation:
 *
 * - Keys have been removed from nodes
 *
 * - Ordering checks for insertion are performed by comparing NCR values to the Trove's current NCR.
 *
 * - Public functions with parameters have been made internal to save gas, and given an external wrapper function for external access
 */
contract SortedTroves is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ISortedTroves
{
    string public constant NAME = "SortedTroves";

    // Constants used for documentation purposes
    uint256 constant UNINITIALIZED_ID = 0;
    uint256 constant BAD_HINT = 0;

    event TroveManagerAddressChanged(address _troveManagerAddress);
    event BorrowerOperationsAddressChanged(address _borrowerOperationsAddress);

    address public borrowerOperationsAddress;
    ITroveManager public troveManager;

    // Information for a node in the list
    struct Node {
        uint256 nextId; // Id of next node (smaller NCR) in the list
        uint256 prevId; // Id of previous node (larger NCR) in the list
        bool exists;
    }

    struct Position {
        uint256 prevId;
        uint256 nextId;
    }

    // Current size of the list
    uint256 public size;

    // Stores the forward and reverse links of each node in the list.
    // nodes[ROOT_NODE_ID] holds the head and tail of the list. This avoids the need for special
    // handling when inserting into or removing from a terminal position (head or tail), inserting
    // into an empty list or removing the element of a singleton list.
    mapping(uint256 => Node) public nodes;

    constructor(IAddressesRegistry _addressesRegistry) {
        _disableInitializers();

        troveManager = ITroveManager(_addressesRegistry.troveManager());
        borrowerOperationsAddress = address(
            _addressesRegistry.borrowerOperations()
        );
    }

    function initialize(address initialOwner) public initializer {
        __Ownable_init();
        transferOwnership(initialOwner);

        // Technically, this is not needed as long as ROOT_NODE_ID is 0, but it doesn't hurt
        nodes[ROOT_NODE_ID].nextId = ROOT_NODE_ID;
        nodes[ROOT_NODE_ID].prevId = ROOT_NODE_ID;

        emit TroveManagerAddressChanged(address(troveManager));
        emit BorrowerOperationsAddressChanged(borrowerOperationsAddress);
    }

    function updateByAddressRegistry(
        IAddressesRegistry _addressesRegistry
    ) external onlyOwner {
        troveManager = ITroveManager(_addressesRegistry.troveManager());
        borrowerOperationsAddress = address(
            _addressesRegistry.borrowerOperations()
        );
        emit TroveManagerAddressChanged(address(troveManager));
        emit BorrowerOperationsAddressChanged(borrowerOperationsAddress);
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    // Insert an entire list slice (such as a batch of Troves sharing the same interest rate)
    // between adjacent nodes `_prevId` and `_nextId`.
    // Can be used to insert a single node by passing its ID as both `_sliceHead` and `_sliceTail`.
    function _insertSliceIntoVerifiedPosition(
        uint256 _sliceHead,
        uint256 _sliceTail,
        uint256 _prevId,
        uint256 _nextId
    ) internal {
        nodes[_prevId].nextId = _sliceHead;
        nodes[_sliceHead].prevId = _prevId;
        nodes[_sliceTail].nextId = _nextId;
        nodes[_nextId].prevId = _sliceTail;
    }

    function _insertSlice(
        ITroveManager _troveManager,
        uint256 _sliceHead,
        uint256 _sliceTail,
        uint256 _ncr,
        uint256 _prevId,
        uint256 _nextId
    ) internal {
        if (!_validInsertPosition(_troveManager, _ncr, _prevId, _nextId)) {
            // Sender's hint was not a valid insert position
            // Use sender's hint to find a valid insert position
            (_prevId, _nextId) = _findInsertPosition(
                _troveManager,
                _ncr,
                _prevId,
                _nextId
            );
        }

        _insertSliceIntoVerifiedPosition(
            _sliceHead,
            _sliceTail,
            _prevId,
            _nextId
        );
    }

    /*
     * @dev Add a Trove to the list
     * @param _id Trove's id
     * @param _ncr Trove's nominal collateral ratio
     * @param _prevId Id of previous Trove for the insert position
     * @param _nextId Id of next Trove for the insert position
     */
    function insert(
        uint256 _id,
        uint256 _ncr,
        uint256 _prevId,
        uint256 _nextId
    ) external override {
        _requireCallerIsBorrowerOperations();
        require(!contains(_id), "SortedTroves: List already contains the node");
        require(
            _id != ROOT_NODE_ID,
            "SortedTroves: _id cannot be the root node's ID"
        );

        _insertSlice(troveManager, _id, _id, _ncr, _prevId, _nextId);
        nodes[_id].exists = true;
        ++size;
    }

    // Remove the entire slice between `_sliceHead` and `_sliceTail` from the list while keeping
    // the removed nodes connected to each other, such that they can be reinserted into a different
    // position with `_insertSlice()`.
    // Can be used to remove a single node by passing its ID as both `_sliceHead` and `_sliceTail`.
    function _removeSlice(uint256 _sliceHead, uint256 _sliceTail) internal {
        nodes[nodes[_sliceHead].prevId].nextId = nodes[_sliceTail].nextId;
        nodes[nodes[_sliceTail].nextId].prevId = nodes[_sliceHead].prevId;
    }

    /*
     * @dev Remove a non-batched Trove from the list
     * @param _id Trove's id
     */
    function remove(uint256 _id) external override {
        _requireCallerIsBOorTM();
        require(contains(_id), "SortedTroves: List does not contain the id");

        _removeSlice(_id, _id);
        delete nodes[_id];
        --size;
    }

    function _reInsertSlice(
        ITroveManager _troveManager,
        uint256 _sliceHead,
        uint256 _sliceTail,
        uint256 _ncr,
        uint256 _prevId,
        uint256 _nextId
    ) internal {
        if (!_validInsertPosition(_troveManager, _ncr, _prevId, _nextId)) {
            // Sender's hint was not a valid insert position
            // Use sender's hint to find a valid insert position
            (_prevId, _nextId) = _findInsertPosition(
                _troveManager,
                _ncr,
                _prevId,
                _nextId
            );
        }

        // Check that the new insert position isn't the same as the existing one
        if (_nextId != _sliceHead && _prevId != _sliceTail) {
            _removeSlice(_sliceHead, _sliceTail);
            _insertSliceIntoVerifiedPosition(
                _sliceHead,
                _sliceTail,
                _prevId,
                _nextId
            );
        }
    }

    /*
     * @dev Re-insert a non-batched Trove at a new position, based on its new NCR
     * @param _id Trove's id
     * @param _newNcr Trove's new nominal collateral ratio
     * @param _prevId Id of previous Trove for the new insert position
     * @param _nextId Id of next Trove for the new insert position
     */
    function reInsert(
        uint256 _id,
        uint256 _newNcr,
        uint256 _prevId,
        uint256 _nextId
    ) external override {
        _requireCallerIsBorrowerOperations();
        require(contains(_id), "SortedTroves: List does not contain the id");

        _reInsertSlice(troveManager, _id, _id, _newNcr, _prevId, _nextId);
    }

    /*
     * @dev Checks if the list contains a node
     */
    function contains(uint256 _id) public view override returns (bool) {
        return nodes[_id].exists;
    }

    /*
     * @dev Checks if the list is empty
     */
    function isEmpty() external view override returns (bool) {
        return size == 0;
    }

    /*
     * @dev Returns the current size of the list
     */
    function getSize() external view override returns (uint256) {
        return size;
    }

    /*
     * @dev Returns the first node in the list (node with the largest NCR)
     */
    function getFirst() external view override returns (uint256) {
        return nodes[ROOT_NODE_ID].nextId;
    }

    /*
     * @dev Returns the last node in the list (node with the smallest NCR)
     */
    function getLast() external view override returns (uint256) {
        return nodes[ROOT_NODE_ID].prevId;
    }

    /*
     * @dev Returns the next node (with a smaller NCR) in the list for a given node
     * @param _id Node's id
     */
    function getNext(uint256 _id) external view override returns (uint256) {
        return nodes[_id].nextId;
    }

    /*
     * @dev Returns the previous node (with a larger NCR) in the list for a given node
     * @param _id Node's id
     */
    function getPrev(uint256 _id) external view override returns (uint256) {
        return nodes[_id].prevId;
    }

    /*
     * @dev Check if a pair of nodes is a valid insertion point for a new node with the given NCR
     * @param _ncr Node's nominal collateral ratio
     * @param _prevId Id of previous node for the insert position
     * @param _nextId Id of next node for the insert position
     */
    function validInsertPosition(
        uint256 _ncr,
        uint256 _prevId,
        uint256 _nextId
    ) external view override returns (bool) {
        return _validInsertPosition(troveManager, _ncr, _prevId, _nextId);
    }

    function _validInsertPosition(
        ITroveManager _troveManager,
        uint256 _ncr,
        uint256 _prevId,
        uint256 _nextId
    ) internal view returns (bool) {
        // `(_prevId, _nextId)` is a valid insert position if:
        return // they are adjacent nodes
        (nodes[_prevId].nextId == _nextId &&
            nodes[_nextId].prevId == _prevId &&
            // `_ncr` falls between the two nodes' NCRs
            (_prevId == ROOT_NODE_ID ||
                _troveManager.getTroveNominalCR(_prevId) >= _ncr) &&
            (_nextId == ROOT_NODE_ID ||
                _ncr > _troveManager.getTroveNominalCR(_nextId)));
    }

    function _descendOne(
        ITroveManager _troveManager,
        uint256 _ncr,
        Position memory _pos
    ) internal view returns (bool found) {
        if (
            _pos.nextId == ROOT_NODE_ID ||
            _ncr > _troveManager.getTroveNominalCR(_pos.nextId)
        ) {
            found = true;
        } else {
            _pos.prevId = _pos.nextId;
            _pos.nextId = nodes[_pos.prevId].nextId;
        }
    }

    function _ascendOne(
        ITroveManager _troveManager,
        uint256 _ncr,
        Position memory _pos
    ) internal view returns (bool found) {
        if (
            _pos.prevId == ROOT_NODE_ID ||
            _troveManager.getTroveNominalCR(_pos.prevId) >= _ncr
        ) {
            found = true;
        } else {
            _pos.nextId = _pos.prevId;
            _pos.prevId = nodes[_pos.nextId].prevId;
        }
    }

    /*
     * @dev Descend the list (larger interest rates to smaller interest rates) to find a valid insert position
     * @param _troveManager TroveManager contract, passed in as param to save SLOAD’s
     * @param _annualInterestRate Node's annual interest rate
     * @param _startId Id of node to start descending the list from
     */
    function _descendList(
        ITroveManager _troveManager,
        uint256 _annualInterestRate,
        uint256 _startId
    ) internal view returns (uint256, uint256) {
        Position memory pos = Position(_startId, nodes[_startId].nextId);

        while (!_descendOne(_troveManager, _annualInterestRate, pos)) {}
        return (pos.prevId, pos.nextId);
    }

    /*
     * @dev Ascend the list (smaller interest rates to larger interest rates) to find a valid insert position
     * @param _troveManager TroveManager contract, passed in as param to save SLOAD’s
     * @param _annualInterestRate Node's annual interest rate
     * @param _startId Id of node to start ascending the list from
     */
    function _ascendList(
        ITroveManager _troveManager,
        uint256 _annualInterestRate,
        uint256 _startId
    ) internal view returns (uint256, uint256) {
        Position memory pos = Position(nodes[_startId].prevId, _startId);

        while (!_ascendOne(_troveManager, _annualInterestRate, pos)) {}
        return (pos.prevId, pos.nextId);
    }

    function _descendAndAscendList(
        ITroveManager _troveManager,
        uint256 _ncr,
        uint256 _descentStartId,
        uint256 _ascentStartId
    ) internal view returns (uint256 prevId, uint256 nextId) {
        Position memory descentPos = Position(
            _descentStartId,
            nodes[_descentStartId].nextId
        );
        Position memory ascentPos = Position(
            nodes[_ascentStartId].prevId,
            _ascentStartId
        );

        for (;;) {
            if (_descendOne(_troveManager, _ncr, descentPos)) {
                return (descentPos.prevId, descentPos.nextId);
            }

            if (_ascendOne(_troveManager, _ncr, ascentPos)) {
                return (ascentPos.prevId, ascentPos.nextId);
            }
        }

        assert(false); // Should not reach
    }

    /*
     * @dev Find the insert position for a new node with the given NCR
     * @param _ncr Node's nominal collateral ratio
     * @param _prevId Id of previous node for the insert position
     * @param _nextId Id of next node for the insert position
     */
    function findInsertPosition(
        uint256 _ncr,
        uint256 _prevId,
        uint256 _nextId
    ) external view override returns (uint256, uint256) {
        return _findInsertPosition(troveManager, _ncr, _prevId, _nextId);
    }

    // This function is optimized under the assumption that only one of the original neighbours has been (re)moved.
    // In other words, we assume that the correct position can be found close to one of the two.
    // Nevertheless, the function will always find the correct position, regardless of hints or interference.
    function _findInsertPosition(
        ITroveManager _troveManager,
        uint256 _ncr,
        uint256 _prevId,
        uint256 _nextId
    ) internal view returns (uint256, uint256) {
        if (_prevId == ROOT_NODE_ID) {
            // The original correct position was found before the head of the list.
            // Assuming minimal interference, the new correct position is still close to the head.
            return _descendList(_troveManager, _ncr, ROOT_NODE_ID);
        } else {
            if (
                !contains(_prevId) ||
                _troveManager.getTroveNominalCR(_prevId) < _ncr
            ) {
                // `prevId` does not exist anymore or now has a smaller NCR than the given NCR
                _prevId = BAD_HINT;
            }
        }

        if (_nextId == ROOT_NODE_ID) {
            // The original correct position was found after the tail of the list.
            // Assuming minimal interference, the new correct position is still close to the tail.
            return _ascendList(_troveManager, _ncr, ROOT_NODE_ID);
        } else {
            if (
                !contains(_nextId) ||
                _ncr <= _troveManager.getTroveNominalCR(_nextId)
            ) {
                // `nextId` does not exist anymore or now has a larger NCR than the given NCR
                _nextId = BAD_HINT;
            }
        }

        if (_prevId == BAD_HINT && _nextId == BAD_HINT) {
            // Both original neighbours have been moved or removed.
            // We default to descending the list, starting from the head.
            return _descendList(_troveManager, _ncr, ROOT_NODE_ID);
        } else if (_prevId == BAD_HINT) {
            // No `prevId` for hint - ascend list starting from `nextId`
            return _ascendList(_troveManager, _ncr, _nextId);
        } else if (_nextId == BAD_HINT) {
            // No `nextId` for hint - descend list starting from `prevId`
            return _descendList(_troveManager, _ncr, _prevId);
        } else {
            // The correct position is still somewhere between the 2 hints, so it's not obvious
            // which of the 2 has been moved (assuming only one of them has been).
            // We simultaneously descend & ascend in the hope that one of them is very close.
            return _descendAndAscendList(_troveManager, _ncr, _prevId, _nextId);
        }
    }

    // --- 'require' functions ---

    function _requireCallerIsBOorTM() internal view {
        require(
            msg.sender == borrowerOperationsAddress ||
                msg.sender == address(troveManager),
            "SortedTroves: Caller is not BorrowerOperations nor TroveManager"
        );
    }

    function _requireCallerIsBorrowerOperations() internal view {
        require(
            msg.sender == borrowerOperationsAddress,
            "SortedTroves: Caller is not BorrowerOperations"
        );
    }
}
