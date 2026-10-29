// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    HelperFixture,
    TestMarket,
    PersonalStakingHelper,
    PersonalStakingHelperFactory,
    ICoinDAOFactory,
    IStakingRewards,
    CoinDAOFactoryRegistry
} from "./HelperFixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract GeneralizedStakingHelperTest is HelperFixture {
    event HelperCreated(uint256 indexed daoId, address indexed owner, address indexed helper);
    event DepositedAndStaked(uint256 indexed daoId, address indexed owner, address indexed helper, uint256 assets, uint256 shares);
    event Staked(uint256 indexed daoId, address indexed owner, address indexed helper, uint256 shares);

    function _existingSCoin(address who, uint256 assets) private returns (uint256 shares) {
        vm.startPrank(who);
        token.approve(address(vault), assets);
        shares = vault.deposit(assets, who);
        vault.approve(address(factory), type(uint256).max);
        vm.stopPrank();
    }

    function test_ExistingSCoinCreatesHelperWithoutDepositingAgain() public {
        uint256 shares = _existingSCoin(alice, 100e18);
        uint256 supply = vault.totalSupply();
        uint256 coinBalance = token.balanceOf(alice);
        vm.prank(alice);
        PersonalStakingHelper helper = factory.stake(daoId, shares);
        assertEq(helper.owner(), alice);
        assertEq(address(factory.helperOf(daoId, alice)), address(helper));
        assertEq(helper.stakedShares(), shares);
        assertEq(vault.totalSupply(), supply);
        assertEq(token.balanceOf(alice), coinBalance);
        assertEq(vault.balanceOf(alice), 0);
        assertClean(helper);
    }

    function test_SCoinAndCoinEntriesReusePositionAndPreserveRewards() public {
        uint256 shares = _existingSCoin(alice, 100e18);
        vm.prank(alice);
        PersonalStakingHelper helper = factory.stake(daoId, shares);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 reward = helper.earned();
        (PersonalStakingHelper reused, uint256 added) = deposit(alice, 50e18);
        assertEq(address(reused), address(helper));
        assertEq(helper.earned(), reward);
        uint256 extra = _existingSCoin(alice, 25e18);
        vm.prank(alice);
        assertEq(address(factory.stake(daoId, extra)), address(helper));
        assertEq(helper.stakedShares(), shares + added + extra);
        vm.prank(alice);
        helper.withdraw(shares + added + extra, true);
        assertEq(vault.balanceOf(alice), shares + added + extra);
        assertEq(gov.balanceOf(alice), reward);
        assertClean(helper);
    }

    function test_SCoinEntryKeepsOwnersAndLooseDonationsSeparate() public {
        uint256 aliceShares = _existingSCoin(alice, 100e18);
        uint256 bobShares = _existingSCoin(bob, 200e18);
        vm.prank(alice);
        PersonalStakingHelper a = factory.stake(daoId, aliceShares / 2);
        vm.prank(alice);
        vault.transfer(address(a), 7e18);
        uint256 remaining = vault.balanceOf(alice);
        vm.prank(alice);
        factory.stake(daoId, remaining);
        vm.prank(bob);
        PersonalStakingHelper b = factory.stake(daoId, bobShares);
        assertNotEq(address(a), address(b));
        assertEq(a.stakedShares(), aliceShares - 7e18);
        assertEq(b.stakedShares(), bobShares);
        assertEq(vault.balanceOf(address(a)), 7e18);
        vm.prank(alice);
        a.recoverToken(vault);
        assertEq(vault.balanceOf(alice), 7e18);
        assertClean(a);
        assertClean(b);
    }

    function test_SCoinEntryRequiresSCoinAllowanceAndRollsBackCreation() public {
        uint256 shares = _existingSCoin(alice, 100e18);
        vm.prank(alice);
        vault.approve(address(factory), 0);
        uint64 nonce = vm.getNonce(address(factory));
        vm.prank(alice);
        vm.expectRevert();
        factory.stake(daoId, shares);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(pool.totalSupply(), 0);
        assertEq(address(factory.helperOf(daoId, alice)), address(0));
        assertEq(vm.getNonce(address(factory)), nonce);
    }

    function test_FailedSCoinStakeRollsBackTransfersAndCreation() public {
        uint256 shares = _existingSCoin(alice, 100e18);
        vm.mockCallRevert(
            address(pool), abi.encodeCall(IStakingRewards.stake, (shares)), abi.encodeWithSignature("Error(string)", "STAKE_FAILED")
        );
        vm.prank(alice);
        vm.expectRevert("STAKE_FAILED");
        factory.stake(daoId, shares);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(pool.totalSupply(), 0);
        assertEq(address(factory.helperOf(daoId, alice)), address(0));
    }

    function test_StakeRejectsZeroAndDirectHelperCalls() public {
        vm.prank(alice);
        vm.expectRevert(PersonalStakingHelperFactory.ZeroAmount.selector);
        factory.stake(daoId, 0);
        assertEq(address(factory.helperOf(daoId, alice)), address(0));
        (PersonalStakingHelper helper,) = deposit(alice, 100e18);
        vm.prank(bob);
        vm.expectRevert(PersonalStakingHelper.OnlyFactory.selector);
        helper.stake(1);
        vm.prank(address(factory));
        vm.expectRevert(PersonalStakingHelper.ZeroAmount.selector);
        helper.stake(0);
    }

    function test_StakeRejectsUnknownDAOWithoutCreatingHelper() public {
        uint256 shares = _existingSCoin(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert();
        factory.stake(type(uint256).max, shares);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(address(factory.helperOf(type(uint256).max, alice)), address(0));
    }

    function test_StakeSupportsDirectCoinAndRejectsCallbackReentrancy() public {
        (uint256 id, TestMarket memory direct) = createDAO("Direct", false);
        fundAndApprove(direct, alice, 200e18);
        direct.token.setHook(alice, address(factory), abi.encodeWithSignature("stake(uint256,uint256)", id, 1));
        vm.prank(alice);
        PersonalStakingHelper helper = factory.stake(id, 100e18);
        assertFalse(direct.token.callbackSuccess());
        assertEq(direct.token.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(helper.stakedShares(), 100e18);
        (PersonalStakingHelper reused,) = depositIn(id, direct, alice, 100e18);
        assertEq(address(reused), address(helper));
        assertEq(helper.stakedShares(), 200e18);
        assertEq(direct.vault.totalSupply(), 0);
        assertClean(helper);
    }

    function testFuzz_ExistingSCoinRoundTrip(uint96 amount_) public {
        uint256 amount = bound(uint256(amount_), MIN_SHARES + 1, 1e26);
        uint256 shares = _existingSCoin(alice, amount);
        vm.prank(alice);
        PersonalStakingHelper helper = factory.stake(daoId, shares);
        vm.prank(alice);
        helper.withdraw(shares, false);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(helper.stakedShares(), 0);
        assertClean(helper);
    }

    function testFuzz_ReceiverEntriesCreateAndReuseTheOwnersHelper(bool stakeEntry, bool directCoin, uint96 rawAmount) public {
        uint256 id = daoId;
        TestMarket memory market = TestMarket(token, gov, lender, vault, pool);
        if (directCoin) {
            (id, market) = createDAO("Direct receiver", false);
            fundAndApprove(market, alice, 1e30);
            fundAndApprove(market, bob, 1000e18);
        }
        uint256 amount = bound(uint256(rawAmount), MIN_SHARES + 1, 1e26);
        if (stakeEntry && !directCoin) amount = _existingSCoin(alice, amount);
        IERC20 entryToken = stakeEntry ? IERC20(market.pool.stakingToken()) : IERC20(address(market.token));
        vm.prank(alice);
        entryToken.approve(address(factory), amount);
        uint256 payerBefore = entryToken.balanceOf(alice);
        uint256 receiverBefore = market.token.balanceOf(bob);
        uint256 expected = stakeEntry || directCoin ? amount : market.vault.previewDeposit(amount);
        address predicted = factory.predictHelper(id, bob);
        vm.expectEmit(true, true, true, true, address(factory));
        emit HelperCreated(id, bob, predicted);
        vm.expectEmit(true, true, true, true, address(factory));
        if (stakeEntry) emit Staked(id, bob, predicted, expected);
        else emit DepositedAndStaked(id, bob, predicted, amount, expected);
        PersonalStakingHelper helper;
        vm.prank(alice);
        if (stakeEntry) helper = factory.stake(id, amount, bob);
        else {
            uint256 shares;
            (helper, shares) = factory.depositAndStake(id, amount, expected, bob);
            assertEq(shares, expected);
        }
        assertEq(address(helper), predicted);
        assertEq(helper.owner(), bob);
        assertEq(address(factory.helperOf(id, bob)), predicted);
        assertEq(address(factory.helperOf(id, alice)), address(0));
        assertEq(entryToken.balanceOf(alice), payerBefore - amount);
        assertEq(market.token.balanceOf(bob), receiverBefore);
        assertEq(helper.stakedShares(), expected);
        vm.prank(alice);
        vm.expectRevert(PersonalStakingHelper.OnlyOwner.selector);
        helper.withdraw(1, false);

        // The owner's existing entry route reuses the helper created by the payer.
        (PersonalStakingHelper reused, uint256 added) = depositIn(id, market, bob, 25e18);
        assertEq(address(reused), predicted);
        assertEq(helper.stakedShares(), expected + added);
        assertClean(helper);
    }

    function testFuzz_ReceiverEntryRejectsZeroAmount(bool stakeEntry) public {
        vm.prank(alice);
        vm.expectRevert(PersonalStakingHelperFactory.ZeroAmount.selector);
        if (stakeEntry) factory.stake(daoId, 0, bob);
        else factory.depositAndStake(daoId, 0, 0, bob);
        assertEq(address(factory.helperOf(daoId, bob)), address(0));
    }

    function testFuzz_ReceiverEntryRejectsZeroReceiver(bool stakeEntry) public {
        uint256 beforeBalance = token.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(PersonalStakingHelperFactory.ZeroAddress.selector);
        if (stakeEntry) factory.stake(daoId, 1e18, address(0));
        else factory.depositAndStake(daoId, 1e18, 0, address(0));
        assertEq(token.balanceOf(alice), beforeBalance);
        assertEq(address(factory.helperOf(daoId, address(0))), address(0));
        assertEq(factory.predictHelper(daoId, address(0)).code.length, 0);
    }

    function testFuzz_ReceiverEntryCannotSpendAnotherAccountsAllowance(bool stakeEntry) public {
        uint256 amount = stakeEntry ? _existingSCoin(bob, 100e18) : 100e18;
        uint256 coinBefore = token.balanceOf(bob);
        uint256 sharesBefore = vault.balanceOf(bob);
        address unfunded = makeAddr("unfunded payer");
        vm.prank(unfunded);
        vm.expectRevert();
        if (stakeEntry) factory.stake(daoId, amount, bob);
        else factory.depositAndStake(daoId, amount, 0, bob);
        assertEq(token.balanceOf(bob), coinBefore);
        assertEq(vault.balanceOf(bob), sharesBefore);
        assertEq(address(factory.helperOf(daoId, bob)), address(0));
        assertEq(factory.predictHelper(daoId, bob).code.length, 0);
    }

    function test_ReceiverDepositSlippageRollsBackCreationAndFunds() public {
        uint256 beforeBalance = token.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PersonalStakingHelper.InsufficientShares.selector, 100e18 - MIN_SHARES, 100e18));
        factory.depositAndStake(daoId, 100e18, 100e18, bob);
        assertEq(token.balanceOf(alice), beforeBalance);
        assertEq(token.allowance(alice, address(factory)), type(uint256).max);
        assertEq(vault.totalSupply(), 0);
        assertEq(pool.totalSupply(), 0);
        assertEq(address(factory.helperOf(daoId, bob)), address(0));
        assertEq(factory.predictHelper(daoId, bob).code.length, 0);
    }

    function testFuzz_ReceiverEntryUsesOnlyNewFunds(bool stakeEntry) public {
        (PersonalStakingHelper helper, uint256 original) = deposit(bob, 100e18);
        _existingSCoin(alice, 100e18);
        token.mint(address(helper), 7e18);
        vm.prank(alice);
        vault.transfer(address(helper), 7e18);
        vm.prank(alice);
        if (stakeEntry) factory.stake(daoId, 10e18, bob);
        else factory.depositAndStake(daoId, 10e18, 10e18, bob);
        assertEq(helper.stakedShares(), original + 10e18);
        assertEq(token.balanceOf(address(helper)), 7e18);
        assertEq(vault.balanceOf(address(helper)), 7e18);
        vm.startPrank(bob);
        helper.recoverToken(token);
        helper.recoverToken(vault);
        vm.stopPrank();
        assertClean(helper);
    }

    function testFuzz_ReceiverEntryRejectsCallbackReentrancy(bool stakeEntry, bool reenterLegacy) public {
        (uint256 id, TestMarket memory direct) = createDAO("Receiver callback", false);
        fundAndApprove(direct, alice, 100e18);
        bytes memory data = reenterLegacy
            ? abi.encodeWithSignature("depositAndStake(uint256,uint256,uint256)", id, 1, 0)
            : abi.encodeWithSignature("stake(uint256,uint256,address)", id, 1, bob);
        direct.token.setHook(alice, address(factory), data);
        PersonalStakingHelper helper;
        vm.prank(alice);
        if (stakeEntry) helper = factory.stake(id, 100e18, bob);
        else (helper,) = factory.depositAndStake(id, 100e18, 100e18, bob);
        assertFalse(direct.token.callbackSuccess());
        assertEq(direct.token.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(helper.owner(), bob);
        assertEq(helper.stakedShares(), 100e18);
        assertClean(helper);
    }

    function test_ContractCanFundOtherOwnerThroughBothReceiverRoutes() public {
        token.mint(address(this), 200e18);
        token.approve(address(factory), 100e18);
        (PersonalStakingHelper helper, uint256 shares) = factory.depositAndStake(daoId, 100e18, 1, bob);
        token.approve(address(vault), 100e18);
        uint256 extra = vault.deposit(100e18, address(this));
        vault.approve(address(factory), extra);
        PersonalStakingHelper reused = factory.stake(daoId, extra, bob);
        assertEq(helper.owner(), bob);
        assertEq(address(reused), address(helper));
        assertEq(helper.stakedShares(), shares + extra);
        assertEq(address(factory.helperOf(daoId, address(this))), address(0));
        assertClean(helper);
    }

    function test_PublicRegistryGetterDecodesDeploymentFields() public {
        CoinDAOFactoryRegistry.Deployment memory expected = CoinDAOFactoryRegistry.Deployment({
            govToken: address(0x101),
            staker: address(0x102),
            governor: address(0x103),
            timelock: address(0x104),
            lender: address(0x105),
            coin: address(0x106),
            vault: address(0x107),
            stakingToken: address(0x108),
            revenueRouter: address(0x109),
            coinStakingRewards: address(0x10a),
            coinStakingRewardsFunder: address(0x10b),
            treasuryVesting: address(0x10c),
            monolithVesting: address(0x10d),
            deployerVesting: address(0x10e)
        });
        uint256 id = coinDAOFactory.addDeployment(expected);
        ICoinDAOFactory.Deployment memory actual = factory.coinDAOFactory().deployments(id);
        assertEq(abi.encode(actual), abi.encode(expected));
        assertEq(actual.govToken, expected.govToken);
        assertEq(actual.coin, expected.coin);
        assertEq(actual.vault, expected.vault);
        assertEq(actual.stakingToken, expected.stakingToken);
        assertEq(actual.coinStakingRewards, expected.coinStakingRewards);
    }

    function test_NewDAOUsesTheExistingFactoryAndImplementation() public {
        address implementation = address(factory.implementation());
        (uint256 id, TestMarket memory second) = createDAO("SecondToken", true);
        fundAndApprove(second, alice, 1e30);
        (PersonalStakingHelper helper, uint256 shares) = depositIn(id, second, alice, 100e18);
        assertEq(address(factory.coinDAOFactory()), address(coinDAOFactory));
        assertEq(address(factory.implementation()), implementation);
        assertEq(address(factory.helperOf(id, alice)), address(helper));
        assertEq(address(factory.helperOf(daoId, alice)), address(0));
        assertEq(helper.owner(), alice);
        assertEq(helper.factory(), address(factory));
        assertEq(address(helper.asset()), address(second.token));
        assertEq(address(helper.vault()), address(second.vault));
        assertEq(address(helper.stakingRewards()), address(second.pool));
        assertEq(address(helper.rewardToken()), address(second.gov));
        assertEq(shares, 100e18 - MIN_SHARES);
        (PersonalStakingHelper again, uint256 added) = depositIn(id, second, alice, 10e18);
        assertEq(address(again), address(helper));
        assertEq(helper.stakedShares(), shares + added);
        assertClean(helper);
    }

    function test_OneOwnerHasIsolatedStakesRewardsAndExitsAcrossDAOs() public {
        (PersonalStakingHelper a, uint256 aShares) = deposit(alice, 100e18);
        (uint256 id, TestMarket memory second) = createDAO("SecondToken", true);
        fundAndApprove(second, alice, 1e30);
        (PersonalStakingHelper b, uint256 bShares) = depositIn(id, second, alice, 200e18);
        assertNotEq(address(a), address(b));
        lender.addInterest(20e18);
        second.lender.addInterest(30e18);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 earnedA = a.earned();
        uint256 earnedB = b.earned();
        assertGt(earnedA, 0);
        assertGt(earnedB, 0);
        vm.prank(alice);
        a.claim();
        assertEq(gov.balanceOf(alice), earnedA);
        assertEq(second.gov.balanceOf(alice), 0);
        assertEq(b.earned(), earnedB);
        vm.prank(alice);
        b.claim();
        assertEq(second.gov.balanceOf(alice), earnedB);
        assertEq(gov.balanceOf(alice), earnedA);
        uint256 secondBalance = second.token.balanceOf(alice);
        uint256 quote = vault.previewRedeem(aShares);
        vm.prank(alice);
        assertEq(a.withdrawAndRedeem(aShares, quote, false), quote);
        assertEq(a.stakedShares(), 0);
        assertEq(b.stakedShares(), bShares);
        assertEq(second.token.balanceOf(alice), secondBalance);
        vm.prank(alice);
        b.withdraw(bShares, false);
        assertEq(second.vault.balanceOf(alice), bShares);
        assertEq(b.stakedShares(), 0);
        assertClean(a);
        assertClean(b);
    }

    function test_EachDAORequiresApprovalForItsOwnToken() public {
        (uint256 id, TestMarket memory second) = createDAO("SecondToken", true);
        second.token.mint(alice, 100e18);
        uint256 firstBalance = token.balanceOf(alice);
        uint256 firstAllowance = token.allowance(alice, address(factory));
        vm.prank(alice);
        vm.expectRevert();
        factory.depositAndStake(id, 100e18, 1);
        assertEq(address(factory.helperOf(id, alice)), address(0));
        assertEq(token.balanceOf(alice), firstBalance);
        assertEq(token.allowance(alice, address(factory)), firstAllowance);
        assertEq(second.token.balanceOf(alice), 100e18);
        vm.prank(alice);
        second.token.approve(address(factory), 100e18);
        (PersonalStakingHelper helper,) = depositIn(id, second, alice, 100e18);
        assertEq(second.token.balanceOf(alice), 0);
        assertEq(token.balanceOf(alice), firstBalance);
        assertClean(helper);
    }

    function test_TokenStakingDAODepositsAndWithdrawsWithoutUsingVault() public {
        (uint256 id, TestMarket memory direct) = createDAO("DirectToken", false);
        fundAndApprove(direct, alice, 100e18);
        vm.prank(alice);
        (PersonalStakingHelper helper, uint256 amount) = factory.depositAndStake(id, 100e18, 100e18);
        assertEq(amount, 100e18);
        assertEq(helper.stakedShares(), amount);
        assertEq(helper.stakingRewards().stakingToken(), address(direct.token));
        assertEq(direct.vault.totalSupply(), 0);
        assertEq(direct.token.balanceOf(alice), 0);
        assertEq(direct.token.allowance(address(helper), address(direct.pool)), 0);
        vm.prank(alice);
        helper.withdraw(amount, false);
        assertEq(direct.token.balanceOf(alice), 100e18);
        assertEq(direct.token.balanceOf(address(factory)), 0);
        assertEq(direct.pool.totalSupply(), 0);
    }

    function test_UnknownDAORevertsWithoutSpendingAnotherDAOTokens() public {
        uint256 balanceBefore = token.balanceOf(alice);
        uint64 nonceBefore = vm.getNonce(address(factory));
        vm.prank(alice);
        vm.expectRevert();
        factory.depositAndStake(type(uint256).max, 100e18, 1);
        assertEq(token.balanceOf(alice), balanceBefore);
        assertEq(address(factory.helperOf(type(uint256).max, alice)), address(0));
        assertEq(vm.getNonce(address(factory)), nonceBefore);
    }

    function test_ZeroVaultRecordRejected() public {
        CoinDAOFactoryRegistry.Deployment memory empty;
        uint256 id = coinDAOFactory.addDeployment(empty);
        vm.prank(alice);
        vm.expectRevert(PersonalStakingHelperFactory.InvalidPair.selector);
        factory.depositAndStake(id, 100e18, 1);
        assertEq(address(factory.helperOf(id, alice)), address(0));
    }

    function test_HelperCannotBeReboundToAnotherDAO() public {
        (PersonalStakingHelper helper, uint256 shares) = deposit(alice, 100e18);
        (, TestMarket memory second) = createDAO("SecondToken", true);
        vm.prank(address(factory));
        vm.expectRevert(PersonalStakingHelper.AlreadyInitialized.selector);
        helper.initialize(alice, second.vault, IStakingRewards(address(second.pool)), address(0));
        assertEq(helper.owner(), alice);
        assertEq(address(helper.asset()), address(token));
        assertEq(address(helper.vault()), address(vault));
        assertEq(address(helper.stakingRewards()), address(pool));
        assertEq(address(helper.rewardToken()), address(gov));
        assertEq(helper.stakedShares(), shares);
    }

    function test_FailedSecondDAODepositLeavesFirstDAOPositionUntouched() public {
        (PersonalStakingHelper first, uint256 shares) = deposit(alice, 100e18);
        (uint256 id, TestMarket memory second) = createDAO("SecondToken", true);
        fundAndApprove(second, alice, 100e18);
        vm.prank(alice);
        second.token.approve(address(factory), 100e18);
        uint64 nonceBefore = vm.getNonce(address(factory));
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(PersonalStakingHelper.InsufficientShares.selector, 100e18 - MIN_SHARES, 100e18)
        );
        factory.depositAndStake(id, 100e18, 100e18);
        assertEq(address(factory.helperOf(id, alice)), address(0));
        assertEq(vm.getNonce(address(factory)), nonceBefore);
        assertEq(second.token.balanceOf(alice), 100e18);
        assertEq(second.token.allowance(alice, address(factory)), 100e18);
        assertEq(second.vault.totalSupply(), 0);
        assertEq(second.pool.totalSupply(), 0);
        assertEq(address(factory.helperOf(daoId, alice)), address(first));
        assertEq(first.stakedShares(), shares);
        assertClean(first);
    }
}
