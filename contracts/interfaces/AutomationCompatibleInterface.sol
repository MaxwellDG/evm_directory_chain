// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Minimal copy of Chainlink Automation's AutomationCompatibleInterface
/// Source: smartcontractkit/chainlink, contracts/src/v0.8/automation/interfaces.
interface AutomationCompatibleInterface {
    function checkUpkeep(bytes calldata checkData) external returns (bool upkeepNeeded, bytes memory performData);

    function performUpkeep(bytes calldata performData) external;
}
