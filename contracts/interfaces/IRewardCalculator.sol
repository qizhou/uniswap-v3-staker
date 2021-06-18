// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

interface IRewardCalculator {
    /// @notice Calculates rewards based on time frame
    function getRewards(uint256 startTime, uint256 endTime) external view returns (uint256);
}
