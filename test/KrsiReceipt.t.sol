// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm, console2} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC7943NonFungible} from "../src/interfaces/IERC7943NonFungible.sol";
import {KrsiReceipt} from "../src/KrsiReceipt.sol";
import {KrsiEncoding} from "../src/lib/KrsiEncoding.sol";
import {IKrsiKyc} from "../src/interfaces/IKrsiKyc.sol";
import {KrsiFixture} from "./utils/KrsiFixture.sol";
import {ReceiptHandler} from "./handlers/ReceiptHandler.sol";

contract KrsiReceiptTest is KrsiFixture {
    bytes32 internal constant TRANSFER = keccak256("Transfer(address,address,uint256)");
    bytes32 internal constant FROZEN = keccak256("Frozen(address,uint256,bool)");
    bytes32 internal constant FORCED = keccak256("ForcedTransfer(address,address,uint256)");

    string internal constant SAMPLE_JSON =
        '{"name":"eNWR ENWR-000006","description":"KRSI electronic negotiable warehouse receipt","attributes":[{"trait_type":"Receipt No","value":"ENWR-000006"},{"trait_type":"Warehouse","value":"agri-vault"},{"trait_type":"Commodity","value":"Coffee"},{"trait_type":"Grade","value":"Raw"},{"trait_type":"Quantity (kg)","display_type":"number","value":20000},{"trait_type":"Stored On","display_type":"date","value":1792627200},{"trait_type":"Valid Till","display_type":"date","value":1808179200},{"trait_type":"Moisture (bps)","display_type":"number","value":1000},{"trait_type":"Foreign Matter (bps)","display_type":"number","value":100},{"trait_type":"Parent","display_type":"number","value":0},{"trait_type":"State","value":"ACTIVE"},{"trait_type":"Ledger Hash","value":"0x89561c5c9b311b531577de5a72ef7afc25a06176216bcdef2b0a6b62ed7928d0"}]}';

    // ---------- log helpers ----------

    function a32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function u32(uint256 v) internal pure returns (bytes32) {
        return bytes32(v);
    }

    function b32(bool v) internal pure returns (bytes32) {
        return v ? bytes32(uint256(1)) : bytes32(0);
    }

    function t2(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory r) {
        r = new bytes32[](2);
        (r[0], r[1]) = (a, b);
    }

    function t3(bytes32 a, bytes32 b, bytes32 c) internal pure returns (bytes32[] memory r) {
        r = new bytes32[](3);
        (r[0], r[1], r[2]) = (a, b, c);
    }

    function t4(bytes32 a, bytes32 b, bytes32 c, bytes32 d) internal pure returns (bytes32[] memory r) {
        r = new bytes32[](4);
        (r[0], r[1], r[2], r[3]) = (a, b, c, d);
    }

    /// The receipt's logs from the last recording, in emission order.
    function receiptLogs() internal returns (Vm.Log[] memory out) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 n;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(receipt)) n++;
        }
        out = new Vm.Log[](n);
        n = 0;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(receipt)) out[n++] = logs[i];
        }
    }

    function assertLog(Vm.Log memory l, bytes32[] memory topics, bytes memory data) internal pure {
        assertEq(l.topics.length, topics.length, "topic count");
        for (uint256 i = 0; i < topics.length; ++i) {
            assertEq(l.topics[i], topics[i], "topic");
        }
        assertEq(l.data, data, "data");
    }

    function frozenLog(address account, uint256 tokenId, bool status) internal pure returns (bytes32[] memory) {
        return t4(FROZEN, a32(account), u32(tokenId), b32(status));
    }

    function transferLog(address from, address to, uint256 tokenId) internal pure returns (bytes32[] memory) {
        return t4(TRANSFER, a32(from), a32(to), u32(tokenId));
    }

    function release() internal {
        vm.prank(farmer);
        receipt.requestRelease(ID);
        vm.prank(warehouseOwner);
        receipt.confirmRelease(ID);
    }

    // ---------- 1 to 10: issue ----------

    function test_Issue_ByAuditor_MintsToVerifiedHolder() public {
        vm.recordLogs();
        issueSample();
        Vm.Log[] memory logs = receiptLogs();
        assertEq(logs.length, 2);
        assertLog(logs[0], transferLog(address(0), farmer, ID), "");
        assertLog(
            logs[1],
            t4(KrsiReceipt.ReceiptIssued.selector, u32(ID), a32(farmer), ref(FARMER_ID)),
            abi.encode("ENWR-000006", QTY, LEDGER)
        );

        KrsiReceipt.Receipt memory r = receipt.getReceipt(ID);
        assertEq(r.receiptNo, "ENWR-000006");
        assertEq(r.warehouseKey, keccak256(bytes(SLUG)));
        assertEq(r.warehouseSlug, SLUG);
        assertEq(r.commodity, "Coffee");
        assertEq(r.grade, "Raw");
        assertEq(r.quantityKg, QTY);
        assertEq(r.storedOn, STORED_ON);
        assertEq(r.validTill, VALID_TILL);
        assertEq(r.moistureBps, MOISTURE);
        assertEq(r.foreignMatterBps, FOREIGN);
        assertEq(r.inspector, auditor);
        assertEq(r.inspectedOn, INSPECTED_ON);
        assertEq(r.inspectionHash, KrsiEncoding.inspectionHash("Fine", INSPECTED_ON));
        assertEq(r.ledgerHash, LEDGER);
        assertEq(r.parentId, 0);
        assertEq(uint8(r.state), uint8(KrsiReceipt.State.ACTIVE));
        assertEq(uint8(receipt.stateOf(ID)), uint8(KrsiReceipt.State.ACTIVE));
        assertEq(receipt.ownerOf(ID), farmer);
        assertEq(receipt.balanceOf(farmer), 1);
        assertFalse(receipt.getFrozenTokens(farmer, ID));
        assertFalse(receipt.isExpired(ID));
    }

    function test_Issue_RevertsWhen_NotAuditor() public {
        bytes32 role = receipt.AUDITOR_ROLE();
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, role)
        );
        receipt.issue(sample(), ref(FARMER_ID));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, role));
        receipt.issue(sample(), ref(FARMER_ID));
    }

    function test_Issue_RevertsWhen_HolderNotVerified() public {
        vm.prank(auditor);
        vm.expectRevert(abi.encodeWithSelector(KrsiReceipt.HolderNotVerified.selector, ref(999)));
        receipt.issue(sample(), ref(999));
        revokeKyc(farmer);
        vm.prank(auditor);
        vm.expectRevert(abi.encodeWithSelector(KrsiReceipt.HolderNotVerified.selector, ref(FARMER_ID)));
        receipt.issue(sample(), ref(FARMER_ID));
    }

    function test_Issue_RevertsWhen_TokenExists() public {
        issueSample();
        vm.prank(auditor);
        vm.expectRevert(abi.encodeWithSelector(KrsiReceipt.TokenExists.selector, ID));
        receipt.issue(sample(), ref(FARMER_ID));
        release();
        vm.prank(auditor);
        vm.expectRevert(abi.encodeWithSelector(KrsiReceipt.TokenExists.selector, ID));
        receipt.issue(sample(), ref(FARMER_ID));
    }

    function test_Issue_RevertsWhen_ZeroTokenId() public {
        vm.prank(auditor);
        vm.expectRevert(KrsiReceipt.InvalidTokenId.selector);
        receipt.issue(sampleWithId(0), ref(FARMER_ID));
    }

    function test_Issue_RevertsWhen_ZeroQuantity() public {
        KrsiReceipt.ReceiptInput memory r = sample();
        r.quantityKg = 0;
        vm.prank(auditor);
        vm.expectRevert(KrsiReceipt.InvalidQuantity.selector);
        receipt.issue(r, ref(FARMER_ID));
    }

    function test_Issue_RevertsWhen_Expired() public {
        vm.warp(EXPIRES_AT);
        vm.prank(auditor);
        vm.expectRevert(KrsiReceipt.InvalidDates.selector);
        receipt.issue(sample(), ref(FARMER_ID));
    }

    function test_Issue_AllowedOnLastValidSecond() public {
        vm.warp(EXPIRES_AT - 1);
        attestFor(farmer, FARMER_ID, 1); // the setUp attestation has expired by now
        issueSample();
        assertFalse(receipt.isExpired(ID));
        vm.warp(EXPIRES_AT);
        assertTrue(receipt.isExpired(ID));
    }

    function test_Issue_RevertsWhen_StoredAfterValidTill() public {
        KrsiReceipt.ReceiptInput memory r = sample();
        r.storedOn = VALID_TILL + 1;
        vm.prank(auditor);
        vm.expectRevert(KrsiReceipt.InvalidDates.selector);
        receipt.issue(r, ref(FARMER_ID));
        r.storedOn = VALID_TILL; // equal dates are allowed
        vm.prank(auditor);
        receipt.issue(r, ref(FARMER_ID));
    }

    function test_Issue_RevertsWhen_QualityAbove10000() public {
        KrsiReceipt.ReceiptInput memory r = sample();
        r.moistureBps = 10001;
        vm.prank(auditor);
        vm.expectRevert(KrsiReceipt.InvalidQuality.selector);
        receipt.issue(r, ref(FARMER_ID));
        r.moistureBps = 10000;
        r.foreignMatterBps = 10001;
        vm.prank(auditor);
        vm.expectRevert(KrsiReceipt.InvalidQuality.selector);
        receipt.issue(r, ref(FARMER_ID));
        r.foreignMatterBps = 10000;
        vm.prank(auditor);
        receipt.issue(r, ref(FARMER_ID));
    }

    function test_Issue_RevertsWhen_BadString() public {
        string[5] memory bad = [
            "",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            'say "hi"',
            "back\\slash",
            "new\nline"
        ];
        assertEq(bytes(bad[1]).length, 65);
        for (uint256 field = 0; field < 4; ++field) {
            for (uint256 i = 0; i < bad.length; ++i) {
                KrsiReceipt.ReceiptInput memory r = sample();
                if (field == 0) r.receiptNo = bad[i];
                if (field == 1) r.warehouseSlug = bad[i];
                if (field == 2) r.commodity = bad[i];
                if (field == 3) r.grade = bad[i];
                vm.prank(auditor);
                vm.expectRevert(KrsiReceipt.InvalidString.selector);
                receipt.issue(r, ref(FARMER_ID));
            }
        }
    }

    function test_Issue_RevertsWhen_Paused() public {
        vm.prank(admin);
        receipt.pause();
        vm.prank(auditor);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        receipt.issue(sample(), ref(FARMER_ID));
    }

    // ---------- 11 to 20: lock and the transfer gate ----------

    function test_Lock_ByOwner_SetsListedAndFrozen() public {
        issueSample();
        vm.recordLogs();
        vm.prank(farmer);
        receipt.lock(ID);
        Vm.Log[] memory logs = receiptLogs();
        assertEq(logs.length, 2);
        assertLog(logs[0], frozenLog(farmer, ID, true), "");
        assertLog(logs[1], t2(KrsiReceipt.ReceiptLocked.selector, u32(ID)), "");
        assertEq(uint8(receipt.stateOf(ID)), uint8(KrsiReceipt.State.LISTED));
        assertTrue(receipt.getFrozenTokens(farmer, ID));
    }

    function test_Lock_ByAdmin() public {
        issueSample();
        vm.recordLogs();
        vm.prank(admin);
        receipt.lock(ID);
        Vm.Log[] memory logs = receiptLogs();
        assertLog(logs[0], frozenLog(farmer, ID, true), ""); // the owner, not the admin
        assertEq(uint8(receipt.stateOf(ID)), uint8(KrsiReceipt.State.LISTED));
    }

    function test_Lock_RevertsWhen_NotOwner() public {
        issueSample();
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(KrsiReceipt.NotTokenOwner.selector, ID, outsider));
        receipt.lock(ID);
        vm.prank(merchant);
        vm.expectRevert(abi.encodeWithSelector(KrsiReceipt.NotTokenOwner.selector, ID, merchant));
        receipt.lock(ID);
    }

    function test_Lock_RevertsWhen_NotActive() public {
        issueAndLock();
        vm.prank(farmer);
        vm.expectRevert(abi.encodeWithSelector(KrsiReceipt.WrongState.selector, ID, KrsiReceipt.State.LISTED));
        receipt.lock(ID);
    }

    function test_Lock_RevertsWhen_Expired() public {
        issueSample();
        vm.warp(EXPIRES_AT);
        vm.prank(farmer);
        vm.expectRevert(abi.encodeWithSelector(KrsiReceipt.ReceiptExpired.selector, ID));
        receipt.lock(ID);
    }

    function test_Unlock_ByOwner_RestoresActive() public {
        issueAndLock();
        vm.recordLogs();
        vm.prank(farmer);
        receipt.unlock(ID);
        Vm.Log[] memory logs = receiptLogs();
        assertEq(logs.length, 2);
        assertLog(logs[0], frozenLog(farmer, ID, false), "");
        assertLog(logs[1], t2(KrsiReceipt.ReceiptUnlocked.selector, u32(ID)), "");
        assertEq(uint8(receipt.stateOf(ID)), uint8(KrsiReceipt.State.ACTIVE));
        assertFalse(receipt.getFrozenTokens(farmer, ID));
    }

    function test_Unlock_AllowedAfterExpiry_ByAdminToo() public {
        issueAndLock();
        vm.warp(EXPIRES_AT + 30 days); // SPEC 9.3: an expired listing can still be withdrawn
        vm.prank(admin);
        receipt.unlock(ID);
        assertEq(uint8(receipt.stateOf(ID)), uint8(KrsiReceipt.State.ACTIVE));
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(KrsiReceipt.NotTokenOwner.selector, ID, outsider));
        receipt.unlock(ID);
    }

    function test_TransferFrom_RevertsWhen_Listed() public {
        issueAndLock();
        vm.prank(farmer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC7943NonFungible.ERC7943InsufficientUnfrozenBalance.selector, farmer, ID)
        );
        receipt.transferFrom(farmer, merchant, ID);
    }

    function test_TransferFrom_RevertsWhen_RecipientUnverified() public {
        issueSample();
        vm.prank(farmer);
        vm.expectRevert(abi.encodeWithSelector(IERC7943NonFungible.ERC7943CannotReceive.selector, outsider));
        receipt.transferFrom(farmer, outsider, ID);
    }

    function test_TransferFrom_RevertsWhen_SenderRevoked() public {
        issueSample();
        revokeKyc(farmer);
        vm.prank(farmer);
        vm.expectRevert(abi.encodeWithSelector(IERC7943NonFungible.ERC7943CannotSend.selector, farmer));
        receipt.transferFrom(farmer, merchant, ID);
    }

    function test_TransferFrom_RevertsWhen_Paused() public {
        issueSample();
        vm.prank(admin);
        receipt.pause();
        vm.prank(farmer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC7943NonFungible.ERC7943CannotTransfer.selector, farmer, merchant, ID)
        );
        receipt.transferFrom(farmer, merchant, ID);
    }

    /// Documents known limitation 2 (SPEC 6.5 and 9.2).
    function test_TransferFrom_SucceedsBetweenVerifiedWhenActive() public {
        issueSample();
        vm.prank(farmer);
        receipt.transferFrom(farmer, merchant, ID);
        assertEq(receipt.ownerOf(ID), merchant);
        assertEq(uint8(receipt.stateOf(ID)), uint8(KrsiReceipt.State.ACTIVE));
    }

    function test_TransferFrom_RevertsWhen_Expired() public {
        issueSample();
        vm.warp(EXPIRES_AT);
        attestFor(farmer, FARMER_ID, 1);
        attestFor(merchant, MERCHANT_ID, 2);
        vm.prank(farmer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC7943NonFungible.ERC7943CannotTransfer.selector, farmer, merchant, ID)
        );
        receipt.transferFrom(farmer, merchant, ID);
    }

    function test_NoPublicBurn() public {
        string memory artifact = vm.readFile("out/KrsiReceipt.sol/KrsiReceipt.json");
        string[] memory methods = vm.parseJsonKeys(artifact, ".methodIdentifiers");
        assertGt(methods.length, 20);
        for (uint256 i = 0; i < methods.length; ++i) {
            assertEq(vm.indexOf(methods[i], "burn"), type(uint256).max, methods[i]);
        }
        issueSample();
        (bool ok,) = address(receipt).call(abi.encodeWithSignature("burn(uint256)", ID));
        assertFalse(ok);
        vm.prank(farmer);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0)));
        receipt.transferFrom(farmer, address(0), ID);
        assertEq(receipt.ownerOf(ID), farmer);
    }

    // ---------- 21 to 25: settle ----------

    function test_Settle_WholeQuantity_TransfersAndActivates() public {
        issueAndLock();
        vm.recordLogs();
        vm.prank(farmer);
        receipt.settle(ID, ref(MERCHANT_ID), QTY, 0, "", bytes32(0), TRADE);
        Vm.Log[] memory logs = receiptLogs();
        assertEq(logs.length, 3);
        assertLog(logs[0], frozenLog(farmer, ID, false), "");
        assertLog(logs[1], transferLog(farmer, merchant, ID), "");
        assertLog(
            logs[2],
            t4(KrsiReceipt.ReceiptTransferred.selector, u32(ID), a32(farmer), a32(merchant)),
            abi.encode(QTY, TRADE)
        );
        assertEq(receipt.ownerOf(ID), merchant);
        assertEq(uint8(receipt.stateOf(ID)), uint8(KrsiReceipt.State.ACTIVE));
        assertFalse(receipt.getFrozenTokens(merchant, ID));
        assertEq(receipt.getReceipt(ID).quantityKg, QTY);
    }

    function test_Settle_WholeQuantity_IgnoresChildArguments() public {
        issueAndLock();
        vm.prank(farmer);
        receipt.settle(ID, ref(MERCHANT_ID), QTY, CHILD, "", CHILD_LEDGER, TRADE);
        assertEq(receipt.ownerOf(ID), merchant);
        assertEq(uint8(receipt.stateOf(CHILD)), uint8(KrsiReceipt.State.NONE));
    }

    function test_Settle_PartQuantity_SplitsIntoChild() public {
        issueAndLock();
        vm.recordLogs();
        vm.prank(farmer);
        receipt.settle(ID, ref(MERCHANT_ID), 12000, CHILD, "ENWR-000007", CHILD_LEDGER, TRADE);
        Vm.Log[] memory logs = receiptLogs();
        assertEq(logs.length, 2);
        assertLog(logs[0], transferLog(address(0), merchant, CHILD), "");
        assertLog(
            logs[1],
            t4(KrsiReceipt.ReceiptSplit.selector, u32(ID), u32(CHILD), a32(merchant)),
            abi.encode(farmer, uint64(12000), uint64(8000), TRADE)
        );

        KrsiReceipt.Receipt memory p = receipt.getReceipt(ID);
        assertEq(p.quantityKg, 8000);
        assertEq(uint8(p.state), uint8(KrsiReceipt.State.LISTED));
        assertTrue(receipt.getFrozenTokens(farmer, ID));
        assertEq(receipt.ownerOf(ID), farmer);

        KrsiReceipt.Receipt memory c = receipt.getReceipt(CHILD);
        assertEq(receipt.ownerOf(CHILD), merchant);
        assertEq(c.quantityKg, 12000);
        assertEq(uint8(c.state), uint8(KrsiReceipt.State.ACTIVE));
        assertFalse(receipt.getFrozenTokens(merchant, CHILD));
        assertEq(c.parentId, ID);
        assertEq(c.receiptNo, "ENWR-000007");
        assertEq(c.ledgerHash, CHILD_LEDGER);
        assertEq(c.warehouseKey, p.warehouseKey);
        assertEq(c.warehouseSlug, p.warehouseSlug);
        assertEq(c.commodity, p.commodity);
        assertEq(c.grade, p.grade);
        assertEq(c.storedOn, p.storedOn);
        assertEq(c.validTill, p.validTill);
        assertEq(c.moistureBps, p.moistureBps);
        assertEq(c.foreignMatterBps, p.foreignMatterBps);
        assertEq(c.inspector, p.inspector);
        assertEq(c.inspectedOn, p.inspectedOn);
        assertEq(c.inspectionHash, p.inspectionHash);
    }

    function testFuzz_Settle_ConservesQuantity(uint64 qty) public {
        qty = uint64(bound(qty, 1, QTY - 1));
        issueAndLock();
        vm.prank(farmer);
        receipt.settle(ID, ref(MERCHANT_ID), qty, CHILD, "ENWR-000007", CHILD_LEDGER, TRADE);
        assertEq(receipt.getReceipt(ID).quantityKg + receipt.getReceipt(CHILD).quantityKg, QTY);
        assertEq(receipt.getReceipt(CHILD).quantityKg, qty);
    }

    function test_Settle_ChildCanBeListedAndSplitAgain() public {
        issueAndLock();
        vm.prank(farmer);
        receipt.settle(ID, ref(MERCHANT_ID), 12000, CHILD, "ENWR-000007", CHILD_LEDGER, TRADE);
        vm.startPrank(merchant);
        receipt.lock(CHILD);
        receipt.settle(CHILD, ref(FARMER_ID), 5000, 8, "ENWR-000008", keccak256("split 8"), TRADE + 1);
        vm.stopPrank();
        assertEq(receipt.getReceipt(CHILD).quantityKg, 7000);
        assertEq(uint8(receipt.stateOf(CHILD)), uint8(KrsiReceipt.State.LISTED));
        assertEq(receipt.ownerOf(8), farmer);
        assertEq(receipt.getReceipt(8).quantityKg, 5000);
        assertEq(receipt.getReceipt(8).parentId, CHILD);
        assertEq(receipt.getReceipt(ID).quantityKg + 7000 + 5000, QTY);
    }

    function test_Settle_RevertsWhen_NotOwner() public {
        issueAndLock();
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(KrsiReceipt.NotTokenOwner.selector, ID, outsider));
        receipt.settle(ID, ref(MERCHANT_ID), QTY, 0, "", bytes32(0), TRADE);
        vm.prank(admin); // admin is not allowed to settle
        vm.expectRevert(abi.encodeWithSelector(KrsiReceipt.NotTokenOwner.selector, ID, admin));
        receipt.settle(ID, ref(MERCHANT_ID), QTY, 0, "", bytes32(0), TRADE);
    }

    function test_Settle_RevertsWhen_NotListed() public {
        issueSample();
        vm.prank(farmer);
        vm.expectRevert(abi.encodeWithSelector(KrsiReceipt.WrongState.selector, ID, KrsiReceipt.State.ACTIVE));
        receipt.settle(ID, ref(MERCHANT_ID), QTY, 0, "", bytes32(0), TRADE);
    }

    function test_Settle_RevertsWhen_Expired() public {
        issueAndLock();
        vm.warp(EXPIRES_AT);
        vm.prank(farmer);
        vm.expectRevert(abi.encodeWithSelector(KrsiReceipt.ReceiptExpired.selector, ID));
        receipt.settle(ID, ref(MERCHANT_ID), QTY, 0, "", bytes32(0), TRADE);
    }

    function test_Settle_RevertsWhen_BuyerNotVerified() public {
        issueAndLock();
        vm.prank(farmer);
        vm.expectRevert(abi.encodeWithSelector(KrsiReceipt.BuyerNotVerified.selector, ref(999)));
        receipt.settle(ID, ref(999), QTY, 0, "", bytes32(0), TRADE);
    }

    function test_Settle_RevertsWhen_SelfTrade() public {
        issueAndLock();
        vm.prank(farmer);
        vm.expectRevert(KrsiReceipt.SelfTrade.selector);
        receipt.settle(ID, ref(FARMER_ID), QTY, 0, "", bytes32(0), TRADE);
    }

    function test_Settle_RevertsWhen_SellerRevoked() public {
        issueAndLock();
        revokeKyc(farmer);
        vm.prank(farmer);
        vm.expectRevert(abi.encodeWithSelector(IERC7943NonFungible.ERC7943CannotSend.selector, farmer));
        receipt.settle(ID, ref(MERCHANT_ID), QTY, 0, "", bytes32(0), TRADE);
    }

    function test_Settle_RevertsWhen_ZeroQty() public {
        issueAndLock();
        vm.prank(farmer);
        vm.expectRevert(KrsiReceipt.InvalidQuantity.selector);
        receipt.settle(ID, ref(MERCHANT_ID), 0, CHILD, "ENWR-000007", CHILD_LEDGER, TRADE);
    }

    function test_Settle_RevertsWhen_QtyAboveQuantity() public {
        issueAndLock();
        vm.prank(farmer);
        vm.expectRevert(KrsiReceipt.InvalidQuantity.selector);
        receipt.settle(ID, ref(MERCHANT_ID), QTY + 1, CHILD, "ENWR-000007", CHILD_LEDGER, TRADE);
    }

    function test_Settle_RevertsWhen_ChildIdZero() public {
        issueAndLock();
        vm.prank(farmer);
        vm.expectRevert(KrsiReceipt.InvalidTokenId.selector);
        receipt.settle(ID, ref(MERCHANT_ID), 12000, 0, "ENWR-000007", CHILD_LEDGER, TRADE);
    }

    function test_Settle_RevertsWhen_ChildExists() public {
        issueAndLock();
        vm.prank(auditor);
        receipt.issue(sampleWithId(9), ref(MERCHANT_ID));
        vm.startPrank(farmer);
        vm.expectRevert(abi.encodeWithSelector(KrsiReceipt.TokenExists.selector, 9));
        receipt.settle(ID, ref(MERCHANT_ID), 12000, 9, "ENWR-000009", CHILD_LEDGER, TRADE);
        vm.expectRevert(abi.encodeWithSelector(KrsiReceipt.TokenExists.selector, ID));
        receipt.settle(ID, ref(MERCHANT_ID), 12000, ID, "ENWR-000007", CHILD_LEDGER, TRADE);
        vm.stopPrank();
    }

    function test_Settle_RevertsWhen_BadChildReceiptNo() public {
        issueAndLock();
        vm.startPrank(farmer);
        vm.expectRevert(KrsiReceipt.InvalidString.selector);
        receipt.settle(ID, ref(MERCHANT_ID), 12000, CHILD, "", CHILD_LEDGER, TRADE);
        vm.expectRevert(KrsiReceipt.InvalidString.selector);
        receipt.settle(ID, ref(MERCHANT_ID), 12000, CHILD, 'ENWR-"7"', CHILD_LEDGER, TRADE);
        vm.stopPrank();
    }

    function test_Settle_RevertsWhen_Paused() public {
        issueAndLock();
        vm.prank(admin);
        receipt.pause();
        vm.prank(farmer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        receipt.settle(ID, ref(MERCHANT_ID), QTY, 0, "", bytes32(0), TRADE);
    }

    // ---------- 26 to 31: release ----------

    function test_RequestRelease_ByOwner_FreezesAndEmits() public {
        issueSample();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(KrsiReceipt.NotTokenOwner.selector, ID, admin));
        receipt.requestRelease(ID);
        vm.recordLogs();
        vm.prank(farmer);
        receipt.requestRelease(ID);
        Vm.Log[] memory logs = receiptLogs();
        assertEq(logs.length, 2);
        assertLog(logs[0], frozenLog(farmer, ID, true), "");
        assertLog(logs[1], t3(KrsiReceipt.ReleaseRequested.selector, u32(ID), a32(farmer)), "");
        assertEq(uint8(receipt.stateOf(ID)), uint8(KrsiReceipt.State.RELEASE_REQUESTED));
        assertTrue(receipt.getFrozenTokens(farmer, ID));
    }

    function test_RequestRelease_RevertsWhen_Listed() public {
        issueAndLock();
        vm.prank(farmer);
        vm.expectRevert(abi.encodeWithSelector(KrsiReceipt.WrongState.selector, ID, KrsiReceipt.State.LISTED));
        receipt.requestRelease(ID);
    }

    function test_RequestRelease_AllowedAfterExpiry() public {
        issueSample();
        vm.warp(EXPIRES_AT + 400 days); // the holder's KYC has expired too
        release();
        assertEq(uint8(receipt.stateOf(ID)), uint8(KrsiReceipt.State.RELEASED));
    }

    function test_CancelRelease_ByOwnerOrAdmin() public {
        issueSample();
        vm.prank(farmer);
        receipt.requestRelease(ID);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(KrsiReceipt.NotTokenOwner.selector, ID, outsider));
        receipt.cancelRelease(ID);

        vm.recordLogs();
        vm.prank(farmer);
        receipt.cancelRelease(ID);
        Vm.Log[] memory logs = receiptLogs();
        assertEq(logs.length, 2);
        assertLog(logs[0], frozenLog(farmer, ID, false), "");
        assertLog(logs[1], t2(KrsiReceipt.ReleaseCancelled.selector, u32(ID)), "");
        assertEq(uint8(receipt.stateOf(ID)), uint8(KrsiReceipt.State.ACTIVE));
        assertFalse(receipt.getFrozenTokens(farmer, ID));

        vm.prank(farmer);
        receipt.requestRelease(ID);
        vm.prank(admin);
        receipt.cancelRelease(ID);
        assertEq(uint8(receipt.stateOf(ID)), uint8(KrsiReceipt.State.ACTIVE));

        vm.prank(farmer);
        vm.expectRevert(abi.encodeWithSelector(KrsiReceipt.WrongState.selector, ID, KrsiReceipt.State.ACTIVE));
        receipt.cancelRelease(ID);
    }

    function test_ConfirmRelease_ByWarehouseOwner_BurnsAndKeepsRecord() public {
        issueSample();
        vm.prank(farmer);
        receipt.requestRelease(ID);
        vm.recordLogs();
        vm.prank(warehouseOwner);
        receipt.confirmRelease(ID);
        Vm.Log[] memory logs = receiptLogs();
        assertEq(logs.length, 3);
        assertLog(logs[0], frozenLog(farmer, ID, false), "");
        assertLog(logs[1], transferLog(farmer, address(0), ID), "");
        assertLog(
            logs[2],
            t4(KrsiReceipt.ReceiptReleased.selector, u32(ID), a32(farmer), a32(warehouseOwner)),
            abi.encode(QTY)
        );

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, ID));
        receipt.ownerOf(ID);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, ID));
        receipt.tokenURI(ID);
        KrsiReceipt.Receipt memory r = receipt.getReceipt(ID);
        assertEq(uint8(r.state), uint8(KrsiReceipt.State.RELEASED));
        assertEq(r.quantityKg, QTY);
        assertEq(r.receiptNo, "ENWR-000006");
        assertFalse(receipt.getFrozenTokens(farmer, ID));
        assertEq(receipt.balanceOf(farmer), 0);
        assertEq(vm.parseJsonString(receipt.tokenJSON(ID), ".attributes[10].value"), "RELEASED"); // DEVIATIONS D10
    }

    function test_ConfirmRelease_RevertsWhen_NotWarehouseOwner() public {
        issueSample();
        vm.prank(farmer);
        receipt.requestRelease(ID);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(KrsiReceipt.NotWarehouseOwner.selector, ID, outsider));
        receipt.confirmRelease(ID);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(KrsiReceipt.NotWarehouseOwner.selector, ID, admin));
        receipt.confirmRelease(ID);
        // A zero owner disables releases for that warehouse.
        vm.prank(admin);
        receipt.setWarehouseOwner(SLUG, address(0));
        vm.prank(warehouseOwner);
        vm.expectRevert(abi.encodeWithSelector(KrsiReceipt.NotWarehouseOwner.selector, ID, warehouseOwner));
        receipt.confirmRelease(ID);
    }

    function test_ConfirmRelease_RevertsWhen_NotRequested() public {
        issueSample();
        vm.prank(warehouseOwner);
        vm.expectRevert(abi.encodeWithSelector(KrsiReceipt.WrongState.selector, ID, KrsiReceipt.State.ACTIVE));
        receipt.confirmRelease(ID);
    }

    // ---------- 32 to 37: ERC 7943 and interfaces ----------

    function test_SupportsInterfaces() public view {
        assertTrue(receipt.supportsInterface(0x01ffc9a7));
        assertTrue(receipt.supportsInterface(0x80ac58cd));
        assertTrue(receipt.supportsInterface(0x5b5e139f));
        assertTrue(receipt.supportsInterface(0x7965db0b));
        assertTrue(receipt.supportsInterface(0xbf1ef5fe));
        assertFalse(receipt.supportsInterface(0xffffffff));
    }

    enum Scenario {
        ActiveVerified,
        Listed,
        ReleaseRequested,
        Paused,
        Expired,
        SenderRevoked,
        ReceiverUnverified
    }

    function test_CanTransfer_AgreesWithGate() public {
        issueSample();
        for (uint8 k = 0; k <= uint8(Scenario.ReceiverUnverified); ++k) {
            uint256 snapshot = vm.snapshotState();
            Scenario s = Scenario(k);
            address to = merchant;
            if (s == Scenario.Listed) {
                vm.prank(farmer);
                receipt.lock(ID);
            } else if (s == Scenario.ReleaseRequested) {
                vm.prank(farmer);
                receipt.requestRelease(ID);
            } else if (s == Scenario.Paused) {
                vm.prank(admin);
                receipt.pause();
            } else if (s == Scenario.Expired) {
                vm.warp(EXPIRES_AT);
                attestFor(farmer, FARMER_ID, 1);
                attestFor(merchant, MERCHANT_ID, 2);
            } else if (s == Scenario.SenderRevoked) {
                revokeKyc(farmer);
            } else if (s == Scenario.ReceiverUnverified) {
                to = outsider;
            }
            bool predicted = receipt.canTransfer(farmer, to, ID);
            vm.prank(farmer);
            bool moved;
            try receipt.transferFrom(farmer, to, ID) {
                moved = true;
            } catch {
                moved = false;
            }
            assertEq(predicted, moved, "canTransfer disagrees with transferFrom");
            assertEq(moved, s == Scenario.ActiveVerified, "only the active and verified case may move");
            vm.revertToState(snapshot);
        }
    }

    function test_CanTransfer_NeverReverts_ForUnknownToken() public view {
        assertFalse(receipt.canTransfer(farmer, merchant, 999));
        assertFalse(receipt.canTransfer(address(0), address(0), 0));
        assertFalse(receipt.canTransfer(farmer, merchant, type(uint256).max));
        assertFalse(receipt.getFrozenTokens(farmer, 999));
        assertFalse(receipt.canSend(address(0)));
        assertFalse(receipt.canReceive(address(0)));
        assertFalse(receipt.canSend(outsider));
        assertTrue(receipt.canSend(farmer));
        assertTrue(receipt.canReceive(merchant));
    }

    function test_SetFrozenTokens_AdminOnly_EmitsFrozen_StateUnchanged() public {
        issueSample();
        bytes32 adminRole = receipt.DEFAULT_ADMIN_ROLE();
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, adminRole)
        );
        receipt.setFrozenTokens(farmer, ID, true);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(KrsiReceipt.NotTokenOwner.selector, ID, merchant)); // DEVIATIONS D9
        receipt.setFrozenTokens(merchant, ID, true);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(KrsiReceipt.NotTokenOwner.selector, 999, address(0)));
        receipt.setFrozenTokens(address(0), 999, true);

        vm.prank(admin);
        receipt.pause(); // works while paused
        vm.recordLogs();
        vm.prank(admin);
        assertTrue(receipt.setFrozenTokens(farmer, ID, true));
        Vm.Log[] memory logs = receiptLogs();
        assertEq(logs.length, 1);
        assertLog(logs[0], frozenLog(farmer, ID, true), "");
        assertEq(uint8(receipt.stateOf(ID)), uint8(KrsiReceipt.State.ACTIVE));
        assertTrue(receipt.getFrozenTokens(farmer, ID));

        vm.prank(admin);
        receipt.unpause();
        vm.prank(farmer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC7943NonFungible.ERC7943InsufficientUnfrozenBalance.selector, farmer, ID)
        );
        receipt.transferFrom(farmer, merchant, ID);
        assertFalse(receipt.canTransfer(farmer, merchant, ID));

        vm.prank(admin);
        receipt.setFrozenTokens(farmer, ID, false);
        assertTrue(receipt.canTransfer(farmer, merchant, ID));
    }

    function test_ForcedTransfer_AdminOnly_UnfreezesFirst() public {
        issueAndLock();
        bytes32 adminRole = receipt.DEFAULT_ADMIN_ROLE();
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, adminRole)
        );
        receipt.forcedTransfer(farmer, merchant, ID);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(KrsiReceipt.NotTokenOwner.selector, ID, merchant)); // DEVIATIONS D9
        receipt.forcedTransfer(merchant, farmer, ID);

        vm.recordLogs();
        vm.prank(admin);
        assertTrue(receipt.forcedTransfer(farmer, merchant, ID));
        Vm.Log[] memory logs = receiptLogs();
        assertEq(logs.length, 3);
        assertLog(logs[0], frozenLog(farmer, ID, false), "");
        assertLog(logs[1], transferLog(farmer, merchant, ID), "");
        assertLog(logs[2], t4(FORCED, a32(farmer), a32(merchant), u32(ID)), "");
        assertEq(receipt.ownerOf(ID), merchant);
        assertEq(uint8(receipt.stateOf(ID)), uint8(KrsiReceipt.State.ACTIVE));
        assertFalse(receipt.getFrozenTokens(merchant, ID));
    }

    function test_ForcedTransfer_WorksWhilePaused_AndForReleaseRequested() public {
        issueSample();
        vm.prank(farmer);
        receipt.requestRelease(ID);
        vm.startPrank(admin);
        receipt.pause();
        receipt.forcedTransfer(farmer, merchant, ID);
        vm.stopPrank();
        assertEq(receipt.ownerOf(ID), merchant);
        assertEq(uint8(receipt.stateOf(ID)), uint8(KrsiReceipt.State.ACTIVE));
    }

    function test_ForcedTransfer_RevertsWhen_RecipientUnverified() public {
        issueSample();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IERC7943NonFungible.ERC7943CannotReceive.selector, outsider));
        receipt.forcedTransfer(farmer, outsider, ID);
    }

    // ---------- 38 to 41: metadata and SPEC conformance ----------

    function test_TokenJSON_MatchesSpecExactly() public {
        issueSample();
        assertEq(receipt.tokenJSON(ID), SAMPLE_JSON);
        assertEq(vm.parseJsonString(SAMPLE_JSON, ".name"), "eNWR ENWR-000006"); // valid JSON
        assertEq(vm.parseJsonUint(SAMPLE_JSON, ".attributes[4].value"), QTY);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 999)); // D10
        receipt.tokenJSON(999);
    }

    function test_TokenURI_IsBase64OfTokenJSON() public {
        issueSample();
        assertEq(receipt.tokenURI(ID), string.concat("data:application/json;base64,", vm.toBase64(SAMPLE_JSON)));
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 999));
        receipt.tokenURI(999);
    }

    function test_Spec_Signatures() public view {
        assertEq(
            receipt.issue.selector,
            bytes4(
                keccak256(
                    "issue((uint256,string,string,string,string,uint64,uint64,uint64,uint16,uint16,uint64,bytes32,bytes32),bytes32)"
                )
            )
        );
        assertEq(receipt.lock.selector, bytes4(keccak256("lock(uint256)")));
        assertEq(receipt.unlock.selector, bytes4(keccak256("unlock(uint256)")));
        assertEq(
            receipt.settle.selector, bytes4(keccak256("settle(uint256,bytes32,uint64,uint256,string,bytes32,uint256)"))
        );
        assertEq(receipt.requestRelease.selector, bytes4(keccak256("requestRelease(uint256)")));
        assertEq(receipt.cancelRelease.selector, bytes4(keccak256("cancelRelease(uint256)")));
        assertEq(receipt.confirmRelease.selector, bytes4(keccak256("confirmRelease(uint256)")));
        assertEq(receipt.setWarehouseOwner.selector, bytes4(keccak256("setWarehouseOwner(string,address)")));
        assertEq(receipt.pause.selector, bytes4(keccak256("pause()")));
        assertEq(receipt.unpause.selector, bytes4(keccak256("unpause()")));
        assertEq(receipt.setFrozenTokens.selector, bytes4(keccak256("setFrozenTokens(address,uint256,bool)")));
        assertEq(receipt.forcedTransfer.selector, bytes4(keccak256("forcedTransfer(address,address,uint256)")));
        assertEq(receipt.getReceipt.selector, bytes4(keccak256("getReceipt(uint256)")));
        assertEq(receipt.stateOf.selector, bytes4(keccak256("stateOf(uint256)")));
        assertEq(receipt.isExpired.selector, bytes4(keccak256("isExpired(uint256)")));
        assertEq(receipt.tokenJSON.selector, bytes4(keccak256("tokenJSON(uint256)")));
        assertEq(receipt.canSend.selector, bytes4(keccak256("canSend(address)")));
        assertEq(receipt.canReceive.selector, bytes4(keccak256("canReceive(address)")));
        assertEq(receipt.canTransfer.selector, bytes4(keccak256("canTransfer(address,address,uint256)")));
        assertEq(receipt.getFrozenTokens.selector, bytes4(keccak256("getFrozenTokens(address,uint256)")));
        assertEq(receipt.warehouseOwnerOf.selector, bytes4(keccak256("warehouseOwnerOf(bytes32)")));
        assertEq(receipt.kyc.selector, bytes4(keccak256("kyc()")));
        assertEq(receipt.AUDITOR_ROLE.selector, bytes4(keccak256("AUDITOR_ROLE()")));
    }

    function test_Spec_EventsAndErrors() public view {
        assertEq(
            KrsiReceipt.ReceiptIssued.selector,
            keccak256("ReceiptIssued(uint256,address,bytes32,string,uint64,bytes32)")
        );
        assertEq(KrsiReceipt.ReceiptLocked.selector, keccak256("ReceiptLocked(uint256)"));
        assertEq(KrsiReceipt.ReceiptUnlocked.selector, keccak256("ReceiptUnlocked(uint256)"));
        assertEq(
            KrsiReceipt.ReceiptTransferred.selector,
            keccak256("ReceiptTransferred(uint256,address,address,uint64,uint256)")
        );
        assertEq(
            KrsiReceipt.ReceiptSplit.selector,
            keccak256("ReceiptSplit(uint256,uint256,address,address,uint64,uint64,uint256)")
        );
        assertEq(KrsiReceipt.ReleaseRequested.selector, keccak256("ReleaseRequested(uint256,address)"));
        assertEq(KrsiReceipt.ReleaseCancelled.selector, keccak256("ReleaseCancelled(uint256)"));
        assertEq(KrsiReceipt.ReceiptReleased.selector, keccak256("ReceiptReleased(uint256,address,address,uint64)"));
        assertEq(KrsiReceipt.WarehouseOwnerSet.selector, keccak256("WarehouseOwnerSet(bytes32,string,address)"));
        assertEq(IERC7943NonFungible.Frozen.selector, FROZEN);
        assertEq(IERC7943NonFungible.ForcedTransfer.selector, FORCED);

        assertEq(KrsiReceipt.ZeroAddress.selector, bytes4(keccak256("ZeroAddress()")));
        assertEq(KrsiReceipt.InvalidTokenId.selector, bytes4(keccak256("InvalidTokenId()")));
        assertEq(KrsiReceipt.TokenExists.selector, bytes4(keccak256("TokenExists(uint256)")));
        assertEq(KrsiReceipt.InvalidString.selector, bytes4(keccak256("InvalidString()")));
        assertEq(KrsiReceipt.InvalidQuantity.selector, bytes4(keccak256("InvalidQuantity()")));
        assertEq(KrsiReceipt.InvalidDates.selector, bytes4(keccak256("InvalidDates()")));
        assertEq(KrsiReceipt.InvalidQuality.selector, bytes4(keccak256("InvalidQuality()")));
        assertEq(KrsiReceipt.HolderNotVerified.selector, bytes4(keccak256("HolderNotVerified(bytes32)")));
        assertEq(KrsiReceipt.BuyerNotVerified.selector, bytes4(keccak256("BuyerNotVerified(bytes32)")));
        assertEq(KrsiReceipt.NotTokenOwner.selector, bytes4(keccak256("NotTokenOwner(uint256,address)")));
        assertEq(KrsiReceipt.WrongState.selector, bytes4(keccak256("WrongState(uint256,uint8)")));
        assertEq(KrsiReceipt.ReceiptExpired.selector, bytes4(keccak256("ReceiptExpired(uint256)")));
        assertEq(KrsiReceipt.SelfTrade.selector, bytes4(keccak256("SelfTrade()")));
        assertEq(KrsiReceipt.NotWarehouseOwner.selector, bytes4(keccak256("NotWarehouseOwner(uint256,address)")));
        assertEq(IERC7943NonFungible.ERC7943CannotSend.selector, bytes4(keccak256("ERC7943CannotSend(address)")));
        assertEq(IERC7943NonFungible.ERC7943CannotReceive.selector, bytes4(keccak256("ERC7943CannotReceive(address)")));
        assertEq(
            IERC7943NonFungible.ERC7943CannotTransfer.selector,
            bytes4(keccak256("ERC7943CannotTransfer(address,address,uint256)"))
        );
        assertEq(
            IERC7943NonFungible.ERC7943InsufficientUnfrozenBalance.selector,
            bytes4(keccak256("ERC7943InsufficientUnfrozenBalance(address,uint256)"))
        );

        // The ReceiptInput tuple encodes field by field in SPEC 6.2 order.
        KrsiReceipt.ReceiptInput memory r = sample();
        bytes32 owner = ref(FARMER_ID);
        assertEq(
            abi.encodeCall(receipt.issue, (r, owner)),
            abi.encodeWithSignature(
                "issue((uint256,string,string,string,string,uint64,uint64,uint64,uint16,uint16,uint64,bytes32,bytes32),bytes32)",
                r,
                owner
            )
        );
        // A struct with string fields is a dynamic tuple: one offset word, then the fields in order.
        assertEq(
            abi.encode(r),
            bytes.concat(
                bytes32(uint256(0x20)),
                abi.encode(
                    ID,
                    "ENWR-000006",
                    SLUG,
                    "Coffee",
                    "Raw",
                    QTY,
                    STORED_ON,
                    VALID_TILL,
                    MOISTURE,
                    FOREIGN,
                    INSPECTED_ON,
                    KrsiEncoding.inspectionHash("Fine", INSPECTED_ON),
                    LEDGER
                )
            )
        );
    }

    // ---------- extra checks beyond the mandatory list ----------

    function test_Constructor_SetsIdentity_RejectsZero() public {
        assertEq(receipt.name(), "KRSI eNWR");
        assertEq(receipt.symbol(), "ENWR");
        assertEq(address(receipt.kyc()), address(resolver));
        assertTrue(receipt.hasRole(receipt.DEFAULT_ADMIN_ROLE(), admin));
        assertEq(receipt.AUDITOR_ROLE(), keccak256("AUDITOR_ROLE"));
        vm.expectRevert(KrsiReceipt.ZeroAddress.selector);
        new KrsiReceipt(address(0), resolver);
        vm.expectRevert(KrsiReceipt.ZeroAddress.selector);
        new KrsiReceipt(admin, IKrsiKyc(address(0)));
    }

    function test_SetWarehouseOwner_AdminOnly_ValidSlug_Emits() public {
        bytes32 adminRole = receipt.DEFAULT_ADMIN_ROLE();
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, adminRole)
        );
        receipt.setWarehouseOwner("nayak", outsider);
        vm.prank(admin);
        vm.expectRevert(KrsiReceipt.InvalidString.selector);
        receipt.setWarehouseOwner("", outsider);

        vm.recordLogs();
        vm.prank(admin);
        receipt.setWarehouseOwner("nayak", outsider);
        Vm.Log[] memory logs = receiptLogs();
        assertEq(logs.length, 1);
        assertLog(
            logs[0], t3(KrsiReceipt.WarehouseOwnerSet.selector, keccak256("nayak"), a32(outsider)), abi.encode("nayak")
        );
        assertEq(receipt.warehouseOwnerOf(keccak256("nayak")), outsider);
        assertEq(receipt.warehouseOwnerOf(keccak256(bytes(SLUG))), warehouseOwner);
    }

    /// SPEC 6.5.2: no path reaches a burn without the bypass, so a harness calls _burn directly.
    function test_Gate_BurnWithoutBypass_Reverts() public {
        KrsiReceiptHarness harness = new KrsiReceiptHarness(admin, resolver);
        vm.startPrank(admin);
        harness.grantRole(harness.AUDITOR_ROLE(), auditor);
        vm.stopPrank();
        vm.prank(auditor);
        harness.issue(sample(), ref(FARMER_ID));
        vm.expectRevert(
            abi.encodeWithSelector(IERC7943NonFungible.ERC7943CannotTransfer.selector, farmer, address(0), ID)
        );
        harness.burnWithoutBypass(ID);
        assertEq(harness.ownerOf(ID), farmer);
    }

    function test_Pause_AdminOnly_BlocksStateChanges() public {
        issueSample();
        bytes32 adminRole = receipt.DEFAULT_ADMIN_ROLE(); // read before the prank, which the next call consumes
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, adminRole)
        );
        receipt.pause();
        vm.prank(admin);
        receipt.pause();
        vm.startPrank(farmer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        receipt.lock(ID);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        receipt.requestRelease(ID);
        vm.stopPrank();
        vm.prank(admin);
        receipt.unpause();
        vm.prank(farmer);
        receipt.lock(ID);
    }
}

contract KrsiReceiptHarness is KrsiReceipt {
    constructor(address admin, IKrsiKyc kyc_) KrsiReceipt(admin, kyc_) {}

    function burnWithoutBypass(uint256 tokenId) external {
        _burn(tokenId);
    }
}

/// Invariant 6.10.4 through a handler that issues, locks, unlocks, splits, sells whole, and releases at random.
contract KrsiReceiptInvariantTest is KrsiFixture {
    ReceiptHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new ReceiptHandler(receipt, auditor, farmer, merchant, warehouseOwner, FARMER_ID, MERCHANT_ID);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = ReceiptHandler.issue.selector;
        selectors[1] = ReceiptHandler.lock.selector;
        selectors[2] = ReceiptHandler.unlock.selector;
        selectors[3] = ReceiptHandler.settle.selector;
        selectors[4] = ReceiptHandler.requestRelease.selector;
        selectors[5] = ReceiptHandler.cancelRelease.selector;
        selectors[6] = ReceiptHandler.confirmRelease.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// For each original receipt: live lineage quantity plus released quantity equals the issued quantity.
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_QuantityConserved() public view {
        uint256[] memory live = new uint256[](handler.rootCount());
        uint256[] memory released = new uint256[](live.length);
        uint256 n = handler.idCount();
        for (uint256 j = 0; j < n; ++j) {
            uint256 id = handler.idAt(j);
            uint256 slot = handler.rootIndexOf(_rootOf(id)); // lineage found from parentId on chain
            KrsiReceipt.Receipt memory r = receipt.getReceipt(id);
            if (r.state == KrsiReceipt.State.RELEASED) released[slot] += r.quantityKg;
            else live[slot] += r.quantityKg;
        }
        for (uint256 i = 0; i < live.length; ++i) {
            assertEq(live[i] + released[i], handler.issuedOf(handler.rootAt(i)), "lineage quantity changed");
        }
    }

    /// Frozen exactly when LISTED or RELEASE_REQUESTED (the handler never calls setFrozenTokens), and only
    /// RELEASED records have no owner.
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_FrozenAndOwnershipMatchState() public view {
        uint256 n = handler.idCount();
        for (uint256 j = 0; j < n; ++j) {
            uint256 id = handler.idAt(j);
            KrsiReceipt.State s = receipt.stateOf(id);
            bool expectFrozen = s == KrsiReceipt.State.LISTED || s == KrsiReceipt.State.RELEASE_REQUESTED;
            assertEq(receipt.getFrozenTokens(address(0), id), expectFrozen, "frozen flag");
            if (s == KrsiReceipt.State.RELEASED) {
                try receipt.ownerOf(id) returns (address) {
                    revert("released receipt still has an owner");
                } catch {}
            } else {
                address owner = receipt.ownerOf(id);
                assertTrue(owner == farmer || owner == merchant, "owner is a verified party");
            }
        }
    }

    /// Shows that the runs really split, sold whole and released (visible with -vv).
    function afterInvariant() public view {
        console2.log("splits", handler.splits(), "whole sales", handler.wholeSales());
        console2.log("releases", handler.releases(), "tokens", handler.idCount());
    }

    function _rootOf(uint256 id) internal view returns (uint256) {
        uint256 parent = receipt.getReceipt(id).parentId;
        while (parent != 0) {
            id = parent;
            parent = receipt.getReceipt(id).parentId;
        }
        return id;
    }
}
