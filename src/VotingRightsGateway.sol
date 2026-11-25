// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title VotingRightsGateway
/// @notice Self-custody payment gateway for paid voting-rights purchases on the GIWA chain.
/// @dev Records the fact of a payment on-chain and immediately forwards the funds to
///      `treasury`. The contract never takes custody (post-transfer balance is always zero,
///      forward-only).
///
///      The contract holds NO price or exchange-rate logic. It records only
///      (buyer, token, amount, orderRef); the credit/vote amount is pre-determined off-chain by
///      the backend against `orderRef` (an Order id derived value). The backend confirms the
///      matching event on-chain (topic-indexed by buyer/token/orderRef) and then runs the
///      existing vote-issuance flow.
///
///      `orderRef` provides idempotency: a given reference can be paid exactly once, so a
///      re-broadcast or duplicate submission cannot double-charge or double-credit.
///
///      Token acceptance is a whitelist (`acceptedToken`) so an arbitrary/malicious ERC-20 cannot
///      be routed through the gateway; native GIWA payments are gated separately by
///      `nativeAccepted`.
contract VotingRightsGateway is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Address that receives all forwarded payments. Funds are transferred here within the
    ///         same transaction as the purchase; the gateway retains nothing.
    address public treasury;

    /// @notice ERC-20 tokens accepted for purchases. Only whitelisted tokens may be spent.
    mapping(address => bool) public acceptedToken;

    /// @notice Whether native GIWA payments (via {purchaseNative}) are currently accepted.
    bool public nativeAccepted;

    /// @notice Tracks which order references have already been paid, enforcing idempotency.
    mapping(bytes32 => bool) public orderRefUsed;

    /// @notice Emitted on a successful ERC-20 purchase after funds are forwarded to `treasury`.
    /// @param buyer The payer (`msg.sender`).
    /// @param token The ERC-20 token spent.
    /// @param amount The token amount forwarded to `treasury` (in the token's own units).
    /// @param orderRef The backend order reference this payment settles.
    event Purchased(address indexed buyer, address indexed token, uint256 amount, bytes32 indexed orderRef);

    /// @notice Emitted on a successful native (GIWA) purchase after funds are forwarded to `treasury`.
    /// @param buyer The payer (`msg.sender`).
    /// @param amount The native amount forwarded to `treasury` (in wei).
    /// @param orderRef The backend order reference this payment settles.
    event NativePurchased(address indexed buyer, uint256 amount, bytes32 indexed orderRef);

    /// @notice Emitted when the treasury address is updated (also emitted from the constructor).
    event TreasuryUpdated(address treasury);

    /// @notice Emitted when an ERC-20 token's whitelist status changes.
    event TokenAccepted(address token, bool accepted);

    /// @notice Emitted when native-payment acceptance is toggled.
    event NativeAcceptedSet(bool accepted);

    /// @dev Thrown when a zero address is supplied where a non-zero address is required.
    error ZeroAddress();
    /// @dev Thrown when the supplied token is not on the accepted whitelist.
    error TokenNotAccepted(address token);
    /// @dev Thrown when native payments are not currently accepted.
    error NativeNotAccepted();
    /// @dev Thrown when the paid amount is zero.
    error ZeroAmount();
    /// @dev Thrown when the order reference is the zero value.
    error ZeroOrderRef();
    /// @dev Thrown when the order reference has already been paid (idempotency guard).
    error OrderRefAlreadyUsed(bytes32 orderRef);
    /// @dev Thrown when forwarding native funds to `treasury` fails.
    error NativeTransferFailed();

    /// @param owner_ The initial owner (admin) of the gateway.
    /// @param treasury_ The address that will receive all forwarded payments.
    constructor(address owner_, address treasury_) Ownable(owner_) {
        // Ownable(owner_) already reverts on a zero owner via OwnableInvalidOwner.
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    /// @notice Pay for voting rights with a whitelisted ERC-20 token.
    /// @dev Effects (mark `orderRef` used) are applied before the external transfer.
    ///      Uses {SafeERC20-safeTransferFrom} so non-standard (no-return) tokens are handled.
    ///      The caller must have approved this contract for at least `amount`.
    /// @param token The whitelisted ERC-20 token to spend.
    /// @param amount The token amount to pay (must be > 0).
    /// @param orderRef The backend order reference (must be non-zero and unused).
    function purchase(address token, uint256 amount, bytes32 orderRef) external nonReentrant whenNotPaused {
        if (!acceptedToken[token]) revert TokenNotAccepted(token);
        if (amount == 0) revert ZeroAmount();
        if (orderRef == bytes32(0)) revert ZeroOrderRef();
        if (orderRefUsed[orderRef]) revert OrderRefAlreadyUsed(orderRef);

        // Effects before interaction: reserve the reference so a reentrant or racing call
        // cannot reuse it, then forward funds directly to the treasury (no custody).
        orderRefUsed[orderRef] = true;

        IERC20(token).safeTransferFrom(msg.sender, treasury, amount);

        emit Purchased(msg.sender, token, amount, orderRef);
    }

    /// @notice Pay for voting rights with the native GIWA token.
    /// @dev Effects (mark `orderRef` used) are applied before forwarding native value to
    ///      `treasury`. `nonReentrant` guards the external call.
    /// @param orderRef The backend order reference (must be non-zero and unused).
    function purchaseNative(bytes32 orderRef) external payable nonReentrant whenNotPaused {
        if (!nativeAccepted) revert NativeNotAccepted();
        if (msg.value == 0) revert ZeroAmount();
        if (orderRef == bytes32(0)) revert ZeroOrderRef();
        if (orderRefUsed[orderRef]) revert OrderRefAlreadyUsed(orderRef);

        // Effects before interaction.
        orderRefUsed[orderRef] = true;

        (bool ok,) = treasury.call{value: msg.value}("");
        if (!ok) revert NativeTransferFailed();

        emit NativePurchased(msg.sender, msg.value, orderRef);
    }

    /// @notice Update the treasury address that receives forwarded payments.
    /// @param treasury_ The new treasury address (must be non-zero).
    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    /// @notice Set the whitelist status of an ERC-20 token.
    /// @param token The token to update.
    /// @param accepted True to accept the token for purchases, false to reject.
    function setAcceptedToken(address token, bool accepted) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        acceptedToken[token] = accepted;
        emit TokenAccepted(token, accepted);
    }

    /// @notice Toggle acceptance of native GIWA payments.
    /// @param accepted True to accept native payments, false to reject.
    function setNativeAccepted(bool accepted) external onlyOwner {
        nativeAccepted = accepted;
        emit NativeAcceptedSet(accepted);
    }

    /// @notice Pause purchases (emergency stop). Admin-only.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resume purchases after a pause. Admin-only.
    function unpause() external onlyOwner {
        _unpause();
    }
}
