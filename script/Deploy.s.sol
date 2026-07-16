// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";
import {MSPToken} from "../src/MSPToken.sol";

/// @title Deploy
/// @notice Deploys the ERC-2771 forwarder and the MSP voting token to the GIWA chain.
/// @dev Deployment order:
///        1. ERC2771Forwarder("MyStarPick Forwarder") — OpenZeppelin's stock forwarder.
///        2. MSPToken(forwarder, admin, minter).
///      The admin and minter addresses are read from the ADMIN_ADDRESS and MINTER_ADDRESS
///      environment variables. When either is unset (address(0)), the deployer address is used.
///
///      Run with:
///        forge script script/Deploy.s.sol:Deploy \
///          --rpc-url giwa_sepolia --broadcast --verify
contract Deploy is Script {
    function run() external returns (ERC2771Forwarder forwarder, MSPToken token) {
        address deployer = msg.sender;
        address admin = _envAddressOr("ADMIN_ADDRESS", deployer);
        address minter = _envAddressOr("MINTER_ADDRESS", deployer);

        vm.startBroadcast();

        forwarder = new ERC2771Forwarder("MyStarPick Forwarder");
        token = new MSPToken(address(forwarder), admin, minter);

        vm.stopBroadcast();

        // Post-deploy assertions: fail loudly if the granted roles do not match the
        // intended admin/minter (e.g. a constructor/env mismatch). Reverts the script.
        require(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin), "admin role not granted");
        require(token.hasRole(token.MINTER_ROLE(), minter), "minter role not granted");

        console2.log("ERC2771Forwarder:", address(forwarder));
        console2.log("MSPToken:", address(token));
        console2.log("Admin:", admin);
        console2.log("Minter:", minter);
    }

    /// @dev Resolves an address role parameter from the environment.
    ///      - If `key` is set, it is parsed with `vm.envAddress`, which reverts on a malformed
    ///        value instead of silently falling back — so a typo'd/truncated address aborts the
    ///        deployment rather than quietly handing the role to the deployer EOA.
    ///      - Only when `key` is entirely unset does the deployer address get used.
    function _envAddressOr(string memory key, address fallbackAddr) internal view returns (address) {
        if (!vm.envExists(key)) {
            return fallbackAddr;
        }
        return vm.envAddress(key);
    }
}
