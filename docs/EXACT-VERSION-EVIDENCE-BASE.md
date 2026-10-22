# CIPHRA ($CPH) on Base: exact-version evidence for review

This is CIPHRA's Base launch: a separate token with its own fixed 1,000,000,000 supply, its own Uniswap v4 pool and its
own Cipher Vault. It is not bridged to, backed by or interchangeable with CPH on Ethereum
(`0x787A9070832A56F442664E3764585b1a003fcfBA`, approved request `412702b0`).

## The graph

Programmable's sealed Base launch-protection package v1 (CLI 4.2.0) is used unchanged, with CipherVault added as a
fourth target and set as the hook's immutable creator-fee recipient:

- `BaseProtectedNativeInitializerV1`, which checks the Chainlink ETH/USD feed and the Base sequencer uptime feed;
- `ProtectedLaunchTokenV1`;
- `BaseProtectedNative30HookV1`;
- `CipherVault`.

The machine-readable evidence is packed as the attestation `exact-version-execution-evidence`
([`protected-base/ciphra/evidence/exact-version.json`](../protected-base/ciphra/evidence/exact-version.json)).

## Method

The method is the same as the approved Ethereum request:

1. `export-exact-fixture.mjs` reads the submitted Base `launch.json` and produces the Router's graph targets with
   resolved init code and initializer calldata, in deployment order.
2. On a Base mainnet fork, those targets go to Programmable's Base GraphFactory (`0xB914…692e`). The call comes from
   the Base Router (`0xEf97…2eF4`), with the launch wallet as `tx.origin`.
3. Every target is asserted at its predicted CREATE2 address with the packed runtime code hash.
4. Protection-window buys go through the canonical Base Universal Router (`0xd614…9c40`), with its `minHopPriceX36`
   parameter layout.
5. Only the Router's permit signature check is not exercised.

The evidence file holds no target addresses. The request is rebuilt and re-tested until the evidence is
byte-identical. Results: 19 of 19 exact-version tests pass, and 40 of 40 tests pass in total.

## Key results on Base

| Item | Value |
|---|---|
| Bound call | `initialize(hook, token, 187560, developer, 6710670923927445743591303)`, value 0.05 ETH |
| Observed initial buy | 0.05 ETH in, 6,778,455.48 CPH out (at or above the minimum, below the 2% cap) |
| Fees on the initial buy | platform 0.00015 ETH; creator 0.001 ETH; opening tax 0 (developer exempt) |
| Opening valuation | USD 17,005 at tick 187560; feed 940 s old (limit 3,600 s) |
| Floor | Launch passes while ETH/USD ≥ 2,095.61 (11.79% below the observed 2,375.86); one unit lower reverts |
| Permit window | 24 hours, opening about 24 hours after packing (the Router's maximum lifetime) |
| Platform fee | 3,000 ppm of gross on the Universal Router, a v4 test router and a raw PoolManager integration |

All twelve protection scenarios (P01–P12) pass on Base. So do:

- the four swap quadrants at three sizes;
- a second user over a year;
- liquidity custody and third-party withdrawal;
- callback authentication;
- fee backing, inventory, refunds and caller-independent claims.

## Ballot status at launch

This is identical to Ethereum:

- No ballot is bound at launch; `CipherVault.ballot` is empty and the Sealed Pot route stays at Burn.
- The guardian, one ordinary wallet (`0x8B4b…944F`, not a multisig), binds the first ballot once, immediately and with
  no timelock.
- Ballot replacement, recipient changes and guardian changes wait 48 hours.
- CipherStake and BlindBallot are planned. They are deployed after launch and are not part of this graph or of
  Programmable's review.

## Reproduce

```bash
CHAIN_ID=8453 PL_DIR=<@programmable/launch 4.2.0> PROTECTED_DIR=protected-base EXACT_FIXTURE=test/fixtures/exact-launch-base.json node programmable/export-exact-fixture.mjs
mkdir -p evidence/base/exact
EXACT_FIXTURE=test/fixtures/exact-launch-base.json EXACT_EVIDENCE_DIR=evidence/base/exact/ ETH_RPC_URL=<Base RPC> FORK_BLOCK=52952374 forge test --match-contract CiphraExactVersionForkTest
```
