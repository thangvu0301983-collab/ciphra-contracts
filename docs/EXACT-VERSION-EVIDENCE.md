# CIPHRA ($CPH): exact-version evidence for review

This page answers the review of CIPHRA's protected Ethereum launch point by point. The machine-readable evidence is
packed inside the request as the attestation `exact-version-execution-evidence`
([`protected/ciphra/evidence/exact-version.json`](../protected/ciphra/evidence/exact-version.json)). It was produced by
[`test/CiphraExactVersion.fork.t.sol`](../test/CiphraExactVersion.fork.t.sol), and
[`programmable/pack-exact.mjs`](../programmable/pack-exact.mjs) reproduces it.

## Why the admission record still says "static only"

The v3.6 API accepts `behaviorExecution` only from Programmable's platform runtime executor ("caller or agent
declarations never satisfy this schema"). Profile 3.6 rejects `behaviorScenarioInputs`. The CLI README states that
caller-supplied proofs cannot clear admission findings. On Ethereum the executor currently reports
`BEHAVIOR_RUNNER_NOT_CONFIGURED`. The finalized LUCID launch (`533c853e`), built on the same sealed protection package,
shows `not_executed` on every vector for this reason. The applicant cannot add runtime evidence to that record, so it
is provided here, bound to the exact request.

## How the evidence is bound to the exact version

1. `export-exact-fixture.mjs` reads the submitted `launch.json`. It produces the Router's graph targets with resolved
   init code and initializer calldata, in deployment order, plus the route namespace and nonce.
2. On an Ethereum mainnet fork, the test sends those exact targets to Programmable's GraphFactory
   (`0xB012…A887`). The call comes from the 24h Router (`0xBE4b…C4C3`), with the launch wallet as `tx.origin`.
3. Every target is asserted at its predicted CREATE2 address with the packed runtime code hash.
4. Only the Router's permit signature check is not exercised.

The evidence file is part of the source bundle, which decides the addresses, so it records no target addresses. The
request is rebuilt and re-tested until the regenerated evidence is byte-identical to the packed file. Results: 19 of
19 exact-version tests pass, and 42 of 42 repository tests pass.

## 1. Deadline covering the review and launch windows

The permit is valid from `validAfter` = 2026-10-20 07:05:56 UTC to `deadline` = 2026-10-21 07:05:56 UTC. That is
86,400 s, the 24h Router's `MAX_PERMIT_LIFETIME`, and the Router checks `deadline - validAfter <= 24 hours`. The
window opens about 24 hours after packing, so it covers the 24-hour review and then the 24-hour launch window.

## 2. Initial buy: bound call, observed input and output

| Item | Value |
|---|---|
| Bound call | `initialize(hook, token, 187740, developer, 6831709475946227712311826)`, value 0.05 ETH, executed by the GraphFactory in the launch transaction |
| Observed input | 50,000,000,000,000,000 wei |
| Observed output | 6,900,716,642,369,926,982,133,158 CPH units (6,900,716.64 CPH) to the developer, at or above the minimum and below the 2% cap (20,000,000 CPH) |
| Fees | platform 150,000,000,000,000 wei; creator 1,000,000,000,000,000 wei; opening tax 0 (developer exempt) |
| Opening price | FDV USD 17,058 at tick 187740 |
| Feed | Chainlink ETH/USD answer 242643149375, 1,824 s old (limit 3,600 s) |
| Floor | Launch passes while the answer is at least 213367474739 (12.06% below); one unit lower reverts with `OpeningValuationTooLow` |
| Oversized buy | A 0.5 ETH opening buy reverts the whole graph (`BuyerLimitExceeded`) |
| Short buy | A 0.045 ETH buy misses the bound minimum and reverts (`InvalidInitialBuy`) |

## 3. Twelve protection scenarios (P01–P12)

| # | Scenario | Result |
|---|---|---|
| P01 | USD 15,000 floor | Reverts one feed unit below the floor; passes at it |
| P02 | Fresh oracle | Feed older than 3,600 s reverts (`InvalidOraclePrice`); exactly 3,600 s is accepted |
| P03 | 2% opening-buy cap | 0.5 ETH opening buy reverts atomically; nothing is deployed |
| P04 | Minimum output | Underfunded buy reverts |
| P05 | Single atomic initialization | Initializer callable only by the GraphFactory, once; `start()` initializer-only; the pool cannot be re-initialized or cloned; the graph authorization cannot be replayed |
| P06 | 99% opening fee | 0.01 ETH buy at second 0: opening tax 0.00967 ETH, platform 0.00003 ETH, creator 0.0002 ETH (990,000 ppm) |
| P07 | Linear decay | Exact surcharge at seconds 1, 10, 20 and 29; zero from second 30 |
| P08 | Developer | Exempt from the surcharge but still capped: an over-cap buy reverts (`BuyerLimitExceeded`) |
| P09 | Cumulative buyer cap | Second buy over 2% reverts; selling does not refill the budget |
| P10 | Recipient cap | Over-cap transfer reverts (`WalletLimitExceeded`); forwarding does not refill; self-transfer is neutral |
| P11 | Canonical router only | For 300 s, buys through a test router or a raw PoolManager integration revert (`UnsupportedRouter`); the Universal Router works; sells use any route at normal fees |
| P12 | Expiry | Still protected at second 299; at second 300 a buy above 2% and a transfer above 2% succeed |

## 4. Swaps, liquidity, callbacks, accounting and the 0.3% fee

- **Four swap quadrants** (S01). Exact-in and exact-out buys and sells at three sizes each, all checked against an
  independent reimplementation of the fee formula (gross native ETH, ceil per trade). Examples:
  - exact-out buy of 5,000,000 CPH: gross 0.077122544140539232 ETH, platform fee 231,367,632,421,618 wei;
  - exact-in sell of 1,000,000 CPH: gross 0.017108933354084709 ETH, seller receives 0.01671542788694076 ETH.
- **Second user and time** (S02). Interleaved users across 30 days and one year; every fee is exact.
- **Liquidity custody and withdrawal** (L01). The seed position (liquidity 83,845,840,171,149,445,848,971) belongs to
  the initializer, which has no withdrawal entry point. It is unchanged after ten years of trading. A third-party LP
  adds and fully withdraws, losing at most 1 wei of rounding on each side.
- **Callback authentication** (C01, P05).
  - Hook callbacks revert unless called by the PoolManager (`NotPoolManager`).
  - `afterSwap` is bound to the active swap (`InvalidSwapContext`).
  - The module is kernel-only (`OnlyKernel`).
  - Fee vaults reject non-kernel records (`UnauthorizedKernel`) and unbound callbacks (`InvalidClaim`).
  - The initializer callback is bound to its own unlock (`Unauthorized`).
- **Custom accounting** (A01).
  - Recorded fees are backed one-to-one by PoolManager ERC-6909 claims, and the hook holds no ETH, tokens or claims.
  - Supply is conserved.
  - An exact-output buy sent with 10 ETH pays exactly its gross (0.035804063260342068 ETH) and gets the rest refunded.
  - Claims are caller-independent and reach only the fixed recipients: creator fees go to CipherVault, platform fees
    and the opening tax go to the treasury. A second claim reverts (`NothingToClaim`).
- **Exact 0.3% platform fee** (F01). The same trades go through the Universal Router, a v4 test router and a raw
  PoolManager integration with arbitrary hookData. Each pays exactly `ceil(gross × 30 / 10000)`, so there is no
  bypass, and the total is 3,000 ppm of 21.87 ETH gross, so there is no overcharge. The platform and creator ledgers
  are isolated.

## Reproduce

Place the submitted bytes at `protected/launch.json` with its config, then run:

```bash
PL_DIR=<@programmable/launch 4.1.7> node programmable/export-exact-fixture.mjs
mkdir -p evidence/exact
ETH_RPC_URL=<archive RPC> FORK_BLOCK=26224790 forge test --json > forge.json
FORK_BLOCK=26224790 node programmable/collect-exact-evidence.mjs forge.json
```

`evidence/exact-version.json` then matches the packed `ciphra/evidence/exact-version.json` byte for byte.
