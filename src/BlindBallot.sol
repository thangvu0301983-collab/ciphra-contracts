// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ICipherStake {
    function stakeAt(address account, uint64 time) external view returns (uint256);
    function totalAt(uint64 time) external view returns (uint256);
}

interface ICipherVault {
    function route() external view returns (uint8);
    function applyRoute(uint64 epoch, uint8 newRoute, bytes32 tallyHash) external returns (bool);
}

/// @title CIPHRA Blind Ballot, phase 1 (commit-reveal)
/// @notice Each 7-day epoch, stakers choose where the Cipher Vault's Sealed Pot goes: BURN, COMPUTE or NODES.
///           Days 1 to 5 (seal):  submit commitment = keccak256(abi.encode(route, salt, voter, epoch, this, chainid))
///           Days 6 and 7 (open): reveal route and salt; weight = stake held strictly before the epoch opened
///           After the epoch:     anyone calls finalize(epoch); with quorum, the winner is written to the vault
///         Nobody sees a vote before it is revealed, and stake added after an epoch opened has no weight in it.
///         Phase 2 replaces this contract (through the vault's 48-hour timelock) with one whose ballots are
///         encrypted to the CIPHRA network's threshold key and tallied on ciphertext.
contract BlindBallot {
    uint32 public constant EPOCH = 7 days;
    uint32 public constant SEAL = 5 days;
    uint8 public constant ROUTES = 3;

    ICipherStake public immutable stake;
    ICipherVault public immutable vault;
    uint64 public immutable genesis; // start of epoch 1, e.g. a Sunday 00:00 UTC
    uint16 public immutable quorumBps; // revealed weight needed, as a share of total stake at epoch open

    mapping(uint64 => mapping(address => bytes32)) public commitmentOf;
    mapping(uint64 => mapping(address => bool)) public revealed;
    mapping(uint64 => uint256[3]) private _tally;
    mapping(uint64 => bool) public finalized;

    event Sealed(uint64 indexed epoch, address indexed voter, bytes32 commitment);
    event Revealed(uint64 indexed epoch, address indexed voter, uint8 route, uint256 weight);
    event Finalized(uint64 indexed epoch, bool quorum, uint8 winner, uint256[3] tally, uint256 totalStake, bytes32 tallyHash, bool applied);

    error NotStarted();
    error WrongPhase();
    error BadRoute();
    error NoCommitment();
    error AlreadyRevealed();
    error CommitmentMismatch();
    error NoWeight();
    error EpochNotOver();
    error AlreadyFinalized();
    error BadConfig();

    constructor(address stake_, address vault_, uint64 genesis_, uint16 quorumBps_) {
        if (stake_ == address(0) || vault_ == address(0) || quorumBps_ == 0 || quorumBps_ > 10_000) revert BadConfig();
        stake = ICipherStake(stake_);
        vault = ICipherVault(vault_);
        genesis = genesis_;
        quorumBps = quorumBps_;
    }

    // ================================================================== time
    /// @notice Current epoch number (1-based), 0 before genesis.
    function currentEpoch() public view returns (uint64) {
        if (block.timestamp < genesis) return 0;
        return uint64((block.timestamp - genesis) / EPOCH) + 1;
    }

    function epochStart(uint64 epoch) public view returns (uint64) {
        return genesis + (epoch - 1) * EPOCH;
    }

    /// @notice The commitment a voter must submit (also usable off-chain).
    function commitmentFor(uint8 route, bytes32 salt, address voter, uint64 epoch) public view returns (bytes32) {
        return keccak256(abi.encode(route, salt, voter, epoch, address(this), block.chainid));
    }

    // ================================================================== voting
    /// @notice Seal (or replace) this epoch's ballot during days 1 to 5.
    function commit(bytes32 commitment) external {
        uint64 e = currentEpoch();
        if (e == 0) revert NotStarted();
        if (block.timestamp >= epochStart(e) + SEAL) revert WrongPhase();
        commitmentOf[e][msg.sender] = commitment;
        emit Sealed(e, msg.sender, commitment);
    }

    /// @notice Open the ballot during days 6 and 7.
    function reveal(uint8 route, bytes32 salt) external {
        uint64 e = currentEpoch();
        if (e == 0) revert NotStarted();
        if (block.timestamp < epochStart(e) + SEAL) revert WrongPhase();
        if (route >= ROUTES) revert BadRoute();
        bytes32 c = commitmentOf[e][msg.sender];
        if (c == bytes32(0)) revert NoCommitment();
        if (revealed[e][msg.sender]) revert AlreadyRevealed();
        if (c != commitmentFor(route, salt, msg.sender, e)) revert CommitmentMismatch();
        uint256 weight = stake.stakeAt(msg.sender, epochStart(e));
        if (weight == 0) revert NoWeight();
        revealed[e][msg.sender] = true;
        _tally[e][route] += weight;
        emit Revealed(e, msg.sender, route, weight);
    }

    /// @notice Close a past epoch. With quorum the heaviest route wins; a tie keeps the vault's current route
    ///         if it is among the leaders, otherwise the lowest route id. Without quorum the route stays.
    function finalize(uint64 epoch) external {
        if (epoch == 0 || epoch >= currentEpoch()) revert EpochNotOver();
        if (finalized[epoch]) revert AlreadyFinalized();
        finalized[epoch] = true;

        uint256[3] memory t = _tally[epoch];
        uint256 totalStake = stake.totalAt(epochStart(epoch));
        uint256 votes = t[0] + t[1] + t[2];
        bool quorum = totalStake != 0 && votes * 10_000 >= totalStake * quorumBps;

        uint8 current = vault.route();
        uint8 winner = current;
        if (quorum) {
            uint256 best = t[0];
            winner = 0;
            for (uint8 r = 1; r < ROUTES; ++r) {
                if (t[r] > best) {
                    best = t[r];
                    winner = r;
                }
            }
            if (t[current] == best) winner = current; // ties keep the current route
        }
        bytes32 tallyHash = keccak256(abi.encode(address(this), epoch, t, totalStake));
        bool applied = quorum ? vault.applyRoute(epoch, winner, tallyHash) : false;
        emit Finalized(epoch, quorum, winner, t, totalStake, tallyHash, applied);
    }

    function tally(uint64 epoch) external view returns (uint256[3] memory) {
        return _tally[epoch];
    }
}
