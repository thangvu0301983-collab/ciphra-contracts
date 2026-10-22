# CIPHRA contracts

CIPHRA ($CPH) is an FHE coprocessor network for language models: AI that computes on ciphertext.
This repository holds the exact sources of the $CPH launch graph for the
[Programmable](https://programmable.market) Ethereum Custom Launch, and CIPHRA's own contracts.

## Launch graph (`protected/`)

Programmable requires every new native-ETH launch to use its sealed launch-protection package v1
(`@programmable/launch` 4.1.7). $CPH uses that package unchanged, plus one CIPHRA contract:

| Target | Contract | Role |
|---|---|---|
| `initializer` | `ProtectedNativeInitializerV1` (Programmable) | USD 15,000 opening floor on the Chainlink ETH/USD feed, 100% of supply as one locked position, the capped opening buy |
| `token` | `ProtectedLaunchTokenV1` (Programmable) | $CPH, 1,000,000,000 fixed supply; 2% receive cap per wallet for 300 seconds |
| `hook` | `ProtectedNative30HookV1` (Programmable) | 0.30% platform fee + fixed 2% creator fee on buys and sells; 99% opening buy fee decaying to normal in 30 seconds; 2% per-buyer cap for 300 seconds |
| `vault` | `src/CipherVault.sol` (CIPHRA) | The hook's immutable creator-fee recipient |

Only one value differs from Programmable's own helper output: the creator-fee recipient is CipherVault instead
of the launch wallet.

## CIPHRA contracts (`src/`)

- **CipherVault**: splits every creator fee 50% Sealed Pot (route set by the Blind Ballot: BURN to the buyback
  wallet, COMPUTE to the compute fund, NODES to the node fund), 30% R&D treasury, 20% Break-the-Cipher bounty pool.
  Fees that arrived under the old route are distributed before a switch. The guardian (at launch one ordinary wallet, not a multisig) binds
  the first ballot once, immediately and without a timelock; it can replace the ballot, change recipients or change
  itself only after a 48-hour timelock, pays bounties from the bounty pool, and can pause the ballot (safe mode: route
  frozen at BURN). Reentrancy-guarded; no immutables.
- **CipherStake**: stake $CPH for voting weight, read from checkpoints at a past timestamp; unstaking removes
  weight at once and releases tokens after 7 days. No rewards are minted.
- **BlindBallot** (phase 1, commit-reveal): 7-day epochs, seal days 1 to 5, reveal days 6 and 7, weight = stake
  held strictly before the epoch opened, quorum in basis points of total stake, ties keep the current route.
  Phase 2 replaces it, through the vault's timelock, with a ballot tallied on ciphertext by CIPHRA nodes.

CipherStake and BlindBallot are not part of the launch graph. At launch `CipherVault.ballot` is empty and the route
stays at BURN. The two contracts are deployed after launch (they need the token address); the guardian then binds the
first ballot once with `bindFirstBallot`, which takes effect immediately (no timelock), and any later ballot change
goes through the 48-hour timelock. Whatever address is bound as the ballot can set the route among the three fixed
recipients, so the first binding relies on the guardian until the bound ballot is verified on-chain.

## Build and test

Foundry, solc 0.8.26, optimizer 1000, `cancun`, no via-IR, no CBOR metadata. Dependencies are vendored in `lib/`.

```bash
forge test
ETH_RPC_URL=https://ethereum-rpc.publicnode.com forge test --match-contract CiphraProtectedLaunchForkTest -vv
```

The fork test runs Programmable's exact published bytecode with CipherVault as creator-fee recipient: the USD
floor, the router-only protection window, trades, `claimCreator()` into the vault, the 50/30/20 split, real $CPH
staked, a sealed ballot, the route switch and the split after it.

## Packing the Programmable request

`programmable/build-protected.mjs` reproduces Programmable's `buildProtectedEthereumLaunchV1` with CipherVault as
the fourth target, writes `protected/` and `protected/protected-launch.config.json`, and verifies every predicted
address with the CLI library. Then, from `protected/`:

```bash
programmable-launch pack --config protected-launch.config.json --output launch.json
programmable-launch validate launch.json --config protected-launch.config.json --remote
```

On Windows run the CLI with `node --import ../programmable/win-dir-fsync-shim.mjs <cli>`.

## Exact-version execution evidence

Reviewer summary: [docs/EXACT-VERSION-EVIDENCE.md](docs/EXACT-VERSION-EVIDENCE.md) (Ethereum) and [docs/EXACT-VERSION-EVIDENCE-BASE.md](docs/EXACT-VERSION-EVIDENCE-BASE.md) (Base: `CHAIN_ID=8453`, CLI 4.2.0, output in `protected-base/`).

`programmable/pack-exact.mjs` packs the request together with execution evidence for that exact request:

1. `build-protected.mjs` writes `protected/` (nonce, permit window, opening tick pinned by `LAUNCH_NONCE`,
   `VALID_AFTER`, `DEADLINE`, `START_TICK`), and the CLI packs `protected/launch.json`.
2. `export-exact-fixture.mjs` turns that `launch.json` into `test/fixtures/exact-launch.json`: the Router's graph
   targets with resolved init code and initializer calldata, in deployment order, plus the route namespace and nonce.
3. `forge test` runs everything. `test/CiphraExactVersion.fork.t.sol` deploys those exact targets through
   Programmable's GraphFactory on a mainnet fork (pinned by `FORK_BLOCK`), called as the 24h Router with the launch
   wallet as `tx.origin`, and asserts each target's CREATE2 address and runtime code hash. Only the Router's permit
   signature is not exercised. Scenarios: the bound initial buy; twelve protection scenarios (USD floor, stale feed,
   2% opening-buy cap, minimum output, single atomic initialization, 99% opening fee, its decay, developer exemption,
   cumulative buyer cap, recipient cap, canonical-router-only buys, expiry at 300 s); four swap quadrants at three sizes;
   a second user over a year; liquidity custody and third-party withdrawal; callback authentication; fee backing,
   inventory, refunds and claims; and the exact 0.30% platform fee on every route.
4. `collect-exact-evidence.mjs` writes `evidence/exact-version.json` (no target addresses) and
   `evidence/forge-tests.json`, which the next build packs as attestation evidence.

Because the evidence is inside the source bundle and the bundle decides the CREATE2 addresses, the loop repeats until
the regenerated evidence is byte-identical to the packed evidence. To check a submitted request, place its bytes at
`protected/launch.json` with its config and run steps 2 to 4.

The permit window starts about 24 hours after packing and lasts the Router's maximum of 24 hours, so it covers the
review and the launch window. The opening FDV check uses the live Chainlink feed at launch; the evidence records the
lowest ETH/USD answer at which the launch still clears USD 15,000.

## License

CIPHRA sources: MIT. Vendored dependencies keep their own licenses.
