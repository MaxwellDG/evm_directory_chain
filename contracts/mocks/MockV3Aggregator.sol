// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";

/// @notice Test/local stand-in for a Chainlink price feed. Never deploy to a live network.
contract MockV3Aggregator is AggregatorV3Interface {
    uint8 public immutable override decimals;
    int256 public latestAnswer;
    uint256 public latestTimestamp;
    uint80 public latestRound;

    constructor(uint8 decimals_, int256 initialAnswer) {
        decimals = decimals_;
        updateAnswer(initialAnswer);
    }

    function updateAnswer(int256 answer) public {
        updateRoundData(latestRound + 1, answer, block.timestamp);
    }

    function updateRoundData(uint80 roundId, int256 answer, uint256 updatedAt) public {
        latestRound = roundId;
        latestAnswer = answer;
        latestTimestamp = updatedAt;
    }

    function description() external pure override returns (string memory) {
        return "MockV3Aggregator ETH / USD";
    }

    function version() external pure override returns (uint256) {
        return 4;
    }

    function getRoundData(uint80 roundId)
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (roundId, latestAnswer, latestTimestamp, latestTimestamp, roundId);
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (latestRound, latestAnswer, latestTimestamp, latestTimestamp, latestRound);
    }
}
