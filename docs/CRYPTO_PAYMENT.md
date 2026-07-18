# Crypto-Funded Voting Rights — Architecture (GIWA)

MyStarPick lets fans buy **paid voting rights** to vote for candidates. Today those
rights are purchased with fiat (credit card, via five payment gateways). This
document describes how the platform accepts **on-chain payment on GIWA** — a GIWA
mainnet token, a stablecoin, or our future **MyStarChain (MSC)** token — and
converts it into the exact same voting rights, reusing the existing issuance flow.

Everything described here as **built** runs today on **GIWA Sepolia**; everything
under **Roadmap** is the work the GASOK program would fund.

---

## Design principles

1. **Self-custody (voter pays).** The platform never custodies user funds. The
   voter signs their own payment transaction from their own wallet (e.g. GIWA
   Wallet); the gateway forwards the payment straight to the treasury and keeps
   nothing.
2. **Token-agnostic.** The gateway accepts a *whitelist* of tokens — the native
   GIWA token, stablecoins, and MSC — so the platform can add rails and tune
   exchange rates over time. Pricing/rate logic is **off-chain**; the contract
   records only *what was paid against which order*.
3. **Reuse, don't rebuild.** A crypto payment is just a **sixth payment gateway**.
   Fiat and crypto both converge on one seam — `OrderCompleteService#after_complete`
   — which already handles idempotency, per-contest limits, and voting-rights
   issuance. The voting logic is untouched.

## The MSP vs MSC distinction

- **MSP** (already live on GIWA) is a *vote-receipt* token: `decimals == 0`, minted
  as a side effect of a vote and transferred to the candidate. It is not a payment
  token and is never bought.
- **MSC** (roadmap) is a *payment/utility* token with real tokenomics, standard
  `decimals`, and exchange listing. It is one of several accepted payment rails —
  not a replacement for MSP.

---

## Flow

```
 ┌────────────┐   1. checkout        ┌─────────────────────────────┐
 │   Voter    │ ───────────────────► │  MyStarPick backend (Rails) │
 │  (wallet)  │                      │  creates Order(unpaid),     │
 │            │ ◄─────────────────── │  returns orderRef           │
 └─────┬──────┘   orderRef           └──────────────┬──────────────┘
       │                                            │
       │ 2. pay on-chain (self-custody, pays gas)   │
       ▼                                            │
 ┌──────────────────────┐  forward   ┌───────────┐  │
 │ VotingRightsGateway  │ ─────────► │ Treasury  │  │
 │  purchase / native   │            └───────────┘  │
 │  emits Purchased(     │                          │
 │   buyer,token,amount, │                          │
 │   orderRef)           │                          │
 └──────────┬───────────┘                          │
            │ 3. tx hash                            │
            ▼                                       ▼
 ┌─────────────────────────────────────────────────────────────┐
 │ backend verifies the on-chain event (express /giwa/          │
 │ verify_purchase reads the receipt, matches orderRef) and     │
 │ calls OrderCompleteService#after_complete(order, user,       │
 │ "giwa:<txhash>")  ── the SAME seam the 5 fiat PGs use ──►    │
 │ Order → paid → voting rights (votes) issued                  │
 └─────────────────────────────────────────────────────────────┘
```

`orderRef` is the `Order` id encoded as `bytes32`. The gateway enforces
**one payment per orderRef** on-chain (`orderRefUsed`), and the backend is
idempotent (an already-paid order is a no-op), so a re-broadcast or duplicate
submission can neither double-charge nor double-credit.

---

## Built (GIWA Sepolia, chain id 91342)

| Piece | Where | Status |
| ----- | ----- | ------ |
| `VotingRightsGateway` | [`0x100Df5a4835a6e63a2E095AC8F99743a89f97e67`](https://sepolia-explorer.giwa.io/address/0x100Df5a4835a6e63a2E095AC8F99743a89f97e67) | deployed + source-verified |
| Test token (GTT, ERC-20 stand-in) | [`0x307eFc47664f47d68C6D5867D99c30bb032d2E79`](https://sepolia-explorer.giwa.io/address/0x307eFc47664f47d68C6D5867D99c30bb032d2E79) | deployed + verified |
| `src/VotingRightsGateway.sol` + tests | this repo | 13 tests (idempotency, whitelist, native, pause, onlyOwner) |
| `verify_purchase` endpoint + Rails service | MyStarPick backend | verified against real on-chain txs |

**On-chain demo transactions:**

- ERC-20 purchase → treasury received the token, `Purchased` event emitted:
  [`0xc4ef825e…c1f63b`](https://sepolia-explorer.giwa.io/tx/0xc4ef825e432d6d806b6af7ed7554b52de15a619e76dacd7efe4a0fed59c1f63b)
- Native-token purchase → treasury received the native value, `NativePurchased`:
  [`0x72acd538…25fc90`](https://sepolia-explorer.giwa.io/tx/0x72acd53839d33a1856d893f7039e3fd0f1574d42bc931403b30af2422225fc90)
- Idempotency: re-paying a used `orderRef` reverts with `OrderRefAlreadyUsed`.

The backend `verify_purchase` endpoint was run against both real transactions and
correctly returned `confirmed: true` with the matching buyer / token / amount /
orderRef (and `confirmed: false` for a mismatched ref). The verification service
then routes into the existing `after_complete` seam, which issues voting rights —
proven by unit tests that assert the order flips to `paid` and votes are created.

This composes with the already-live GIWA voting integration (paid rights →
gas-sponsored vote → MSP receipt), so the full consumer loop — **pay with a GIWA
token → receive voting rights → cast a gasless vote recorded on GIWA** — runs
end-to-end on testnet.

---

## Roadmap (what the program funds)

- **MSC token & tokenomics** — capped supply, allocation/vesting, exchange listing,
  liquidity. (This repo's gateway already accepts it via the whitelist.)
- **Mainnet deployment** — redeploy gateway + MSP on GIWA mainnet; production
  treasury as a **multisig**; a dedicated production minter/relayer key.
- **Pricing** — quote-and-lock the required token amount at checkout from an
  exchange price feed (voting rights are priced in fiat; the token floats).
  Stablecoin rails avoid this entirely and are the preferred first mainnet rail.
- **Finality & reconciliation** — wait for `safe`/`finalized` before crediting;
  a chain-scan job to reconcile any payment the backend missed.
- **Refund policy** — crypto is irreversible; define a credit/refund runbook.
- **Compliance** — VASP / 특금법 review for accepting tokens as payment and for
  MSC issuance (legal-gated, not a contract concern).

---

## Why this fits GIWA / GASOK

- **Real consumer transaction volume.** K-pop voting is high-frequency, large-scale
  micro-payments. Routing it on-chain brings sustained transaction volume and
  treasury TVL to GIWA — directly matching the program's KPI axes (transaction
  volume, TVL, user acquisition).
- **Wallet integration.** The self-custody model connects the **GIWA Wallet** as the
  payment signer — hitting the "structural fit for wallet integration" criterion
  head-on.
- **Already working on testnet.** Verified contracts + real on-chain demo
  transactions demonstrate "a product functioning at an operational level with
  robust technical implementation," which is what Phase 2 evaluates.
