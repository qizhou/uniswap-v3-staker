// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import './interfaces/IUniversalV3Staker.sol';
import './interfaces/IRewardCalculator.sol';
import './libraries/RewardMath.sol';
import './libraries/NFTPositionInfo.sol';
import './libraries/CumulativeFunction.sol';
import './libraries/UniversalIncentiveId.sol';

import '@openzeppelin/contracts/math/SafeMath.sol';

import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol';
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';
import '@uniswap/v3-core/contracts/interfaces/IERC20Minimal.sol';
import '@uniswap/v3-core/contracts/libraries/BitMath.sol';
import '@uniswap/v3-core/contracts/libraries/TickMath.sol';

import '@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol';
import '@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol';
import '@uniswap/v3-periphery/contracts/base/Multicall.sol';

/// @title Universal staking interface for Uniswap V3
contract UniversalV3Staker is IUniversalV3Staker, Multicall {
    using SafeMath for uint256;

    /// @notice Represents a staking incentive
    struct Incentive {
        uint256 totalRewardUnclaimed;
        uint96 numberOfStakes;
    }

    /// @notice Represents the deposit of a liquidity NFT
    struct Deposit {
        address owner;
        uint48 numberOfStakes;
        int24 tickLower;
        int24 tickUpper;
    }

    /// @notice Represents a staked liquidity NFT
    struct Stake {
        uint160 secondsPerLiquidityInsideInitialX128;
        uint96 liquidityNoOverflow;
        uint128 liquidityIfOverflow;
        // TODO: uint128 for struct packing?
        uint256 rewardDebt;
    }

    /// @inheritdoc IUniversalV3Staker
    IUniswapV3Factory public immutable override factory;
    /// @inheritdoc IUniversalV3Staker
    INonfungiblePositionManager public immutable override nonfungiblePositionManager;

    /// @inheritdoc IUniversalV3Staker
    uint256 public immutable override maxIncentiveStartLeadTime;
    /// @inheritdoc IUniversalV3Staker
    uint256 public immutable override maxIncentiveDuration;
    /// @inheritdoc IUniversalV3Staker
    uint256 public override rewardUpdatedAt;
    /// @inheritdoc IUniversalV3Staker
    int24 public override lastTick;

    /// @dev bytes32 refers to the return value of IncentiveId.compute
    mapping(bytes32 => Incentive) public override incentives;

    /// @dev deposits[tokenId] => Deposit
    mapping(uint256 => Deposit) public override deposits;

    /// @dev stakes[tokenId][incentiveHash] => Stake
    mapping(uint256 => mapping(bytes32 => Stake)) private _stakes;

    // @dev a constant used for cumulative function tree manipulation
    uint256 private immutable _cfNbits;
    // @dev unsigned tick => liquidity left boundary
    mapping(uint24 => CumulativeFunction.Node) private _cumulativeLiquidityLower;
    // @dev unsigned tick => liquidity right boundary
    mapping(uint24 => CumulativeFunction.Node) private _cumulativeLiquidityUpper;
    // @dev unsigned tick => accumulated rewards (shifted 64 bits to avoid underflow)
    mapping(uint24 => CumulativeFunction.Node) private _cumulativeAccumulatedRewardsX64;

    using CumulativeFunction for mapping(uint24 => CumulativeFunction.Node);

    /// @inheritdoc IUniversalV3Staker
    function stakes(uint256 tokenId, bytes32 incentiveId)
        public
        view
        override
        returns (
            uint160 secondsPerLiquidityInsideInitialX128,
            uint128 liquidity,
            uint256 rewardDebt
        )
    {
        Stake storage stake = _stakes[tokenId][incentiveId];
        secondsPerLiquidityInsideInitialX128 = stake.secondsPerLiquidityInsideInitialX128;
        liquidity = stake.liquidityNoOverflow;
        if (liquidity == type(uint96).max) {
            liquidity = stake.liquidityIfOverflow;
        }
        rewardDebt = stake.rewardDebt;
    }

    /// @inheritdoc IUniversalV3Staker
    /// @dev rewards[rewardToken][owner] => uint256
    mapping(IERC20Minimal => mapping(address => uint256)) public override rewards;

    /// @param _factory the Uniswap V3 factory
    /// @param _nonfungiblePositionManager the NFT position manager contract address
    /// @param _maxIncentiveStartLeadTime the max duration of an incentive in seconds
    /// @param _maxIncentiveDuration the max amount of seconds into the future the incentive startTime can be set
    constructor(
        IUniswapV3Factory _factory,
        INonfungiblePositionManager _nonfungiblePositionManager,
        uint256 _maxIncentiveStartLeadTime,
        uint256 _maxIncentiveDuration
    ) {
        factory = _factory;
        nonfungiblePositionManager = _nonfungiblePositionManager;
        maxIncentiveStartLeadTime = _maxIncentiveStartLeadTime;
        maxIncentiveDuration = _maxIncentiveDuration;

        // tick range inclusive
        // also add another zero-tick indicating `null` in cumulative function
        uint24 numTicks = uint24(TickMath.MAX_TICK - TickMath.MIN_TICK + 1 + 1);
        uint8 nbits = BitMath.mostSignificantBit(uint256(numTicks)) + 1;
        _cfNbits = uint256(nbits);
    }

    /// @inheritdoc IUniversalV3Staker
    function createIncentive(IncentiveKey memory key, uint256 reward) external override {
        require(reward > 0, 'UniswapV3Staker::createIncentive: reward must be positive');
        require(
            block.timestamp <= key.startTime,
            'UniswapV3Staker::createIncentive: start time must be now or in the future'
        );
        require(
            key.startTime - block.timestamp <= maxIncentiveStartLeadTime,
            'UniswapV3Staker::createIncentive: start time too far into future'
        );
        require(key.startTime < key.endTime, 'UniswapV3Staker::createIncentive: start time must be before end time');
        require(
            key.endTime - key.startTime <= maxIncentiveDuration,
            'UniswapV3Staker::createIncentive: incentive duration is too long'
        );

        bytes32 incentiveId = UniversalIncentiveId.compute(key);

        // totalRewardUnclaimed cannot decrease until key.startTime has passed, meaning this check is safe
        require(
            incentives[incentiveId].totalRewardUnclaimed == 0,
            'UniswapV3Staker::createIncentive: incentive already exists'
        );

        incentives[incentiveId] = Incentive({totalRewardUnclaimed: reward, numberOfStakes: 0});

        TransferHelper.safeTransferFrom(address(key.rewardToken), msg.sender, address(this), reward);

        emit IncentiveCreated(key.rewardToken, key.pool, key.startTime, key.endTime, key.refundee, reward);
    }

    /// @inheritdoc IUniversalV3Staker
    function endIncentive(IncentiveKey memory key) external override returns (uint256 refund) {
        require(block.timestamp >= key.endTime, 'UniswapV3Staker::endIncentive: cannot end incentive before end time');

        bytes32 incentiveId = UniversalIncentiveId.compute(key);
        Incentive storage incentive = incentives[incentiveId];

        refund = incentive.totalRewardUnclaimed;

        require(refund > 0, 'UniswapV3Staker::endIncentive: no refund available');
        require(
            incentive.numberOfStakes == 0,
            'UniswapV3Staker::endIncentive: cannot end incentive while deposits are staked'
        );

        // issue the refund
        incentive.totalRewardUnclaimed = 0;
        TransferHelper.safeTransfer(address(key.rewardToken), key.refundee, refund);

        emit IncentiveEnded(incentiveId, refund);
    }

    /// @inheritdoc IERC721Receiver
    function onERC721Received(
        address,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        require(
            msg.sender == address(nonfungiblePositionManager),
            'UniswapV3Staker::onERC721Received: not a univ3 nft'
        );

        (, , , , , int24 tickLower, int24 tickUpper, , , , , ) = nonfungiblePositionManager.positions(tokenId);

        deposits[tokenId] = Deposit({owner: from, numberOfStakes: 0, tickLower: tickLower, tickUpper: tickUpper});
        emit DepositTransferred(tokenId, address(0), from);

        if (data.length > 0) {
            if (data.length == 192) {
                _stakeToken(abi.decode(data, (IncentiveKey)), tokenId);
            } else {
                IncentiveKey[] memory keys = abi.decode(data, (IncentiveKey[]));
                for (uint256 i = 0; i < keys.length; i++) {
                    _stakeToken(keys[i], tokenId);
                }
            }
        }
        return this.onERC721Received.selector;
    }

    /// @inheritdoc IUniversalV3Staker
    function transferDeposit(uint256 tokenId, address to) external override {
        require(to != address(0), 'UniswapV3Staker::transferDeposit: invalid transfer recipient');
        address owner = deposits[tokenId].owner;
        require(owner == msg.sender, 'UniswapV3Staker::transferDeposit: can only be called by deposit owner');
        deposits[tokenId].owner = to;
        emit DepositTransferred(tokenId, owner, to);
    }

    /// @inheritdoc IUniversalV3Staker
    function withdrawToken(
        uint256 tokenId,
        address to,
        bytes memory data
    ) external override {
        Deposit memory deposit = deposits[tokenId];
        require(deposit.numberOfStakes == 0, 'UniswapV3Staker::withdrawToken: cannot withdraw token while staked');
        require(deposit.owner == msg.sender, 'UniswapV3Staker::withdrawToken: only owner can withdraw token');

        delete deposits[tokenId];
        emit DepositTransferred(tokenId, deposit.owner, address(0));

        nonfungiblePositionManager.safeTransferFrom(address(this), to, tokenId, data);
    }

    /// @inheritdoc IUniversalV3Staker
    function stakeToken(IncentiveKey memory key, uint256 tokenId) external override {
        require(deposits[tokenId].owner == msg.sender, 'UniswapV3Staker::stakeToken: only owner can stake token');

        _stakeToken(key, tokenId);
    }

    /// @inheritdoc IUniversalV3Staker
    function unstakeToken(IncentiveKey memory key, uint256 tokenId) external override {
        Deposit memory deposit = deposits[tokenId];
        // anyone can call unstakeToken if the block time is after the end time of the incentive
        if (block.timestamp < key.endTime) {
            require(
                deposit.owner == msg.sender,
                'UniswapV3Staker::unstakeToken: only owner can withdraw token before incentive end time'
            );
        }

        bytes32 incentiveId = UniversalIncentiveId.compute(key);

        (, uint128 liquidity, uint256 rewardDebt) = stakes(tokenId, incentiveId);

        require(liquidity != 0, 'UniswapV3Staker::unstakeToken: stake does not exist');

        (, int24 currentTick, , , , , ) = key.pool.slot0();
        _updatePrice(block.timestamp, currentTick, key.rewardCalc);

        Incentive storage incentive = incentives[incentiveId];

        deposits[tokenId].numberOfStakes--;
        incentive.numberOfStakes--;

        uint24 tickLowerShifted = uint24(deposit.tickLower - TickMath.MIN_TICK + 1);
        uint24 tickUpperShifted = uint24(deposit.tickUpper - TickMath.MIN_TICK + 1);
        uint256 latestReward = _calculateReward(liquidity, tickLowerShifted, tickUpperShifted);
        uint256 reward = latestReward.sub(rewardDebt);

        // reward is never greater than total reward unclaimed
        incentive.totalRewardUnclaimed -= reward;
        // this only overflows if a token has a total supply greater than type(uint256).max
        rewards[key.rewardToken][deposit.owner] += reward;

        Stake storage stake = _stakes[tokenId][incentiveId];
        delete stake.secondsPerLiquidityInsideInitialX128;
        delete stake.liquidityNoOverflow;
        if (liquidity >= type(uint96).max) delete stake.liquidityIfOverflow;

        // liquidity casting uint128 => uint208
        _cumulativeLiquidityLower.remove(_cfNbits, tickLowerShifted, uint208(liquidity));
        _cumulativeLiquidityUpper.remove(_cfNbits, tickUpperShifted, uint208(liquidity));
        emit TokenUnstaked(tokenId, incentiveId);
    }

    /// @inheritdoc IUniversalV3Staker
    function claimReward(
        IERC20Minimal rewardToken,
        address to,
        uint256 amountRequested
    ) external override returns (uint256 reward) {
        reward = rewards[rewardToken][msg.sender];
        if (amountRequested != 0 && amountRequested < reward) {
            reward = amountRequested;
        }

        rewards[rewardToken][msg.sender] -= reward;
        TransferHelper.safeTransfer(address(rewardToken), to, reward);

        emit RewardClaimed(to, reward);
    }

    /// @inheritdoc IUniversalV3Staker
    function getRewardInfo(IncentiveKey memory key, uint256 tokenId)
        external
        view
        override
        returns (uint256 reward, uint160)
    {
        (, int24 _currentTick, , , , , ) = key.pool.slot0();
        uint24 currentTick = uint24(_currentTick - TickMath.MIN_TICK + 1);

        uint128 liquidity;
        uint24 tickLowerShifted;
        uint24 tickUpperShifted;
        {
            uint256 rewardDebt;
            Deposit memory deposit = deposits[tokenId];
            (, liquidity, rewardDebt) = stakes(tokenId, UniversalIncentiveId.compute(key));
            require(liquidity > 0, 'UniswapV3Staker::getRewardInfo: stake does not exist');
            tickLowerShifted = uint24(deposit.tickLower - TickMath.MIN_TICK + 1);
            tickUpperShifted = uint24(deposit.tickUpper - TickMath.MIN_TICK + 1);
            reward = _calculateReward(liquidity, tickLowerShifted, tickUpperShifted).sub(rewardDebt);
        }

        if (currentTick >= tickLowerShifted && currentTick <= tickUpperShifted) {
            uint24 lastTickShifted = uint24(lastTick - TickMath.MIN_TICK + 1);
            uint208 liquidityLower = _cumulativeLiquidityLower.get(_cfNbits, lastTickShifted);
            uint208 liquidityUpper = _cumulativeLiquidityUpper.get(_cfNbits, lastTickShifted);
            uint208 totalLiq = liquidityLower - liquidityUpper;
            require(totalLiq <= liquidityLower, 'UniswapV3Staker::gerRewardInfo: overflow');
            uint256 calculatedRewards = key.rewardCalc.getRewards(rewardUpdatedAt + 1, block.timestamp);
            uint256 rewardShareX64 = calculatedRewards.mul(2**64).div(uint256(totalLiq));
            uint256 rewardX64 = uint256(liquidity).mul(rewardShareX64);
            reward = reward.add(rewardX64.div(2**64));
        }

        return (reward, 0);
    }

    /// @inheritdoc IUniversalV3Staker
    function updatePrice(IncentiveKey memory key) external override {
        require(block.timestamp >= key.startTime, 'UniswapV3Staker::updatePrice: incentive not started');
        require(block.timestamp < key.endTime, 'UniswapV3Staker::updatePrice: incentive ended');

        bytes32 incentiveId = UniversalIncentiveId.compute(key);
        require(
            incentives[incentiveId].totalRewardUnclaimed > 0,
            'UniswapV3Staker::updatePrice: non-existent incentive'
        );

        (, int24 currentTick, , , , , ) = key.pool.slot0();
        _updatePrice(block.timestamp, currentTick, key.rewardCalc);
    }

    /// @dev Update can be called either externally or through staking / unstaking
    function _updatePrice(
        uint256 timestamp,
        int24 tick,
        IRewardCalculator rewardCalc
    ) private {
        require(timestamp >= rewardUpdatedAt, 'UniswapV3Staker::updatePrice: invalid timestamp');
        uint256 calculatedRewards = rewardCalc.getRewards(rewardUpdatedAt + 1, timestamp);
        if (calculatedRewards == 0) return;

        rewardUpdatedAt = timestamp;
        // TODO: math check
        uint24 tickBeforeUpdate = uint24(lastTick - TickMath.MIN_TICK + 1);
        lastTick = tick;

        uint208 liquidityLower = _cumulativeLiquidityLower.get(_cfNbits, tickBeforeUpdate);
        uint208 liquidityUpper = _cumulativeLiquidityUpper.get(_cfNbits, tickBeforeUpdate);
        uint208 liquidity = liquidityLower - liquidityUpper;
        require(liquidity <= liquidityLower, 'UniswapV3Staker::updatePrice: overflow');
        if (liquidity == 0) return;

        // avoid underflow
        uint256 rewardShareX64 = calculatedRewards.mul(2**64).div(uint256(liquidity));
        require(uint256(uint208(rewardShareX64)) == rewardShareX64, 'UniswapV3Staker::updatePrice: casting');
        // i.e. using  208 - 64 = 144 bits to store shares, with the max to be  2 ^ 144 - 1 = ~10^43, thus 10^25 ether
        _cumulativeAccumulatedRewardsX64.add(_cfNbits, tickBeforeUpdate + 1, uint208(rewardShareX64));
    }

    /// @dev Stakes a deposited token without doing an ownership check
    function _stakeToken(IncentiveKey memory key, uint256 tokenId) private {
        require(block.timestamp >= key.startTime, 'UniswapV3Staker::stakeToken: incentive not started');
        require(block.timestamp < key.endTime, 'UniswapV3Staker::stakeToken: incentive ended');

        bytes32 incentiveId = UniversalIncentiveId.compute(key);

        require(
            incentives[incentiveId].totalRewardUnclaimed > 0,
            'UniswapV3Staker::stakeToken: non-existent incentive'
        );
        require(
            _stakes[tokenId][incentiveId].liquidityNoOverflow == 0,
            'UniswapV3Staker::stakeToken: token already staked'
        );

        (IUniswapV3Pool pool, int24 tickLower, int24 tickUpper, uint128 liquidity) =
            NFTPositionInfo.getPositionInfo(factory, nonfungiblePositionManager, tokenId);

        require(pool == key.pool, 'UniswapV3Staker::stakeToken: token pool is not the incentive pool');
        require(liquidity > 0, 'UniswapV3Staker::stakeToken: cannot stake token with 0 liquidity');

        (, int24 currentTick, , , , , ) = key.pool.slot0();
        _updatePrice(block.timestamp, currentTick, key.rewardCalc);

        deposits[tokenId].numberOfStakes++;
        incentives[incentiveId].numberOfStakes++;

        (, uint160 secondsPerLiquidityInsideX128, ) = pool.snapshotCumulativesInside(tickLower, tickUpper);

        uint24 tickLowerShifted = uint24(tickLower - TickMath.MIN_TICK + 1);
        uint24 tickUpperShifted = uint24(tickUpper - TickMath.MIN_TICK + 1);
        uint256 rewardDebt = _calculateReward(liquidity, tickLowerShifted, tickUpperShifted);
        if (liquidity >= type(uint96).max) {
            _stakes[tokenId][incentiveId] = Stake({
                secondsPerLiquidityInsideInitialX128: secondsPerLiquidityInsideX128,
                liquidityNoOverflow: type(uint96).max,
                liquidityIfOverflow: liquidity,
                rewardDebt: rewardDebt
            });
        } else {
            _stakes[tokenId][incentiveId] = Stake({
                secondsPerLiquidityInsideInitialX128: secondsPerLiquidityInsideX128,
                liquidityNoOverflow: uint96(liquidity),
                liquidityIfOverflow: 0,
                rewardDebt: rewardDebt
            });
        }

        // liquidity casting uint128 => uint208
        _cumulativeLiquidityLower.add(_cfNbits, tickLowerShifted, uint208(liquidity));
        _cumulativeLiquidityUpper.add(_cfNbits, tickUpperShifted, uint208(liquidity));

        emit TokenStaked(tokenId, incentiveId, liquidity);
    }

    // @dev Calculate reward based on cumulative function records
    function _calculateReward(
        uint128 liquidity,
        uint24 tickLowerShifted,
        uint24 tickUpperShifted
    ) private view returns (uint256 reward) {
        uint208 rshareLowerX64 = _cumulativeAccumulatedRewardsX64.get(_cfNbits, tickLowerShifted);
        uint208 rshareUpperX64 = _cumulativeAccumulatedRewardsX64.get(_cfNbits, tickUpperShifted);
        uint208 rshareX64 = rshareUpperX64 - rshareLowerX64;
        require(rshareX64 <= rshareUpperX64, 'UniswapV3Staker::calculateReward: sub overflow');
        uint256 rewardX64 = uint256(liquidity).mul(uint256(rshareX64));
        if (rewardX64 == 0) return 0;

        reward = rewardX64 >> 64;
    }
}
