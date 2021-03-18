// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Reservoir Contract
 * @notice Distributes a token to a different contract at a fixed rate.
 * @dev This contract must be poked via the `drip()` function every so often.
 * @author Compound, modified by Notional
 */
contract Reservoir {
    using SafeMath for uint;

    /// @notice The timestamp when the Reservoir started
    uint immutable public DRIP_START;

    /// @notice Tokens per second that to drip to target
    uint immutable public DRIP_RATE;

    /// @notice Reference to token to drip
    IERC20 immutable public TOKEN;

    /// @notice Target to receive dripped tokens
    address immutable public TARGET;

    /// @notice Amount that has already been dripped
    uint public dripped;

    /**
      * @notice Constructs a Reservoir
      * @param dripRate_ Numer of tokens per block to drip
      * @param token_ The token to drip
      * @param target_ The recipient of dripped tokens
      */
    constructor(uint dripRate_, IERC20 token_, address target_) {
        DRIP_START = block.timestamp;
        DRIP_RATE = dripRate_;
        TOKEN = token_;
        TARGET = target_;
        dripped = 0;
    }

    /**
      * @notice Drips the maximum amount of tokens to match the drip rate since inception
      * @dev Note: this will only drip up to the amount of tokens available.
      * @return The amount of tokens dripped in this call
      */
    function drip() public returns (uint) {
        uint reservoirBalance = TOKEN.balanceOf(address(this));
        require(reservoirBalance > 0, "Reservoir empty");
        uint blockTime = block.timestamp;

        uint amountToDrip = DRIP_RATE.mul(blockTime - DRIP_START).sub(dripped);
        if (amountToDrip > reservoirBalance) amountToDrip = reservoirBalance;

        // Finally, write new `dripped` value and transfer tokens to target
        dripped = dripped.add(amountToDrip);
        bool success = TOKEN.transfer(TARGET, amountToDrip);
        require(success, "Transfer failed");

        return amountToDrip;
    }
}