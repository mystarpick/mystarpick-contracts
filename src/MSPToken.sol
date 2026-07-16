// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title MSPToken
/// @notice MyStarPick (MSP) voting token for the GIWA chain.
/// @dev Minimal ERC-20 with `decimals() == 0` to match the existing Kaia MSP token
///      (0xf3fb962716229265fe9532cb4cb7e7c9fdca5713), where vote counts are minted and
///      transferred as raw integers with no scaling.
///
///      Voting flow (two transactions):
///        tx1: an address holding MINTER_ROLE mints vote tokens to the voter.
///        tx2: the voter transfers tokens to a candidate. This transfer is submitted as an
///             ERC-2771 meta-transaction relayed through a trusted forwarder, so the voter
///             pays no gas (gas is sponsored by the relayer).
///
///      Only ERC-20 transfer/mint and role-gated minting are supported. No burn, pause, or
///      upgradeability by design — the token is intentionally minimal.
contract MSPToken is ERC20, ERC2771Context, AccessControl {
    /// @notice Role allowed to mint new vote tokens.
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @dev Thrown when the admin address is the zero address, which would render
    ///      role administration permanently unrecoverable (no account could grant or
    ///      revoke MINTER_ROLE).
    error MSPTokenZeroAdmin();

    /// @dev Thrown when the minter address is the zero address. Granting MINTER_ROLE to the
    ///      zero address is almost always an operator mistake (e.g. exporting MINTER_ADDRESS=0x0
    ///      intending "unset"); rejecting it prevents a silently misconfigured deployment.
    error MSPTokenZeroMinter();

    /// @dev Thrown when the trusted forwarder is the zero address. The forwarder is immutable,
    ///      so a zero value cannot be corrected after deployment and would disable meta-transactions.
    error MSPTokenZeroForwarder();

    /// @param trustedForwarder Address of the ERC-2771 forwarder that may relay meta-transactions. Must be non-zero.
    /// @param admin Address granted DEFAULT_ADMIN_ROLE (can manage roles). Must be non-zero.
    /// @param minter Address granted MINTER_ROLE (can mint vote tokens). Must be non-zero.
    constructor(address trustedForwarder, address admin, address minter)
        ERC20("MyStarPick", "MSP")
        ERC2771Context(trustedForwarder)
    {
        if (trustedForwarder == address(0)) revert MSPTokenZeroForwarder();
        if (admin == address(0)) revert MSPTokenZeroAdmin();
        if (minter == address(0)) revert MSPTokenZeroMinter();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, minter);
    }

    /// @notice Number of decimals used by the token.
    /// @dev Returns 0 so that one token equals one vote, matching the Kaia MSP token.
    function decimals() public pure override returns (uint8) {
        return 0;
    }

    /// @notice Mint `amount` vote tokens to `to`.
    /// @dev Signature matches the existing Kaia MSP ABI. Restricted to MINTER_ROLE.
    /// @param to Recipient of the newly minted tokens.
    /// @param amount Number of tokens to mint (raw integer, no scaling).
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    // ---------------------------------------------------------------------
    // ERC2771Context <-> Context overrides required by OpenZeppelin v5.
    // Both ERC20 (via Context) and ERC2771Context define these; disambiguate
    // to route the sender/data through the forwarder-aware implementation.
    // ---------------------------------------------------------------------

    /// @inheritdoc ERC2771Context
    function _msgSender() internal view override(Context, ERC2771Context) returns (address) {
        return ERC2771Context._msgSender();
    }

    /// @inheritdoc ERC2771Context
    function _msgData() internal view override(Context, ERC2771Context) returns (bytes calldata) {
        return ERC2771Context._msgData();
    }

    /// @inheritdoc ERC2771Context
    function _contextSuffixLength() internal view override(Context, ERC2771Context) returns (uint256) {
        return ERC2771Context._contextSuffixLength();
    }
}
