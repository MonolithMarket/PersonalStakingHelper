// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStakingRewards} from "./interfaces/IStakingRewards.sol";
import {ICoinDAOFactory} from "./interfaces/ICoinDAOFactory.sol";
import {PersonalStakingHelper} from "./PersonalStakingHelper.sol";

/// @notice Token or sToken staking for GOV rewards, with one helper per owner and CoinDAO.
/// @dev One fixed, trusted CoinDAOFactory registry. No admin or upgrade path.
contract PersonalStakingHelperFactory is ReentrancyGuard {
    using SafeERC20 for IERC20;

    ICoinDAOFactory public immutable coinDAOFactory;
    PersonalStakingHelper public immutable implementation;
    mapping(uint256 daoId => mapping(address owner => PersonalStakingHelper helper)) public helperOf;

    error InvalidFactory();
    error InvalidPair();
    error ZeroAmount();
    error ZeroAddress();

    event HelperCreated(uint256 indexed daoId, address indexed owner, address indexed helper);
    event DepositedAndStaked(
        uint256 indexed daoId, address indexed owner, address indexed helper, uint256 assets, uint256 shares
    );
    event Staked(uint256 indexed daoId, address indexed owner, address indexed helper, uint256 shares);

    constructor(ICoinDAOFactory coinDAOFactory_) {
        if (address(coinDAOFactory_).code.length == 0) revert InvalidFactory();
        coinDAOFactory = coinDAOFactory_;
        implementation = new PersonalStakingHelper();
    }

    /// @notice Approve this factory for Token, then deposit for your own address.
    function depositAndStake(uint256 daoId, uint256 assets, uint256 minShares)
        external
        returns (PersonalStakingHelper helper, uint256 shares)
    {
        return depositAndStake(daoId, assets, minShares, msg.sender);
    }

    /// @notice Deposits the caller's Token and stakes for the receiver's fixed helper.
    function depositAndStake(uint256 daoId, uint256 assets, uint256 minShares, address receiver)
        public
        nonReentrant
        returns (PersonalStakingHelper helper, uint256 shares)
    {
        if (assets == 0) revert ZeroAmount();

        helper = _getOrCreateHelper(daoId, receiver);
        helper.asset().safeTransferFrom(msg.sender, address(helper), assets);
        shares = helper.depositAndStake(assets, minShares);
        emit DepositedAndStaked(daoId, receiver, address(helper), assets, shares);
    }

    /// @notice Stakes existing sCoin, or Coin for direct-Coin pools, for the caller.
    function stake(uint256 daoId, uint256 shares) external returns (PersonalStakingHelper helper) {
        return stake(daoId, shares, msg.sender);
    }

    /// @notice Stakes the caller's pool tokens for the receiver's fixed helper.
    function stake(uint256 daoId, uint256 shares, address receiver) public nonReentrant returns (PersonalStakingHelper helper) {
        if (shares == 0) revert ZeroAmount();
        helper = _getOrCreateHelper(daoId, receiver);
        IERC20(helper.stakingRewards().stakingToken()).safeTransferFrom(msg.sender, address(helper), shares);
        helper.stake(shares);
        emit Staked(daoId, receiver, address(helper), shares);
    }

    /// @notice Swaps the caller's ERC20 input into Coin and stakes through their helper.
    function zapAndStake(
        uint256 daoId, IERC20 tokenIn, uint256 amountIn, address aggregator, bytes calldata data, uint256 minCoinOut, uint256 minShares
    ) external nonReentrant returns (PersonalStakingHelper helper, uint256 shares) {
        if (amountIn == 0) revert ZeroAmount();
        helper = _getOrCreateHelper(daoId, msg.sender);
        tokenIn.safeTransferFrom(msg.sender, address(helper), amountIn);
        shares = helper.zapAndStake(tokenIn, amountIn, aggregator, data, minCoinOut, minShares);
        emit Staked(daoId, msg.sender, address(helper), shares);
    }

    /// @notice Quote recipient for aggregator calldata, including before the first deposit.
    function predictHelper(uint256 daoId, address owner) external view returns (address) {
        return Clones.predictDeterministicAddress(address(implementation), keccak256(abi.encode(daoId, owner)), address(this));
    }

    function _getOrCreateHelper(uint256 daoId, address owner) private returns (PersonalStakingHelper helper) {
        if (owner == address(0)) revert ZeroAddress();
        helper = helperOf[daoId][owner];
        if (address(helper) == address(0)) {
            ICoinDAOFactory.Deployment memory deployment = coinDAOFactory.deployments(daoId);
            if (deployment.vault == address(0)) revert InvalidPair();
            if (deployment.stakingToken != deployment.vault && deployment.stakingToken != deployment.coin) revert InvalidPair();
            helper = PersonalStakingHelper(
                Clones.cloneDeterministic(address(implementation), keccak256(abi.encode(daoId, owner)))
            );
            helper.initialize(
                owner, IERC4626(deployment.vault), IStakingRewards(deployment.coinStakingRewards), deployment.staker
            );
            helperOf[daoId][owner] = helper;
            emit HelperCreated(daoId, owner, address(helper));
        }
    }
}
