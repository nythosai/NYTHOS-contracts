// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title NYT — NYTHOS Token
 * @notice The governance and utility token of the NYTHOS AI platform.
 *         Total supply: 100,000,000 NYT (fixed, no minting after deploy).
 *
 *  Allocation (basis points, out of 10000):
 *   - Presale (private + IDO + public): 27%  → NYTPresale contract
 *   - Community Airdrop:                18%  → NYTAirdrop contract
 *   - Ecosystem & Rewards:              18%  → NYTStaking contract (staking reward pool)
 *   - Team (vested):                    15%  → NYTVesting contract
 *   - Liquidity Pool:                   15%  → liquidity wallet (for DEX launch)
 *   - Treasury:                          7%  → treasury wallet (audits, legal, ops)
 *
 *  Burn mechanism: 20% of platform revenue is used to buy NYT from the open
 *  market and burn it permanently. Supply only ever decreases after deploy.
 */
contract NYT is ERC20, ERC20Burnable, Ownable {

    // ─── Supply ───────────────────────────────────────────────────────────────
    uint256 public constant TOTAL_SUPPLY = 100_000_000 * 1e18;

    // ─── Allocation (basis points, must sum to 10000) ─────────────────────────
    uint256 public constant PRESALE_BP   = 2700;  // 27% — private + IDO + public sale
    uint256 public constant AIRDROP_BP   = 1800;  // 18% — community airdrop
    uint256 public constant ECOSYSTEM_BP = 1800;  // 18% — staking rewards + platform incentives
    uint256 public constant TEAM_BP      = 1500;  // 15% — team (1yr cliff, 2yr linear vest)
    uint256 public constant LIQUIDITY_BP = 1500;  // 15% — DEX liquidity (Aerodrome + Uniswap)
    uint256 public constant TREASURY_BP  =  700;  //  7% — audits, legal, emergency, ops

    // ─── Allocation recipients (set immutably at deploy) ─────────────────────
    address public immutable presaleContract;
    address public immutable airdropContract;
    address public immutable stakingContract;
    address public immutable teamVesting;
    address public immutable liquidityWallet;
    address public immutable treasuryWallet;

    // ─── Events ───────────────────────────────────────────────────────────────
    event TokensBurned(address indexed burner, uint256 amount);

    constructor(
        address _presaleContract,
        address _airdropContract,
        address _stakingContract,
        address _teamVesting,
        address _liquidityWallet,
        address _treasuryWallet
    ) ERC20("NYTHOS", "NYT") Ownable(msg.sender) {
        require(_presaleContract  != address(0), "NYT: zero address");
        require(_airdropContract  != address(0), "NYT: zero address");
        require(_stakingContract  != address(0), "NYT: zero address");
        require(_teamVesting      != address(0), "NYT: zero address");
        require(_liquidityWallet  != address(0), "NYT: zero address");
        require(_treasuryWallet   != address(0), "NYT: zero address");

        presaleContract  = _presaleContract;
        airdropContract  = _airdropContract;
        stakingContract  = _stakingContract;
        teamVesting      = _teamVesting;
        liquidityWallet  = _liquidityWallet;
        treasuryWallet   = _treasuryWallet;

        // Mint total supply and distribute in one shot at deployment
        _mint(_presaleContract,  (TOTAL_SUPPLY * PRESALE_BP)   / 10000);  // 27,000,000 NYT
        _mint(_airdropContract,  (TOTAL_SUPPLY * AIRDROP_BP)   / 10000);  // 18,000,000 NYT
        _mint(_stakingContract,  (TOTAL_SUPPLY * ECOSYSTEM_BP) / 10000);  // 18,000,000 NYT
        _mint(_teamVesting,      (TOTAL_SUPPLY * TEAM_BP)      / 10000);  // 15,000,000 NYT
        _mint(_liquidityWallet,  (TOTAL_SUPPLY * LIQUIDITY_BP) / 10000);  // 15,000,000 NYT
        _mint(_treasuryWallet,   (TOTAL_SUPPLY * TREASURY_BP)  / 10000);  //  7,000,000 NYT
    }

    /**
     * @notice Burns tokens from the caller's balance.
     *         Called by the revenue burn mechanism: platform buys NYT from DEX
     *         then calls this to permanently remove them from supply.
     */
    function burnTokens(uint256 amount) external {
        _burn(msg.sender, amount);
        emit TokensBurned(msg.sender, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }
}
