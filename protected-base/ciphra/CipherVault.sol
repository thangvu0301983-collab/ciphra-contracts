// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title CIPHRA Cipher Vault
/// @notice The immutable creator-fee recipient of the $CPH pool, which runs Programmable's sealed
///         launch-protection hook (ProtectedNative30HookV1). Anyone may call the hook fee vault's
///         claimCreator() to push accrued creator fees (ETH) here, and anyone may call distribute().
///
///         Every distribution splits the ETH waiting here:
///           50% Sealed Pot   -> the route chosen by the Blind Ballot:
///                               BURN    -> buyback vault (a Safe buys $CPH back and burns it)
///                               COMPUTE -> compute fund (encrypted-inference credits and grants)
///                               NODES   -> node fund (rewards per verified job)
///           30% R&D treasury
///           20% Break-the-Cipher pool, kept here and paid out by the guardian as public bounties
///
///         Only the bound ballot contract can change the route, at most once per epoch, and fees that
///         arrived under the old route are distributed before the switch. The guardian (a Safe) can
///         change recipients, the ballot or itself only through a 48-hour public timelock, and can pause
///         the ballot (safe mode), which freezes the route at BURN. Nobody can withdraw ETH any other way.
contract CipherVault {
    uint16 public constant BPS = 10_000;
    uint16 public constant SHARE_SEALED_BPS = 5_000;
    uint16 public constant SHARE_RND_BPS = 3_000;
    uint16 public constant SHARE_BOUNTY_BPS = 2_000;

    uint8 public constant ROUTE_BURN = 0;
    uint8 public constant ROUTE_COMPUTE = 1;
    uint8 public constant ROUTE_NODES = 2;

    uint32 public constant TIMELOCK = 48 hours;

    struct Recipients {
        address buyback;
        address compute;
        address nodes;
        address rnd;
    }

    address public guardian;
    address public ballot;
    Recipients public recipients;

    uint8 public route; // starts at ROUTE_BURN
    uint64 public lastAppliedEpoch;
    bool public paused;

    uint256 public bountyPool;
    uint256 public totalDistributed;
    uint256 public totalBountiesPaid;

    // ---- timelocked changes
    Recipients public pendingRecipients;
    uint64 public recipientsReadyAt;
    address public pendingBallot;
    uint64 public ballotReadyAt;
    address public pendingGuardian;
    uint64 public guardianReadyAt;

    bool private _locked;

    event Received(address indexed from, uint256 amount);
    event Distributed(uint8 indexed route, uint256 toSealedPot, uint256 toRnd, uint256 toBounty);
    event RouteApplied(uint64 indexed epoch, uint8 oldRoute, uint8 newRoute, bytes32 tallyHash);
    event RouteIgnored(uint64 indexed epoch, uint8 route, string reason);
    event BountyPaid(address indexed to, uint256 amount, bytes32 reportHash);
    event SafeMode(bool paused);
    event RecipientsProposed(Recipients next, uint64 readyAt);
    event RecipientsChanged(Recipients next);
    event BallotProposed(address next, uint64 readyAt);
    event BallotChanged(address previous, address next);
    event GuardianProposed(address next, uint64 readyAt);
    event GuardianChanged(address previous, address next);
    event ProposalCancelled(uint8 kind);

    error ZeroAddress();
    error NotGuardian();
    error NotBallot();
    error BadRoute();
    error TooEarly();
    error NothingPending();
    error BountyTooLarge();
    error TransferFailed();
    error Reentrant();

    modifier nonReentrant() {
        if (_locked) revert Reentrant();
        _locked = true;
        _;
        _locked = false;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    constructor(address guardian_, address buyback_, address compute_, address nodes_, address rnd_) {
        if (guardian_ == address(0)) revert ZeroAddress();
        guardian = guardian_;
        _checkRecipients(Recipients(buyback_, compute_, nodes_, rnd_));
        recipients = Recipients(buyback_, compute_, nodes_, rnd_);
    }

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    /// @notice ETH waiting to be split (everything except the bounty pool).
    function pending() public view returns (uint256) {
        return address(this).balance - bountyPool;
    }

    // ================================================================== permissionless
    function distribute() external nonReentrant {
        _distribute();
    }

    // ================================================================== ballot
    /// @notice Written by the Blind Ballot when an epoch closes with quorum. Ignored (not reverted) while
    ///         paused or for an epoch that is not newer than the last one applied.
    function applyRoute(uint64 epoch, uint8 newRoute, bytes32 tallyHash) external nonReentrant returns (bool) {
        if (msg.sender != ballot || ballot == address(0)) revert NotBallot();
        if (newRoute > ROUTE_NODES) revert BadRoute();
        if (paused) {
            emit RouteIgnored(epoch, newRoute, "paused");
            return false;
        }
        if (lastAppliedEpoch != 0 && epoch <= lastAppliedEpoch) {
            emit RouteIgnored(epoch, newRoute, "stale epoch");
            return false;
        }
        _distribute(); // fees that arrived under the old route go the old way
        uint8 old = route;
        route = newRoute;
        lastAppliedEpoch = epoch;
        emit RouteApplied(epoch, old, newRoute, tallyHash);
        return true;
    }

    // ================================================================== guardian
    /// @notice Safe mode: freeze the route at BURN and ignore ballot results until unpaused.
    function setPaused(bool paused_) external onlyGuardian nonReentrant {
        if (paused_) {
            _distribute();
            route = ROUTE_BURN;
        }
        paused = paused_;
        emit SafeMode(paused_);
    }

    /// @notice Pay a Break-the-Cipher bounty from the bounty pool, with the hash of the public report.
    function payBounty(address to, uint256 amount, bytes32 reportHash) external onlyGuardian nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount > bountyPool) revert BountyTooLarge();
        bountyPool -= amount;
        totalBountiesPaid += amount;
        _send(to, amount);
        emit BountyPaid(to, amount, reportHash);
    }

    /// @notice The first ballot binding is immediate (no ballot exists at launch). Any later change is timelocked.
    function bindFirstBallot(address ballot_) external onlyGuardian {
        if (ballot_ == address(0)) revert ZeroAddress();
        if (ballot != address(0)) revert TooEarly();
        ballot = ballot_;
        emit BallotChanged(address(0), ballot_);
    }

    function proposeRecipients(Recipients calldata next) external onlyGuardian {
        _checkRecipients(next);
        pendingRecipients = next;
        recipientsReadyAt = uint64(block.timestamp + TIMELOCK);
        emit RecipientsProposed(next, recipientsReadyAt);
    }

    function executeRecipients() external onlyGuardian nonReentrant {
        if (recipientsReadyAt == 0) revert NothingPending();
        if (block.timestamp < recipientsReadyAt) revert TooEarly();
        _distribute(); // fees earned under the old recipients go to them
        recipients = pendingRecipients;
        delete pendingRecipients;
        recipientsReadyAt = 0;
        emit RecipientsChanged(recipients);
    }

    function proposeBallot(address next) external onlyGuardian {
        if (next == address(0)) revert ZeroAddress();
        pendingBallot = next;
        ballotReadyAt = uint64(block.timestamp + TIMELOCK);
        emit BallotProposed(next, ballotReadyAt);
    }

    function executeBallot() external onlyGuardian {
        if (ballotReadyAt == 0) revert NothingPending();
        if (block.timestamp < ballotReadyAt) revert TooEarly();
        emit BallotChanged(ballot, pendingBallot);
        ballot = pendingBallot;
        pendingBallot = address(0);
        ballotReadyAt = 0;
    }

    /// @notice Hand the guardian role to a new Safe or DAO, or to address(0) to renounce, after the timelock.
    function proposeGuardian(address next) external onlyGuardian {
        pendingGuardian = next;
        guardianReadyAt = uint64(block.timestamp + TIMELOCK);
        emit GuardianProposed(next, guardianReadyAt);
    }

    function executeGuardian() external onlyGuardian {
        if (guardianReadyAt == 0) revert NothingPending();
        if (block.timestamp < guardianReadyAt) revert TooEarly();
        emit GuardianChanged(guardian, pendingGuardian);
        guardian = pendingGuardian;
        pendingGuardian = address(0);
        guardianReadyAt = 0;
    }

    /// @param kind 0 recipients, 1 ballot, 2 guardian
    function cancelProposal(uint8 kind) external onlyGuardian {
        if (kind == 0) {
            delete pendingRecipients;
            recipientsReadyAt = 0;
        } else if (kind == 1) {
            pendingBallot = address(0);
            ballotReadyAt = 0;
        } else {
            pendingGuardian = address(0);
            guardianReadyAt = 0;
        }
        emit ProposalCancelled(kind);
    }

    // ================================================================== internals
    function _distribute() internal {
        uint256 amount = pending();
        if (amount == 0) return;
        uint256 toSealed = amount * SHARE_SEALED_BPS / BPS;
        uint256 toRnd = amount * SHARE_RND_BPS / BPS;
        uint256 toBounty = amount - toSealed - toRnd;
        // Book the bounty share before any ETH leaves, so pending() can never count it again.
        bountyPool += toBounty;
        totalDistributed += amount;
        Recipients memory r = recipients;
        uint8 rt = route;
        _send(rt == ROUTE_BURN ? r.buyback : rt == ROUTE_COMPUTE ? r.compute : r.nodes, toSealed);
        _send(r.rnd, toRnd);
        emit Distributed(rt, toSealed, toRnd, toBounty);
    }

    function _checkRecipients(Recipients memory r) private pure {
        if (r.buyback == address(0) || r.compute == address(0) || r.nodes == address(0) || r.rnd == address(0)) {
            revert ZeroAddress();
        }
    }

    function _send(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
