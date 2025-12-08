// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;
import "./MainnetPriceFeedBase.sol";

// Custom price oracle core contract
contract WXOCPriceFeed is MainnetPriceFeedBase {
    // ============ State Variables ============
    // Price feeder whitelist (multi-sig/single-sig, supports updates)
    address public priceFeeder;
    // Signature validity period (prevents replay attacks, in seconds)
    uint256 public signatureValidity;
    // Price update interval (prevents high-frequency manipulation, in seconds)
    uint256 public minUpdateInterval;
    // Last feeding timestamp (prevents frequent updates)
    uint256 public lastFeedTimestamp;

    // ============ Events ============
    event PriceUpdated(uint256 newPrice, uint256 timestamp, address feeder);
    event FeederUpdated(address oldFeeder, address newFeeder);

    // ============ Errors ============
    error InvalidSignature();
    error SignatureExpired();
    error PriceOutOfRange();
    error FeederNotAuthorized();
    error UpdateTooFrequent();

    // ============ Constructor ============
    constructor(
        address _priceFeeder,          // Off-chain price feeder address (private key stored offline)
        uint256 _signatureValidity,    // Signature validity period (e.g., 300 seconds)
        uint256 _minUpdateInterval,    // Minimum update interval (e.g., 60 seconds)
        uint256 _stalenessThreshold,   // Price staleness threshold (e.g., 1800 seconds)
        address _borrowerOperationsAddress
    ) MainnetPriceFeedBase(
    _stalenessThreshold,
    _borrowerOperationsAddress
    ) {
        priceFeeder = _priceFeeder;
        signatureValidity = _signatureValidity;
        minUpdateInterval = _minUpdateInterval;
        // Initialize price source as primary
        priceSource = PriceSource.primary;
        // Initialize last feeding time as deployment time
        lastFeedTimestamp = block.timestamp;
    }

    // ============ Off-chain Price Feeding Core Function (External Call) ============
    /**
     * @dev Called by off-chain price feeder to update price (requires signature verification)
     * @param _price Price to feed (18 decimal places)
     * @param _timestamp Timestamp when off-chain signature was created (prevents replay)
     * @param _v Signature v component
     * @param _r Signature r component
     * @param _s Signature s component
     */
    function updatePrice(
        uint256 _price,
        uint256 _timestamp,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external {
        // 1. Verify caller is the price feeder (optional: any address can call, only signature is verified)
        if (msg.sender != priceFeeder) revert FeederNotAuthorized();
        // 2. Verify update frequency (prevents high-frequency manipulation)
        if (block.timestamp - lastFeedTimestamp < minUpdateInterval) revert UpdateTooFrequent();
        // 3. Verify signature validity period
        if (block.timestamp - _timestamp > signatureValidity) revert SignatureExpired();
        // 4. Verify signature authenticity
        bytes32 messageHash = keccak256(abi.encodePacked(_price, _timestamp, address(this)));
        bytes32 ethSignedMessageHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        address signer = ecrecover(ethSignedMessageHash, _v, _r, _s);
        if (signer != priceFeeder || signer == address(0)) revert InvalidSignature();
        // 5. Verify price rationality (optional: prevents feeding errors, such as zero/abnormal values)
        if (_price == 0 || _price > 1e24) revert PriceOutOfRange(); // Example: price cap 1e6 USDT (1e24 = 1e6 * 1e18)

        // 6. Update state
        lastGoodPrice = _price; // Directly update last valid price
        lastFeedTimestamp = block.timestamp;
        priceSource = PriceSource.primary; // Restore primary price source (if previously down)

        // 7. Emit event
        emit PriceUpdated(_price, _timestamp, msg.sender);
    }

    function _fetchPricePrimary() internal override returns (uint256, bool) {
        assert(priceSource == PriceSource.primary);

        // Check if price is stale
        bool priceIsStale = block.timestamp - lastFeedTimestamp > stalenessThreshold;
        if (priceIsStale) {
            // Price is stale: switch to last good price + shut down borrowing branch
            return (_shutDownAndSwitchToLastGoodPrice(address(this)), true);
        }

        // Price is valid: return last fed price
        return (lastGoodPrice, false);
    }

    // Override: External price fetching (compatible with original interface)
    function fetchPrice() public returns (uint256, bool) {
        // If branch is live and the primary oracle setup has been working, try to use it
        if (priceSource == PriceSource.primary) {
            return _fetchPricePrimary();
        }

        // Otherwise if branch is shut down and already using the lastGoodPrice, continue with it
        assert(priceSource == PriceSource.lastGoodPrice);
        return (lastGoodPrice, false);
    }

    function fetchRedemptionPrice() external returns (uint256, bool) {
        // Use same price for redemption as all other ops in WXOC branch
        return fetchPrice();
    }

    // ============ Permission Management Functions (Only callable by feeder/admin, extensible to multi-sig) ============
    function updateFeeder(address _newFeeder) external {
        if (msg.sender != priceFeeder) revert FeederNotAuthorized();
        emit FeederUpdated(priceFeeder, _newFeeder);
        priceFeeder = _newFeeder;
    }

    function updateSignatureValidity(uint256 _newValidity) external {
        if (msg.sender != priceFeeder) revert FeederNotAuthorized();
        signatureValidity = _newValidity;
    }

    function updateMinUpdateInterval(uint256 _newInterval) external {
        if (msg.sender != priceFeeder) revert FeederNotAuthorized();
        minUpdateInterval = _newInterval;
    }
}