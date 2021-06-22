// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

import '../interfaces/IRewardCalculator.sol';

contract TestRewardCalc is IRewardCalculator {
    function getRewards(uint256 startTime, uint256 endTime) external view override returns (uint256){
        return 1;
    }
}
