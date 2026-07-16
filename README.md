# MyStarPick Contracts — MSP Voting Token (GIWA)

Smart contracts for **MyStarPick**'s on-chain voting token (**MSP**) on the
[GIWA](https://giwa.io) chain. This repository is the public submission for the
GASOK Phase 2 review.

MSP is a minimal ERC-20 whose balance represents raw vote counts. It is a GIWA
counterpart to MyStarPick's existing Kaia MSP token
(`0xf3fb962716229265fe9532cb4cb7e7c9fdca5713`), and matches it exactly on the
metadata that the vote-processing backend depends on: `name = "MyStarPick"`,
`symbol = "MSP"`, and **`decimals = 0`** (one token = one vote, no scaling).

## Architecture

Voting is settled in **two transactions**, with the voter paying **no gas**:

```
                        +----------------------------------------------+
                        |                MyStarPick backend            |
                        |            (holds MINTER_ROLE key)           |
                        +----------------+-----------------------------+
                                         |
   tx1: mint(voter, N)                   |  signed & sent by the minter
   ------------------------------------->|
                                         v
                                  +-------------+
                                  |  MSPToken   |  ERC-20, decimals 0
                                  +-------------+
                                         ^
                                         |  transfer(candidate, N) executed
                                         |  as msgSender == voter (ERC-2771)
                                         |
   tx2: voter signs an EIP-712           |
        ForwardRequest (off-chain,       |
        zero gas)                        |
        |                                |
        v                                |
   +-----------+   execute(request)   +--------------------+
   |  Relayer  | -------------------> | ERC2771Forwarder   |
   | (pays gas)|                      | "MyStarPick Fwd."  |
   +-----------+                      +--------------------+
```

1. **tx1 — mint.** A backend address holding `MINTER_ROLE` mints `N` vote tokens
   to the voter's address.
2. **tx2 — gas-sponsored transfer.** The voter signs an EIP-712 `ForwardRequest`
   off-chain (no gas, no ETH required). A relayer submits it to the
   `ERC2771Forwarder`, which calls `MSPToken.transfer(candidate, N)` with the
   voter recovered as `msg.sender` via ERC-2771. The relayer pays the gas.

### Contracts

| Contract           | Source                        | Notes                                                             |
| ------------------ | ----------------------------- | ----------------------------------------------------------------- |
| `MSPToken`         | `src/MSPToken.sol`            | ERC-20 + `ERC2771Context` + `AccessControl`; `decimals() == 0`.   |
| `ERC2771Forwarder` | OpenZeppelin (deployed as-is) | Stock OZ forwarder, deployed with name `"MyStarPick Forwarder"`.  |

`MSPToken` exposes:

- `mint(address to, uint256 amount)` — restricted to `MINTER_ROLE` (ABI-compatible
  with the Kaia MSP token).
- Standard ERC-20 `transfer` / `approve` / `transferFrom`.
- `AccessControl` role management under `DEFAULT_ADMIN_ROLE`.

There is intentionally **no** burn, pause, or upgradeability — the token is kept
minimal.

## Requirements

- [Foundry](https://book.getfoundry.sh/) (`forge`, `cast`).

## Install

Dependencies (OpenZeppelin v5, forge-std) are git submodules, so clone
recursively:

```bash
git clone --recurse-submodules <this-repo-url>
cd mystarpick-contracts
```

If you already cloned without `--recurse-submodules`, pull them in:

```bash
git submodule update --init --recursive
```

## Build

```bash
forge build
```

## Test

```bash
forge test -vv
```

The suite covers metadata, role-gated minting, plain transfers, and the full
ERC-2771 meta-transaction flow — including a gasless voter (0 ETH), replay
protection, invalid-signature rejection, and expired-deadline rejection.

## Deploy (GIWA Sepolia)

GIWA Sepolia — chain id **91342**, RPC `https://sepolia-rpc.giwa.io`, explorer
`https://sepolia-explorer.giwa.io`.

1. Copy the env template and fill it in (never commit `.env`):

   ```bash
   cp .env.example .env
   # edit .env: DEPLOYER_KEY, optional ADMIN_ADDRESS / MINTER_ADDRESS
   ```

2. Deploy the forwarder and token, then verify on Blockscout:

   ```bash
   source .env
   forge script script/Deploy.s.sol:Deploy \
     --rpc-url giwa_sepolia \
     --private-key "$DEPLOYER_KEY" \
     --broadcast \
     --verify \
     --verifier blockscout \
     --verifier-url https://sepolia-explorer.giwa.io/api
   ```

   If `ADMIN_ADDRESS` / `MINTER_ADDRESS` are unset, the deployer receives both
   `DEFAULT_ADMIN_ROLE` and `MINTER_ROLE`.

## Deployed addresses

| Network      | Contract           | Address |
| ------------ | ------------------ | ------- |
| GIWA Sepolia | `ERC2771Forwarder` | _TBD_   |
| GIWA Sepolia | `MSPToken`         | _TBD_   |

_(Filled in after deployment.)_

## Trust model

MSP is intentionally minimal, so its integrity rests on a small set of explicit
trust assumptions rather than on-chain safeguards:

- **The minter key is the single trust anchor for issuance.** `mint` has no supply
  cap (by design — one token per vote, minted by the backend). Whoever holds
  `MINTER_ROLE` can issue unlimited vote tokens, so that key is the integrity of
  the entire voting system. There is no on-chain limit; security depends entirely
  on how the minter key is managed off-chain.
- **There is no burn, pause, or upgrade — and thus no on-chain emergency stop.**
  The only incident-response lever is the admin revoking `MINTER_ROLE` (e.g. if a
  minter key leaks) and rotating to a fresh minter. Document this procedure in your
  operational runbook: `admin.revokeRole(MINTER_ROLE, compromisedMinter)` →
  rotate the server signing key → `admin.grantRole(MINTER_ROLE, newMinter)`.
- **Recommended production posture:** hold `DEFAULT_ADMIN_ROLE` in a **multisig**
  (e.g. a Safe), keep `MINTER_ROLE` on a separate server-side signing address, and
  after deployment transfer admin to the multisig and have the deployer EOA
  `renounceRole(DEFAULT_ADMIN_ROLE, deployer)`. This removes the deployer hot key
  as a single point of failure.
- **Testnet starting point:** on GIWA Sepolia the deploy defaults to
  `deployer == admin == minter` (a single EOA) for convenience. This is acceptable
  for testing only — do **not** carry that configuration to a production
  deployment; split the roles and move admin to a multisig first.

## Security notes

- `mint` is gated by `MINTER_ROLE`; role administration is gated by
  `DEFAULT_ADMIN_ROLE`.
- The forwarder enforces EIP-712 signatures, per-signer nonces (replay
  protection), and request deadlines.
- Never commit private keys or a populated `.env`. `.env` is git-ignored.

## License

[MIT](./LICENSE) © MyStarPick
