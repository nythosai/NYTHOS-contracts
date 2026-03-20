// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title NYTPresale — NYTHOS Token Sale
 * @notice Handles three sale rounds:
 *   Round 0: PRIVATE  — $0.005 per NYT  (whitelist only)
 *   Round 1: PRESALE  — $0.008 per NYT  (whitelist + public)
 *   Round 2: PUBLIC   — $0.010 per NYT  (open to all)
 *
 *  Buyers pay in ETH. ETH/USD price is set by owner (updated periodically).
 *  Soft cap:  $100,000  — if not reached, buyers can refund
 *  Hard cap:  $245,000  — sale ends when hard cap is hit
 *
 *  After sale, owner calls finalize() to release ETH and unlock claims.
 *  Buyers call claim() to receive their NYT.
 */
contract NYTPresale is Ownable, ReentrancyGuard {

    IERC20 public immutable nyt;

    // ─── Sale rounds ──────────────────────────────────────────────────────────
    enum Round { PRIVATE, PRESALE, PUBLIC }

    struct RoundInfo {
        uint256 priceUSD;        // price in USD cents (e.g. 500 = $0.005)
        uint256 allocation;      // NYT allocated to this round (in wei)
        uint256 sold;            // NYT sold so far (in wei)
        bool    whitelistOnly;
    }

    RoundInfo[3] public rounds;
    Round public currentRound;
    bool  public saleOpen;
    bool  public finalized;
    bool  public softCapReached;

    // ─── Caps (in USD cents) ──────────────────────────────────────────────────
    uint256 public constant SOFT_CAP_USD = 100_000 * 100;   // $100,000
    uint256 public constant HARD_CAP_USD = 245_000 * 100;   // $245,000
    uint256 public raisedUSD;                                // total raised (USD cents)

    // ─── ETH price oracle (set by owner) ─────────────────────────────────────
    uint256 public ethPriceUSD;   // USD cents per ETH (e.g. 300000 = $3,000.00)

    // ─── Buyer records ────────────────────────────────────────────────────────
    mapping(address => uint256) public nytPurchased;   // total NYT bought
    mapping(address => uint256) public ethPaid;         // total ETH paid
    mapping(address => bool)    public whitelist;

    // ─── Events ───────────────────────────────────────────────────────────────
    event SaleOpened(Round round);
    event SaleClosed();
    event Purchase(address indexed buyer, uint256 ethAmount, uint256 nytAmount, Round round);
    event Claimed(address indexed buyer, uint256 amount);
    event Refunded(address indexed buyer, uint256 ethAmount);
    event Finalized(uint256 totalRaisedETH);
    event EthPriceUpdated(uint256 newPriceUSD);

    constructor(
        address _nyt,
        uint256 _initialEthPriceUSD  // in USD cents, e.g. 300000 for $3,000
    ) Ownable(msg.sender) {
        require(_nyt != address(0), "Presale: zero address");
        nyt = IERC20(_nyt);
        ethPriceUSD = _initialEthPriceUSD;

        // Private: $0.005, 20M NYT
        rounds[0] = RoundInfo({ priceUSD: 50, allocation: 20_000_000 * 1e18, sold: 0, whitelistOnly: true });
        // Presale: $0.008, 20M NYT
        rounds[1] = RoundInfo({ priceUSD: 80, allocation: 20_000_000 * 1e18, sold: 0, whitelistOnly: false });
        // Public:  $0.010, 20M NYT (remaining from presale allocation pool)
        rounds[2] = RoundInfo({ priceUSD: 100, allocation: 20_000_000 * 1e18, sold: 0, whitelistOnly: false });
    }

    // ─── Owner controls ───────────────────────────────────────────────────────

    function openRound(Round round) external onlyOwner {
        currentRound = round;
        saleOpen = true;
        emit SaleOpened(round);
    }

    function closeSale() external onlyOwner {
        saleOpen = false;
        emit SaleClosed();
    }

    function setEthPrice(uint256 _priceUSD) external onlyOwner {
        require(_priceUSD > 0, "Presale: zero price");
        ethPriceUSD = _priceUSD;
        emit EthPriceUpdated(_priceUSD);
    }

    function addToWhitelist(address[] calldata addrs) external onlyOwner {
        for (uint256 i = 0; i < addrs.length; i++) {
            whitelist[addrs[i]] = true;
        }
    }

    function removeFromWhitelist(address[] calldata addrs) external onlyOwner {
        for (uint256 i = 0; i < addrs.length; i++) {
            whitelist[addrs[i]] = false;
        }
    }

    /**
     * @notice Finalize the sale. Releases ETH to owner if soft cap reached.
     *         Must be called before buyers can claim.
     */
    function finalize() external onlyOwner {
        require(!finalized, "Presale: already finalized");
        saleOpen = false;
        finalized = true;

        if (raisedUSD >= SOFT_CAP_USD) {
            softCapReached = true;
            // Transfer all ETH to owner
            (bool ok, ) = owner().call{value: address(this).balance}("");
            require(ok, "Presale: ETH transfer failed");
        }
        // If soft cap NOT reached, ETH stays in contract so buyers can refund

        emit Finalized(address(this).balance);
    }

    // ─── Buy ──────────────────────────────────────────────────────────────────

    /**
     * @notice Buy NYT by sending ETH. Amount of NYT is calculated from
     *         current ETH price and round price.
     */
    function buy() external payable nonReentrant {
        require(saleOpen, "Presale: sale not open");
        require(!finalized, "Presale: finalized");
        require(msg.value > 0, "Presale: zero ETH");

        RoundInfo storage r = rounds[uint256(currentRound)];

        if (r.whitelistOnly) {
            require(whitelist[msg.sender], "Presale: not whitelisted");
        }

        // Calculate NYT amount
        // nytAmount = (ethPaid * ethPriceUSD) / priceUSD
        // All in consistent units: ethPriceUSD in USD cents, priceUSD in USD cents
        uint256 usdValue = (msg.value * ethPriceUSD) / 1e18;  // in USD cents
        uint256 nytAmount = (usdValue * 1e18) / r.priceUSD;

        // Cap at remaining round allocation
        uint256 remaining = r.allocation - r.sold;
        require(remaining > 0, "Presale: round sold out");
        if (nytAmount > remaining) {
            nytAmount = remaining;
            // Refund excess ETH
            uint256 excessUSD = ((nytAmount - remaining) * r.priceUSD) / 1e18;
            uint256 excessETH = (excessUSD * 1e18) / ethPriceUSD;
            (bool ok, ) = msg.sender.call{value: excessETH}("");
            require(ok, "Presale: refund failed");
        }

        // Cap at hard cap
        uint256 thisUSD = (nytAmount * r.priceUSD) / 1e18;
        require(raisedUSD + thisUSD <= HARD_CAP_USD, "Presale: hard cap reached");

        r.sold      += nytAmount;
        raisedUSD   += thisUSD;
        nytPurchased[msg.sender] += nytAmount;
        ethPaid[msg.sender]      += msg.value;

        // Auto-close when hard cap hit
        if (raisedUSD >= HARD_CAP_USD) {
            saleOpen = false;
            emit SaleClosed();
        }

        emit Purchase(msg.sender, msg.value, nytAmount, currentRound);
    }

    // ─── Claim ────────────────────────────────────────────────────────────────

    /**
     * @notice Buyer claims their NYT after the sale is finalized and soft cap reached.
     */
    function claim() external nonReentrant {
        require(finalized, "Presale: not finalized");
        require(softCapReached, "Presale: soft cap not reached, use refund()");

        uint256 amount = nytPurchased[msg.sender];
        require(amount > 0, "Presale: nothing to claim");

        nytPurchased[msg.sender] = 0;
        nyt.transfer(msg.sender, amount);

        emit Claimed(msg.sender, amount);
    }

    // ─── Refund (if soft cap not reached) ────────────────────────────────────

    /**
     * @notice If soft cap was not reached, buyers can refund their ETH.
     */
    function refund() external nonReentrant {
        require(finalized, "Presale: not finalized");
        require(!softCapReached, "Presale: soft cap reached, use claim()");

        uint256 amount = ethPaid[msg.sender];
        require(amount > 0, "Presale: nothing to refund");

        ethPaid[msg.sender] = 0;
        nytPurchased[msg.sender] = 0;

        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "Presale: refund failed");

        emit Refunded(msg.sender, amount);
    }

    // ─── View helpers ─────────────────────────────────────────────────────────

    function totalSold() external view returns (uint256) {
        return rounds[0].sold + rounds[1].sold + rounds[2].sold;
    }

    function raisedETH() external view returns (uint256) {
        return address(this).balance;
    }

    // Allow contract to receive ETH
    receive() external payable {}
}
