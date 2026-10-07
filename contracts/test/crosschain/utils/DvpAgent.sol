// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ISpokeExposureGuard } from "../../../src/interfaces/ISpokeExposureGuard.sol";

/// A security on the public chain (test asset).
contract TestBond is ERC20 {
    constructor() ERC20("Test bond", "BOND") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Delivery versus payment on a public spoke: a buying bank registers this agent as its issuerOps
/// there. A seller escrows the security; the buyer's operations key settles, which pays the price
/// in the buyer's deposit token (minted within the buyer's collateral envelope) and delivers the
/// security in the same transaction. A payment the envelope cannot cover would be queued, so the
/// agent reverts: delivery happens only against payment.
contract DvpAgent {
    struct Deal {
        address seller;
        bytes32 sellerBank;
        uint256 qty;
        uint256 price;
        bool settled;
    }

    address public immutable deployer;
    IERC20 public immutable asset;
    address public owner;
    ISpokeExposureGuard public guard;
    uint256 public nextDeal = 1;
    mapping(uint256 => Deal) public deals;

    error NotOwner();
    error AlreadyBound();
    error PaymentNotFinal(uint256 seq);
    error DealSettled(uint256 id);

    constructor(IERC20 asset_) {
        deployer = msg.sender;
        asset = asset_;
    }

    function bind(ISpokeExposureGuard guard_, address owner_) external {
        if (msg.sender != deployer || address(guard) != address(0)) {
            revert AlreadyBound();
        }
        guard = guard_;
        owner = owner_;
    }

    function offer(bytes32 sellerBank, uint256 qty, uint256 price) external returns (uint256 id) {
        asset.transferFrom(msg.sender, address(this), qty);
        id = nextDeal++;
        deals[id] = Deal({ seller: msg.sender, sellerBank: sellerBank, qty: qty, price: price, settled: false });
    }

    function settle(uint256 id, address receiver) external {
        if (msg.sender != owner) {
            revert NotOwner();
        }
        Deal storage d = deals[id];
        if (d.settled) {
            revert DealSettled(id);
        }
        uint256 seq = guard.pay(d.sellerBank, d.price, bytes32(id));
        if (guard.queueEntry(seq).state != ISpokeExposureGuard.QueueState.NONE) {
            revert PaymentNotFinal(seq);
        }
        d.settled = true;
        asset.transfer(receiver, d.qty);
    }
}
