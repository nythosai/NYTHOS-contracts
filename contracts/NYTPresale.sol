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
 *  Hard cap:  $219,000  — sale ends when hard cap is hit
 *             ($25,000 private + $104,000 IDO + $90,000 public)
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
    uint256 public constant HARD_CAP_USD = 219_000 * 100;   // $219,000
    uint256 public raisedUSD;                                // total raised (USD cents)

    // ─── ETH price oracle (set by owner) ─────────────────────────────────────
    uint256 public ethPriceUSD;   // USD cents per ETH (e.g. 300000 = $3,000.00)

    // ─── Buyer records ────────────────────────────────────────────────────────
    mapping(address => uint256) public nytPurchased;       // total NYT bought
    mapping(address => uint256) public ethPaid;             // total ETH paid
    mapping(address => bool)    public whitelist;
    mapping(address => Round)   public buyerRound;          // which round buyer participated in
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
        uint256 _initialEthPriceUSD  // in USD cents, e.g. 300000 for $3,000
    ) Ownable(msg.sender) {
        require(_nyt != address(0), "Presale: zero address");
        nyt = IERC20(_nyt);
        ethPriceUSD = _initialEthPriceUSD;

        // Private: $0.005, 5M NYT  — whitelist only, $25,000 raise
        rounds[0] = RoundInfo({ priceUSD: 50,  allocation:  5_000_000 * 1e18, sold: 0, whitelistOnly: true  });
        // IDO:     $0.008, 13M NYT — Pinksale/Gempad, $104,000 raise
        rounds[1] = RoundInfo({ priceUSD: 80,  allocation: 13_000_000 * 1e18, sold: 0, whitelistOnly: false });
        // Public:  $0.010, 9M NYT  — 30-day cliff before claim, $90,000 raise
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
     * @notice Finalize the sale. Releases ETH to owner if soft cap reached.
     *         Must be called before buyers can claim.
     */
    function finalize() external onlyOwner {
        require(!finalized, "Presale: already finalized");
        saleOpen = false;
        finalized = true;

        finalizedAt = block.timestamp;

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
        // ethPriceUSD is in USD cents (e.g. 200000 = $2,000.00)
        // priceUSD is in units of $0.0001 (e.g. 50 = $0.005, 80 = $0.008, 100 = $0.010)
        // usdValue = ETH paid × ETH price → result in USD cents
        // nytAmount = usdValue (cents) × 100 / priceUSD ($0.0001 units) → in NYT wei
        //   factor of 100 converts from cents ($0.01) to $0.0001 units
        uint256 usdValue = (msg.value * ethPriceUSD) / 1e18;  // in USD cents
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
            // Inverse of nytAmount formula: excessETH = excessNyt × priceUSD / (ethPriceUSD × 100)
            uint256 excessETH = (excessNyt * r.priceUSD) / (ethPriceUSD * 100);
            if (excessETH > 0 && excessETH <= msg.value) {
                actualETHPaid = msg.value - excessETH;
                (bool ok, ) = msg.sender.call{value: excessETH}("");
                require(ok, "Presale: refund failed");
            }
        }

        // Cap at hard cap — thisUSD in cents = nytAmount × priceUSD / (1e18 × 100)
        uint256 thisUSD = (nytAmount * r.priceUSD) / (1e18 * 100);
        require(raisedUSD + thisUSD <= HARD_CAP_USD, "Presale: hard cap reached");

        r.sold      += nytAmount;
        raisedUSD   += thisUSD;
        nytPurchased[msg.sender] += nytAmount;
        ethPaid[msg.sender]      += actualETHPaid; // only track what was actually kept
        buyerRound[msg.sender]    = currentRound;  // record which round they bought in

        // Auto-close when hard cap hit
        if (raisedUSD >= HARD_CAP_USD) {
            saleOpen = false;
            emit SaleClosed();
        }

        emit Purchase(msg.sender, msg.value, nytAmount, currentRound);
    }

    // ─── Claim ────────────────────────────────────────────────────────────────

    // Public sale buyers must wait 30 days after finalization before claiming
    uint256 public constant PUBLIC_CLIFF = 30 days;

    /**
     * @notice Buyer claims their NYT after the sale is finalized and soft cap reached.
     *         Public sale (Round 2) buyers must wait 30 days after finalization.
     */
    function claim() external nonReentrant {
        require(finalized, "Presale: not finalized");
        require(softCapReached, "Presale: soft cap not reached, use refund()");

        // Enforce 30-day cliff for public sale buyers
        if (buyerRound[msg.sender] == Round.PUBLIC) {
            require(
                block.timestamp >= finalizedAt + PUBLIC_CLIFF,
                "Presale: 30-day cliff not yet passed"
            );
        }

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
