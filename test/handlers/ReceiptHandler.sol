// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {KrsiReceipt} from "../../src/KrsiReceipt.sol";
import {KrsiEncoding} from "../../src/lib/KrsiEncoding.sol";

/// Drives KrsiReceipt through random valid actions between two verified parties. Each action checks its own
/// preconditions and does nothing when they do not hold, so the invariant run can fail on any revert.
contract ReceiptHandler is Test {
    KrsiReceipt internal immutable receipt;
    address internal immutable auditor;
    address internal immutable farmer;
    address internal immutable merchant;
    address internal immutable warehouseOwner;
    bytes32 internal immutable farmerRef;
    bytes32 internal immutable merchantRef;

    uint256 internal nextId = 1000;
    uint256[] internal ids; // every token ever minted, roots and children
    uint256[] internal roots; // tokens minted by issue
    mapping(uint256 => uint256) public issuedOf; // root => issued quantity
    mapping(uint256 => uint256) public rootIndexOf; // root => position in roots

    uint256 public splits;
    uint256 public wholeSales;
    uint256 public releases;

    constructor(
        KrsiReceipt receipt_,
        address auditor_,
        address farmer_,
        address merchant_,
        address warehouseOwner_,
        uint256 farmerId,
        uint256 merchantId
    ) {
        receipt = receipt_;
        auditor = auditor_;
        farmer = farmer_;
        merchant = merchant_;
        warehouseOwner = warehouseOwner_;
        farmerRef = KrsiEncoding.userRef(farmerId);
        merchantRef = KrsiEncoding.userRef(merchantId);
    }

    // ---------- actions ----------

    function issue(uint64 quantitySeed, bool toMerchant) external {
        uint64 quantity = uint64(bound(quantitySeed, 1, 100_000_000));
        uint256 id = nextId++;
        KrsiReceipt.ReceiptInput memory r = KrsiReceipt.ReceiptInput({
            tokenId: id,
            receiptNo: "ENWR-001000",
            warehouseSlug: "agri-vault",
            commodity: "Coffee",
            grade: "Raw",
            quantityKg: quantity,
            storedOn: 1792627200,
            validTill: 1808179200,
            moistureBps: 1000,
            foreignMatterBps: 100,
            inspectedOn: 1792689759,
            inspectionHash: KrsiEncoding.inspectionHash("Fine", 1792689759),
            ledgerHash: keccak256(abi.encode(id))
        });
        vm.prank(auditor);
        receipt.issue(r, toMerchant ? merchantRef : farmerRef);
        ids.push(id);
        rootIndexOf[id] = roots.length;
        roots.push(id);
        issuedOf[id] = quantity;
    }

    function lock(uint256 seed) external {
        (uint256 id, bool found) = _pick(seed, KrsiReceipt.State.ACTIVE);
        if (!found) return;
        vm.prank(receipt.ownerOf(id));
        receipt.lock(id);
    }

    function unlock(uint256 seed) external {
        (uint256 id, bool found) = _pick(seed, KrsiReceipt.State.LISTED);
        if (!found) return;
        vm.prank(receipt.ownerOf(id));
        receipt.unlock(id);
    }

    function settle(uint256 seed, uint64 quantitySeed, bool whole) external {
        (uint256 id, bool found) = _pick(seed, KrsiReceipt.State.LISTED);
        if (!found) return;
        address seller = receipt.ownerOf(id);
        bytes32 buyerRef = seller == farmer ? merchantRef : farmerRef;
        uint64 available = receipt.getReceipt(id).quantityKg;
        uint64 quantity = whole ? available : uint64(bound(quantitySeed, 1, available));
        if (quantity == available) {
            vm.prank(seller);
            receipt.settle(id, buyerRef, quantity, 0, "", bytes32(0), id);
            wholeSales++;
        } else {
            uint256 child = nextId++;
            vm.prank(seller);
            receipt.settle(id, buyerRef, quantity, child, "ENWR-001001", keccak256(abi.encode(child)), id);
            ids.push(child);
            splits++;
        }
    }

    function requestRelease(uint256 seed) external {
        (uint256 id, bool found) = _pick(seed, KrsiReceipt.State.ACTIVE);
        if (!found) return;
        vm.prank(receipt.ownerOf(id));
        receipt.requestRelease(id);
    }

    function cancelRelease(uint256 seed) external {
        (uint256 id, bool found) = _pick(seed, KrsiReceipt.State.RELEASE_REQUESTED);
        if (!found) return;
        vm.prank(receipt.ownerOf(id));
        receipt.cancelRelease(id);
    }

    function confirmRelease(uint256 seed) external {
        (uint256 id, bool found) = _pick(seed, KrsiReceipt.State.RELEASE_REQUESTED);
        if (!found) return;
        vm.prank(warehouseOwner);
        receipt.confirmRelease(id);
        releases++;
    }

    // ---------- views for the invariants ----------

    function idCount() external view returns (uint256) {
        return ids.length;
    }

    function idAt(uint256 i) external view returns (uint256) {
        return ids[i];
    }

    function rootCount() external view returns (uint256) {
        return roots.length;
    }

    function rootAt(uint256 i) external view returns (uint256) {
        return roots[i];
    }

    /// The first token in `wanted` state, scanning from a random start.
    function _pick(uint256 seed, KrsiReceipt.State wanted) internal view returns (uint256, bool) {
        uint256 n = ids.length;
        if (n == 0) return (0, false);
        uint256 start = seed % n;
        for (uint256 k = 0; k < n; ++k) {
            uint256 id = ids[(start + k) % n];
            if (receipt.stateOf(id) == wanted) return (id, true);
        }
        return (0, false);
    }
}
