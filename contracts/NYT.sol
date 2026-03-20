// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title NYT — NYTHOS Token
 * @notice The governance and utility token of the NYTHOS AI platform.
 *         Total supply: 100,000,000 NYT (fixed).
 *         Burn mechanism: owner can burn tokens from the treasury to reduce supply.
 *         No minting after deployment — supply only goes down.
 */
contract NYT is ERC20, ERC20Burnable, Ownable {

    // ─── Token Distribution ───────────────────────────────────────────────────
    uint256 public constant TOTAL_SUPPLY     = 100_000_000 * 1e18;

    // Allocation percentages (basis points, out of 10000)
    uint256 public constant PRESALE_BP       = 4000;  // 40% — private + presale + public
    uint256 public constant STAKING_BP       = 2000;  // 20% — staking rewards pool
    uint256 public constant TEAM_BP          = 1500;  // 15% — team (vested)
    uint256 public constant LIQUIDITY_BP     = 1000;  // 10% — DEX liquidity
    uint256 public constant ECOSYSTEM_BP     =  800;  //  8% — ecosystem / grants
    uint256 public constant MARKETING_BP     =  500;  //  5% — marketing / community
    uint256 public constant AIRDROP_BP       =  200;  //  2% — airdrop

    // ─── Addresses to receive allocations at deploy ───────────────────────────
    address public immutable presaleContract;
    address public immutable stakingContract;
    address public immutable teamVesting;
    address public immutable liquidityWallet;
    address public immutable ecosystemWallet;
    address public immutable marketingWallet;
    address public immutable airdropWallet;

    // ─── Events ───────────────────────────────────────────────────────────────
    event TokensBurned(address indexed burner, uint256 amount);

    constructor(
        address _presaleContract,
        address _stakingContract,
        address _teamVesting,
        address _liquidityWallet,
        address _ecosystemWallet,
        address _marketingWallet,
        address _airdropWallet
    ) ERC20("NYTHOS", "NYT") Ownable(msg.sender) {
        require(_presaleContract  != address(0), "NYT: zero address");
        require(_stakingContract  != address(0), "NYT: zero address");
        require(_teamVesting      != address(0), "NYT: zero address");
        require(_liquidityWallet  != address(0), "NYT: zero address");
        require(_ecosystemWallet  != address(0), "NYT: zero address");
        require(_marketingWallet  != address(0), "NYT: zero address");
        require(_airdropWallet    != address(0), "NYT: zero address");

        presaleContract  = _presaleContract;
        stakingContract  = _stakingContract;
        teamVesting      = _teamVesting;
        liquidityWallet  = _liquidityWallet;
        ecosystemWallet  = _ecosystemWallet;
        marketingWallet  = _marketingWallet;
        airdropWallet    = _airdropWallet;

        // Mint total supply and distribute
        _mint(_presaleContract,  (TOTAL_SUPPLY * PRESALE_BP)   / 10000);
        _mint(_stakingContract,  (TOTAL_SUPPLY * STAKING_BP)   / 10000);
        _mint(_teamVesting,      (TOTAL_SUPPLY * TEAM_BP)      / 10000);
        _mint(_liquidityWallet,  (TOTAL_SUPPLY * LIQUIDITY_BP) / 10000);
        _mint(_ecosystemWallet,  (TOTAL_SUPPLY * ECOSYSTEM_BP) / 10000);
        _mint(_marketingWallet,  (TOTAL_SUPPLY * MARKETING_BP) / 10000);
        _mint(_airdropWallet,    (TOTAL_SUPPLY * AIRDROP_BP)   / 10000);
    }

    /**
     * @notice Burns tokens from the caller's balance (anyone can call).
     *         Used by the revenue burn mechanism: platform buys NYT then burns it.
     */
    function burnTokens(uint256 amount) external {
        _burn(msg.sender, amount);
        emit TokensBurned(msg.sender, amount);
    }

    // ─── View helpers ─────────────────────────────────────────────────────────

    function decimals() public pure override returns (uint8) {
        return 18;
    }
}
