//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "./interfaces/WETH9.sol";

import "@eth-optimism/contracts/libraries/bridge/CrossDomainEnabled.sol";
import "@eth-optimism/contracts/libraries/constants/Lib_PredeployAddresses.sol";
import "@eth-optimism/contracts/L2/messaging/IL2ERC20Bridge.sol";
import "./SpokePool.sol";
import "./SpokePoolInterface.sol";

/**
 * @notice OVM specific SpokePool.
 * @dev Uses OVM cross-domain-enabled logic for access control.
 */

contract Optimism_SpokePool is CrossDomainEnabled, SpokePoolInterface, SpokePool {
    // "l1Gas" parameter used in call to bridge tokens from this contract back to L1 via `IL2ERC20Bridge`.
    uint32 public l1Gas = 5_000_000;

    address public l2Eth = address(Lib_PredeployAddresses.OVM_ETH);

    event OptimismTokensBridged(address indexed l2Token, address target, uint256 numberOfTokensBridged, uint256 l1Gas);
    event SetL1Gas(uint32 indexed newL1Gas);

    constructor(
        address _crossDomainAdmin,
        address _hubPool,
        address timerAddress
    )
        CrossDomainEnabled(Lib_PredeployAddresses.L2_CROSS_DOMAIN_MESSENGER)
        SpokePool(_crossDomainAdmin, _hubPool, 0x4200000000000000000000000000000000000006, timerAddress)
    {}

    /*******************************************
     *    OPTIMISM-SPECIFIC ADMIN FUNCTIONS    *
     *******************************************/

    function setL1GasLimit(uint32 newl1Gas) public onlyAdmin {
        l1Gas = newl1Gas;
        emit SetL1Gas(newl1Gas);
    }

    /**************************************
     *         DATA WORKER FUNCTIONS      *
     **************************************/
    function executeSlowRelayRoot(
        address depositor,
        address recipient,
        address destinationToken,
        uint256 totalRelayAmount,
        uint256 originChainId,
        uint64 realizedLpFeePct,
        uint64 relayerFeePct,
        uint32 depositId,
        uint32 rootBundleId,
        bytes32[] memory proof
    ) public override nonReentrant {
        if (destinationToken == address(weth)) _depositEthToWeth();

        _executeSlowRelayRoot(
            depositor,
            recipient,
            destinationToken,
            totalRelayAmount,
            originChainId,
            realizedLpFeePct,
            relayerFeePct,
            depositId,
            rootBundleId,
            proof
        );
    }

    function executeRelayerRefundRoot(
        uint32 rootBundleId,
        SpokePoolInterface.RelayerRefundLeaf memory relayerRefundLeaf,
        bytes32[] memory proof
    ) public override nonReentrant {
        if (relayerRefundLeaf.l2TokenAddress == address(weth)) _depositEthToWeth();

        _executeRelayerRefundRoot(rootBundleId, relayerRefundLeaf, proof);
    }

    /**************************************
     *        INTERNAL FUNCTIONS          *
     **************************************/
    function _depositEthToWeth() internal {
        // Wrap any ETH owned by this contract so we can send expected L2 token to recipient. This is neccessary because
        // this SpokePool will receive ETH from the canonical token bridge instead of WETH.
        if (address(this).balance > 0) weth.deposit{ value: address(this).balance }();
    }

    function _bridgeTokensToHubPool(RelayerRefundLeaf memory relayerRefundLeaf) internal override {
        // If the token being bridged is WETH then we need to first unwrap it to ETH and then send ETH over the
        // canonical bridge. On Optimism, this is address 0xDeadDeAddeAddEAddeadDEaDDEAdDeaDDeAD0000.
        if (relayerRefundLeaf.l2TokenAddress == address(weth)) {
            WETH9(relayerRefundLeaf.l2TokenAddress).withdraw(relayerRefundLeaf.amountToReturn); // Unwrap ETH.
            relayerRefundLeaf.l2TokenAddress = l2Eth; // Set the l2TokenAddress to ETH.
        }
        IL2ERC20Bridge(Lib_PredeployAddresses.L2_STANDARD_BRIDGE).withdrawTo(
            relayerRefundLeaf.l2TokenAddress, // _l2Token. Address of the L2 token to bridge over.
            hubPool, // _to. Withdraw, over the bridge, to the l1 pool contract.
            relayerRefundLeaf.amountToReturn, // _amount.
            l1Gas, // _l1Gas. Unused, but included for potential forward compatibility considerations
            "" // _data. We don't need to send any data for the bridging action.
        );

        emit OptimismTokensBridged(relayerRefundLeaf.l2TokenAddress, hubPool, relayerRefundLeaf.amountToReturn, l1Gas);
    }

    function _requireAdminSender() internal override onlyFromCrossDomainAccount(crossDomainAdmin) {}
}