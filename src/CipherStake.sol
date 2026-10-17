// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IERC20Like {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title CIPHRA Cipher Stake
/// @notice Holders stake $CPH to vote in the Blind Ballot (and, later, to run nodes). No rewards are minted:
///         staking only gives voting weight. Weight is read at a past timestamp from checkpoints, so stake added
///         after an epoch opened does not count in that epoch, and tokens cannot be borrowed for one vote.
///         Unstaking removes weight at once and releases the tokens after a 7-day cooldown.
contract CipherStake {
    uint32 public constant COOLDOWN = 7 days;

    struct Checkpoint {
        uint64 time;
        uint192 amount;
    }

    struct Unstake {
        uint192 amount;
        uint64 readyAt;
    }

    IERC20Like public immutable token;

    mapping(address => Checkpoint[]) private _stakeOf;
    Checkpoint[] private _total;
    mapping(address => Unstake) public unstaking;

    event Staked(address indexed account, uint256 amount, uint256 newStake);
    event UnstakeRequested(address indexed account, uint256 amount, uint64 readyAt);
    event Withdrawn(address indexed account, uint256 amount);

    error ZeroAmount();
    error InsufficientStake();
    error NotReady();
    error TransferFailed();
    error FutureLookup();

    constructor(address token_) {
        token = IERC20Like(token_);
    }

    // ================================================================== actions
    function stake(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (!token.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        uint256 next = stakeOf(msg.sender) + amount;
        _push(_stakeOf[msg.sender], next);
        _push(_total, totalStaked() + amount);
        emit Staked(msg.sender, amount, next);
    }

    /// @notice Remove `amount` of weight now; the tokens can be withdrawn after the cooldown.
    ///         A new request adds to the pending amount and restarts the cooldown.
    function requestUnstake(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        uint256 current = stakeOf(msg.sender);
        if (amount > current) revert InsufficientStake();
        _push(_stakeOf[msg.sender], current - amount);
        _push(_total, totalStaked() - amount);
        Unstake storage u = unstaking[msg.sender];
        u.amount += uint192(amount);
        u.readyAt = uint64(block.timestamp + COOLDOWN);
        emit UnstakeRequested(msg.sender, amount, u.readyAt);
    }

    function withdraw() external {
        Unstake memory u = unstaking[msg.sender];
        if (u.amount == 0) revert ZeroAmount();
        if (block.timestamp < u.readyAt) revert NotReady();
        delete unstaking[msg.sender];
        if (!token.transfer(msg.sender, u.amount)) revert TransferFailed();
        emit Withdrawn(msg.sender, u.amount);
    }

    // ================================================================== views
    function stakeOf(address account) public view returns (uint256) {
        Checkpoint[] storage c = _stakeOf[account];
        return c.length == 0 ? 0 : c[c.length - 1].amount;
    }

    function totalStaked() public view returns (uint256) {
        return _total.length == 0 ? 0 : _total[_total.length - 1].amount;
    }

    /// @notice Stake held at the end of timestamp `time - 1`, i.e. strictly before `time`.
    function stakeAt(address account, uint64 time) external view returns (uint256) {
        if (time > block.timestamp) revert FutureLookup();
        return _lookup(_stakeOf[account], time);
    }

    function totalAt(uint64 time) external view returns (uint256) {
        if (time > block.timestamp) revert FutureLookup();
        return _lookup(_total, time);
    }

    // ================================================================== internals
    /// @dev Last checkpoint with c.time < time (binary search).
    function _lookup(Checkpoint[] storage c, uint64 time) private view returns (uint256) {
        uint256 lo = 0;
        uint256 hi = c.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (c[mid].time < time) lo = mid + 1;
            else hi = mid;
        }
        return lo == 0 ? 0 : c[lo - 1].amount;
    }

    function _push(Checkpoint[] storage c, uint256 amount) private {
        uint64 now_ = uint64(block.timestamp);
        if (c.length != 0 && c[c.length - 1].time == now_) c[c.length - 1].amount = uint192(amount);
        else c.push(Checkpoint(now_, uint192(amount)));
    }
}
