// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// Minimal interface to call burnTokens() on the NYT contract
interface INYTBurnable is IERC20 {
    function burnTokens(uint256 amount) external;
}

/**
 * @title NYTStaking - NYTHOS Revenue Share Staking
 * @notice Stake NYT for a fixed duration to earn a share of platform revenue.
 *
 *  Tiers:
 *   30  days  → 12% APY, 1x  multiplier, min 100 NYT
 *   90  days  → 28% APY, 1.5x multiplier, min 500 NYT
 *   180 days  → 52% APY, 2x  multiplier, min 1,000 NYT
 *   365 days  → 100% APY, 3x multiplier, min 5,000 NYT
 *
 *  Rewards:
 *   - Owner deposits ETH into the reward pool (from platform revenue).
 *   - Each active stake earns an annualized share of the available reward pool
 *     based on its amount, lock multiplier, and tier APY target.
 *   - Early unstake incurs a 20% penalty on staked principal (penalty burned).
 *
 *  Note: APY is an annualized reward-share target, not a guaranteed fixed
 *  payout. Claims are always capped by the ETH currently available in the pool.
 */
contract NYTStaking is Ownable, Pausable, ReentrancyGuard {

    INYTBurnable public immutable nyt;

    // ─── Tiers ────────────────────────────────────────────────────────────────
    struct Tier {
        uint256 duration;     // in seconds
        uint256 apyBP;        // APY in basis points (12% = 1200)
        uint256 multiplierBP; // multiplier in basis points (1x = 10000, 1.5x = 15000)
        uint256 minStake;     // minimum NYT (in wei)
    }

    Tier[4] public tiers;

    // ─── Stakes ───────────────────────────────────────────────────────────────
    struct Stake {
        uint256 amount;        // NYT staked (in wei)
        uint256 tierIndex;     // which tier
        uint256 startTime;     // when staked
        uint256 endTime;       // when lock expires
        uint256 lastClaim;     // last time rewards were claimed
        bool    active;
    }

    uint256 public nextStakeId;
    mapping(uint256 => Stake)   public stakes;
    mapping(address => uint256[]) public userStakes;  // stakeId list per user

    // ─── Revenue reward pool ──────────────────────────────────────────────────
    uint256 public rewardPool;            // ETH currently available in reward pool
    uint256 public totalWeightedStake;    // sum of (amount * multiplier) across all active stakes

    // Early unstake penalty
    uint256 public constant PENALTY_BP = 2000; // 20%

    // ─── Events ───────────────────────────────────────────────────────────────
    event Staked(address indexed user, uint256 stakeId, uint256 amount, uint256 tierIndex);
    event Unstaked(address indexed user, uint256 stakeId, uint256 returned, uint256 penalty);
    event RewardClaimed(address indexed user, uint256 stakeId, uint256 ethAmount);
    event RevenueDeposited(uint256 amount);

    constructor(address _nyt) Ownable(msg.sender) {
        require(_nyt != address(0), "Staking: zero address");
        nyt = INYTBurnable(_nyt);

        tiers[0] = Tier({ duration:  30 days, apyBP:  1200, multiplierBP: 10000, minStake:     100 * 1e18 });
        tiers[1] = Tier({ duration:  90 days, apyBP:  2800, multiplierBP: 15000, minStake:     500 * 1e18 });
        tiers[2] = Tier({ duration: 180 days, apyBP:  5200, multiplierBP: 20000, minStake:   1_000 * 1e18 });
        tiers[3] = Tier({ duration: 365 days, apyBP: 10000, multiplierBP: 30000, minStake:   5_000 * 1e18 });
    }

    // ─── Revenue deposit ──────────────────────────────────────────────────────

    /**
     * @notice Owner deposits ETH from platform revenue into the reward pool.
     */
    /// @notice Pause halts stake(), claimRewards(), and unstake() - use in emergencies.
    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function depositRevenue() external payable onlyOwner {
        require(msg.value > 0, "Staking: zero value");
        rewardPool += msg.value;
        emit RevenueDeposited(msg.value);
    }

    // ─── Stake ────────────────────────────────────────────────────────────────

    /**
     * @notice Stake NYT tokens for a chosen tier.
     * @param  amount     Amount of NYT to stake (in wei)
     * @param  tierIndex  0=30d, 1=90d, 2=180d, 3=365d
     */
    function stake(uint256 amount, uint256 tierIndex) external nonReentrant whenNotPaused {
        require(tierIndex < 4, "Staking: invalid tier");
        Tier memory t = tiers[tierIndex];
        require(amount >= t.minStake, "Staking: below minimum");

        nyt.transferFrom(msg.sender, address(this), amount);

        uint256 id = nextStakeId++;
        stakes[id] = Stake({
            amount:    amount,
            tierIndex: tierIndex,
            startTime: block.timestamp,
            endTime:   block.timestamp + t.duration,
            lastClaim: block.timestamp,
            active:    true
        });

        userStakes[msg.sender].push(id);

        // Update weighted total
        totalWeightedStake += (amount * t.multiplierBP) / 10000;

        emit Staked(msg.sender, id, amount, tierIndex);
    }

    // ─── Claim rewards ────────────────────────────────────────────────────────

    /**
     * @notice Claim accumulated ETH rewards for a stake.
     */
    function claimRewards(uint256 stakeId) external nonReentrant whenNotPaused {
        require(_isOwnerOfStake(msg.sender, stakeId), "Staking: not your stake");
        Stake storage s = stakes[stakeId];
        require(s.active, "Staking: not active");

        uint256 reward = _pendingReward(stakeId);
        require(reward > 0, "Staking: no rewards");
        require(rewardPool >= reward, "Staking: pool empty");

        s.lastClaim = block.timestamp;
        rewardPool -= reward;

        (bool ok, ) = msg.sender.call{value: reward}("");
        require(ok, "Staking: transfer failed");

        emit RewardClaimed(msg.sender, stakeId, reward);
    }

    // ─── Unstake ──────────────────────────────────────────────────────────────

    /**
     * @notice Unstake after lock expires. Claims remaining rewards automatically.
     */
    function unstake(uint256 stakeId) external nonReentrant whenNotPaused {
        require(_isOwnerOfStake(msg.sender, stakeId), "Staking: not your stake");
        Stake storage s = stakes[stakeId];
        require(s.active, "Staking: not active");

        bool early = block.timestamp < s.endTime;
        uint256 penalty = 0;
        uint256 returned = s.amount;

        if (early) {
            penalty  = (s.amount * PENALTY_BP) / 10000;
            returned = s.amount - penalty;
            // Burn penalty by calling burnTokens() on the NYT contract
            // This permanently removes the tokens from supply (deflationary)
            INYTBurnable(address(nyt)).burnTokens(penalty);
        }

        // Auto-claim pending rewards
        uint256 reward = _pendingReward(stakeId);
        if (reward > 0 && rewardPool >= reward) {
            rewardPool -= reward;
            (bool ok1, ) = msg.sender.call{value: reward}("");
            require(ok1, "Staking: reward transfer failed");
            emit RewardClaimed(msg.sender, stakeId, reward);
        }

        // Remove from weighted total
        Tier memory t = tiers[s.tierIndex];
        uint256 weight = (s.amount * t.multiplierBP) / 10000;
        totalWeightedStake = totalWeightedStake >= weight ? totalWeightedStake - weight : 0;

        s.active = false;

        nyt.transfer(msg.sender, returned);

        emit Unstaked(msg.sender, stakeId, returned, penalty);
    }

    // ─── View helpers ─────────────────────────────────────────────────────────

    function pendingReward(uint256 stakeId) external view returns (uint256) {
        return _pendingReward(stakeId);
    }

    function getUserStakes(address user) external view returns (uint256[] memory) {
        return userStakes[user];
    }

    function totalStakers() external view returns (uint256) {
        return nextStakeId;
    }

    // ─── Internal helpers ─────────────────────────────────────────────────────

    /**
     * @dev Calculates ETH reward owed since last claim.
     *      Formula:
     *      rewardPool * (tier APY) * (userWeight / totalWeight) * (elapsed / 365 days)
     *
     *      This keeps reward claims tied to available platform revenue while
     *      making the advertised APY tiers materially affect payouts.
     */
    function _pendingReward(uint256 stakeId) internal view returns (uint256) {
        Stake memory s = stakes[stakeId];
        if (!s.active || totalWeightedStake == 0 || rewardPool == 0) return 0;

        Tier memory t = tiers[s.tierIndex];
        uint256 userWeight = (s.amount * t.multiplierBP) / 10000;

        uint256 elapsed = block.timestamp - s.lastClaim;
        if (elapsed == 0) return 0;

        uint256 reward = (
            rewardPool
            * t.apyBP
            * userWeight
            * elapsed
        ) / (10000 * totalWeightedStake * 365 days);

        return reward > rewardPool ? rewardPool : reward;
    }

    function _isOwnerOfStake(address user, uint256 stakeId) internal view returns (bool) {
        uint256[] memory ids = userStakes[user];
        for (uint256 i = 0; i < ids.length; i++) {
            if (ids[i] == stakeId) return true;
        }
        return false;
    }

    function _totalActiveStaked() internal view returns (uint256 total) {
        for (uint256 i = 0; i < nextStakeId; i++) {
            if (stakes[i].active) total += stakes[i].amount;
        }
    }

    receive() external payable {
        rewardPool += msg.value;
    }
}
