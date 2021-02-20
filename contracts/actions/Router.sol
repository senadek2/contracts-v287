// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../storage/StorageLayoutV1.sol";

/**
 * @notice Sits behind an upgradeable proxy and routes methods to an appropriate implementation contract. All storage
 * will sit inside the upgradeable proxy and this router will authorize the call and re-route the calls to implementing
 * contracts.
 *
 * This pattern adds an additional hop between the proxy and the ultimate implementation contract, however, it also
 * allows for atomic upgrades of the entire system. Individual implementation contracts will be deployed and then a
 * new Router with the new hardcoded addresses will then be deployed and upgraded into place.
 */
contract Router is StorageLayoutV1 {
    address public constant GOVERNANCE = address(0);

    function initialize(address owner_, address token_) public {
        owner = owner_;
        token = token_;

        // TODO: List ETH as a default currency
    }

    /**
     * @notice Returns the implementation contract for the method signature
     */
    function getRouterImplementation(bytes4 sig) public view returns (address) {
        // TODO: order these by most commonly used
        if (
            sig == bytes4(keccak256("listCurrency(address,bool,address,bool,uint8,uint8,uint8)")) ||
            sig == bytes4(keccak256("enableCashGroup(uint16,address,(cashGroup))")) ||
            sig == bytes4(keccak256("updateCashGroup(uint16,(cashGroup))")) ||
            sig == bytes4(keccak256("updateAssetRate(uint16,address)")) ||
            sig == bytes4(keccak256("updateETHRate(uint16,address,bool,uint8,uint8)")) ||
            sig == bytes4(keccak256("transferOwnership(address)"))
        ) {
            return GOVERNANCE;
        }

    }

    /**
     * @dev Delegates the current call to `implementation`.
     *
     * This function does not return to its internal call site, it will return directly to the external caller.
     */
    function _delegate(address implementation) internal {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // Copy msg.data. We take full control of memory in this inline assembly
            // block because it will not return to Solidity code. We overwrite the
            // Solidity scratch pad at memory position 0.
            calldatacopy(0, 0, calldatasize())

            // Call the implementation.
            // out and outsize are 0 because we don't know the size yet.
            let result := delegatecall(gas(), implementation, 0, calldatasize(), 0, 0)

            // Copy the returned data.
            returndatacopy(0, 0, returndatasize())

            switch result
            // delegatecall returns 0 on error.
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    fallback() external {
        _delegate(getRouterImplementation(msg.sig));
    }

}