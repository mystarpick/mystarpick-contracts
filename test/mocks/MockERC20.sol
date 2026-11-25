// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockERC20
/// @notice TEST-ONLY ERC-20 with an unrestricted public {mint}. NOT a product contract.
/// @dev This is a stand-in for a real stablecoin on GIWA so the {VotingRightsGateway} can be
///      exercised in tests and on GIWA Sepolia. It carries 18 decimals and lets anyone mint any
///      amount. That is acceptable only because it holds no value and exists purely to exercise
///      the purchase flow. Do NOT deploy this to any mainnet or treat it as a real asset.
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    /// @notice Mint `amount` tokens to `to`. Unrestricted, test only.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
