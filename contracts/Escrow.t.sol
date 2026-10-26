// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Escrow} from "./Escrow.sol";
import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";

/// @dev Seller/buyer contract that tries to re-enter the escrow when it receives ETH.
contract ReentrantParty {
    Escrow public immutable escrow;
    uint256 public targetOffer;
    bool public reenterRefund;

    constructor(Escrow escrow_) {
        escrow = escrow_;
    }

    function list(uint256 amount) external returns (uint256 id) {
        id = escrow.createOffer(Escrow.Side.Sell, address(0), amount);
        targetOffer = id;
    }

    function setReenterRefund(bool v) external {
        reenterRefund = v;
    }

    receive() external payable {
        if (reenterRefund) escrow.refund(targetOffer);
        else escrow.completeSale(targetOffer);
    }
}

contract EscrowTest is Test {
    uint8 constant DECIMALS = 8;
    int256 constant PRICE = 2_000e8; // $2,000 / ETH
    uint256 constant MAX_AGE = 3_600;
    uint256 constant SETTLE = 7 days;

    MockV3Aggregator feed;
    Escrow escrow;

    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");
    address stranger = makeAddr("stranger");
    address arbiter = makeAddr("arbiter");

    event OfferCreated(
        uint256 indexed offerId,
        address indexed seller,
        address indexed buyer,
        address creator,
        Escrow.Side side,
        uint256 amount,
        uint256 usdValue
    );
    event OfferAccepted(uint256 indexed offerId, address indexed seller, address indexed buyer, uint256 amount);
    event OfferCancelled(uint256 indexed offerId, address indexed cancelledBy);
    event SaleExecuted(
        uint256 indexed offerId, address indexed seller, address indexed buyer, uint256 amount, uint256 usdValue
    );
    event Refunded(uint256 indexed offerId, address indexed buyer, address indexed refundedBy, uint256 amount);
    event OfferExpired(uint256 indexed offerId, address indexed buyer, address indexed expiredBy, uint256 amount);

    function setUp() public {
        vm.warp(1_700_000_000);
        feed = new MockV3Aggregator(DECIMALS, PRICE);
        escrow = new Escrow(address(feed), MAX_AGE, arbiter, SETTLE);
        vm.deal(buyer, 100 ether);
        vm.deal(seller, 100 ether);
        vm.deal(stranger, 100 ether);
    }

    // ------------------------------------------------------------------ helpers

    function _list(uint256 amount) internal returns (uint256) {
        vm.prank(seller);
        return escrow.createOffer(Escrow.Side.Sell, address(0), amount);
    }

    function _listAndAccept(uint256 amount) internal returns (uint256 id) {
        id = _list(amount);
        vm.prank(buyer);
        escrow.acceptOffer{value: amount}(id);
    }

    // ------------------------------------------------------------------ constructor / price

    function test_ConstructorRejectsZeroFeed() public {
        vm.expectRevert(Escrow.InvalidPriceFeed.selector);
        new Escrow(address(0), MAX_AGE, arbiter, SETTLE);
    }

    function test_UsdValue() public view {
        assertEq(escrow.getUsdValue(1.5 ether), 3_000e18);
    }

    function test_RevertWhen_PriceStale() public {
        vm.warp(block.timestamp + MAX_AGE + 1);
        vm.expectRevert(abi.encodeWithSelector(Escrow.StalePrice.selector, 1_700_000_000, block.timestamp));
        _list(1 ether);
    }

    function test_PriceAtMaxAgeIsAccepted() public {
        vm.warp(block.timestamp + MAX_AGE);
        assertEq(_list(1 ether), 1);
    }

    function test_RevertWhen_PriceNonPositive() public {
        feed.updateAnswer(0);
        vm.expectRevert(abi.encodeWithSelector(Escrow.InvalidPrice.selector, int256(0)));
        _list(1 ether);
    }

    function test_RevertWhen_PriceUpdatedAtZero() public {
        feed.updateRoundData(2, PRICE, 0);
        vm.expectRevert(abi.encodeWithSelector(Escrow.StalePrice.selector, 0, block.timestamp));
        _list(1 ether);
    }

    // ------------------------------------------------------------------ happy paths

    function test_SellListingHappyPath() public {
        vm.expectEmit(true, true, true, true);
        emit OfferCreated(1, seller, address(0), seller, Escrow.Side.Sell, 2 ether, 4_000e18);
        uint256 id = _list(2 ether);

        vm.expectEmit(true, true, true, true);
        emit OfferAccepted(id, seller, buyer, 2 ether);
        vm.prank(buyer);
        escrow.acceptOffer{value: 2 ether}(id);
        assertEq(address(escrow).balance, 2 ether);

        // price moves after creation; recorded USD value does not
        feed.updateAnswer(3_000e8);

        uint256 sellerBefore = seller.balance;
        vm.expectEmit(true, true, true, true);
        emit SaleExecuted(id, seller, buyer, 2 ether, 4_000e18);
        vm.prank(buyer);
        escrow.completeSale(id);

        assertEq(seller.balance, sellerBefore + 2 ether);
        assertEq(address(escrow).balance, 0);
        Escrow.Offer memory o = escrow.getOffer(id);
        assertEq(uint8(o.status), uint8(Escrow.Status.Completed));
        assertEq(o.buyer, buyer);
    }

    function test_BuyOfferHappyPath() public {
        vm.prank(buyer);
        uint256 id = escrow.createOffer{value: 1 ether}(Escrow.Side.Buy, seller, 1 ether);
        assertEq(address(escrow).balance, 1 ether);

        vm.prank(seller);
        escrow.acceptOffer(id);

        uint256 sellerBefore = seller.balance;
        vm.prank(arbiter);
        escrow.completeSale(id);
        assertEq(seller.balance, sellerBefore + 1 ether);
    }

    // ------------------------------------------------------------------ cancel

    function test_CancelSellListing() public {
        uint256 id = _list(1 ether);
        vm.expectEmit(true, true, false, false);
        emit OfferCancelled(id, seller);
        vm.prank(seller);
        escrow.cancelOffer(id);
        assertEq(uint8(escrow.getOffer(id).status), uint8(Escrow.Status.Cancelled));
    }

    function test_CancelBuyOfferReturnsDeposit() public {
        vm.prank(buyer);
        uint256 id = escrow.createOffer{value: 1 ether}(Escrow.Side.Buy, address(0), 1 ether);
        uint256 before = buyer.balance;
        vm.prank(buyer);
        escrow.cancelOffer(id);
        assertEq(buyer.balance, before + 1 ether);
        assertEq(address(escrow).balance, 0);
    }

    function test_RevertWhen_CancelAfterAccepted() public {
        uint256 id = _listAndAccept(1 ether);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(Escrow.InvalidStatus.selector, id, Escrow.Status.Accepted));
        escrow.cancelOffer(id);
    }

    function test_RevertWhen_NonCreatorCancels() public {
        uint256 id = _list(1 ether);
        vm.prank(buyer);
        vm.expectRevert(Escrow.Unauthorized.selector);
        escrow.cancelOffer(id);
    }

    function test_RevertWhen_AcceptCancelled() public {
        uint256 id = _list(1 ether);
        vm.prank(seller);
        escrow.cancelOffer(id);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Escrow.InvalidStatus.selector, id, Escrow.Status.Cancelled));
        escrow.acceptOffer{value: 1 ether}(id);
    }

    // ------------------------------------------------------------------ validation / access control

    function test_RevertWhen_ZeroAmount() public {
        vm.prank(seller);
        vm.expectRevert(Escrow.InvalidAmount.selector);
        escrow.createOffer(Escrow.Side.Sell, address(0), 0);
    }

    function test_RevertWhen_SelfCounterparty() public {
        vm.prank(seller);
        vm.expectRevert(Escrow.InvalidCounterparty.selector);
        escrow.createOffer(Escrow.Side.Sell, seller, 1 ether);
    }

    function test_RevertWhen_BuyOfferUnderfunded() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Escrow.IncorrectPayment.selector, 1 ether, 0.5 ether));
        escrow.createOffer{value: 0.5 ether}(Escrow.Side.Buy, address(0), 1 ether);
    }

    function test_RevertWhen_SellListingSendsEth() public {
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(Escrow.IncorrectPayment.selector, 0, 1 ether));
        escrow.createOffer{value: 1 ether}(Escrow.Side.Sell, address(0), 1 ether);
    }

    function test_RevertWhen_AcceptWrongPayment() public {
        uint256 id = _list(1 ether);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Escrow.IncorrectPayment.selector, 1 ether, 0.9 ether));
        escrow.acceptOffer{value: 0.9 ether}(id);
    }

    function test_RevertWhen_CreatorAcceptsOwnOffer() public {
        uint256 id = _list(1 ether);
        vm.prank(seller);
        vm.expectRevert(Escrow.Unauthorized.selector);
        escrow.acceptOffer{value: 1 ether}(id);
    }

    function test_RevertWhen_WrongCounterpartyAccepts() public {
        vm.prank(seller);
        uint256 id = escrow.createOffer(Escrow.Side.Sell, buyer, 1 ether);
        vm.prank(stranger);
        vm.expectRevert(Escrow.Unauthorized.selector);
        escrow.acceptOffer{value: 1 ether}(id);
    }

    function test_RevertWhen_UnknownOffer() public {
        vm.expectRevert(abi.encodeWithSelector(Escrow.OfferNotFound.selector, 42));
        escrow.acceptOffer(42);
    }

    function test_RevertWhen_SellerCompletesSale() public {
        uint256 id = _listAndAccept(1 ether);
        vm.prank(seller);
        vm.expectRevert(Escrow.Unauthorized.selector);
        escrow.completeSale(id);
    }

    function test_RevertWhen_BuyerRefundsThemselves() public {
        uint256 id = _listAndAccept(1 ether);
        vm.prank(buyer);
        vm.expectRevert(Escrow.Unauthorized.selector);
        escrow.refund(id);
    }

    function test_RevertWhen_CompleteBeforeAccepted() public {
        uint256 id = _list(1 ether);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Escrow.InvalidStatus.selector, id, Escrow.Status.Open));
        escrow.completeSale(id);
    }

    function test_NoArbiterMeansZeroAddressHasNoPower() public {
        Escrow noArb = new Escrow(address(feed), MAX_AGE, address(0), SETTLE);
        vm.prank(seller);
        uint256 id = noArb.createOffer(Escrow.Side.Sell, address(0), 1 ether);
        vm.prank(buyer);
        noArb.acceptOffer{value: 1 ether}(id);
        vm.prank(address(0));
        vm.expectRevert(Escrow.Unauthorized.selector);
        noArb.completeSale(id);
    }

    // ------------------------------------------------------------------ refund

    function test_SellerRefunds() public {
        uint256 id = _listAndAccept(1 ether);
        uint256 before = buyer.balance;
        vm.expectEmit(true, true, true, true);
        emit Refunded(id, buyer, seller, 1 ether);
        vm.prank(seller);
        escrow.refund(id);
        assertEq(buyer.balance, before + 1 ether);
        assertEq(uint8(escrow.getOffer(id).status), uint8(Escrow.Status.Refunded));
    }

    function test_ArbiterRefunds() public {
        uint256 id = _listAndAccept(1 ether);
        vm.prank(arbiter);
        escrow.refund(id);
        assertEq(address(escrow).balance, 0);
    }

    function test_RevertWhen_DoubleSettle() public {
        uint256 id = _listAndAccept(1 ether);
        vm.prank(buyer);
        escrow.completeSale(id);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(Escrow.InvalidStatus.selector, id, Escrow.Status.Completed));
        escrow.refund(id);
    }

    // ------------------------------------------------------------------ reentrancy

    function test_ReentrantSellerCannotDoubleWithdraw() public {
        ReentrantParty attacker = new ReentrantParty(escrow);
        uint256 id = attacker.list(1 ether);
        vm.prank(buyer);
        escrow.acceptOffer{value: 1 ether}(id);

        // Attacker's receive() re-enters refund(); the guard reverts it, so the payout fails as a whole.
        attacker.setReenterRefund(true);
        vm.prank(buyer);
        vm.expectRevert(Escrow.TransferFailed.selector);
        escrow.completeSale(id);

        assertEq(address(escrow).balance, 1 ether);
        assertEq(uint8(escrow.getOffer(id).status), uint8(Escrow.Status.Accepted));
    }

    // ------------------------------------------------------------------ expiry

    function _acceptedListing(uint256 amount) internal returns (uint256 id) {
        vm.prank(seller);
        id = escrow.createOffer(Escrow.Side.Sell, address(0), amount);
        vm.deal(buyer, amount);
        vm.prank(buyer);
        escrow.acceptOffer{value: amount}(id);
    }

    function test_ConstructorRejectsZeroSettlementPeriod() public {
        vm.expectRevert(Escrow.InvalidSettlementPeriod.selector);
        new Escrow(address(feed), MAX_AGE, arbiter, 0);
    }

    function test_AcceptRecordsAcceptedAt() public {
        uint256 id = _acceptedListing(1 ether);
        assertEq(escrow.getOffer(id).acceptedAt, block.timestamp);
    }

    function test_RevertWhen_ExpireDuringSettlementPeriod() public {
        uint256 id = _acceptedListing(1 ether);
        vm.warp(block.timestamp + SETTLE - 1);
        assertFalse(escrow.isExpired(id));
        vm.expectRevert(
            abi.encodeWithSelector(Escrow.SettlementPeriodActive.selector, id, block.timestamp + 1)
        );
        escrow.expireOffer(id);
    }

    function test_AnyoneExpiresAfterSettlementPeriod() public {
        uint256 id = _acceptedListing(1 ether);
        uint256 before = buyer.balance;
        vm.warp(block.timestamp + SETTLE);
        assertTrue(escrow.isExpired(id));

        vm.expectEmit(address(escrow));
        emit OfferExpired(id, buyer, stranger, 1 ether);
        vm.prank(stranger);
        escrow.expireOffer(id);

        assertEq(buyer.balance, before + 1 ether);
        assertEq(address(escrow).balance, 0);
        assertEq(uint8(escrow.getOffer(id).status), uint8(Escrow.Status.Expired));
        assertFalse(escrow.isExpired(id));
    }

    function test_RevertWhen_ExpireSettledOffer() public {
        uint256 id = _acceptedListing(1 ether);
        vm.prank(buyer);
        escrow.completeSale(id);
        vm.warp(block.timestamp + SETTLE);
        vm.expectRevert(abi.encodeWithSelector(Escrow.InvalidStatus.selector, id, Escrow.Status.Completed));
        escrow.expireOffer(id);
    }

    function test_RevertWhen_ExpireOpenOffer() public {
        vm.prank(seller);
        uint256 id = escrow.createOffer(Escrow.Side.Sell, address(0), 1 ether);
        vm.warp(block.timestamp + SETTLE);
        assertFalse(escrow.isExpired(id));
        vm.expectRevert(abi.encodeWithSelector(Escrow.InvalidStatus.selector, id, Escrow.Status.Open));
        escrow.expireOffer(id);
    }

    // ------------------------------------------------------------------ automation

    function test_CheckUpkeepFalseWhenNothingExpired() public {
        _acceptedListing(1 ether);
        (bool needed, bytes memory data) = escrow.checkUpkeep("");
        assertFalse(needed);
        assertEq(abi.decode(data, (uint256[])).length, 0);
    }

    function test_UpkeepExpiresOnlyExpiredOffers() public {
        uint256 a = _acceptedListing(1 ether);
        vm.warp(block.timestamp + 1 days);
        feed.updateAnswer(PRICE); // keep the price fresh
        uint256 b = _acceptedListing(2 ether);
        vm.prank(seller);
        escrow.createOffer(Escrow.Side.Sell, address(0), 1 ether); // open, never expires
        vm.warp(block.timestamp + SETTLE - 1 days); // only `a` has expired

        (bool needed, bytes memory data) = escrow.checkUpkeep("");
        assertTrue(needed);
        uint256[] memory ids = abi.decode(data, (uint256[]));
        assertEq(ids.length, 1);
        assertEq(ids[0], a);

        vm.prank(stranger);
        escrow.performUpkeep(data);
        assertEq(uint8(escrow.getOffer(a).status), uint8(Escrow.Status.Expired));
        assertEq(uint8(escrow.getOffer(b).status), uint8(Escrow.Status.Accepted));

        // Replaying the same performData is a no-op.
        escrow.performUpkeep(data);
        (needed,) = escrow.checkUpkeep("");
        assertFalse(needed);
    }

    function test_PerformUpkeepSkipsNonExpiredIds() public {
        uint256 a = _acceptedListing(1 ether);
        uint256[] memory ids = new uint256[](2);
        ids[0] = a;
        ids[1] = 999;
        escrow.performUpkeep(abi.encode(ids));
        assertEq(uint8(escrow.getOffer(a).status), uint8(Escrow.Status.Accepted));
    }

    function test_CheckUpkeepRespectsStartIdAndBatchLimit() public {
        uint256 total = escrow.MAX_UPKEEP_BATCH() + 5;
        for (uint256 i; i < total; ++i) _acceptedListing(1 ether);
        vm.warp(block.timestamp + SETTLE);

        (, bytes memory data) = escrow.checkUpkeep("");
        uint256[] memory ids = abi.decode(data, (uint256[]));
        assertEq(ids.length, escrow.MAX_UPKEEP_BATCH());
        assertEq(ids[0], 1);

        (, data) = escrow.checkUpkeep(abi.encode(uint256(21)));
        ids = abi.decode(data, (uint256[]));
        assertEq(ids.length, 5);
        assertEq(ids[0], 21);
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_UsdValueMatchesFeed(uint96 amount, uint64 price) public {
        vm.assume(price > 0);
        feed.updateAnswer(int256(uint256(price)));
        assertEq(escrow.getUsdValue(amount), (uint256(amount) * price) / 1e8);
    }
}
