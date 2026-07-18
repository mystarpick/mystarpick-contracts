// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VotingRightsGateway} from "../src/VotingRightsGateway.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract VotingRightsGatewayTest is Test {
    VotingRightsGateway internal gateway;
    MockERC20 internal token;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal buyer = makeAddr("buyer");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant AMOUNT = 100e18;
    bytes32 internal constant REF = keccak256("order-1");

    // Mirror of the events under test (must match VotingRightsGateway exactly).
    event Purchased(address indexed buyer, address indexed token, uint256 amount, bytes32 indexed orderRef);
    event NativePurchased(address indexed buyer, uint256 amount, bytes32 indexed orderRef);

    function setUp() public {
        gateway = new VotingRightsGateway(owner, treasury);
        token = new MockERC20("Mock GIWA Token", "MGT");

        // Whitelist the mock token and enable native payments (owner-only).
        vm.startPrank(owner);
        gateway.setAcceptedToken(address(token), true);
        gateway.setNativeAccepted(true);
        vm.stopPrank();

        // Fund the buyer and approve the gateway.
        token.mint(buyer, 1_000e18);
        vm.prank(buyer);
        token.approve(address(gateway), type(uint256).max);
    }

    // 1. ERC-20 purchase success -> treasury balance up + Purchased event + orderRefUsed = true.
    function test_purchase_success() public {
        assertEq(token.balanceOf(treasury), 0);

        vm.expectEmit(true, true, true, true, address(gateway));
        emit Purchased(buyer, address(token), AMOUNT, REF);

        vm.prank(buyer);
        gateway.purchase(address(token), AMOUNT, REF);

        assertEq(token.balanceOf(treasury), AMOUNT, "treasury received tokens");
        assertEq(token.balanceOf(address(gateway)), 0, "gateway retains nothing (forward-only)");
        assertTrue(gateway.orderRefUsed(REF), "orderRef marked used");
    }

    // 2. Non-whitelisted token purchase reverts.
    function test_purchase_revertsWhenTokenNotAccepted() public {
        MockERC20 other = new MockERC20("Other", "OTH");
        other.mint(buyer, 1_000e18);
        vm.prank(buyer);
        other.approve(address(gateway), type(uint256).max);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(VotingRightsGateway.TokenNotAccepted.selector, address(other)));
        gateway.purchase(address(other), AMOUNT, REF);
    }

    // 3. Duplicate orderRef reverts (idempotency).
    function test_purchase_revertsOnDuplicateOrderRef() public {
        vm.prank(buyer);
        gateway.purchase(address(token), AMOUNT, REF);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(VotingRightsGateway.OrderRefAlreadyUsed.selector, REF));
        gateway.purchase(address(token), AMOUNT, REF);
    }

    // 4. amount 0 / orderRef 0 revert.
    function test_purchase_revertsOnZeroAmount() public {
        vm.prank(buyer);
        vm.expectRevert(VotingRightsGateway.ZeroAmount.selector);
        gateway.purchase(address(token), 0, REF);
    }

    function test_purchase_revertsOnZeroOrderRef() public {
        vm.prank(buyer);
        vm.expectRevert(VotingRightsGateway.ZeroOrderRef.selector);
        gateway.purchase(address(token), AMOUNT, bytes32(0));
    }

    // 5. purchaseNative success -> treasury ETH up + NativePurchased event.
    function test_purchaseNative_success() public {
        bytes32 ref = keccak256("order-native");
        uint256 value = 1 ether;
        vm.deal(buyer, value);
        uint256 treasuryBefore = treasury.balance;

        vm.expectEmit(true, false, true, true, address(gateway));
        emit NativePurchased(buyer, value, ref);

        vm.prank(buyer);
        gateway.purchaseNative{value: value}(ref);

        assertEq(treasury.balance, treasuryBefore + value, "treasury received native");
        assertEq(address(gateway).balance, 0, "gateway retains no native (forward-only)");
        assertTrue(gateway.orderRefUsed(ref), "orderRef marked used");
    }

    // 6. purchaseNative reverts when native disabled.
    function test_purchaseNative_revertsWhenDisabled() public {
        vm.prank(owner);
        gateway.setNativeAccepted(false);

        bytes32 ref = keccak256("order-native-2");
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        vm.expectRevert(VotingRightsGateway.NativeNotAccepted.selector);
        gateway.purchaseNative{value: 1 ether}(ref);
    }

    // 7. paused -> purchase and purchaseNative revert.
    function test_purchase_revertsWhenPaused() public {
        vm.prank(owner);
        gateway.pause();

        vm.prank(buyer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        gateway.purchase(address(token), AMOUNT, REF);
    }

    function test_purchaseNative_revertsWhenPaused() public {
        vm.prank(owner);
        gateway.pause();

        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        gateway.purchaseNative{value: 1 ether}(keccak256("order-native-3"));
    }

    // 8. onlyOwner: non-owner setTreasury / setAcceptedToken revert.
    function test_setTreasury_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        gateway.setTreasury(stranger);
    }

    function test_setAcceptedToken_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        gateway.setAcceptedToken(address(token), false);
    }

    // 9. setTreasury(0) reverts.
    function test_setTreasury_revertsOnZero() public {
        vm.prank(owner);
        vm.expectRevert(VotingRightsGateway.ZeroAddress.selector);
        gateway.setTreasury(address(0));
    }

    function test_constructor_revertsOnZeroTreasury() public {
        vm.expectRevert(VotingRightsGateway.ZeroAddress.selector);
        new VotingRightsGateway(owner, address(0));
    }
}
