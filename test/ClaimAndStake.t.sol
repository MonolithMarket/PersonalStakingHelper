// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    HelperFixture,
    TestMarket,
    PersonalStakingHelper,
    PersonalStakingHelperFactory,
    CoinDAOFactoryRegistry,
    RevenueRouterStub,
    StakedGovToken
} from "./HelperFixture.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract ClaimAndStakeTest is HelperFixture {
    function test_ClaimAndStakeCreditsOwnerAndLeavesNoAllowance() public {
        (PersonalStakingHelper helper, uint256 shares) = deposit(alice, 100e18);
        StakedGovToken staker = StakedGovToken(address(helper.govStaking()));
        assertEq(address(staker.underlying()), address(gov));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 reward = helper.earned();
        gov.mint(address(helper), 5e18);
        vm.prank(alice);
        assertEq(helper.claimAndStake(), reward + 5e18);
        assertEq(staker.balanceOf(alice), reward + 5e18);
        assertEq(staker.balanceOf(address(helper)), 0);
        assertEq(gov.balanceOf(address(helper)), 0);
        assertEq(gov.balanceOf(alice), 0);
        assertEq(gov.allowance(address(helper), address(staker)), 0);
        assertEq(helper.stakedShares(), shares);
        assertEq(helper.earned(), 0);
        vm.prank(alice);
        staker.withdraw();
        assertEq(gov.balanceOf(alice), reward + 5e18);
    }

    function test_TokenPoolCanClaimStakeExitAndClaimAgain() public {
        (uint256 id, TestMarket memory direct) = createDAO("DirectToken", false);
        fundAndApprove(direct, alice, 100e18);
        (PersonalStakingHelper helper, uint256 amount) = depositIn(id, direct, alice, 100e18);
        StakedGovToken staker = StakedGovToken(address(helper.govStaking()));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 first = helper.earned();
        vm.prank(alice);
        helper.claimAndStake();
        assertEq(staker.balanceOf(alice), first);
        assertEq(direct.vault.totalSupply(), 0);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 second = helper.earned();
        vm.prank(alice);
        helper.withdraw(amount, false);
        vm.prank(alice);
        helper.claimAndStake();
        assertEq(staker.balanceOf(alice), first + second);
        assertEq(direct.token.balanceOf(alice), amount);
        assertEq(helper.stakedShares(), 0);
    }

    function test_FailedGovStakeRollsBackClaimAndPlainClaimStillWorks() public {
        (PersonalStakingHelper helper,) = deposit(alice, 100e18);
        StakedGovToken staker = StakedGovToken(address(helper.govStaking()));
        RevenueRouterStub(address(staker.revenueRouter())).setBlocked(true);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 reward = helper.earned();
        vm.prank(alice);
        vm.expectRevert("ROUTER_BLOCKED");
        helper.claimAndStake();
        assertEq(helper.earned(), reward);
        assertEq(gov.allowance(address(helper), address(staker)), 0);
        assertEq(staker.balanceOf(alice), 0);
        vm.prank(alice);
        assertEq(helper.claim(), reward);
        assertEq(gov.balanceOf(alice), reward);
    }

    function test_EmptyClaimSkipsGovStakingAndOnlyOwnerCanCall() public {
        (PersonalStakingHelper helper,) = deposit(alice, 100e18);
        StakedGovToken staker = StakedGovToken(address(helper.govStaking()));
        RevenueRouterStub router = RevenueRouterStub(address(staker.revenueRouter()));
        router.setBlocked(true);
        vm.prank(bob);
        vm.expectRevert(PersonalStakingHelper.OnlyOwner.selector);
        helper.claimAndStake();
        vm.prank(alice);
        assertEq(helper.claimAndStake(), 0);
        assertEq(router.calls(), 0);
    }

    function test_TokenPoolMinimumRollsBackAndCannotRedeemVaultShares() public {
        (uint256 id, TestMarket memory direct) = createDAO("DirectToken", false);
        fundAndApprove(direct, alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PersonalStakingHelper.InsufficientShares.selector, 100e18, 101e18));
        factory.depositAndStake(id, 100e18, 101e18);
        assertEq(address(factory.helperOf(id, alice)), address(0));
        assertEq(direct.token.balanceOf(alice), 100e18);
        (PersonalStakingHelper helper, uint256 amount) = depositIn(id, direct, alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(PersonalStakingHelper.NotVaultStaking.selector);
        helper.withdrawAndRedeem(amount, 0, false);
        assertEq(helper.stakedShares(), amount);
    }

    function test_SeparateUsersAndDAOsReceiveOnlyTheirOwnGovStake() public {
        (PersonalStakingHelper a,) = deposit(alice, 100e18);
        (PersonalStakingHelper b,) = deposit(bob, 200e18);
        (uint256 id, TestMarket memory direct) = createDAO("DirectToken", false);
        fundAndApprove(direct, alice, 100e18);
        (PersonalStakingHelper c,) = depositIn(id, direct, alice, 100e18);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 aReward = a.earned();
        uint256 bReward = b.earned();
        uint256 cReward = c.earned();
        vm.prank(alice);
        a.claimAndStake();
        vm.prank(alice);
        c.claimAndStake();
        StakedGovToken first = StakedGovToken(address(a.govStaking()));
        StakedGovToken second = StakedGovToken(address(c.govStaking()));
        assertEq(first.balanceOf(alice), aReward);
        assertEq(first.balanceOf(bob), 0);
        assertEq(second.balanceOf(alice), cReward);
        assertEq(second.balanceOf(bob), 0);
        assertEq(b.earned(), bReward);
    }

    function test_ClaimAndStakeRejectsAuthorizedOwnerReentrancy() public {
        (PersonalStakingHelper helper,) = deposit(alice, 100e18);
        // A token callback impersonates the authorized owner to exercise the guard.
        gov.mint(address(helper), 1e18);
        gov.setHook(address(helper), address(this), abi.encodeCall(this.reenter, (helper)));
        vm.prank(alice);
        helper.claimAndStake();
        assertTrue(gov.callbackSuccess());
    }

    function reenter(PersonalStakingHelper helper) external {
        vm.prank(helper.owner());
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        helper.claimAndStake();
    }

    function test_RegistryCannotSelectAnUnrelatedStakingToken() public {
        CoinDAOFactoryRegistry.Deployment memory deployment;
        deployment.coin = address(token);
        deployment.vault = address(vault);
        deployment.stakingToken = address(0xbeef);
        uint256 id = coinDAOFactory.addDeployment(deployment);
        vm.prank(alice);
        vm.expectRevert(PersonalStakingHelperFactory.InvalidPair.selector);
        factory.depositAndStake(id, 100e18, 1);
        assertEq(address(factory.helperOf(id, alice)), address(0));
    }
}
