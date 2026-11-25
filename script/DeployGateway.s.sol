// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {VotingRightsGateway} from "../src/VotingRightsGateway.sol";

/// @title DeployGateway
/// @notice Deploys the {VotingRightsGateway} paid-voting payment gateway to the GIWA chain.
/// @dev The deployer becomes the owner (admin). The treasury is read from the TREASURY_ADDRESS
///      environment variable; when unset, the deployer address is used.
///
///      Token whitelisting (setAcceptedToken) and native acceptance (setNativeAccepted) are NOT
///      done here. They are separate owner transactions sent after deploy,
///      so the gateway ships in a locked-down default (no token accepted, native off).
///
///      Run with:
///        forge script script/DeployGateway.s.sol:DeployGateway \
///          --rpc-url giwa_sepolia --broadcast --verify
contract DeployGateway is Script {
    function run() external returns (VotingRightsGateway gateway) {
        address deployer = msg.sender;
        address treasury = _envAddressOr("TREASURY_ADDRESS", deployer);

        // Abort before broadcasting if TREASURY_ADDRESS was explicitly set to the zero address.
        // The constructor also guards this, but failing here avoids a doomed, gas-wasting deploy.
        require(treasury != address(0), "treasury must be non-zero");

        vm.startBroadcast();

        gateway = new VotingRightsGateway(deployer, treasury);

        vm.stopBroadcast();

        // Post-deploy assertions: fail loudly on any owner/treasury mismatch. Reverts the script.
        require(gateway.owner() == deployer, "owner not set to deployer");
        require(gateway.treasury() == treasury, "treasury not set");

        console2.log("VotingRightsGateway:", address(gateway));
        console2.log("Owner:", deployer);
        console2.log("Treasury:", treasury);
    }

    /// @dev Resolves an address parameter from the environment.
    ///      - If `key` is set, it is parsed with `vm.envAddress`, which reverts on a malformed
    ///        value instead of silently falling back, so a typo'd/truncated address aborts the
    ///        deployment rather than quietly handing the treasury role to the deployer EOA.
    ///      - Only when `key` is entirely unset does the fallback address get used.
    function _envAddressOr(string memory key, address fallbackAddr) internal view returns (address) {
        if (!vm.envExists(key)) {
            return fallbackAddr;
        }
        return vm.envAddress(key);
    }
}
