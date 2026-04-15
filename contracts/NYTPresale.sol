// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title NYTPresale - NYTHOS Early Access Sale
 * @notice Handles three sale rounds using the legacy enum names kept for
 *         frontend and test compatibility:
 *   Round 0: founder / strategic allowlist  - $0.005 per NYT
 *   Round 1: early access round             - $0.008 per NYT
 *   Round 2: public access round            - $0.010 per NYT
 *
 *  Buyers pay in ETH. ETH/USD price is set by owner (updated periodically).
 *  Soft cap:  $100,000  - if not reached, buyers can refund
 *  Hard cap:  $219,000  - sale ends when hard cap is hit
 *             ($25,000 founder + $104,000 early access + $90,000 public)
 *
 *  After sale, owner calls finalize() to release ETH and unlock claims.
 *  Buyers call claim() to receive their NYT.
 */
contract NYTPresale is Ownable, Pausable, ReentrancyGuard {

    IERC20 public immutable nyt;

    // ─── Sale rounds ──────────────────────────────────────────────────────────
    // Legacy enum names are kept to avoid breaking existing integrations.
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
    uint256 public constant HARD_CAP_USD = 219_000 * 100;   // $219,000
    uint256 public raisedUSD;                                // total raised (USD cents)
    uint256 public raisedETHTotal;                           // total ETH kept by sale after any refunds

    // ─── ETH price oracle ────────────────────────────────────────────────────
    // Primary: Chainlink ETH/USD feed (8 decimals → converted to USD cents)
    // Fallback: owner-set manual price, used only if Chainlink feed is stale (>2h)
    AggregatorV3Interface public immutable ethUsdFeed;
    uint256 public constant ORACLE_STALENESS = 2 hours;
    uint256 public ethPriceUSD;   // manual fallback price in USD cents (e.g. 300000 = $3,000.00)

    // ─── Per-wallet caps ─────────────────────────────────────────────────────
    // maxPerWallet[roundIndex] = max NYT a single wallet may buy in that round (in wei).
    // 0 means uncapped. Set by owner before or during a round.
    mapping(uint256 => uint256) public maxPerWallet;

    // ─── Buyer records ────────────────────────────────────────────────────────
    mapping(address => uint256) public nytPurchased;        // total unclaimed NYT bought
    mapping(address => uint256) public ethPaid;             // total ETH paid
    mapping(address => bool)    public whitelist;
    mapping(address => Round)   public buyerRound;          // latest round buyer participated in
    mapping(address => uint256[3]) private purchasedByRound;
    mapping(address => uint256[3]) private ethPaidByRound;
    uint256 public finalizedAt;                             // timestamp when finalize() was called

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
        address _ethUsdFeed,         // Chainlink ETH/USD feed address
        uint256 _initialEthPriceUSD  // manual fallback in USD cents, e.g. 300000 for $3,000
    ) Ownable(msg.sender) {
        require(_nyt        != address(0), "Presale: zero address");
        require(_ethUsdFeed != address(0), "Presale: zero oracle address");
        nyt        = IERC20(_nyt);
        ethUsdFeed = AggregatorV3Interface(_ethUsdFeed);
        ethPriceUSD = _initialEthPriceUSD;

        // Founder allowlist: $0.005, 5M NYT - whitelist only, $25,000 raise
        rounds[0] = RoundInfo({ priceUSD: 50,  allocation:  5_000_000 * 1e18, sold: 0, whitelistOnly: true  });
        // Early access:     $0.008, 13M NYT - $104,000 raise
        rounds[1] = RoundInfo({ priceUSD: 80,  allocation: 13_000_000 * 1e18, sold: 0, whitelistOnly: false });
        // Public access:    $0.010, 9M NYT - 30-day cliff before claim, $90,000 raise
        rounds[2] = RoundInfo({ priceUSD: 100, allocation:  9_000_000 * 1e18, sold: 0, whitelistOnly: false });
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

    /// @notice Pause halts buy(), claim(), and refund() - use in emergencies.
    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // Price bounds: $100 – $1,000,000 per ETH (in USD cents: 10000 – 100000000)
    uint256 public constant MIN_ETH_PRICE_USD = 10_000;      // $100
    uint256 public constant MAX_ETH_PRICE_USD = 100_000_000; // $1,000,000

    function setEthPrice(uint256 _priceUSD) external onlyOwner {
        require(_priceUSD >= MIN_ETH_PRICE_USD, "Presale: price too low");
        require(_priceUSD <= MAX_ETH_PRICE_USD, "Presale: price too high");
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
     * @notice Set the maximum NYT a single wallet may purchase in a given round.
     *         Pass 0 to remove the cap (uncapped).
     * @param  roundIndex  0 = Founder, 1 = Early Access, 2 = Public
     * @param  maxNYT      Max NYT in wei (e.g. 500_000 * 1e18 for 500k NYT)
     */
    function setMaxPerWallet(uint256 roundIndex, uint256 maxNYT) external onlyOwner {
        require(roundIndex < 3, "Presale: invalid round");
        maxPerWallet[roundIndex] = maxNYT;
    }

    /**
     * @notice Finalize the sale. Releases ETH to owner if soft cap reached.
     *         Must be called before buyers can claim.
     */
    function finalize() external onlyOwner {
        require(!finalized, "Presale: already finalized");
        saleOpen = false;
        finalized = true;

        finalizedAt = block.timestamp;
        uint256 totalRaisedETH = raisedETHTotal;

        if (raisedUSD >= SOFT_CAP_USD) {
            softCapReached = true;
            // Transfer all ETH to owner
            (bool ok, ) = owner().call{value: address(this).balance}("");
            require(ok, "Presale: ETH transfer failed");
        }
        // If soft cap NOT reached, ETH stays in contract so buyers can refund

        emit Finalized(totalRaisedETH);
    }

    // ─── ETH price resolution ─────────────────────────────────────────────────

    /**
     * @notice Returns ETH price in USD cents.
     *         Tries Chainlink first. Falls back to owner-set manual price if:
     *         - Chainlink answer is <= 0, or
     *         - Feed data is stale (updatedAt older than ORACLE_STALENESS)
     */
    function _getEthPrice() internal view returns (uint256) {
        try ethUsdFeed.latestRoundData() returns (
            uint80,
            int256  answer,
            uint256,
            uint256 updatedAt,
            uint80
        ) {
            if (answer > 0 && block.timestamp - updatedAt <= ORACLE_STALENESS) {
                // Chainlink feed uses 8 decimals. Convert to USD cents:
                // answer / 1e8 = price in USD → × 100 = price in cents
                return uint256(answer) / 1e6;
            }
        } catch {}
        // Fallback to owner-set price
        return ethPriceUSD;
    }

    // ─── Buy ──────────────────────────────────────────────────────────────────

    /**
     * @notice Buy NYT by sending ETH. ETH/USD rate is sourced from Chainlink
     *         with a manual fallback if the feed is stale.
     */
    function buy() external payable nonReentrant whenNotPaused {
        require(saleOpen, "Presale: sale not open");
        require(!finalized, "Presale: finalized");
        require(msg.value > 0, "Presale: zero ETH");

        RoundInfo storage r = rounds[uint256(currentRound)];

        if (r.whitelistOnly) {
            require(whitelist[msg.sender], "Presale: not whitelisted");
        }

        // Resolve ETH/USD price - Chainlink primary, manual fallback
        uint256 currentEthPrice = _getEthPrice();

        // Calculate NYT amount
        // currentEthPrice is in USD cents (e.g. 200000 = $2,000.00)
        // priceUSD is in units of $0.0001 (e.g. 50 = $0.005, 80 = $0.008, 100 = $0.010)
        // usdValue = ETH paid × ETH price → result in USD cents
        // nytAmount = usdValue (cents) × 100 / priceUSD ($0.0001 units) → in NYT wei
        //   factor of 100 converts from cents ($0.01) to $0.0001 units
        uint256 usdValue  = (msg.value * currentEthPrice) / 1e18;  // in USD cents
        uint256 nytAmount = (usdValue * 100 * 1e18) / r.priceUSD;

        // Cap at remaining round allocation
        uint256 remaining = r.allocation - r.sold;
        require(remaining > 0, "Presale: round sold out");

        uint256 actualETHPaid = msg.value; // track what buyer actually pays after any refund

        if (nytAmount > remaining) {
            // Save original amount BEFORE capping so we can calculate excess correctly
            uint256 originalNytAmount = nytAmount;
            nytAmount = remaining;

            // Excess NYT buyer can't receive → refund that portion of ETH
            uint256 excessNyt = originalNytAmount - nytAmount;
            // Inverse of nytAmount formula: excessETH = excessNyt × priceUSD / (currentEthPrice × 100)
            uint256 excessETH = (excessNyt * r.priceUSD) / (currentEthPrice * 100);
            if (excessETH > 0 && excessETH <= msg.value) {
                actualETHPaid = msg.value - excessETH;
                (bool ok, ) = msg.sender.call{value: excessETH}("");
                require(ok, "Presale: refund failed");
            }
        }

        // Cap at hard cap - thisUSD in cents = nytAmount × priceUSD / (1e18 × 100)
        uint256 thisUSD = (nytAmount * r.priceUSD) / (1e18 * 100);
        require(raisedUSD + thisUSD <= HARD_CAP_USD, "Presale: hard cap reached");

        // Enforce per-wallet cap (0 = uncapped)
        uint256 walletCap = maxPerWallet[uint256(currentRound)];
        if (walletCap > 0) {
            require(
                purchasedByRound[msg.sender][uint256(currentRound)] + nytAmount <= walletCap,
                "Presale: wallet cap exceeded"
            );
        }

        r.sold      += nytAmount;
        raisedUSD   += thisUSD;
        raisedETHTotal += actualETHPaid;
        nytPurchased[msg.sender] += nytAmount;
        ethPaid[msg.sender]      += actualETHPaid; // only track what was actually kept
        buyerRound[msg.sender]    = currentRound;  // latest round for compatibility
        purchasedByRound[msg.sender][uint256(currentRound)] += nytAmount;
        ethPaidByRound[msg.sender][uint256(currentRound)] += actualETHPaid;

        // Auto-close when hard cap hit
        if (raisedUSD >= HARD_CAP_USD) {
            saleOpen = false;
            emit SaleClosed();
        }

        emit Purchase(msg.sender, actualETHPaid, nytAmount, currentRound);
    }

    // ─── Claim ────────────────────────────────────────────────────────────────

    // Claim cliffs per round (measured from finalizedAt)
    // Round 0 (Founder):      90-day cliff - protects against immediate founder dumps
    // Round 1 (Early Access): 30-day cliff - short delay before early backers can sell
    // Round 2 (Public):       30-day cliff - same as early access for public buyers
    uint256 public constant FOUNDER_CLIFF = 90 days;
    uint256 public constant EARLY_CLIFF   = 30 days;
    uint256 public constant PUBLIC_CLIFF  = 30 days;

    /**
     * @notice Buyer claims their NYT after the sale is finalized and soft cap reached.
     *         Cliffs per round:
     *           Round 0 (Founder)      - 90 days after finalization
     *           Round 1 (Early Access) - 30 days after finalization
     *           Round 2 (Public)       - 30 days after finalization
     */
    function claim() external nonReentrant whenNotPaused {
        require(finalized, "Presale: not finalized");
        require(softCapReached, "Presale: soft cap not reached, use refund()");

        uint256 privateAmount = purchasedByRound[msg.sender][uint256(Round.PRIVATE)];
        uint256 earlyAmount   = purchasedByRound[msg.sender][uint256(Round.PRESALE)];
        uint256 publicAmount  = purchasedByRound[msg.sender][uint256(Round.PUBLIC)];

        bool founderUnlocked = block.timestamp >= finalizedAt + FOUNDER_CLIFF;
        bool earlyUnlocked   = block.timestamp >= finalizedAt + EARLY_CLIFF;
        bool publicUnlocked  = block.timestamp >= finalizedAt + PUBLIC_CLIFF;

        uint256 amount = 0;

        if (founderUnlocked && privateAmount > 0) {
            amount += privateAmount;
            purchasedByRound[msg.sender][uint256(Round.PRIVATE)] = 0;
        }
        if (earlyUnlocked && earlyAmount > 0) {
            amount += earlyAmount;
            purchasedByRound[msg.sender][uint256(Round.PRESALE)] = 0;
        }
        if (publicUnlocked && publicAmount > 0) {
            amount += publicAmount;
            purchasedByRound[msg.sender][uint256(Round.PUBLIC)] = 0;
        }

        require(amount > 0, "Presale: nothing claimable yet. Cliff not passed.");

        nytPurchased[msg.sender] -= amount;
        nyt.transfer(msg.sender, amount);

        emit Claimed(msg.sender, amount);
    }

    // ─── Refund (if soft cap not reached) ────────────────────────────────────

    /**
     * @notice If soft cap was not reached, buyers can refund their ETH.
     */
    function refund() external nonReentrant whenNotPaused {
        require(finalized, "Presale: not finalized");
        require(!softCapReached, "Presale: soft cap reached, use claim()");

        uint256 amount = ethPaid[msg.sender];
        require(amount > 0, "Presale: nothing to refund");

        ethPaid[msg.sender] = 0;
        nytPurchased[msg.sender] = 0;
        delete purchasedByRound[msg.sender];
        delete ethPaidByRound[msg.sender];

        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "Presale: refund failed");

        emit Refunded(msg.sender, amount);
    }

    // ─── View helpers ─────────────────────────────────────────────────────────

    function totalSold() external view returns (uint256) {
        return rounds[0].sold + rounds[1].sold + rounds[2].sold;
    }

    function raisedETH() external view returns (uint256) {
        return raisedETHTotal;
    }

    // Reject plain ETH transfers. Direct ETH sends bypass buy() and would
    // leave the sender with no tokens and no refund path (ethPaid stays 0).
    // Users must call buy() explicitly.
    receive() external payable {
        revert("Presale: use buy()");
    }
}
