// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title NYTVesting - Team Token Vesting
 * @notice Locks team tokens for 1 year (cliff), then releases linearly
 *         over 2 years. Owner can add multiple beneficiaries.
 *
 *  Timeline example (deploy = Jan 1 2025):
 *   - Cliff:    Jan 1  2026 - nothing claimable before this
 *   - Full vest: Jan 1 2028 - all tokens claimable by this date
 */
contract NYTVesting is Ownable {

    IERC20 public immutable token;

    uint256 public constant CLIFF_DURATION  = 365 days;  // 1 year cliff
    uint256 public constant VEST_DURATION   = 730 days;  // 2 year linear vest after cliff

    struct VestingSchedule {
        uint256 totalAmount;      // total NYT allocated
        uint256 claimedAmount;    // how much has been claimed so far
        uint256 startTime;        // when vesting started (set at grant time)
        bool    initialized;
    }

    mapping(address => VestingSchedule) public schedules;
    address[] public beneficiaries;

    // Total NYT committed across all active grants (claimed tokens reduce this).
    // Used to prevent over-committing: sum of all grants can never exceed contract balance.
    uint256 public totalCommitted;

    // ─── Events ───────────────────────────────────────────────────────────────
    event GrantCreated(address indexed beneficiary, uint256 amount, uint256 startTime);
    event Claimed(address indexed beneficiary, uint256 amount);

    constructor(address _token) Ownable(msg.sender) {
        require(_token != address(0), "Vesting: zero address");
        token = IERC20(_token);
    }

    /**
     * @notice Owner grants a vesting schedule to a beneficiary.
     *         Tokens must already be held by this contract.
     * @param  beneficiary  Address that will receive the vested tokens
     * @param  amount       Total NYT to vest (in wei)
     */
    function createGrant(address beneficiary, uint256 amount) external onlyOwner {
        require(beneficiary != address(0), "Vesting: zero address");
        require(amount > 0, "Vesting: zero amount");
        require(!schedules[beneficiary].initialized, "Vesting: already exists");

        // Contract must hold enough tokens to cover this grant PLUS all existing
        // uncommitted grants. Checking balanceOf alone allows over-commitment
        // because previously granted (but unclaimed) tokens are still in the contract.
        require(
            token.balanceOf(address(this)) >= totalCommitted + amount,
            "Vesting: insufficient balance for new grant"
        );

        totalCommitted += amount;

        schedules[beneficiary] = VestingSchedule({
            totalAmount:   amount,
            claimedAmount: 0,
            startTime:     block.timestamp,
            initialized:   true
        });

        beneficiaries.push(beneficiary);
        emit GrantCreated(beneficiary, amount, block.timestamp);
    }

    /**
     * @notice Beneficiary claims all currently available vested tokens.
     */
    function claim() external {
        VestingSchedule storage s = schedules[msg.sender];
        require(s.initialized, "Vesting: no grant");

        uint256 available = vestedAmount(msg.sender) - s.claimedAmount;
        require(available > 0, "Vesting: nothing to claim");

        s.claimedAmount += available;
        totalCommitted  -= available;
        token.transfer(msg.sender, available);

        emit Claimed(msg.sender, available);
    }

    /**
     * @notice Returns total tokens vested so far for a beneficiary (not necessarily claimed).
     */
    function vestedAmount(address beneficiary) public view returns (uint256) {
        VestingSchedule memory s = schedules[beneficiary];
        if (!s.initialized) return 0;

        uint256 elapsed = block.timestamp - s.startTime;

        // Before cliff: nothing
        if (elapsed < CLIFF_DURATION) return 0;

        // After cliff + full vest: everything
        if (elapsed >= CLIFF_DURATION + VEST_DURATION) return s.totalAmount;

        // Linear vesting between cliff and cliff+vest
        uint256 vestElapsed = elapsed - CLIFF_DURATION;
        return (s.totalAmount * vestElapsed) / VEST_DURATION;
    }

    /**
     * @notice Returns how much a beneficiary can claim right now.
     */
    function claimable(address beneficiary) external view returns (uint256) {
        VestingSchedule memory s = schedules[beneficiary];
        if (!s.initialized) return 0;
        uint256 vested = vestedAmount(beneficiary);
        return vested > s.claimedAmount ? vested - s.claimedAmount : 0;
    }

    /**
     * @notice Returns number of beneficiaries.
     */
    function beneficiaryCount() external view returns (uint256) {
        return beneficiaries.length;
    }
}
