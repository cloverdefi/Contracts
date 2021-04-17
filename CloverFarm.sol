// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./Ownable.sol";
import "./SafeERC20.sol";
import "./EnumerableSet.sol";
import "./ReentrancyGuard.sol";

import "./IStrategy.sol";
import "./CloverToken.sol";

contract CloverFarm is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 shares; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.

        /**
         * We do some fancy math here. Basically, any point in time, the amount of Clover
         * entitled to a user but is pending to be distributed is:
         *
         *   amount = user.shares / sharesTotal * wantLockedTotal
         *   pending reward = (amount * pool.acccloverPerShare) - user.rewardDebt
         *
         * Whenever a user deposits or withdraws want tokens to a pool. Here's what happens:
         *   1. The pool's `acccloverPerShare` (and `lastRewardBlock`) gets updated.
         *   2. User receives the pending reward sent to his/her address.
         *   3. User's `amount` gets updated.
         *   4. User's `rewardDebt` gets updated.
         */
    }

    struct PoolInfo {
        IERC20 want; // Address of the want token.
        uint256 allocPoint; // How many allocation points assigned to this pool. Clover to distribute per block.
        uint256 lastRewardBlock; // Last block number that Clover distribution occurs.
        uint256 acccloverPerShare; // Accumulated Clover per share, times 1e18. See below.
        address strat; // Strategy address that will auto compound want tokens
    }

    // Token address
    CloverToken public clover;
    // Owner reward per block: 100% / ownerReward = 5%;
    uint256 public constant ownerReward = 20;
    // Max supply ever: 900k = 900000e18
    uint256 public constant maxSupply = 900000e18;
    // Clover per block: .09 per block
    uint256 public constant cloverPerBlock = 900000000000000068543270;
    uint256 public constant startBlock = 6854327; // https://bscscan.com/block/countdown/6854327

    PoolInfo[] public poolInfo; // Info of each pool.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo; // Info of each user that stakes LP tokens.
    uint256 public totalAllocPoint = 0; // Total allocation points. Must be the sum of all allocation points in all pools.

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    
    constructor(
        CloverToken _clover
    ) public {
        clover = _clover;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    /**
     * Add a new lp to the pool. Can only be called by the owner.
     * 
     */
    function addPool(uint256 _allocPoint, IERC20 _want, bool _withUpdate, address _strat) external onlyOwner nonReentrant {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(
            PoolInfo({
                want: _want,
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                acccloverPerShare: 0,
                strat: _strat
            })
        );
    }

    // Update the given pool's Clover allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) external onlyOwner nonReentrant {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        if (clover.maxSupply() >= maxSupply) {
            return 0;
        }
        return _to.sub(_from);
    }

    // View function to see pending Clover on frontend.
    function pendingclover(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 acccloverPerShare = pool.acccloverPerShare;
        uint256 sharesTotal = IStrategy(pool.strat).sharesTotal();
        if (block.number > pool.lastRewardBlock && sharesTotal != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 reward = multiplier
                .mul(cloverPerBlock)
                .mul(pool.allocPoint)
                .div(totalAllocPoint);
            acccloverPerShare = acccloverPerShare.add(
                reward.mul(1e18).div(sharesTotal)
            );
        }
        return user.shares.mul(acccloverPerShare).div(1e18).sub(user.rewardDebt);
    }

    // View function to see staked Want tokens on frontend.
    function stakedWantTokens(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        uint256 sharesTotal = IStrategy(pool.strat).sharesTotal();
        uint256 wantLockedTotal = IStrategy(poolInfo[_pid].strat).wantLockedTotal();
        if (sharesTotal == 0) {
            return 0;
        }
        return user.shares.mul(wantLockedTotal).div(sharesTotal);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public nonReentrant {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 sharesTotal = IStrategy(pool.strat).sharesTotal();
        if (sharesTotal == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        if (multiplier <= 0) {
            return;
        }
        uint256 reward = multiplier.mul(cloverPerBlock).mul(pool.allocPoint).div(totalAllocPoint);

        clover.mint(owner(), reward.div(ownerReward));
        clover.mint(address(this), reward);

        pool.acccloverPerShare = pool.acccloverPerShare.add(reward.mul(1e18).div(sharesTotal));
        pool.lastRewardBlock = block.number;
    }

    // Want tokens moved from user ->CloverFarm (Clover allocation) -> Strat (compounding)
    function deposit(uint256 _pid, uint256 _wantAmt) external {
        updatePool(_pid);
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        if (user.shares > 0) {
            uint256 pending = user.shares.mul(pool.acccloverPerShare).div(1e18).sub(user.rewardDebt);
            if (pending > 0) {
                safecloverTransfer(msg.sender, pending);
            }
        }
        if (_wantAmt > 0) {
            pool.want.safeTransferFrom(msg.sender, address(this), _wantAmt);

            pool.want.safeIncreaseAllowance(pool.strat, _wantAmt);
            uint256 sharesAdded = IStrategy(poolInfo[_pid].strat).deposit(msg.sender, _wantAmt);
            user.shares = user.shares.add(sharesAdded);
        }
        user.rewardDebt = user.shares.mul(pool.acccloverPerShare).div(1e18);
        emit Deposit(msg.sender, _pid, _wantAmt);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _wantAmt) public {
        updatePool(_pid);

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint256 wantLockedTotal = IStrategy(poolInfo[_pid].strat).wantLockedTotal();
        uint256 sharesTotal = IStrategy(poolInfo[_pid].strat).sharesTotal();

        require(user.shares > 0, "user.shares is 0");
        require(sharesTotal > 0, "sharesTotal is 0");

        // Withdraw pending Clover
        uint256 pending = user.shares.mul(pool.acccloverPerShare).div(1e18).sub(user.rewardDebt);
        
        if (pending > 0) {
            safecloverTransfer(msg.sender, pending);
        }

        // Withdraw want tokens
        uint256 amount = user.shares.mul(wantLockedTotal).div(sharesTotal);
        if (_wantAmt > amount) {
            _wantAmt = amount;
        }
        if (_wantAmt > 0) {
            uint256 sharesRemoved = IStrategy(poolInfo[_pid].strat).withdraw(msg.sender, _wantAmt);

            if (sharesRemoved > user.shares) {
                user.shares = 0;
            } else {
                user.shares = user.shares.sub(sharesRemoved);
            }

            uint256 wantBal = IERC20(pool.want).balanceOf(address(this));
            if (wantBal < _wantAmt) {
                _wantAmt = wantBal;
            }
            pool.want.safeTransfer(msg.sender, _wantAmt);
        }
        user.rewardDebt = user.shares.mul(pool.acccloverPerShare).div(1e18);
        emit Withdraw(msg.sender, _pid, _wantAmt);
    }

    // Withdraw everything from pool for yourself
    function withdrawAll(uint256 _pid) external {
        withdraw(_pid, uint256(-1));
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) external {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        
        uint256 wantLockedTotal = IStrategy(poolInfo[_pid].strat).wantLockedTotal();
        uint256 sharesTotal = IStrategy(poolInfo[_pid].strat).sharesTotal();
        uint256 amount = user.shares.mul(wantLockedTotal).div(sharesTotal);

        IStrategy(poolInfo[_pid].strat).withdraw(msg.sender, amount);

        pool.want.safeTransfer(msg.sender, amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
        user.shares = 0;
        user.rewardDebt = 0;
    }

    // Safe Clover transfer function, just in case if rounding error causes pool to not have enough
    function safecloverTransfer(address _to, uint256 _amt) internal {
        uint256 bal = clover.balanceOf(address(this));
        bool transferSuccess = false;
        if (_amt > bal) {
            transferSuccess = clover.transfer(_to, bal);
        } else {
            transferSuccess = clover.transfer(_to, _amt);
        }
        require(transferSuccess, "safecloverTransfer: transfer failed");
    }

    /** 
     *  Accidentally send your tokens to this address? We can help!
     *  Explicitly cannot call the only token stored in this contract, Clover
     */
    function inCaseTokensGetStuck(address _token, uint256 _amount) external onlyOwner {
        require(_token != address(clover), "!safe");
        IERC20(_token).safeTransfer(msg.sender, _amount);
    }
}