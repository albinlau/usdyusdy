// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

address constant ZERO_ADDRESS = address(0);

uint256 constant MAX_UINT256 = type(uint256).max;

uint256 constant DECIMAL_PRECISION = 1e18;
uint256 constant _100pct = DECIMAL_PRECISION;
uint256 constant _1pct = DECIMAL_PRECISION / 100;

// Amount of ETH to be locked in gas pool on opening troves
uint256 constant ETH_GAS_COMPENSATION = 0.0375 ether;

// Liquidation
uint256 constant MIN_LIQUIDATION_PENALTY_SP = 5e16; // 5%
uint256 constant MAX_LIQUIDATION_PENALTY_REDISTRIBUTION = 20e16; // 20%

// Collateral branch parameters (SETH = staked ETH, i.e. wstETH / rETH)
uint256 constant CCR_WETH = 150 * _1pct;
uint256 constant CCR_SETH = 160 * _1pct;

uint256 constant MCR_WETH = 110 * _1pct;
uint256 constant MCR_SETH = 120 * _1pct;

uint256 constant SCR_WETH = 110 * _1pct;
uint256 constant SCR_SETH = 120 * _1pct;

uint256 constant LIQUIDATION_PENALTY_SP_WETH = 5 * _1pct;
uint256 constant LIQUIDATION_PENALTY_SP_SETH = 5 * _1pct;

uint256 constant LIQUIDATION_PENALTY_REDISTRIBUTION_WETH = 10 * _1pct;
uint256 constant LIQUIDATION_PENALTY_REDISTRIBUTION_SETH = 20 * _1pct;

// Fraction of collateral awarded to liquidator
uint256 constant COLL_GAS_COMPENSATION_DIVISOR = 200; // dividing by 200 yields 0.5%
uint256 constant COLL_GAS_COMPENSATION_CAP = 2 ether; // Max coll gas compensation capped at 2 ETH

// Minimum amount of net USDX debt a trove must have
uint256 constant MIN_DEBT = 2000e18;

uint256 constant MIN_ANNUAL_INTEREST_RATE = _1pct / 2; // 0.5%
uint256 constant MAX_ANNUAL_INTEREST_RATE = 250 * _1pct;

uint256 constant REDEMPTION_FEE_FLOOR = _1pct / 2; // 0.5%

// Half-life of 6h. 6h = 360 min
// (1/2) = d^360 => d = (1/2)^(1/360)
uint256 constant REDEMPTION_MINUTE_DECAY_FACTOR = 998076443575628800;

// BETA: 18 digit decimal. Parameter by which to divide the redeemed fraction, in order to calc the new base rate from a redemption.
// Corresponds to (1 / ALPHA) in the white paper.
uint256 constant REDEMPTION_BETA = 1;

// To prevent redemptions unless USDX depegs below 0.95 and allow the system to take off
uint256 constant INITIAL_BASE_RATE = _100pct; // 100% initial redemption rate

// Discount to be used once the shutdown thas been triggered
uint256 constant URGENT_REDEMPTION_BONUS = 2e16; // 2%

uint256 constant ONE_MINUTE = 1 minutes;
uint256 constant ONE_YEAR = 365 days;
uint256 constant INTEREST_RATE_ADJ_COOLDOWN = 7 days;

uint256 constant SP_YIELD_SPLIT = 75 * _1pct; // 75%

uint256 constant MIN_USDX_IN_SP = 1e18;

// Dummy contract that lets legacy Hardhat tests query some of the constants
contract Constants {
    uint256 public constant _ETH_GAS_COMPENSATION = ETH_GAS_COMPENSATION;
    uint256 public constant _MIN_DEBT = MIN_DEBT;
}
