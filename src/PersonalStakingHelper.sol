// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStakingRewards, IStakedGovToken} from "./interfaces/IStakingRewards.sol";

/// @notice One owner's position in a fixed Monolith vault and existing rewards pool.
/// @dev Each clone's owner and market are set once by the factory at creation.
contract PersonalStakingHelper is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable factory;
    IERC4626 public vault;
    IStakingRewards public stakingRewards;
    IStakedGovToken public govStaking;
    IERC20 public asset;
    IERC20 public rewardToken;
    address public owner;

    error OnlyFactory();
    error OnlyOwner();
    error AlreadyInitialized();
    error ZeroAddress();
    error ZeroAmount();
    error NotVaultStaking();
    error InsufficientShares(uint256 received, uint256 minimum);
    error InsufficientAssets(uint256 received, uint256 minimum);

    event DepositedAndStaked(uint256 assets, uint256 shares);
    event Withdrawn(uint256 shares);
    event WithdrawnAndRedeemed(uint256 shares, uint256 assets);
    event RewardClaimed(uint256 amount);
    event RewardStaked(uint256 amount);
    event TokenRecovered(address indexed token, uint256 amount);

    /// @dev Called only by the factory's constructor. Locks the implementation.
    constructor() {
        factory = msg.sender;
        owner = address(this);
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert OnlyFactory();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    /// @dev The factory creates and initializes each clone in the same call.
    function initialize(address owner_, IERC4626 vault_, IStakingRewards stakingRewards_, address govStaking_) external onlyFactory {
        if (owner != address(0)) revert AlreadyInitialized();
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        vault = vault_;
        stakingRewards = stakingRewards_;
        govStaking = IStakedGovToken(govStaking_);
        asset = IERC20(vault_.asset());
        rewardToken = IERC20(stakingRewards_.rewardsToken());
    }

    /// @notice Stakes Token directly, or deposits and stakes sToken, as configured by the DAO.
    /// @dev Existing/donated balances are excluded. There is no shared accounting.
    function depositAndStake(uint256 assets, uint256 minShares)
        external
        onlyFactory
        nonReentrant
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroAmount();
        IERC20 stakingToken = IERC20(stakingRewards.stakingToken());
        shares = assets;
        if (address(stakingToken) == address(vault)) {
            asset.forceApprove(address(vault), assets);
            shares = vault.deposit(assets, address(this));
            asset.forceApprove(address(vault), 0);
        }

        // Includes Monolith's first-deposit MIN_SHARES deduction.
        if (shares == 0 || shares < minShares) revert InsufficientShares(shares, minShares);
        _stake(stakingToken, shares);

        emit DepositedAndStaked(assets, shares);
    }

    /// @notice Stakes exactly the pool tokens just supplied by the factory.
    function stake(uint256 shares) external onlyFactory nonReentrant {
        if (shares == 0) revert ZeroAmount();
        _stake(IERC20(stakingRewards.stakingToken()), shares);
    }

    function _stake(IERC20 stakingToken, uint256 shares) private {
        stakingToken.forceApprove(address(stakingRewards), shares);
        stakingRewards.stake(shares);
        stakingToken.forceApprove(address(stakingRewards), 0);
    }

    /// @notice Claims GOV to the fixed owner, including any GOV sent here directly.
    function claim() external onlyOwner nonReentrant returns (uint256 amount) {
        return _claim();
    }

    /// @notice Claims and stakes all loose GOV for the fixed owner, including donated GOV.
    function claimAndStake() external onlyOwner nonReentrant returns (uint256 amount) {
        stakingRewards.getReward();
        amount = rewardToken.balanceOf(address(this));
        if (amount != 0) {
            rewardToken.forceApprove(address(govStaking), amount);
            govStaking.depositFor(owner, amount);
        }
        emit RewardStaked(amount);
    }

    /// @notice Unstakes the pool's Token or sToken to the owner and optionally claims GOV.
    /// @dev With claimRewards=false, GOV claims cannot block the withdrawal.
    function withdraw(uint256 shares, bool claimRewards) external onlyOwner nonReentrant {
        if (shares == 0) revert ZeroAmount();
        stakingRewards.withdraw(shares);
        IERC20(stakingRewards.stakingToken()).safeTransfer(owner, shares);
        emit Withdrawn(shares);
        if (claimRewards) _claim();
    }

    /// @notice Unstakes and redeems to Token for the owner and optionally claims GOV.
    /// @dev With claimRewards=false, GOV claims cannot block the withdrawal.
    function withdrawAndRedeem(uint256 shares, uint256 minAssets, bool claimRewards)
        external
        onlyOwner
        nonReentrant
        returns (uint256 assets)
    {
        if (stakingRewards.stakingToken() != address(vault)) revert NotVaultStaking();
        if (shares == 0) revert ZeroAmount();
        stakingRewards.withdraw(shares);
        assets = vault.redeem(shares, owner, address(this));
        if (assets < minAssets) revert InsufficientAssets(assets, minAssets);
        emit WithdrawnAndRedeemed(shares, assets);
        if (claimRewards) _claim();
    }

    function _claim() private returns (uint256 amount) {
        stakingRewards.getReward();
        amount = rewardToken.balanceOf(address(this));
        if (amount != 0) rewardToken.safeTransfer(owner, amount);
        emit RewardClaimed(amount);
    }

    /// @notice Recovers loose tokens to the owner. Cannot withdraw the staked position.
    function recoverToken(IERC20 token) external onlyOwner nonReentrant returns (uint256 amount) {
        amount = token.balanceOf(address(this));
        if (amount != 0) token.safeTransfer(owner, amount);
        emit TokenRecovered(address(token), amount);
    }

    function stakedShares() external view returns (uint256) {
        return stakingRewards.balanceOf(address(this));
    }

    function earned() external view returns (uint256) {
        return stakingRewards.earned(address(this));
    }
}
