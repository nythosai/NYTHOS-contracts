// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Minimal Chainlink AggregatorV3 mock for local Hardhat testing only.
///      Returns a configurable price with a fresh updatedAt timestamp.
contract MockV3Aggregator {
    int256 private _answer;

    constructor(int256 initialAnswer) {
        _answer = initialAnswer;
    }

    /// @dev Set a new price (8-decimal format, e.g. 200000_00000000 for $2,000).
    function setAnswer(int256 newAnswer) external {
        _answer = newAnswer;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80  roundId,
            int256  answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80  answeredInRound
        )
    {
        return (1, _answer, block.timestamp, block.timestamp, 1);
    }
}
