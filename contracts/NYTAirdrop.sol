// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title NYTAirdrop - NYTHOS Community Airdrop
 * @notice Distributes NYT to a list of recipients in batches.
 *         Owner loads the recipient list and triggers distribution.
 *         Unclaimed tokens can be swept back after the claim window closes.
 *
 *  Flow:
 *   1. Owner calls batchAirdrop() with recipient addresses and amounts.
 *   2. Recipients call claim() to receive their NYT.
 *   3. After claimDeadline, owner calls sweep() to recover unclaimed tokens.
 */
contract NYTAirdrop is Ownable {

    IERC20 public immutable nyt;

    mapping(address => uint256) public allocation;  // NYT allocated to each recipient
    mapping(address => bool)    public claimed;     // whether they claimed

    uint256 public totalAllocated;
    uint256 public totalClaimed;
    uint256 public claimDeadline;  // unix timestamp, 0 = no deadline set yet

    // ─── Events ───────────────────────────────────────────────────────────────
    event AirdropSet(address indexed recipient, uint256 amount);
    event Claimed(address indexed recipient, uint256 amount);
    event Swept(uint256 amount);
    event DeadlineSet(uint256 deadline);

    constructor(address _nyt) Ownable(msg.sender) {
        require(_nyt != address(0), "Airdrop: zero address");
        nyt = IERC20(_nyt);
    }

    // ─── Owner functions ──────────────────────────────────────────────────────

    /**
     * @notice Load airdrop recipients and amounts in batches.
     *         Contract must hold enough NYT before this is called.
     * @param  recipients  Array of wallet addresses
     * @param  amounts     Corresponding NYT amounts (in wei)
     */
    function batchAirdrop(
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external onlyOwner {
        require(recipients.length == amounts.length, "Airdrop: length mismatch");
        require(recipients.length > 0, "Airdrop: empty");

        for (uint256 i = 0; i < recipients.length; i++) {
            require(recipients[i] != address(0), "Airdrop: zero address");
            require(amounts[i] > 0, "Airdrop: zero amount");
            require(!claimed[recipients[i]], "Airdrop: already claimed");

            if (allocation[recipients[i]] == 0) {
                totalAllocated += amounts[i];
            } else {
                totalAllocated = totalAllocated - allocation[recipients[i]] + amounts[i];
            }

            allocation[recipients[i]] = amounts[i];
            emit AirdropSet(recipients[i], amounts[i]);
        }

        require(
            nyt.balanceOf(address(this)) >= totalAllocated - totalClaimed,
            "Airdrop: insufficient balance"
        );
    }

    /**
     * @notice Set the claim deadline. After this timestamp, sweep() can be called.
     * @param  _deadline  Unix timestamp (e.g. block.timestamp + 90 days)
     */
    function setClaimDeadline(uint256 _deadline) external onlyOwner {
        require(_deadline > block.timestamp, "Airdrop: deadline in past");
        claimDeadline = _deadline;
        emit DeadlineSet(_deadline);
    }

    /**
     * @notice After claim deadline, sweep unclaimed tokens back to owner.
     */
    function sweep() external onlyOwner {
        require(claimDeadline > 0, "Airdrop: no deadline set");
        require(block.timestamp > claimDeadline, "Airdrop: deadline not reached");

        uint256 balance = nyt.balanceOf(address(this));
        require(balance > 0, "Airdrop: nothing to sweep");

        nyt.transfer(owner(), balance);
        emit Swept(balance);
    }

    // ─── Claim ────────────────────────────────────────────────────────────────

    /**
     * @notice Recipient claims their airdrop allocation.
     */
    function claim() external {
        uint256 amount = allocation[msg.sender];
        require(amount > 0, "Airdrop: no allocation");
        require(!claimed[msg.sender], "Airdrop: already claimed");

        if (claimDeadline > 0) {
            require(block.timestamp <= claimDeadline, "Airdrop: claim window closed");
        }

        claimed[msg.sender] = true;
        totalClaimed += amount;

        nyt.transfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    // ─── View helpers ─────────────────────────────────────────────────────────

    function claimableAmount(address recipient) external view returns (uint256) {
        if (claimed[recipient]) return 0;
        return allocation[recipient];
    }

    function remainingUnclaimed() external view returns (uint256) {
        return totalAllocated - totalClaimed;
    }
}
