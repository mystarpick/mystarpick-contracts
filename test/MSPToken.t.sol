// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MSPToken} from "../src/MSPToken.sol";

contract MSPTokenTest is Test {
    // EIP-712 type hashes, mirrored from the OpenZeppelin implementations so the test
    // constructs signatures independently of the production code path.
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant FORWARD_REQUEST_TYPEHASH = keccak256(
        "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,uint48 deadline,bytes data)"
    );

    ERC2771Forwarder internal forwarder;
    MSPToken internal token;

    address internal admin = makeAddr("admin");
    address internal minter = makeAddr("minter");
    address internal candidate = makeAddr("candidate");
    address internal relayer = makeAddr("relayer");

    // The voter needs a known private key so the test can sign EIP-712 requests on its behalf.
    Vm.Wallet internal voter;

    function setUp() public {
        voter = vm.createWallet("voter");
        forwarder = new ERC2771Forwarder("MyStarPick Forwarder");
        token = new MSPToken(address(forwarder), admin, minter);
    }

    // ------------------------------------------------------------------
    // 1. Metadata
    // ------------------------------------------------------------------

    function test_Metadata() public view {
        assertEq(token.name(), "MyStarPick");
        assertEq(token.symbol(), "MSP");
        assertEq(token.decimals(), 0);
    }

    // ------------------------------------------------------------------
    // 2. Minting and access control
    // ------------------------------------------------------------------

    function test_Mint_ByMinter() public {
        vm.prank(minter);
        token.mint(voter.addr, 10);
        assertEq(token.balanceOf(voter.addr), 10);
        assertEq(token.totalSupply(), 10);
    }

    function test_Constructor_RevertOnZeroForwarder() public {
        vm.expectRevert(MSPToken.MSPTokenZeroForwarder.selector);
        new MSPToken(address(0), admin, minter);
    }

    function test_Constructor_RevertOnZeroAdmin() public {
        vm.expectRevert(MSPToken.MSPTokenZeroAdmin.selector);
        new MSPToken(address(forwarder), address(0), minter);
    }

    function test_Constructor_RevertOnZeroMinter() public {
        vm.expectRevert(MSPToken.MSPTokenZeroMinter.selector);
        new MSPToken(address(forwarder), admin, address(0));
    }

    function test_Mint_RevertWhenNotMinter() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, candidate, token.MINTER_ROLE()
            )
        );
        vm.prank(candidate);
        token.mint(candidate, 10);
    }

    // ------------------------------------------------------------------
    // 3. Plain transfer
    // ------------------------------------------------------------------

    function test_Transfer() public {
        vm.prank(minter);
        token.mint(voter.addr, 5);

        vm.prank(voter.addr);
        assertTrue(token.transfer(candidate, 3));

        assertEq(token.balanceOf(voter.addr), 2);
        assertEq(token.balanceOf(candidate), 3);
    }

    // ------------------------------------------------------------------
    // 3b. Single-transaction mint + route (mintAndRoute)
    // ------------------------------------------------------------------

    function test_MintAndRoute_ByMinter() public {
        // Both Transfer events must fire in order: mint (0x0 -> user) then route (user -> candidate),
        // reproducing the exact on-chain trail of the old two-transaction flow.
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(0), voter.addr, 9);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(voter.addr, candidate, 9);

        vm.prank(minter);
        token.mintAndRoute(voter.addr, candidate, 9);

        assertEq(token.balanceOf(voter.addr), 0);
        assertEq(token.balanceOf(candidate), 9);
        assertEq(token.totalSupply(), 9);
    }

    function test_MintAndRoute_RevertWhenNotMinter() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, candidate, token.MINTER_ROLE()
            )
        );
        vm.prank(candidate);
        token.mintAndRoute(voter.addr, candidate, 9);
    }

    function test_MintAndRoute_RevertOnZeroUser() public {
        vm.expectRevert(MSPToken.MSPTokenZeroUser.selector);
        vm.prank(minter);
        token.mintAndRoute(address(0), candidate, 9);
    }

    function test_MintAndRoute_RevertOnZeroCandidate() public {
        vm.expectRevert(MSPToken.MSPTokenZeroCandidate.selector);
        vm.prank(minter);
        token.mintAndRoute(voter.addr, address(0), 9);
    }

    // ------------------------------------------------------------------
    // 4. Meta-transaction: voter -> candidate transfer, relayer pays gas
    // ------------------------------------------------------------------

    function test_MetaTx_TransferWithGaslessVoter() public {
        vm.prank(minter);
        token.mint(voter.addr, 7);

        // The voter has no ETH — the relayer sponsors gas.
        assertEq(voter.addr.balance, 0);

        bytes memory data = abi.encodeCall(token.transfer, (candidate, 7));
        ERC2771Forwarder.ForwardRequestData memory request =
            _signRequest(voter, address(token), 0, 200_000, uint48(block.timestamp + 1 hours), data);

        // Transfer event must report the voter as `from`, proving ERC-2771 sender recovery.
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(voter.addr, candidate, 7);

        vm.prank(relayer);
        forwarder.execute(request);

        assertEq(token.balanceOf(voter.addr), 0);
        assertEq(token.balanceOf(candidate), 7);
        assertEq(voter.addr.balance, 0);
    }

    // ------------------------------------------------------------------
    // 5. Replay protection (forwarder nonce)
    // ------------------------------------------------------------------

    function test_MetaTx_RevertOnReplay() public {
        vm.prank(minter);
        token.mint(voter.addr, 4);

        bytes memory data = abi.encodeCall(token.transfer, (candidate, 2));
        ERC2771Forwarder.ForwardRequestData memory request =
            _signRequest(voter, address(token), 0, 200_000, uint48(block.timestamp + 1 hours), data);

        vm.prank(relayer);
        forwarder.execute(request);

        // Re-submitting the same request: the nonce has advanced, so recovered signer no longer
        // matches `from` and the forwarder rejects it as an invalid signer.
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC2771Forwarder.ERC2771ForwarderInvalidSigner.selector, _recoverStale(request), voter.addr
            )
        );
        vm.prank(relayer);
        forwarder.execute(request);
    }

    // ------------------------------------------------------------------
    // 6. Bad signature
    // ------------------------------------------------------------------

    function test_MetaTx_RevertOnBadSignature() public {
        vm.prank(minter);
        token.mint(voter.addr, 4);

        bytes memory data = abi.encodeCall(token.transfer, (candidate, 2));
        ERC2771Forwarder.ForwardRequestData memory request =
            _signRequest(voter, address(token), 0, 200_000, uint48(block.timestamp + 1 hours), data);

        // Corrupt the signature by flipping the last byte (the recovery id / v).
        request.signature[request.signature.length - 1] =
            bytes1(uint8(request.signature[request.signature.length - 1]) ^ 0xff);

        vm.expectRevert();
        vm.prank(relayer);
        forwarder.execute(request);
    }

    // ------------------------------------------------------------------
    // 7. Expired deadline
    // ------------------------------------------------------------------

    function test_MetaTx_RevertOnExpiredDeadline() public {
        vm.prank(minter);
        token.mint(voter.addr, 4);

        vm.warp(1 days);
        uint48 deadline = uint48(block.timestamp - 1);

        bytes memory data = abi.encodeCall(token.transfer, (candidate, 2));
        ERC2771Forwarder.ForwardRequestData memory request =
            _signRequest(voter, address(token), 0, 200_000, deadline, data);

        vm.expectRevert(abi.encodeWithSelector(ERC2771Forwarder.ERC2771ForwarderExpiredRequest.selector, deadline));
        vm.prank(relayer);
        forwarder.execute(request);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev Builds and EIP-712 signs a ForwardRequestData for `signer` at the signer's current nonce.
    function _signRequest(
        Vm.Wallet memory signer,
        address to,
        uint256 value,
        uint256 gas,
        uint48 deadline,
        bytes memory data
    ) internal view returns (ERC2771Forwarder.ForwardRequestData memory) {
        uint256 nonce = forwarder.nonces(signer.addr);
        bytes32 structHash = keccak256(
            abi.encode(FORWARD_REQUEST_TYPEHASH, signer.addr, to, value, gas, nonce, deadline, keccak256(data))
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signer, digest);
        return ERC2771Forwarder.ForwardRequestData({
            from: signer.addr,
            to: to,
            value: value,
            gas: gas,
            deadline: deadline,
            data: data,
            signature: abi.encodePacked(r, s, v)
        });
    }

    /// @dev Domain separator of the deployed forwarder (name "MyStarPick Forwarder", version "1").
    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("MyStarPick Forwarder")),
                keccak256(bytes("1")),
                block.chainid,
                address(forwarder)
            )
        );
    }

    /// @dev Recovers the signer that the forwarder will compute for a replayed request (nonce + 1),
    ///      which no longer matches the original `from`. Used to assert the exact revert argument.
    function _recoverStale(ERC2771Forwarder.ForwardRequestData memory request) internal view returns (address) {
        bytes32 structHash = keccak256(
            abi.encode(
                FORWARD_REQUEST_TYPEHASH,
                request.from,
                request.to,
                request.value,
                request.gas,
                forwarder.nonces(request.from),
                request.deadline,
                keccak256(request.data)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        return ECDSA_recover(digest, request.signature);
    }

    /// @dev Thin wrapper over the cheatcode-free ecrecover for the replayed-digest signer.
    function ECDSA_recover(bytes32 digest, bytes memory sig) internal pure returns (address) {
        require(sig.length == 65, "bad sig len");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
            v := byte(0, mload(add(sig, 0x60)))
        }
        return ecrecover(digest, v, r, s);
    }
}

/// @dev Minimal interface to reference the ERC-20 Transfer event in expectEmit.
interface IERC20 {
    event Transfer(address indexed from, address indexed to, uint256 value);
}
