// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Factory, Lender} from "monolith/Factory.sol";
import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ICoinDAOFactory} from "periphery/interfaces/ICoinDAOFactory.sol";
import {IStakingRewards} from "periphery/interfaces/IStakingRewards.sol";
import {PersonalStakingHelper} from "periphery/PersonalStakingHelper.sol";
import {PersonalStakingHelperFactory} from "periphery/PersonalStakingHelperFactory.sol";
import {SwapRouterStub} from "test-helpers/SwapRouterStub.sol";

interface IRealCoinDAOFactory is ICoinDAOFactory {
    function deploymentsLength() external view returns (uint256);
}

interface ICoinDAOTestDeployer {
    function launch(address registry, address collateral, address feed, bool stakeVault) external returns (uint256);
    function createExistingMarket(address registry, address collateral, address feed) external returns (address);
    function attach(address registry, address lender) external returns (uint256);
}

// Only external collateral and its price feed are simulated. Token, lender,
// interest model, vault, governance system, rewards funder and pools are real.
contract IntegrationCollateral is ERC20 {
    constructor() ERC20("Collateral", "COL", 18) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract IntegrationFeed {
    uint8 public constant decimals = 18;

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 1e18, block.timestamp, block.timestamp, 1);
    }
}

contract PersonalStakingHelperIntegrationTest is Test {
    struct Market {
        uint256 id;
        Lender lender;
        IERC20 token;
        IERC4626 vault;
        IERC20 gov;
        IStakingRewards pool;
    }

    Factory internal monolith;
    IRealCoinDAOFactory internal registry;
    ICoinDAOTestDeployer internal deployer;
    PersonalStakingHelperFactory internal factory;
    IntegrationCollateral internal collateral;
    IntegrationFeed internal feed;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_000_000);
        monolith = new Factory(address(this), 1e15);
        collateral = new IntegrationCollateral();
        feed = new IntegrationFeed();

        // Static address array encodes exactly like CoinDAOFactory.Implementations.
        address[8] memory implementations = [
            _deployCoinDAOCode("GovToken"),
            _deployCoinDAOCode("StakedGovToken"),
            _deployCoinDAOCode("RevenueRouter"),
            _deployCoinDAOCode("StakingRewards"),
            _deployCoinDAOCode("StakingRewardsFunder"),
            _deployCoinDAOCode("CoinDAOVestingWallet"),
            _deployCoinDAOCode("CoinDAOGovernor"),
            _deployCoinDAOCode("CoinDAOTimelock")
        ];
        registry = IRealCoinDAOFactory(
            deployCode(_artifact("CoinDAOFactory"), abi.encode(address(monolith), address(this), implementations))
        );
        deployer = ICoinDAOTestDeployer(_deployCoinDAOCode("CoinDAOTestDeployer"));
        factory = PersonalStakingHelperFactory(
            deployCode(_artifact("PersonalStakingHelperFactory"), abi.encode(address(registry)))
        );
    }

    function test_FullLaunchDepositsEarnYieldAndGovAndExit() public {
        Market memory market = _launch(true);
        _borrowAndApprove(market, alice, 1000e18);
        _borrowAndApprove(market, bob, 2000e18);
        (PersonalStakingHelper a, uint256 aShares) = _deposit(market, alice, 500e18);
        (PersonalStakingHelper b, uint256 bShares) = _deposit(market, bob, 1000e18);
        assertNotEq(address(a), address(b));
        assertEq(aShares, 500e18 - 1e16);
        assertEq(bShares, 1000e18);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 quote = market.vault.previewRedeem(aShares);
        assertGt(quote, 500e18);
        uint256 earnedA = a.earned();
        uint256 earnedB = b.earned();
        assertGt(earnedA, 0);
        assertGt(earnedB, earnedA);
        uint256 remaining = aShares - aShares / 2;
        vm.prank(alice);
        a.withdraw(aShares / 2, true);
        assertEq(market.vault.balanceOf(alice), aShares / 2);
        assertEq(market.gov.balanceOf(alice), earnedA);
        assertEq(a.earned(), 0);
        assertEq(market.gov.balanceOf(bob), 0);
        uint256 tokenBefore = market.token.balanceOf(alice);
        quote = market.vault.previewRedeem(remaining);
        vm.prank(alice);
        assertEq(a.withdrawAndRedeem(remaining, quote, false), quote);
        assertEq(market.token.balanceOf(alice) - tokenBefore, quote);
        assertEq(a.stakedShares(), 0);
        assertEq(b.stakedShares(), bShares);
        vm.prank(bob);
        b.withdraw(bShares, true);
        assertEq(market.gov.balanceOf(bob), earnedB);
        assertEq(b.earned(), 0);
        assertEq(market.pool.balanceOf(address(b)), 0);

        (PersonalStakingHelper reused, uint256 added) = _deposit(market, alice, 10e18);
        assertEq(address(reused), address(a));
        assertEq(a.stakedShares(), added);
        _assertClean(market, a);
        _assertClean(market, b);
    }

    function test_ExistingSCoinStakeMigratesWithoutRedeemingOrMovingPastRewards() public {
        Market memory market = _launch(true);
        _borrowAndApprove(market, alice, 1000e18);
        vm.startPrank(alice);
        market.token.approve(address(market.vault), 500e18);
        uint256 shares = market.vault.deposit(500e18, alice);
        market.vault.approve(address(market.pool), shares);
        market.pool.stake(shares);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 oldReward = market.pool.earned(alice);
        assertGt(oldReward, 0);
        market.pool.withdraw(shares);
        uint256 supply = market.vault.totalSupply();
        uint256 coinBalance = market.token.balanceOf(alice);
        market.vault.approve(address(factory), shares);
        PersonalStakingHelper helper = factory.stake(market.id, shares);
        assertEq(helper.owner(), alice);
        assertEq(helper.stakedShares(), shares);
        assertEq(market.vault.totalSupply(), supply);
        assertEq(market.token.balanceOf(alice), coinBalance);
        assertEq(market.pool.earned(alice), oldReward);
        assertEq(helper.earned(), 0);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 newReward = helper.earned();
        assertGt(newReward, 0);
        helper.withdraw(shares, true);
        assertEq(market.vault.balanceOf(alice), shares);
        assertEq(market.gov.balanceOf(alice), newReward);
        market.pool.getReward();
        assertEq(market.gov.balanceOf(alice), oldReward + newReward);
        vm.stopPrank();
        _assertClean(market, helper);
    }

    function test_ZapIntoRealMarketEarnsYieldAndGovAndExits() public {
        Market memory market = _launch(true);
        _borrowAndApprove(market, bob, 1000e18);
        SwapRouterStub router = new SwapRouterStub();
        vm.prank(bob);
        market.token.transfer(address(router), 500e18);
        IntegrationCollateral input = new IntegrationCollateral();
        input.mint(alice, 100e18);
        address predicted = factory.predictHelper(market.id, alice);
        bytes memory data = abi.encodeCall(router.swap, (IERC20(address(input)), market.token, 100e18, 500e18, predicted));
        uint256 quote = market.vault.previewDeposit(500e18);
        vm.startPrank(alice);
        input.approve(address(factory), 100e18);
        (PersonalStakingHelper helper, uint256 shares) = factory.zapAndStake(
            market.id, IERC20(address(input)), 100e18, address(router), data, 500e18, quote
        );
        assertEq(address(helper), predicted);
        assertEq(router.caller(), predicted);
        assertEq(helper.owner(), alice);
        assertEq(helper.stakedShares(), shares);
        assertEq(shares, quote);
        assertEq(input.balanceOf(alice), 0);
        assertEq(input.allowance(predicted, address(router)), 0);
        assertEq(market.token.balanceOf(bob), 500e18);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        quote = market.vault.previewRedeem(shares);
        assertGt(quote, 500e18);
        uint256 reward = helper.earned();
        assertGt(reward, 0);
        assertEq(helper.withdrawAndRedeem(shares, quote, true), quote);
        assertEq(market.token.balanceOf(alice), quote);
        assertEq(market.gov.balanceOf(alice), reward);
        vm.stopPrank();
        _assertClean(market, helper);
    }

    function test_FutureDAOsKeepOneOwnersPositionsIsolated() public {
        Market memory first = _launch(true);
        _borrowAndApprove(first, alice, 1000e18);
        (PersonalStakingHelper a, uint256 firstShares) = _deposit(first, alice, 100e18);
        address implementation = address(factory.implementation());
        Market memory second = _launch(true);
        _borrowAndApprove(second, alice, 1000e18);
        (PersonalStakingHelper b, uint256 secondShares) = _deposit(second, alice, 200e18);
        assertNotEq(address(a), address(b));
        assertNotEq(address(first.token), address(second.token));
        assertNotEq(address(first.gov), address(second.gov));
        assertEq(address(factory.implementation()), implementation);
        assertEq(address(factory.helperOf(first.id, alice)), address(a));
        assertEq(address(factory.helperOf(second.id, alice)), address(b));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 firstReward = a.earned();
        uint256 secondReward = b.earned();
        assertGt(firstReward, 0);
        assertGt(secondReward, 0);
        uint256 quote = first.vault.previewRedeem(firstShares);
        vm.prank(alice);
        a.withdrawAndRedeem(firstShares, quote, true);
        assertEq(first.gov.balanceOf(alice), firstReward);
        assertEq(second.gov.balanceOf(alice), 0);
        assertEq(b.stakedShares(), secondShares);
        uint256 partialShares = secondShares / 2;
        quote = second.vault.previewRedeem(partialShares);
        vm.prank(alice);
        b.withdrawAndRedeem(partialShares, quote, true);
        assertEq(second.gov.balanceOf(alice), secondReward);
        assertEq(first.gov.balanceOf(alice), firstReward);
        assertEq(a.stakedShares(), 0);
        assertEq(b.stakedShares(), secondShares - partialShares);
        assertEq(b.earned(), 0);
        _assertClean(first, a);
        _assertClean(second, b);
    }

    function test_RealTokenStakingDAOClaimsStakesGovAndExits() public {
        Market memory market = _launch(false);
        assertEq(market.pool.stakingToken(), address(market.token));
        _borrowAndApprove(market, alice, 1000e18);
        uint256 balance = market.token.balanceOf(alice);
        (PersonalStakingHelper helper, uint256 amount) = _deposit(market, alice, 100e18);
        assertEq(amount, 100e18);
        assertEq(market.vault.totalSupply(), 0);
        _assertClaimAndStake(market, helper, alice);
        vm.prank(alice);
        helper.withdraw(amount, false);
        assertEq(market.token.balanceOf(alice), balance);
        assertEq(market.vault.totalSupply(), 0);
        assertEq(helper.stakedShares(), 0);
        _assertClean(market, helper);
    }

    function test_RealVaultStakingDAOClaimsAndStakesGovForOwner() public {
        Market memory market = _launch(true);
        _borrowAndApprove(market, alice, 1000e18);
        (PersonalStakingHelper helper, uint256 shares) = _deposit(market, alice, 100e18);
        _assertClaimAndStake(market, helper, alice);
        assertEq(helper.stakedShares(), shares);
        uint256 quote = market.vault.previewRedeem(shares);
        vm.prank(alice);
        helper.withdrawAndRedeem(shares, quote, false);
        assertEq(helper.stakedShares(), 0);
        _assertClean(market, helper);
    }

    function _assertClaimAndStake(Market memory market, PersonalStakingHelper helper, address who) internal {
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 reward = helper.earned();
        assertGt(reward, 0);
        address staker = registry.deployments(market.id).staker;
        assertEq(address(helper.govStaking()), staker);
        uint256 beforeBalance = IERC20(staker).balanceOf(who);
        vm.prank(who);
        assertEq(helper.claimAndStake(), reward);
        assertEq(IERC20(staker).balanceOf(who) - beforeBalance, reward);
        assertEq(IERC20(staker).balanceOf(address(helper)), 0);
        assertEq(market.gov.balanceOf(who), 0);
        assertEq(market.gov.balanceOf(address(helper)), 0);
        assertEq(market.gov.allowance(address(helper), staker), 0);
        assertEq(helper.earned(), 0);
    }

    function test_ExistingMarketAttachmentUsesCoinDAOId() public {
        // Leave one market without a DAO, so the two factories' indices differ.
        deployer.createExistingMarket(address(registry), address(collateral), address(feed));
        address lender = deployer.createExistingMarket(address(registry), address(collateral), address(feed));
        assertEq(monolith.deployments(1), lender);
        uint256 id = deployer.attach(address(registry), lender);
        assertEq(id, 0);
        Market memory market = _market(id);
        assertEq(address(market.lender), lender);
        _borrowAndApprove(market, alice, 1000e18);
        (PersonalStakingHelper helper, uint256 shares) = _deposit(market, alice, 100e18);
        assertEq(address(helper.vault()), address(market.vault));
        assertEq(address(helper.stakingRewards()), address(market.pool));
        assertEq(helper.stakedShares(), shares);
        uint256 quote = market.vault.previewRedeem(shares);
        vm.prank(alice);
        helper.withdrawAndRedeem(shares, quote, true);
        assertEq(helper.stakedShares(), 0);
        _assertClean(market, helper);
    }

    function _launch(bool stakeVault) internal returns (Market memory) {
        uint256 id = deployer.launch(address(registry), address(collateral), address(feed), stakeVault);
        return _market(id);
    }

    function _market(uint256 id) internal view returns (Market memory market) {
        ICoinDAOFactory.Deployment memory deployment = registry.deployments(id);
        market = Market(
            id,
            Lender(deployment.lender),
            IERC20(deployment.coin),
            IERC4626(deployment.vault),
            IERC20(deployment.govToken),
            IStakingRewards(deployment.coinStakingRewards)
        );
        assertEq(deployment.stakingToken, market.pool.stakingToken());
        assertEq(market.pool.rewardsToken(), address(market.gov));
        assertEq(market.vault.asset(), address(market.token));
        assertGt(market.gov.balanceOf(address(market.pool)), 0);
        assertTrue(monolith.isDeployed(address(market.lender)));
        assertEq(market.lender.operator(), deployment.revenueRouter);
    }

    function _borrowAndApprove(Market memory market, address who, uint256 amount) internal {
        collateral.mint(who, 10_000e18);
        vm.startPrank(who);
        collateral.approve(address(market.lender), type(uint256).max);
        market.lender.adjust(who, int256(10_000e18), int256(amount));
        market.token.approve(address(factory), type(uint256).max);
        vm.stopPrank();
        assertEq(market.token.balanceOf(who), amount);
    }

    function _deposit(Market memory market, address who, uint256 amount)
        internal
        returns (PersonalStakingHelper helper, uint256 shares)
    {
        uint256 quote =
            market.pool.stakingToken() == address(market.vault) ? market.vault.previewDeposit(amount) : amount;
        vm.prank(who);
        return factory.depositAndStake(market.id, amount, quote);
    }

    function _assertClean(Market memory market, PersonalStakingHelper helper) internal view {
        assertEq(market.token.balanceOf(address(helper)), 0);
        assertEq(market.vault.balanceOf(address(helper)), 0);
        assertEq(market.token.allowance(address(helper), address(market.vault)), 0);
        assertEq(market.vault.allowance(address(helper), address(market.pool)), 0);
        assertEq(market.token.balanceOf(address(factory)), 0);
        assertEq(market.vault.balanceOf(address(factory)), 0);
    }

    function _deployCoinDAOCode(string memory name) internal returns (address) {
        return deployCode(_artifact(name));
    }

    function _artifact(string memory name) internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/../../out/", name, ".sol/", name, ".json");
    }
}
