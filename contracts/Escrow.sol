// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";

/// @title Escrow
/// @notice ETH escrow for buyer/seller offers. The USD value of every offer is
/// recorded at creation from a Chainlink ETH/USD price feed (Sepolia:
/// 0x694AA1769357215DE4FAC081bf1f309aDC325306).
///
/// Lifecycle:
///  - Sell offer: the seller lists `amount` (no ETH sent). The buyer accepts by
///    sending exactly `amount`, which is held in escrow.
///  - Buy offer: the buyer offers `amount` and deposits it at creation. The
///    seller accepts (no ETH sent).
///  - Open offers can be cancelled by their creator (a buy offer's deposit is
///    returned).
///  - Accepted offers end with `completeSale` (buyer or arbiter; funds go to the
///    seller) or `refund` (seller or arbiter; funds go back to the buyer).
///  - If neither happens within `settlementPeriod` of acceptance, anyone can call
///    `expireOffer` and the buyer is refunded.
contract Escrow {
    enum Side {
        Sell,
        Buy
    }

    enum Status {
        None,
        Open,
        Accepted,
        Cancelled,
        Completed,
        Refunded,
        Expired
    }

    struct Offer {
        address seller; // zero for an open buy offer until accepted
        address buyer; // zero for an open sell listing until accepted
        address creator;
        Side side;
        Status status;
        uint64 createdAt;
        uint64 acceptedAt; // zero until accepted
        uint256 amount; // wei
        uint256 usdValue; // USD with 18 decimals, at creation
    }

    AggregatorV3Interface public immutable priceFeed;
    /// @notice Maximum age (seconds) of the feed's latest answer before it is treated as stale.
    uint256 public immutable maxPriceAge;
    /// @notice Optional dispute resolver; address(0) disables arbitration.
    address public immutable arbiter;
    /// @notice Seconds after acceptance before an unsettled offer can be expired and the buyer refunded.
    uint256 public immutable settlementPeriod;

    uint256 public offerCount;
    mapping(uint256 offerId => Offer) private _offers;

    uint256 private _locked = 1;

    event OfferCreated(
        uint256 indexed offerId,
        address indexed seller,
        address indexed buyer,
        address creator,
        Side side,
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

    error InvalidAmount();
    error InvalidCounterparty();
    error InvalidPriceFeed();
    error IncorrectPayment(uint256 expected, uint256 sent);
    error OfferNotFound(uint256 offerId);
    error InvalidStatus(uint256 offerId, Status status);
    error Unauthorized();
    error StalePrice(uint256 updatedAt, uint256 currentTime);
    error InvalidPrice(int256 answer);
    error TransferFailed();
    error Reentrancy();
    error InvalidSettlementPeriod();
    error SettlementPeriodActive(uint256 offerId, uint256 expiresAt);

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(address priceFeed_, uint256 maxPriceAge_, address arbiter_, uint256 settlementPeriod_) {
        if (priceFeed_ == address(0) || maxPriceAge_ == 0) revert InvalidPriceFeed();
        if (settlementPeriod_ == 0) revert InvalidSettlementPeriod();
        settlementPeriod = settlementPeriod_;
        priceFeed = AggregatorV3Interface(priceFeed_);
        maxPriceAge = maxPriceAge_;
        arbiter = arbiter_;
    }

    // ---------------------------------------------------------------------
    // Offer lifecycle
    // ---------------------------------------------------------------------

    /// @notice Create a sell listing or a buy offer.
    /// @param side Sell (caller is seller, send no ETH) or Buy (caller is buyer, send `amount`).
    /// @param counterparty The only address allowed to accept, or address(0) for anyone.
    /// @param amount Price in wei.
    function createOffer(Side side, address counterparty, uint256 amount)
        external
        payable
        nonReentrant
        returns (uint256 offerId)
    {
        if (amount == 0) revert InvalidAmount();
        if (counterparty == msg.sender) revert InvalidCounterparty();

        uint256 expected = side == Side.Buy ? amount : 0;
        if (msg.value != expected) revert IncorrectPayment(expected, msg.value);

        uint256 usdValue = getUsdValue(amount);

        offerId = ++offerCount;
        Offer storage o = _offers[offerId];
        o.creator = msg.sender;
        o.side = side;
        o.status = Status.Open;
        o.createdAt = uint64(block.timestamp);
        o.amount = amount;
        o.usdValue = usdValue;
        if (side == Side.Sell) {
            o.seller = msg.sender;
            o.buyer = counterparty;
        } else {
            o.buyer = msg.sender;
            o.seller = counterparty;
        }

        emit OfferCreated(offerId, o.seller, o.buyer, msg.sender, side, amount, usdValue);
    }

    /// @notice Accept an open offer. Buyers accepting a sell listing must send exactly `amount`.
    function acceptOffer(uint256 offerId) external payable nonReentrant {
        Offer storage o = _getOffer(offerId);
        _requireStatus(offerId, o, Status.Open);
        if (msg.sender == o.creator) revert Unauthorized();

        if (o.side == Side.Sell) {
            if (o.buyer != address(0) && o.buyer != msg.sender) revert Unauthorized();
            if (msg.value != o.amount) revert IncorrectPayment(o.amount, msg.value);
            o.buyer = msg.sender;
        } else {
            if (o.seller != address(0) && o.seller != msg.sender) revert Unauthorized();
            if (msg.value != 0) revert IncorrectPayment(0, msg.value);
            o.seller = msg.sender;
        }
        o.status = Status.Accepted;
        o.acceptedAt = uint64(block.timestamp);

        emit OfferAccepted(offerId, o.seller, o.buyer, o.amount);
    }

    /// @notice Cancel an offer that has not been accepted. Only the creator can cancel.
    /// A buy offer's deposit is returned to the buyer.
    function cancelOffer(uint256 offerId) external nonReentrant {
        Offer storage o = _getOffer(offerId);
        _requireStatus(offerId, o, Status.Open);
        if (msg.sender != o.creator) revert Unauthorized();

        o.status = Status.Cancelled;
        emit OfferCancelled(offerId, msg.sender);

        if (o.side == Side.Buy) _send(o.buyer, o.amount);
    }

    /// @notice Release escrowed funds to the seller. Callable by the buyer or the arbiter.
    function completeSale(uint256 offerId) external nonReentrant {
        Offer storage o = _getOffer(offerId);
        _requireStatus(offerId, o, Status.Accepted);
        if (msg.sender != o.buyer && (arbiter == address(0) || msg.sender != arbiter)) revert Unauthorized();

        o.status = Status.Completed;
        emit SaleExecuted(offerId, o.seller, o.buyer, o.amount, o.usdValue);

        _send(o.seller, o.amount);
    }

    /// @notice Return escrowed funds to the buyer. Callable by the seller or the arbiter.
    function refund(uint256 offerId) external nonReentrant {
        Offer storage o = _getOffer(offerId);
        _requireStatus(offerId, o, Status.Accepted);
        if (msg.sender != o.seller && (arbiter == address(0) || msg.sender != arbiter)) revert Unauthorized();

        o.status = Status.Refunded;
        emit Refunded(offerId, o.buyer, msg.sender, o.amount);

        _send(o.buyer, o.amount);
    }

    /// @notice Refund the buyer of an accepted offer that was not settled within
    /// `settlementPeriod`. Callable by anyone, so funds can never be stuck.
    function expireOffer(uint256 offerId) public nonReentrant {
        Offer storage o = _getOffer(offerId);
        _requireStatus(offerId, o, Status.Accepted);
        uint256 expiresAt = uint256(o.acceptedAt) + settlementPeriod;
        if (block.timestamp < expiresAt) revert SettlementPeriodActive(offerId, expiresAt);

        o.status = Status.Expired;
        emit OfferExpired(offerId, o.buyer, msg.sender, o.amount);

        _send(o.buyer, o.amount);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function getOffer(uint256 offerId) external view returns (Offer memory) {
        return _getOffer(offerId);
    }

    /// @notice True when `offerId` is accepted and its settlement period has passed.
    function isExpired(uint256 offerId) public view returns (bool) {
        Offer storage o = _offers[offerId];
        return o.status == Status.Accepted && block.timestamp >= uint256(o.acceptedAt) + settlementPeriod;
    }

    /// @notice Latest ETH/USD price from the feed, reverting if stale or invalid.
    /// @return price The answer, scaled by `priceFeed.decimals()`.
    function getLatestPrice() public view returns (uint256 price) {
        (, int256 answer,, uint256 updatedAt,) = priceFeed.latestRoundData();
        if (answer <= 0) revert InvalidPrice(answer);
        if (updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > maxPriceAge) {
            revert StalePrice(updatedAt, block.timestamp);
        }
        price = uint256(answer);
    }

    /// @notice USD value (18 decimals) of `weiAmount` at the current feed price.
    function getUsdValue(uint256 weiAmount) public view returns (uint256) {
        return (weiAmount * getLatestPrice()) / (10 ** priceFeed.decimals());
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _getOffer(uint256 offerId) private view returns (Offer storage o) {
        o = _offers[offerId];
        if (o.status == Status.None) revert OfferNotFound(offerId);
    }

    function _requireStatus(uint256 offerId, Offer storage o, Status expected) private view {
        if (o.status != expected) revert InvalidStatus(offerId, o.status);
    }

    function _send(address to, uint256 amount) private {
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
