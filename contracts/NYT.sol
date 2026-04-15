// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title NYT - NYTHOS Token
 * @notice The planned utility and governance token of the NYTHOS platform.
 *         Total supply: 100,000,000 NYT (fixed, no minting after deploy).
 *         The full supply is minted to this contract at deployment, then
 *         distributed once to the live NYTHOS contract stack after the
 *         dependent contracts have been deployed.
 *
 *  Allocation (basis points, out of 10000):
 *   - Sale / access allocation:         27%  → NYTPresale contract
 *   - Community Airdrop:                18%  → NYTAirdrop contract
 *   - Ecosystem & Rewards:              18%  → NYTStaking contract (staking reward pool)
 *   - Team (vested):                    15%  → NYTVesting contract
 *   - Liquidity Pool:                   15%  → liquidity wallet (for DEX launch)
 *   - Treasury:                          7%  → treasury wallet (audits, legal, ops)
 *
 *  Burn support is built into the token contract. Any future buyback-and-burn
 *  policy is handled by the platform or treasury offchain, then executed here.
 */
contract NYT is ERC20, ERC20Burnable, Ownable {

    // ─── Supply ───────────────────────────────────────────────────────────────
    uint256 public constant TOTAL_SUPPLY = 100_000_000 * 1e18;

    // ─── Allocation (basis points, must sum to 10000) ─────────────────────────
    uint256 public constant PRESALE_BP   = 2700;  // 27% - founder, early, and public access allocation
    uint256 public constant AIRDROP_BP   = 1800;  // 18% - community airdrop
    uint256 public constant ECOSYSTEM_BP = 1800;  // 18% - staking rewards + platform incentives
    uint256 public constant TEAM_BP      = 1500;  // 15% - team (1yr cliff, 2yr linear vest)
    uint256 public constant LIQUIDITY_BP = 1500;  // 15% - DEX liquidity (Aerodrome + Uniswap)
    uint256 public constant TREASURY_BP  =  700;  //  7% - audits, legal, emergency, ops

    // ─── Allocation recipients ────────────────────────────────────────────────
    address public presaleContract;
    address public airdropContract;
    address public stakingContract;
    address public teamVesting;
    address public immutable liquidityWallet;
    address public immutable treasuryWallet;
    bool public allocationsInitialized;

    // ─── Events ───────────────────────────────────────────────────────────────
    event AllocationsInitialized(
        address indexed presaleContract,
        address indexed airdropContract,
        address indexed stakingContract,
        address teamVesting
    );
    event TokensBurned(address indexed burner, uint256 amount);

    constructor(
        address _liquidityWallet,
        address _treasuryWallet
    ) ERC20("NYTHOS", "NYT") Ownable(msg.sender) {
        require(_liquidityWallet  != address(0), "NYT: zero address");
        require(_treasuryWallet   != address(0), "NYT: zero address");

        liquidityWallet  = _liquidityWallet;
        treasuryWallet   = _treasuryWallet;

        // Mint the full supply into the token contract. The owner then
        // initializes the live NYTHOS recipients exactly once.
        _mint(address(this), TOTAL_SUPPLY);
    }

    /**
     * @notice Finalizes the live NYTHOS allocation map and distributes the
     *         full fixed supply once the dependent contracts are deployed.
     */
    function initializeAllocations(
        address _presaleContract,
        address _airdropContract,
        address _stakingContract,
        address _teamVesting
    ) external onlyOwner {
        require(!allocationsInitialized, "NYT: allocations already initialized");
        require(_presaleContract  != address(0), "NYT: zero address");
        require(_airdropContract  != address(0), "NYT: zero address");
        require(_stakingContract  != address(0), "NYT: zero address");
        require(_teamVesting      != address(0), "NYT: zero address");

        presaleContract  = _presaleContract;
        airdropContract  = _airdropContract;
        stakingContract  = _stakingContract;
        teamVesting      = _teamVesting;
        allocationsInitialized = true;

        _transfer(address(this), _presaleContract,  (TOTAL_SUPPLY * PRESALE_BP)   / 10000);  // 27,000,000 NYT
        _transfer(address(this), _airdropContract,  (TOTAL_SUPPLY * AIRDROP_BP)   / 10000);  // 18,000,000 NYT
        _transfer(address(this), _stakingContract,  (TOTAL_SUPPLY * ECOSYSTEM_BP) / 10000);  // 18,000,000 NYT
        _transfer(address(this), _teamVesting,      (TOTAL_SUPPLY * TEAM_BP)      / 10000);  // 15,000,000 NYT
        _transfer(address(this), liquidityWallet,   (TOTAL_SUPPLY * LIQUIDITY_BP) / 10000);  // 15,000,000 NYT
        _transfer(address(this), treasuryWallet,    (TOTAL_SUPPLY * TREASURY_BP)  / 10000);  //  7,000,000 NYT

        emit AllocationsInitialized(_presaleContract, _airdropContract, _stakingContract, _teamVesting);
    }

    /**
     * @notice Burns tokens from the caller's balance.
     *         Can be used by treasury or market buyback workflows to
     *         permanently remove NYT from circulation.
     */
    function burnTokens(uint256 amount) external {
        _burn(msg.sender, amount);
        emit TokensBurned(msg.sender, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }
}
