// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    HelperFixture, MockToken, IERC20, ICoinDAOFactory, PersonalStakingHelper, PersonalStakingHelperFactory, TestMarket
} from "./HelperFixture.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SwapRouterStub} from "./helpers/SwapRouterStub.sol";

contract SwapInputToken is MockToken {
    constructor() MockToken("USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract ZapAndStakeTest is HelperFixture {
    event RouterSet(address indexed router, bool allowed);

    SwapInputToken internal input;
    SwapRouterStub internal router;
    address internal recipient;

    function setUp() public override {
        super.setUp();
        input = new SwapInputToken();
        router = new SwapRouterStub();
        factory.setRouter(address(router), true);
        recipient = factory.predictHelper(daoId, alice);
        input.mint(alice, 10_000e6);
        token.mint(address(router), 1e30);
        vm.prank(alice);
        input.approve(address(factory), type(uint256).max);
    }

    function _data(uint256 amountIn, uint256 amountOut, address recipient) private view returns (bytes memory) {
        return abi.encodeCall(router.swap, (input, token, amountIn, amountOut, recipient));
    }

    function _zap(uint256 amountIn, uint256 amountOut, uint256 minShares)
        private
        returns (PersonalStakingHelper helper, uint256 shares)
    {
        bytes memory data = _data(amountIn, amountOut, recipient);
        vm.prank(alice);
        return factory.zapAndStake(daoId, input, amountIn, address(router), data, amountOut, minShares);
    }

    function test_ZapCreatesHelperAndUsesSixDecimalInput() public {
        uint256 beforeInput = input.balanceOf(alice);
        address predicted = factory.predictHelper(daoId, alice);
        (PersonalStakingHelper helper, uint256 shares) = _zap(100e6, 100e18, 100e18 - MIN_SHARES);
        assertEq(address(helper), predicted);
        assertEq(helper.owner(), alice);
        assertEq(router.caller(), predicted);
        assertEq(shares, 100e18 - MIN_SHARES);
        assertEq(helper.stakedShares(), shares);
        assertEq(input.balanceOf(alice), beforeInput - 100e6);
        assertEq(input.balanceOf(address(router)), 100e6);
        assertEq(input.balanceOf(predicted), 0);
        assertEq(input.balanceOf(address(factory)), 0);
        assertEq(input.allowance(predicted, address(router)), 0);
        assertClean(helper);
    }

    function test_QuoteAddressSurvivesAnotherOwnersHelperCreation() public {
        address predicted = factory.predictHelper(daoId, alice);
        deposit(bob, 100e18);
        assertEq(factory.predictHelper(daoId, alice), predicted);
        (PersonalStakingHelper helper,) = _zap(100e6, 100e18, 100e18);
        assertEq(address(helper), predicted);
        assertNotEq(predicted, address(factory.helperOf(daoId, bob)));
        assertClean(helper);
    }

    function test_ZapStakesEntireCoinBalanceIncludingPrefunding() public {
        address predicted = factory.predictHelper(daoId, alice);
        token.mint(predicted, 7e18);
        (PersonalStakingHelper helper, uint256 shares) = _zap(100e6, 100e18, 107e18 - MIN_SHARES);
        assertEq(shares, 107e18 - MIN_SHARES);
        assertEq(helper.stakedShares(), shares);
        assertEq(token.balanceOf(predicted), 0);
        assertClean(helper);
    }

    function test_ZapReusesCoinAndSCoinPositionAtAppreciatedVaultPrice() public {
        (PersonalStakingHelper first, uint256 original) = deposit(alice, 100e18);
        lender.addInterest(50e18);
        token.mint(address(first), 7e18);
        uint256 quote = vault.previewDeposit(107e18);
        (PersonalStakingHelper helper, uint256 shares) = _zap(100e6, 100e18, quote);
        assertEq(address(helper), address(first));
        assertEq(shares, quote);
        assertEq(helper.stakedShares(), original + quote);
        assertEq(input.allowance(address(helper), address(router)), 0);
        assertClean(helper);
    }

    function test_ZapSupportsDirectCoinPoolWithoutUsingVault() public {
        (uint256 id, TestMarket memory direct) = createDAO("Direct", false);
        direct.token.mint(address(router), 100e18);
        address predicted = factory.predictHelper(id, alice);
        bytes memory data = abi.encodeCall(router.swap, (input, direct.token, 100e6, 100e18, predicted));
        vm.prank(alice);
        (PersonalStakingHelper helper, uint256 shares) = factory.zapAndStake(id, input, 100e6, address(router), data, 100e18, 100e18);
        assertEq(shares, 100e18);
        assertEq(helper.stakedShares(), shares);
        assertEq(direct.vault.totalSupply(), 0);
        vm.prank(alice);
        helper.withdraw(shares, false);
        assertEq(direct.token.balanceOf(alice), 100e18);
        assertClean(helper);
    }

    function test_RevertingSwapRollsBackInputAndCreationThenCanRetry() public {
        address predicted = factory.predictHelper(daoId, alice);
        uint256 beforeInput = input.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert("SWAP_FAILED");
        factory.zapAndStake(daoId, input, 100e6, address(router), abi.encodeCall(router.fail, ()), 100e18, 0);
        assertEq(input.balanceOf(alice), beforeInput);
        assertEq(input.balanceOf(address(router)), 0);
        assertEq(input.balanceOf(predicted), 0);
        assertEq(input.allowance(predicted, address(router)), 0);
        assertEq(address(factory.helperOf(daoId, alice)), address(0));
        assertEq(predicted.code.length, 0);
        (PersonalStakingHelper helper,) = _zap(100e6, 100e18, 0);
        assertEq(address(helper), predicted);
    }

    function test_MinimumSharesFailureRollsBackSwapAndVaultDeposit() public {
        uint256 beforeInput = input.balanceOf(alice);
        uint256 beforeOutput = token.balanceOf(address(router));
        vm.expectRevert(abi.encodeWithSelector(PersonalStakingHelper.InsufficientShares.selector, 100e18 - MIN_SHARES, 100e18));
        _zap(100e6, 100e18, 100e18);
        assertEq(input.balanceOf(alice), beforeInput);
        assertEq(token.balanceOf(address(router)), beforeOutput);
        assertEq(vault.totalSupply(), 0);
        assertEq(pool.totalSupply(), 0);
        assertEq(address(factory.helperOf(daoId, alice)), address(0));
    }

    function test_NoCoinOutputRevertsAtomically() public {
        uint256 beforeInput = input.balanceOf(alice);
        vm.expectRevert(PersonalStakingHelper.ZeroAmount.selector);
        _zap(100e6, 0, 0);
        assertEq(input.balanceOf(alice), beforeInput);
        assertEq(input.balanceOf(address(router)), 0);
        assertEq(address(factory.helperOf(daoId, alice)), address(0));
    }

    function test_WrongRecipientRevertsWithoutSpendingInput() public {
        uint256 beforeInput = input.balanceOf(alice);
        uint256 beforeCoin = token.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PersonalStakingHelper.InsufficientAssets.selector, 0, 100e18));
        factory.zapAndStake(daoId, input, 100e6, address(router), _data(100e6, 100e18, alice), 100e18, 0);
        assertEq(input.balanceOf(alice), beforeInput);
        assertEq(token.balanceOf(alice), beforeCoin);
        assertEq(address(factory.helperOf(daoId, alice)), address(0));
    }

    function test_SwapCannotUseAnotherOwnersFactoryAllowance() public {
        (PersonalStakingHelper victim, uint256 victimShares) = deposit(bob, 100e18);
        uint256 bobBalance = token.balanceOf(bob);
        uint256 aliceBalance = token.balanceOf(alice);
        bytes memory attack = abi.encodeCall(token.transferFrom, (bob, alice, 1e18));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PersonalStakingHelperFactory.RouterNotAllowed.selector, address(token)));
        factory.zapAndStake(daoId, token, 1e18, address(token), attack, 1e18, 0);
        assertEq(token.balanceOf(bob), bobBalance);
        assertEq(token.balanceOf(alice), aliceBalance);
        assertEq(victim.stakedShares(), victimShares);
        assertEq(address(factory.helperOf(daoId, alice)), address(0));
        assertClean(victim);
    }

    function test_AggregatorCannotReenterSharedFactory() public {
        router.setCallback(address(factory), abi.encodeWithSignature("depositAndStake(uint256,uint256,uint256)", daoId, 1, 0));
        (PersonalStakingHelper helper,) = _zap(100e6, 100e18, 0);
        assertFalse(router.callbackSuccess());
        assertEq(router.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(input.allowance(address(helper), address(router)), 0);
        assertClean(helper);
    }

    function test_PartialInputSpendClearsAllowanceAndRemainsOwnerRecoverable() public {
        address predicted = factory.predictHelper(daoId, alice);
        vm.prank(alice);
        (PersonalStakingHelper helper,) = factory.zapAndStake(
            daoId, input, 100e6, address(router), _data(40e6, 100e18, predicted), 100e18, 0
        );
        assertEq(input.balanceOf(predicted), 60e6);
        assertEq(input.allowance(predicted, address(router)), 0);
        uint256 beforeInput = input.balanceOf(alice);
        vm.prank(alice);
        helper.recoverToken(input);
        assertEq(input.balanceOf(alice), beforeInput + 60e6);
        assertClean(helper);
    }

    function test_ZapRejectsZeroInputNonContractTargetAndDirectHelperCalls() public {
        vm.prank(alice);
        vm.expectRevert(PersonalStakingHelperFactory.ZeroAmount.selector);
        factory.zapAndStake(daoId, input, 0, address(router), "", 0, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PersonalStakingHelperFactory.RouterNotAllowed.selector, bob));
        factory.zapAndStake(daoId, input, 100e6, bob, "", 1, 0);
        assertEq(address(factory.helperOf(daoId, alice)), address(0));
        (PersonalStakingHelper helper,) = _zap(100e6, 100e18, 0);
        vm.prank(alice);
        vm.expectRevert(PersonalStakingHelper.OnlyFactory.selector);
        helper.zapAndStake(input, 100e6, address(router), "", 1, 0);
    }

    function test_PrefundedCoinCannotMaskZeroOutputOrWrongRecipient() public {
        token.mint(recipient, 100e18);
        uint256 beforeInput = input.balanceOf(alice);
        uint256 bobBefore = token.balanceOf(bob);
        uint256 routerBefore = token.balanceOf(address(router));
        for (uint256 i; i < 2; ++i) {
            bytes memory data = _data(100e6, i == 0 ? 0 : 100e18, i == 0 ? recipient : bob);
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(PersonalStakingHelper.InsufficientAssets.selector, 100e18, 200e18));
            factory.zapAndStake(daoId, input, 100e6, address(router), data, 100e18, 100e18 - MIN_SHARES);
            assertEq(input.balanceOf(alice), beforeInput);
            assertEq(input.balanceOf(address(router)), 0);
            assertEq(input.allowance(recipient, address(router)), 0);
            assertEq(token.balanceOf(recipient), 100e18);
            assertEq(token.balanceOf(bob), bobBefore);
            assertEq(token.balanceOf(address(router)), routerBefore);
            assertEq(address(factory.helperOf(daoId, alice)), address(0));
            assertEq(recipient.code.length, 0);
        }
    }

    function test_MinCoinOutRejectsShortfallAndAcceptsExactFreshOutput() public {
        token.mint(recipient, 100e18);
        bytes memory data = _data(100e6, 25e18, recipient);
        uint256 beforeInput = input.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PersonalStakingHelper.InsufficientAssets.selector, 125e18, 130e18));
        factory.zapAndStake(daoId, input, 100e6, address(router), data, 30e18, 100e18 - MIN_SHARES);
        assertEq(input.balanceOf(alice), beforeInput);
        assertEq(token.balanceOf(recipient), 100e18);
        assertEq(vault.totalSupply(), 0);
        vm.prank(alice);
        (PersonalStakingHelper helper, uint256 shares) = factory.zapAndStake(
            daoId, input, 100e6, address(router), data, 25e18, 125e18 - MIN_SHARES
        );
        assertEq(shares, 125e18 - MIN_SHARES);
        assertEq(helper.stakedShares(), shares);
        assertEq(token.balanceOf(recipient), 0);
        assertClean(helper);
    }

    function test_CoinBalanceDecreaseRevertsEvenWithZeroMinimum() public {
        (PersonalStakingHelper helper,) = deposit(alice, 100e18);
        token.mint(address(helper), 100e18);
        uint256 bobBefore = token.balanceOf(bob);
        bytes memory data = abi.encodeCall(token.transfer, (bob, 1e18));
        // Exercise the helper's output guard independently of the factory's router gate.
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(PersonalStakingHelper.InsufficientAssets.selector, 99e18, 100e18));
        helper.zapAndStake(input, 100e6, address(token), data, 0, 0);
        assertEq(token.balanceOf(address(helper)), 100e18);
        assertEq(token.balanceOf(bob), bobBefore);
    }

    function test_FailedOutputMinimumRollsBackUnrelatedTokenApproval() public {
        (PersonalStakingHelper helper,) = deposit(alice, 100e18);
        token.mint(address(helper), 100e18);
        bytes memory data = abi.encodeCall(gov.approve, (bob, type(uint256).max));
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(PersonalStakingHelper.InsufficientAssets.selector, 100e18, 100e18 + 1));
        helper.zapAndStake(input, 100e6, address(gov), data, 1, 0);
        assertEq(gov.allowance(address(helper), bob), 0);
        assertEq(input.balanceOf(address(helper)), 0);
    }

    function test_InitialAdminIsExplicitAndCannotBeZero() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new PersonalStakingHelperFactory(ICoinDAOFactory(address(coinDAOFactory)), address(0), yearnRegistry);
        PersonalStakingHelperFactory other =
            new PersonalStakingHelperFactory(ICoinDAOFactory(address(coinDAOFactory)), bob, yearnRegistry);
        assertEq(other.owner(), bob);
        assertFalse(other.allowedRouters(address(router)));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        other.setRouter(address(router), true);
        vm.prank(bob);
        other.setRouter(address(router), true);
        assertTrue(other.allowedRouters(address(router)));
    }

    function testFuzz_OnlyAdminCanChangeRouterApproval(bool allowed) public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.setRouter(address(router), allowed);
        assertTrue(factory.allowedRouters(address(router)));
    }

    function test_RouterUpdatesEmitEventsAndRejectNonContracts() public {
        vm.expectRevert(PersonalStakingHelperFactory.InvalidRouter.selector);
        factory.setRouter(address(0), true);
        vm.expectRevert(PersonalStakingHelperFactory.InvalidRouter.selector);
        factory.setRouter(bob, true);
        SwapRouterStub second = new SwapRouterStub();
        vm.expectEmit(true, false, false, true, address(factory));
        emit RouterSet(address(second), true);
        factory.setRouter(address(second), true);
        assertTrue(factory.allowedRouters(address(second)));
        vm.expectEmit(true, false, false, true, address(factory));
        emit RouterSet(address(second), false);
        factory.setRouter(address(second), false);
        assertFalse(factory.allowedRouters(address(second)));
    }

    function test_RouterCanBeRemovedWithoutCode() public {
        vm.etch(address(router), "");
        factory.setRouter(address(router), false);
        assertFalse(factory.allowedRouters(address(router)));
    }

    function test_OwnershipTransferOnlyChangesRouterAdministration() public {
        (PersonalStakingHelper helper, uint256 shares) = deposit(alice, 100e18);
        factory.transferOwnership(bob);
        assertEq(factory.owner(), bob);
        assertEq(helper.owner(), alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        factory.setRouter(address(router), false);
        vm.startPrank(bob);
        factory.setRouter(address(router), false);
        vm.expectRevert(PersonalStakingHelper.OnlyOwner.selector);
        helper.withdraw(shares, false);
        vm.stopPrank();
        vm.prank(alice);
        helper.withdraw(shares, false);
        assertEq(vault.balanceOf(alice), shares);
        assertClean(helper);
    }

    function test_UnapprovedRouterRejectedBeforeFundingAndCanBeReenabled() public {
        uint256 beforeInput = input.balanceOf(alice);
        factory.setRouter(address(router), false);
        vm.expectRevert(abi.encodeWithSelector(PersonalStakingHelperFactory.RouterNotAllowed.selector, address(router)));
        _zap(100e6, 100e18, 0);
        assertEq(input.balanceOf(alice), beforeInput);
        assertEq(input.allowance(alice, address(factory)), type(uint256).max);
        assertEq(input.balanceOf(address(router)), 0);
        assertEq(input.balanceOf(recipient), 0);
        assertEq(recipient.code.length, 0);
        assertEq(address(factory.helperOf(daoId, alice)), address(0));

        SwapRouterStub second = new SwapRouterStub();
        token.mint(address(second), 100e18);
        factory.setRouter(address(second), true);
        vm.prank(alice);
        (PersonalStakingHelper helper, uint256 first) = factory.zapAndStake(
            daoId, input, 100e6, address(second), _data(100e6, 100e18, recipient), 100e18, 0
        );
        factory.setRouter(address(router), true);
        (PersonalStakingHelper reused, uint256 next) = _zap(100e6, 100e18, 0);
        assertEq(address(reused), address(helper));
        assertEq(helper.stakedShares(), first + next);
        assertTrue(factory.allowedRouters(address(second)));
        assertClean(helper);
    }

    function testFuzz_RemovingRouterLeavesPlainEntriesClaimsAndExitsAvailable(bool redeem, bool stakeRewards) public {
        (PersonalStakingHelper helper, uint256 original) = deposit(alice, 100e18);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 reward = helper.earned();
        assertGt(reward, 0);
        factory.setRouter(address(router), false);
        vm.startPrank(alice);
        if (stakeRewards) {
            assertEq(helper.claimAndStake(), reward);
            assertEq(IERC20(address(helper.govStaking())).balanceOf(alice), reward);
        } else assertEq(helper.claim(), reward);
        (, uint256 added) = factory.depositAndStake(daoId, 10e18, 1);
        helper.withdraw(added, false);
        vault.approve(address(factory), added);
        assertEq(address(factory.stake(daoId, added)), address(helper));
        uint256 total = original + added;
        if (redeem) helper.withdrawAndRedeem(total, vault.previewRedeem(total), false);
        else helper.withdraw(total, false);
        vm.stopPrank();
        assertEq(helper.stakedShares(), 0);
        assertClean(helper);
    }

    function testFuzz_M1TargetsCannotApproveOrWithdrawHelperAssets(uint8 targetSeed, bool existingHelper) public {
        uint256 beforeStake;
        if (existingHelper) (, beforeStake) = deposit(alice, 100e18);
        token.mint(recipient, 7e18);
        gov.mint(recipient, 9e18);
        address[5] memory targets = [address(token), address(gov), address(vault), address(pool), address(input)];
        uint256 index = targetSeed % targets.length;
        bytes memory data = index == 3
            ? abi.encodeCall(pool.withdraw, (beforeStake))
            : abi.encodeWithSignature("approve(address,uint256)", bob, type(uint256).max);
        uint256 beforeCoin = token.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PersonalStakingHelperFactory.RouterNotAllowed.selector, targets[index]));
        factory.zapAndStake(daoId, token, 2, targets[index], data, 0, 0);
        assertEq(token.balanceOf(alice), beforeCoin);
        assertEq(token.balanceOf(recipient), 7e18);
        assertEq(gov.balanceOf(recipient), 9e18);
        assertEq(pool.balanceOf(recipient), beforeStake);
        assertEq(token.allowance(recipient, bob), 0);
        assertEq(gov.allowance(recipient, bob), 0);
        assertEq(vault.allowance(recipient, bob), 0);
        assertEq(input.allowance(recipient, bob), 0);
        assertEq(address(factory.helperOf(daoId, alice)), existingHelper ? recipient : address(0));
        assertEq(recipient.code.length, existingHelper ? 45 : 0);
    }

    function testFuzz_ApprovedRouterCallbackCannotApproveHelperAssets(bool useVault) public {
        (PersonalStakingHelper helper,) = deposit(alice, 100e18);
        IERC20 protectedToken = useVault ? IERC20(address(vault)) : IERC20(address(gov));
        if (useVault) {
            vm.startPrank(alice);
            helper.withdraw(1e18, false);
            vault.transfer(address(helper), 1e18);
            vm.stopPrank();
        } else gov.mint(address(helper), 1e18);
        router.setCallback(address(protectedToken), abi.encodeCall(protectedToken.approve, (bob, type(uint256).max)));
        _zap(100e6, 100e18, 0);
        assertTrue(router.callbackSuccess());
        assertEq(protectedToken.allowance(address(router), bob), type(uint256).max);
        assertEq(protectedToken.allowance(address(helper), bob), 0);
        assertEq(protectedToken.balanceOf(address(helper)), 1e18);
        vm.prank(bob);
        vm.expectRevert();
        protectedToken.transferFrom(address(helper), bob, 1e18);
    }

    function test_RenouncingAdminPreservesConfiguredRouters() public {
        factory.renounceOwnership();
        assertEq(factory.owner(), address(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        factory.setRouter(address(router), false);
        (PersonalStakingHelper helper, uint256 shares) = _zap(100e6, 100e18, 0);
        vm.prank(alice);
        helper.withdraw(shares, false);
        assertTrue(factory.allowedRouters(address(router)));
        assertClean(helper);
    }

    function testFuzz_ZapAndRedeemRoundTrip(uint64 amount_, uint96 prefund_) public {
        uint256 amountIn = bound(uint256(amount_), 1e6, 1000e6);
        uint256 amountOut = amountIn * 1e12;
        uint256 prefund = bound(uint256(prefund_), 0, 100e18);
        token.mint(recipient, prefund);
        uint256 total = amountOut + prefund;
        uint256 beforeCoin = token.balanceOf(alice);
        (PersonalStakingHelper helper, uint256 shares) = _zap(amountIn, amountOut, total - MIN_SHARES);
        vm.prank(alice);
        helper.withdrawAndRedeem(shares, total - MIN_SHARES, false);
        assertEq(token.balanceOf(alice) - beforeCoin, total - MIN_SHARES);
        assertEq(helper.stakedShares(), 0);
        assertEq(input.allowance(address(helper), address(router)), 0);
        assertClean(helper);
    }
}
