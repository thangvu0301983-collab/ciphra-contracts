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
  Safe, COMPUTE to the compute fund, NODES to the node fund), 30% R&D treasury, 20% Break-the-Cipher bounty pool.
  Fees that arrived under the old route are distributed before a switch. The guardian (a Safe) can change
  recipients, the ballot or itself only after a 48-hour timelock, pays bounties from the bounty pool, and can
  pause the ballot (safe mode: route frozen at BURN). Reentrancy-guarded; no immutables.
- **CipherStake**: stake $CPH for voting weight, read from checkpoints at a past timestamp; unstaking removes
  weight at once and releases tokens after 7 days. No rewards are minted.
- **BlindBallot** (phase 1, commit-reveal): 7-day epochs, seal days 1 to 5, reveal days 6 and 7, weight = stake
  held strictly before the epoch opened, quorum in basis points of total stake, ties keep the current route.
  Phase 2 replaces it, through the vault's timelock, with a ballot tallied on ciphertext by CIPHRA nodes.

CipherStake and BlindBallot are deployed after launch (they need the token address); the guardian binds the first
ballot once with `bindFirstBallot`, and any later ballot change goes through the timelock.

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

## License

CIPHRA sources: MIT. Vendored dependencies keep their own licenses.
