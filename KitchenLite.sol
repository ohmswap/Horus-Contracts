// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;

import "./interfaces/IOwnable.sol";
import "./interfaces/IERC20.sol";

import "./libraries/SafeMath.sol";
import "./libraries/SafeERC20.sol";

import "./types/Ownable.sol";

interface ITreasury {
    function manage( address token, uint amount ) external;

    function deposit( uint _amount, address _token, uint _profit ) external returns ( uint send_ );

    function incurDebt( uint _amount, address _token ) external;

    function repayDebtWithReserve( uint _amount, address _token ) external;

    function repayDebtWithOHM( uint _amount ) external;
}

interface IStaking {
    function stake( uint _amount, address _recipient ) external returns ( bool );
    function claim ( address _recipient ) external;
    function unstake( uint _amount, bool _trigger ) external;
}

interface IRouter02 {
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB);
}

interface IwsOHM {
    function wOHMTosOHM( uint _amount ) external view returns ( uint );
    function sOHMTowOHM( uint _amount ) external view returns ( uint );
}

interface IOSX is IERC20 {
    function mint(address to, uint amount) external;
}

// The LP debt facility is the hearth of OhmieSwap. It allows users to borrow OHM against
// their sOHM, which removes the opportunity cost of unstaking and encourages them to LP.

contract KitchenLite is Ownable {
    
    using SafeERC20 for IERC20;
    using SafeERC20 for IOSX;
    using SafeMath for uint;

    /* ========== STRUCTS ========== */

    struct UserInfo {
        uint balance; // staked balance (wsOHM)
        uint last; // last balance (OHM)
        uint debt; // OHM borrowed
        uint lp; // How many LP tokens the user has created.
        uint rewardDebt; // Reward debt. See explanation below.
    }

    struct Info {
        uint balance; // total staked (in wsOHM)
        uint last; // last total balance (in OHM)
        uint debt; // total OHM borrowed
        uint ceiling; // debt ceiling
        uint lp; // total LP deposited
        IERC20 lpToken; // pool token
        uint accrued; // fees accrued (in wsOHM)
        uint rewardPerBlock; // OSX rewards per block
        uint lastRewardBlock; // last update
        uint accOSXPerShare; // accumulated OSX per share, times 1e12.
    }



    /* ========== STATE VARIABLES ========== */

    IwsOHM immutable wsOHM; // Used for conversions
    IERC20 immutable sOHM; // Collateral token
    address immutable OHM; // Debt token
    address immutable DAI; // Reserve token used
    IOSX immutable OSX; // Pair token

    IRouter02 immutable router; // Sushiswap router
    ITreasury immutable treasury; // Olympus treasury
    IStaking immutable staking; // Olympus staking

    mapping(address => UserInfo) public userInfo;

    Info public global; // fee info



    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _wsOHM,
        address _sOHM,
        address _OHM,
        address _DAI,
        address _OSX,
        address _LP,
        address _treasury,
        address _router,
        address _staking
    ) {
        require( _wsOHM != address(0));
        wsOHM = IwsOHM(_wsOHM);
        require( _sOHM != address(0));
        sOHM = IERC20(_sOHM);
        require( _OHM != address(0));
        OHM = _OHM;
        require( _DAI != address(0));
        DAI = _DAI;
        require( _OSX != address(0));
        OSX = IOSX(_OSX);
        require( _LP != address(0));
        global.lpToken = IERC20(_LP);
        require( _treasury != address(0));
        treasury = ITreasury(_treasury);
        require( _router != address(0));
        router = IRouter02(_router);
        require( _staking != address(0));
        staking = IStaking(_staking);
    }



    /* ========== MUTABLE FUNCTIONS ========== */

    // add sOHM collateral
    function add (uint amount) external {
        sOHM.safeTransferFrom(msg.sender, address(this), amount); 
        _updateCollateral(amount, true); 
    }

    // remove sOHM collateral
    function remove(uint amount) external {
        collectInterest(msg.sender);

        require(amount <= equity(msg.sender), "amount greater than equity");
        _updateCollateral(amount, false);

        sOHM.safeTransfer(msg.sender, amount);
    }

    // create position and deposit for OSX allocation
    function open (
        uint[] calldata args // [ohmDesired, ohmMin, osxDesired, osxMin, deadline]
    ) external returns (
        uint ohmAdded,
        uint osxAdded,
        uint liquidity
    ) {        
        OSX.safeTransferFrom(msg.sender, address(this), args[2]); // transfer paired token

        _borrow(args[0]); // leverage sOHM for OHM

        (ohmAdded, osxAdded, liquidity) = _openPosition(args);

        _updateRewards();
    }

    // args: [liquidity, ohmMin, osxMin, deadline]
    function close (uint[] calldata args) external returns (uint ohmRemoved, uint osxRemoved) {
        _updateRewards();

        (ohmRemoved, osxRemoved) = _closePosition(args);

        _settle(args[0], ohmRemoved);

        OSX.safeTransfer(msg.sender, osxRemoved);
    }

    // claim OSX rewards
    function harvest() external {
        _updateRewards();
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool() public {
        if (block.number <= global.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = global.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            global.lastRewardBlock = block.number;
            return;
        }
        uint256 reward = global.rewardPerBlock.mul(block.number.sub(global.lastRewardBlock));

        OSX.mint(_owner, reward.div(10));
        OSX.mint(address(this), reward);

        global.accOSXPerShare = global.accOSXPerShare.add(
            reward.mul(1e12).div(lpSupply)
        );
        global.lastRewardBlock = block.number;
    }

    // charge interest (only on collateral remove)
    function collectInterest(address user) public {
        UserInfo memory info = userInfo[user];
        uint balance = wsOHM.wOHMTosOHM(info.balance);
        uint growth = balance.sub(info.last);

        if (growth > 0) {
            uint interest = wsOHM.sOHMTowOHM(growth.div(30));
            uint newBalance = info.balance.sub(interest);

            userInfo[user].balance = newBalance;
            userInfo[user].last = wsOHM.wOHMTosOHM(newBalance);

            global.accrued = global.accrued.add(interest);
        }
    }



    /* ========== OWNABLE FUNCTIONS ========== */

    // collect interest fees from depositors
    function collect(address to) external onlyOwner() {
        if (global.accrued > 0) {
            sOHM.safeTransfer(to, wsOHM.wOHMTosOHM(global.accrued));
            global.balance = global.balance.sub(global.accrued);
            global.accrued = 0;
        }
    }

    // sets OSX reward per block
    function setRate(uint rewards) external onlyOwner() {
        updatePool();
        global.rewardPerBlock = rewards;
    }

    // sets debt ceiling for OHM borrowing
    function setCeiling(uint ceiling) external onlyOwner() {
        global.ceiling = ceiling;
    }



    /* ========== VIEW FUNCTIONS ========== */

    // sOHM minus borrowed OHM
    function equity(address user) public view returns (uint) {
        return wsOHM.wOHMTosOHM(userInfo[user].balance).sub(userInfo[user].debt);
    }

    // View function to see pending OSX on frontend.
    function pending (address _user) external view returns (uint) {
        uint256 accOSXPerShare = global.accOSXPerShare;
        uint256 lpSupply = global.lpToken.balanceOf(address(this));
        if (block.number > global.lastRewardBlock && lpSupply != 0) {
            uint reward = global.rewardPerBlock.mul(block.number.sub(global.lastRewardBlock));
            accOSXPerShare = accOSXPerShare.add(
                reward.mul(1e12).div(lpSupply)
            );
        }
        UserInfo storage user = userInfo[_user];
        return user.lp.mul(accOSXPerShare).div(1e12).sub(user.rewardDebt);
    }



    /* ========== INTERNAL FUNCTIONS ========== */

    // mint OHM against sOHM
    function _borrow (uint amount) internal {
        require(amount <= equity(msg.sender), "Amount greater than equity");
        require(global.debt.add(amount) <= global.ceiling, "Debt ceiling hit");

        userInfo[msg.sender].debt = userInfo[msg.sender].debt.add(amount);
        global.debt = global.debt.add(amount);

        amount = amount.mul(1e9);
        treasury.incurDebt(amount, DAI); // borrow backing

        IERC20(DAI).approve(address(treasury), amount);
        treasury.deposit(amount, DAI, 0); // mint new OHM with backing
    }

    // repay OHM debt
    function _settle (uint lp, uint ohmRemoved) internal {
        UserInfo memory user = userInfo[msg.sender];

        uint amount = user.debt.mul(lp).div(user.lp);
        if (amount > ohmRemoved) {
            sOHM.approve(address(staking), amount.sub(ohmRemoved));
            staking.unstake(amount.sub(ohmRemoved), false);
        } else if (amount < ohmRemoved) {
            uint profits = ohmRemoved.sub(amount);
            
            IERC20(OHM).approve(address(staking), profits);
            staking.stake(profits, address(this));
            staking.claim(address(this));
            
            _updateCollateral(profits, true);
        }

        IERC20(OHM).approve(address(treasury), amount);
        treasury.repayDebtWithOHM(amount);

        userInfo[msg.sender].debt = user.debt.sub(amount);
        global.debt = global.debt.sub(amount);
    }

    // adds liquidity and returns excess tokens
    function _openPosition (uint[] calldata args) internal returns (
        uint ohmAdded,
        uint osxAdded,
        uint liquidity
    ) {
        IERC20(OHM).approve(address(router), args[0]);
        OSX.approve(address(router), args[2]);

        (ohmAdded, osxAdded, liquidity) = // add liquidity
            router.addLiquidity(OHM, address(OSX), args[0], args[2], args[1], args[3], address(this), args[4]);

        userInfo[msg.sender].lp = userInfo[msg.sender].lp.add(liquidity);
        global.lp = global.lp.add(liquidity);

        _returnExcess(ohmAdded, args[0], osxAdded, args[2]); // return overflow
    }

    // removes liquidity
    function _closePosition (uint[] calldata args) internal returns (uint ohmRemoved, uint osxRemoved) {
        uint lp = userInfo[msg.sender].lp;
        require(lp >= args[0], "withdraw: not good");

        global.lpToken.approve(address(router), args[0]); // remove liquidity
        (ohmRemoved, osxRemoved) = router.removeLiquidity(OHM, address(OSX), args[0], args[1], args[2], address(this), args[3]);

        userInfo[msg.sender].lp = lp.sub(args[0]);
        global.lp = global.lp.sub(args[0]);
    }

    // Deposit LP tokens to MasterChef for OSX allocation.
    function _updateRewards() internal {
        UserInfo storage user = userInfo[msg.sender];
        updatePool();
        if (user.lp > 0) {
            uint reward =
                user.lp.mul(global.accOSXPerShare).div(1e12).sub(
                    user.rewardDebt
                );
            safeOSXTransfer(msg.sender, reward);
        }
        user.rewardDebt = user.lp.mul(global.accOSXPerShare).div(1e12);
    }

    // accounting to remove sOHM collateral
    function _updateCollateral(uint amount, bool addition) internal {
        uint staticAmount = wsOHM.sOHMTowOHM(amount);
        UserInfo memory info = userInfo[msg.sender];
        
        if (addition) {
            userInfo[msg.sender].balance = info.balance.add(staticAmount); // user info
            userInfo[msg.sender].last = info.last.add(amount);

            global.balance = global.balance.add(staticAmount); // global info
        } else {
            userInfo[msg.sender].balance = info.balance.sub(staticAmount); // user info
            userInfo[msg.sender].last = info.last.sub(amount);

            global.balance = global.balance.sub(staticAmount); // global info
        }
    }

    // return excess token if less than amount desired when adding liquidity
    function _returnExcess(uint amountOhm, uint desiredOHM, uint amountOSX, uint desiredOSX) internal {
        if (amountOhm < desiredOHM) {
            IERC20(OHM).approve(address(treasury), desiredOHM.sub(amountOhm));
            treasury.repayDebtWithOHM(desiredOHM.sub(amountOhm));
        }
        if (amountOSX < desiredOSX) {
            OSX.safeTransfer(msg.sender, desiredOSX.sub(amountOSX));
        }
    }

    // Safe OSX transfer function, just in case if rounding error causes pool to not have enough OSX.
    function safeOSXTransfer(address _to, uint256 _amount) internal {
        uint256 osxBal = OSX.balanceOf(address(this));
        if (_amount > osxBal) {
            OSX.transfer(_to, osxBal);
        } else {
            OSX.transfer(_to, _amount);
        }
    }
}