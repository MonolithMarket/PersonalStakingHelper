// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ICoinDAOFactory} from "../src/interfaces/ICoinDAOFactory.sol";
import {IYearnVaultRegistry} from "../src/interfaces/IYearnVaultRegistry.sol";
import {HelperFixture, PersonalStakingHelper, PersonalStakingHelperFactory} from "./HelperFixture.sol";
import {CompoundVaultFixture} from "./fixtures/YearnVaultFixtures.sol";

contract ClaimAndCompoundTest is HelperFixture {
    PersonalStakingHelper private helper;
    CompoundVaultFixture private compoundVault;

    function setUp() public override {
        super.setUp();
        (helper,) = deposit(alice, 100e18);
        compoundVault = new CompoundVaultFixture(gov);
        yearnRegistry.setVault(address(compoundVault), address(gov), 1);
    }

    function test_ClaimAndCompoundCreditsOwnerUsingOnlyNewRewards() public {
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 reward = helper.earned();
        gov.mint(address(helper), 5e18);
        assertEq(address(helper.yearnRegistry()), address(yearnRegistry));

        vm.prank(alice);
        assertEq(helper.claimAndCompound(compoundVault, reward), reward);

        assertEq(compoundVault.balanceOf(alice), reward);
        assertEq(compoundVault.balanceOf(address(helper)), 0);
        assertEq(gov.balanceOf(address(helper)), 5e18);
        assertEq(gov.allowance(address(helper), address(compoundVault)), 0);
        assertEq(helper.earned(), 0);
    }

    function test_FailedDepositRollsBackClaimAndRewardsRemainClaimable() public {
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 reward = helper.earned();
        uint256 poolBalance = gov.balanceOf(address(pool));
        compoundVault.setDepositLimit(0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, alice, reward, 0));
        helper.claimAndCompound(compoundVault, 1);

        assertEq(helper.earned(), reward);
        assertEq(gov.balanceOf(address(pool)), poolBalance);
        assertEq(gov.allowance(address(helper), address(compoundVault)), 0);
        assertEq(compoundVault.balanceOf(alice), 0);

        vm.prank(alice);
        assertEq(helper.claim(), reward);
        assertEq(gov.balanceOf(alice), reward);
    }

    function test_ClaimAndCompoundBelowMinimumRollsBackDepositAndClaim() public {
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 reward = helper.earned();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PersonalStakingHelper.InsufficientShares.selector, reward, reward + 1));
        helper.claimAndCompound(compoundVault, reward + 1);

        assertEq(helper.earned(), reward);
        assertEq(compoundVault.balanceOf(alice), 0);
    }

    function test_ClaimAndCompoundRejectsUnendorsedVaultAndWrongVaultType() public {
        CompoundVaultFixture unendorsed = new CompoundVaultFixture(gov);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 reward = helper.earned();

        vm.prank(alice);
        vm.expectRevert(PersonalStakingHelper.InvalidCompoundVault.selector);
        helper.claimAndCompound(unendorsed, 1);

        yearnRegistry.setVault(address(unendorsed), address(gov), 2);
        vm.prank(alice);
        vm.expectRevert(PersonalStakingHelper.InvalidCompoundVault.selector);
        helper.claimAndCompound(unendorsed, 1);

        assertEq(helper.earned(), reward);
    }

    function test_ClaimAndCompoundRejectsDifferentAssetEvenIfRegistryRecordMatches() public {
        CompoundVaultFixture wrongVault = new CompoundVaultFixture(token);
        yearnRegistry.setVault(address(wrongVault), address(gov), 1);

        vm.prank(alice);
        vm.expectRevert(PersonalStakingHelper.InvalidCompoundVault.selector);
        helper.claimAndCompound(wrongVault, 1);
    }

    function test_EmptyClaimSkipsDepositAndOnlyOwnerCanCompound() public {
        compoundVault.setDepositLimit(0);
        vm.prank(bob);
        vm.expectRevert(PersonalStakingHelper.OnlyOwner.selector);
        helper.claimAndCompound(compoundVault, 1);

        vm.prank(alice);
        assertEq(helper.claimAndCompound(compoundVault, 1), 0);
        assertEq(compoundVault.balanceOf(alice), 0);
    }

    function test_FactoryRejectsYearnRegistryWithoutCode() public {
        vm.expectRevert(PersonalStakingHelper.InvalidYearnRegistry.selector);
        new PersonalStakingHelperFactory(
            ICoinDAOFactory(address(coinDAOFactory)), address(this), IYearnVaultRegistry(bob)
        );
    }
}
