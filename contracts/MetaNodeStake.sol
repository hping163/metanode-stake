// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/utils/math/Math.sol';
import '@openzeppelin/contracts/utils/Address.sol';

import '@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';

// 质押合约
contract MetaNodeStake is Initializable, UUPSUpgradeable, PausableUpgradeable, AccessControlUpgradeable {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using Address for address;

    // auth setting
    bytes32 public constant ADMIN_ROLE = keccak256('admin_role');
    bytes32 public constant UPGRADER_ROLE = keccak256('upgrader_role');

    // 质押合约数据结构
    struct Pool {
        address stTokenAddress; // 质押池中的代币地址
        uint256 poolWeight; // 质押池权重
        uint256 lastRewardBlock; // 上次更新奖励的块高
        uint256 accMetaNodePerST; // 每个质押代币的奖励数（会随着时间的推移而增加）
        uint256 stTokenAmount; // 质押池中的质押总数量
        uint256 minDepositAmount; // 质押池的最小质押金额
        uint256 unstakeLockedBlocks; // 解除质押的区块数，也就是质押后需要等待的区块数才能解除质押
    }

    // 用户数据结构
    struct User {
        uint256 stAmount; // 用户质押的质押代币数量
        uint256 finishedMetaNode; // 用户已解除质押的奖励数
        uint256 pendingMetaNode; // 用户待解除质押的奖励数
        UnstakeRequest[] requests; // 用户的解质押请求
    }

    // 解质押数据结构
    struct UnstakeRequest {
        uint256 amount; // 解质押的质押代币数量
        uint256 oncePaddingMetaNode; // 每次解质押后用户待领取的奖励数
        uint256 unlockBlocks; // 解质押的区块数，也就是质押后需要等待的区块数才能解除质押
    }

    // ==================授权升级=========================
    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    // ==================基本参数=========================\
    IERC20 public metaNodeToken; // MetaNode代币合约地址
    uint256 public startBlock; // 合约启动的块高
    uint256 public endBlock; // 合约结束的块高
    uint256 public rewardMetaNode; // 每个区块的奖励数量
    uint256 public totalPoolWeight; // 所有质押池的权重总和

    bool public stakePaused; // 质押是否暂停
    bool public unstakePaused; // 解除质押是否暂停
    bool public withdrawPaused; // 提取奖励是否暂停

    Pool[] public pools; // 质押池列表
    mapping(uint256 => mapping(address => User)) public userMapping; // 用户数据 poolId => 用户地址 => 用户数据
    mapping(address => bool) public tokenPoolMapping; // 代币池是否已创建

    // =====================event==========================
    event CreatePoolEvent(address stTokenAddress, uint256 lastRewardBlock, uint256 poolWeight, uint256 minDepositAmount, uint256 unstakeLockedBlocks);
    event StakeEvent(uint256 poolId, address user, uint256 amount);
    event UnstakeEvent(uint256 poolId, address user, uint256 amount);
    event WithdrawEvent(uint256 poolId, address user, uint256 amount);
    event UpdateAccMetaNodePerSTEvent(uint256 poolId, uint256 accMetaNodePerST, uint256 lastRewardBlock);

    // ====================修饰符==========================
    modifier checkPid(uint256 poolId) {
        require(poolId < pools.length, 'MetaNodeStake: poolId is not valid');
        _;
    }
    modifier whenStakeNotPaused() {
        require(!stakePaused, 'MetaNodeStake: stake is paused');
        _;
    }
    modifier whenUnstakeNotPaused() {
        require(!unstakePaused, 'MetaNodeStake: unstake is paused');
        _;
    }
    modifier whenWithdrawNotPaused() {
        require(!withdrawPaused, 'MetaNodeStake: withdraw is paused');
        _;
    }

    // ==================初始化===========================
    function initialize(IERC20 metaNodeToken_, uint256 startBlock_, uint256 endBlock_, uint256 rewardMetaNode_) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);

        metaNodeToken = metaNodeToken_;
        startBlock = startBlock_;
        endBlock = endBlock_;
        rewardMetaNode = rewardMetaNode_;
    }

    // ==================更新参数=========================
    function setMetaNodeToken(IERC20 metaNodeToken_) public onlyRole(ADMIN_ROLE) {
        metaNodeToken = metaNodeToken_;
    }
    function setStartBlock(uint256 startBlock_) public onlyRole(ADMIN_ROLE) {
        startBlock = startBlock_;
    }
    function setEndBlock(uint256 endBlock_) public onlyRole(ADMIN_ROLE) {
        endBlock = endBlock_;
    }
    function setRewardMetaNode(uint256 rewardMetaNode_) public onlyRole(ADMIN_ROLE) {
        rewardMetaNode = rewardMetaNode_;
    }
    function setStakePaused(bool stakePaused_) public onlyRole(ADMIN_ROLE) {
        stakePaused = stakePaused_;
    }
    function setUnstakePaused(bool unstakePaused_) public onlyRole(ADMIN_ROLE) {
        unstakePaused = unstakePaused_;
    }
    function setWithdrawPaused(bool withdrawPaused_) public onlyRole(ADMIN_ROLE) {
        withdrawPaused = withdrawPaused_;
    }

    // 创建质押池
    function createPool(address stTokenAddress, uint256 poolWeight, uint256 minDepositAmount, uint256 unstakeLockedBlocks) public onlyRole(ADMIN_ROLE) {
        require(stTokenAddress != address(0), 'MetaNodeStake: stTokenAddress is not valid');
        require(poolWeight > 0, 'MetaNodeStake: poolWeight is not valid');
        require(minDepositAmount > 0, 'MetaNodeStake: minDepositAmount is not valid');
        require(unstakeLockedBlocks > 0, 'MetaNodeStake: unstakeLockedBlocks is not valid');
        require(!tokenPoolMapping[stTokenAddress], 'MetaNodeStake: pool already exist');

        uint256 lastRewardBlock_ = block.number > startBlock ? block.number : startBlock;

        Pool memory pool = Pool({
            stTokenAddress: stTokenAddress,
            poolWeight: poolWeight,
            lastRewardBlock: lastRewardBlock_,
            accMetaNodePerST: 0,
            stTokenAmount: 0,
            minDepositAmount: minDepositAmount,
            unstakeLockedBlocks: unstakeLockedBlocks
        });
        totalPoolWeight += poolWeight;
        pools.push(pool);
        tokenPoolMapping[stTokenAddress] = true;
        emit CreatePoolEvent(stTokenAddress, lastRewardBlock_, poolWeight, minDepositAmount, unstakeLockedBlocks);
    }

    // 更新质押池数据
    function updatePool(uint256 poolId, address stTokenAddress, uint256 poolWeight, uint256 minDepositAmount, uint256 unstakeLockedBlocks) public onlyRole(ADMIN_ROLE) checkPid(poolId) {
        Pool storage pool = pools[poolId];
        pool.stTokenAddress = stTokenAddress;
        pool.poolWeight = poolWeight;
        pool.minDepositAmount = minDepositAmount;
        pool.unstakeLockedBlocks = unstakeLockedBlocks;
    }

    // 质押
    function stake(uint256 poolId, uint256 amount) public checkPid(poolId) whenStakeNotPaused {
        require(amount > 0, 'MetaNodeStake: amount is not valid');
        Pool storage pool = pools[poolId];
        require(amount >= pool.minDepositAmount, 'MetaNodeStake: amount is not enough');

        // 更新accMetaNodePerST
        _updateAccMetaNodePerST(poolId);

        IERC20(pool.stTokenAddress).approve(address(this), amount);
        IERC20(pool.stTokenAddress).safeTransferFrom(msg.sender, address(this), amount);

        User storage user = userMapping[poolId][msg.sender];
        user.stAmount += amount;
        pool.stTokenAmount += amount;
        emit StakeEvent(poolId, msg.sender, amount);
    }

    // 解除质押
    function unstake(uint256 poolId, uint256 amount) public checkPid(poolId) whenUnstakeNotPaused {
        require(amount > 0, 'MetaNodeStake: amount is not valid');
        Pool storage pool = pools[poolId];
        require(amount <= pool.stTokenAmount, 'MetaNodeStake: amount is not enough');

        // 更新accMetaNodePerST
        _updateAccMetaNodePerST(poolId);

        User storage user = userMapping[poolId][msg.sender];
        // 计算用户待解除质押的奖励数
        uint256 paddingMetaNode = Math.mulDiv(amount, pool.accMetaNodePerST, 1e18);
        if (paddingMetaNode > 0) {
            user.pendingMetaNode += paddingMetaNode;
        }

        user.stAmount -= amount;
        pool.stTokenAmount -= amount;

        UnstakeRequest memory request = UnstakeRequest({ amount: amount, oncePaddingMetaNode: paddingMetaNode, unlockBlocks: block.number + pool.unstakeLockedBlocks });
        user.requests.push(request);
        emit UnstakeEvent(poolId, msg.sender, amount);
    }

    // 领取奖励
    function withdraw(uint256 poolId) public checkPid(poolId) whenWithdrawNotPaused {
        Pool storage pool = pools[poolId];
        User storage user = userMapping[poolId][msg.sender];
        require(user.pendingMetaNode > 0, 'MetaNodeStake: pendingMetaNode is not valid');

        // 更新accMetaNodePerST
        _updateAccMetaNodePerST(poolId);

        uint256 totalWithdraw = 0;
        for (uint256 i = user.requests.length - 1; i >= 0; i--) {
            UnstakeRequest memory request = user.requests[i];
            if (request.unlockBlocks <= block.number) {
                // totalWithdraw += (request.amount * pool.accMetaNodePerST) / 1e18;
                totalWithdraw += request.oncePaddingMetaNode;
                // 最后一个赋值给当前元素,用于删除当前记录
                user.requests[i] = user.requests[user.requests.length - 1];
                user.requests.pop();
            }
        }
        if (totalWithdraw > 0) {
            user.pendingMetaNode -= totalWithdraw;
            IERC20(pool.stTokenAddress).safeTransfer(msg.sender, totalWithdraw);
        }
        emit WithdrawEvent(poolId, msg.sender, totalWithdraw);
    }

    // 计算奖励数
    function getRewardMetaNode(uint256 startBlockNumer, uint256 endBlockNumber) internal view returns (uint256) {
        require(startBlockNumer < endBlockNumber, 'MetaNodeStake: startBlockNumer is not valid');
        if (startBlockNumer < startBlock) {
            startBlockNumer = startBlock;
        }
        if (endBlockNumber > endBlock) {
            endBlockNumber = endBlock;
        }
        (bool success, uint256 rewardMetaNode_) = (endBlockNumber - startBlockNumer).tryMul(rewardMetaNode);
        require(success, 'MetaNodeStake: blockNumber is not valid');
        return rewardMetaNode_;
    }

    // 更新accMetaNodePerST
    function _updateAccMetaNodePerST(uint256 poolId) internal {
        require(poolId <= pools.length, 'MetaNodeStake: poolId is not valid');
        Pool storage pool = pools[poolId];
        if (block.number < pool.lastRewardBlock) {
            return;
        }
        // 计算出在此区块号区间的奖励数
        (bool success1, uint256 totalMetaNode) = getRewardMetaNode(pool.lastRewardBlock, block.number).tryMul(pool.poolWeight);
        require(success1, 'MetaNodeStake: metaNodeReward is not valid');

        // 计算当前质押池的权重对应的奖励数
        (bool success2, uint256 totalPoolMetaNode) = totalMetaNode.tryDiv(totalPoolWeight);
        require(success2, 'MetaNodeStake: metaNodeReward is not valid');

        if (pool.stTokenAmount > 0) {
            pool.accMetaNodePerST += (totalPoolMetaNode * 1e18) / pool.stTokenAmount;
        }

        pool.lastRewardBlock = block.number;
        emit UpdateAccMetaNodePerSTEvent(poolId, pool.accMetaNodePerST, pool.lastRewardBlock);
    }
}
