// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title MSPToken
/// @notice MyStarPick (MSP) voting token for the GIWA chain.
/// @dev Minimal ERC-20 with `decimals() == 0`: vote counts are minted and transferred as
///      raw integers with no scaling (one token = one vote).
///
///      Voting flow: an address holding MINTER_ROLE records a vote via {mintAndRoute}, which
///      mints vote tokens to the voter and routes them to the candidate in a single
///      transaction. A trusted ERC-2771 forwarder is also wired in for gas-sponsored voter
///      transfers when needed.
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

    /// @dev Thrown when `mintAndRoute` is called with the zero address as the voter. Minting vote
    ///      tokens to the zero address would revert inside ERC20._mint anyway; guarding here gives a
    ///      clear, named error at the vote entry point.
    error MSPTokenZeroUser();

    /// @dev Thrown when `mintAndRoute` is called with the zero address as the candidate. Routing a
    ///      vote to the zero address would burn it (ERC20._transfer rejects the zero recipient), so
    ///      an explicit guard prevents a vote from being silently lost.
    error MSPTokenZeroCandidate();

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
    /// @dev Returns 0 so that one token equals one vote (no scaling).
    function decimals() public pure override returns (uint8) {
        return 0;
    }

    /// @notice Mint `amount` vote tokens to `to`.
    /// @dev Restricted to MINTER_ROLE.
    /// @param to Recipient of the newly minted tokens.
    /// @param amount Number of tokens to mint (raw integer, no scaling).
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    /// @notice Mint `amount` vote tokens to `user`, then immediately route them to `candidate`,
    ///         all in one transaction. Restricted to MINTER_ROLE. Preserves the two Transfer
    ///         events (0x0 -> user, user -> candidate) so the on-chain vote trail is identical to
    ///         the previous two-transaction (mint + user-signed transfer) flow.
    /// @dev Collapses the vote into a single minter-submitted transaction: the ERC-2771 forwarder
    ///      and the voter signature are no longer on the vote path (mint and the internal transfer
    ///      are both authorized by MINTER_ROLE, not by the voter). The existing ERC2771 wiring is
    ///      left intact so the plain `transfer` meta-transaction flow keeps working for backward
    ///      compatibility. `amount == 0` is intentionally allowed: it is harmless (both transfers
    ///      are no-ops that still emit the two zero-value Transfer events) and mirrors ERC-20, which
    ///      permits zero-value transfers.
    /// @param user Voter who is credited with the freshly minted tokens before they are routed.
    /// @param candidate Recipient the vote tokens are transferred to. Must be non-zero.
    /// @param amount Number of vote tokens to mint and route (raw integer, no scaling).
    function mintAndRoute(address user, address candidate, uint256 amount) external onlyRole(MINTER_ROLE) {
        if (user == address(0)) revert MSPTokenZeroUser();
        if (candidate == address(0)) revert MSPTokenZeroCandidate();
        _mint(user, amount);
        _transfer(user, candidate, amount);
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
