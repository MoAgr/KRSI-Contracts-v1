// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {EAS} from "@ethereum-attestation-service/eas-contracts/contracts/EAS.sol";
import {SchemaRegistry} from "@ethereum-attestation-service/eas-contracts/contracts/SchemaRegistry.sol";
import {
    AttestationRequest,
    AttestationRequestData,
    RevocationRequest,
    RevocationRequestData
} from "@ethereum-attestation-service/eas-contracts/contracts/IEAS.sol";
import {ISchemaResolver} from "@ethereum-attestation-service/eas-contracts/contracts/resolver/ISchemaResolver.sol";
import {KrsiKycResolver} from "../../src/KrsiKycResolver.sol";
import {KrsiReceipt} from "../../src/KrsiReceipt.sol";
import {KrsiEncoding} from "../../src/lib/KrsiEncoding.sol";

/// Local EAS, the real resolver and KrsiReceipt, wired as SPEC 7.1 describes, plus the golden ENWR-000006 sample.
abstract contract KrsiFixture is Test {
    string internal constant SCHEMA = "bytes32 userRef,uint8 role,bytes32 provider,uint64 kycVerifiedAt";
    string internal constant SLUG = "agri-vault"; // FINDINGS F10, DEVIATIONS D5
    uint256 internal constant TODAY = 1792713600; // 2026 10 23 00:00:00 UTC
    uint256 internal constant FARMER_ID = 101;
    uint256 internal constant MERCHANT_ID = 102;

    // Golden ENWR-000006 (live receipt 6, FINDINGS F6 and handoff/fixtures/receipt.json)
    uint256 internal constant ID = 6;
    uint64 internal constant QTY = 20000;
    uint64 internal constant STORED_ON = 1792627200;
    uint64 internal constant VALID_TILL = 1808179200;
    uint64 internal constant EXPIRES_AT = VALID_TILL + 1 days;
    uint16 internal constant MOISTURE = 1000;
    uint16 internal constant FOREIGN = 100;
    uint64 internal constant INSPECTED_ON = 1792689759;
    bytes32 internal constant LEDGER = 0x89561c5c9b311b531577de5a72ef7afc25a06176216bcdef2b0a6b62ed7928d0;
    // Child ENWR-000007 from handoff/fixtures/acceptBid.json
    uint256 internal constant CHILD = 7;
    bytes32 internal constant CHILD_LEDGER = 0x713b9a45c68a38ea68c2f51b2c5ae718b25d74158d3329186bb554f364a8fda5;
    uint256 internal constant TRADE = 2;

    SchemaRegistry internal registry;
    EAS internal eas;
    KrsiKycResolver internal resolver;
    KrsiReceipt internal receipt;
    bytes32 internal schemaUID;

    address internal admin = makeAddr("admin");
    address internal issuer = makeAddr("issuer");
    address internal auditor = makeAddr("auditor");
    address internal farmer = makeAddr("farmer");
    address internal merchant = makeAddr("merchant");
    address internal outsider = makeAddr("outsider");
    address internal warehouseOwner = makeAddr("warehouseOwner");

    function setUp() public virtual {
        vm.warp(TODAY);
        registry = new SchemaRegistry();
        eas = new EAS(registry);
        resolver = new KrsiKycResolver(eas, issuer, admin);
        schemaUID = registry.register(SCHEMA, ISchemaResolver(address(resolver)), true);
        vm.prank(admin);
        resolver.setSchema(schemaUID);

        receipt = new KrsiReceipt(admin, resolver);
        vm.startPrank(admin);
        receipt.grantRole(receipt.AUDITOR_ROLE(), auditor);
        receipt.setWarehouseOwner(SLUG, warehouseOwner);
        vm.stopPrank();

        attestFor(farmer, FARMER_ID, KrsiEncoding.ROLE_FARMER);
        attestFor(merchant, MERCHANT_ID, KrsiEncoding.ROLE_MERCHANT);
    }

    function ref(uint256 userId) internal pure returns (bytes32) {
        return KrsiEncoding.userRef(userId);
    }

    function attestFor(address wallet, uint256 userId, uint8 role) internal returns (bytes32) {
        bytes memory payload =
            KrsiEncoding.kycData(ref(userId), role, KrsiEncoding.PROVIDER_DEMO, uint64(block.timestamp));
        vm.prank(issuer);
        return eas.attest(
            AttestationRequest({
                schema: schemaUID,
                data: AttestationRequestData({
                    recipient: wallet,
                    expirationTime: uint64(block.timestamp + 365 days),
                    revocable: true,
                    refUID: bytes32(0),
                    data: payload,
                    value: 0
                })
            })
        );
    }

    function revokeKyc(address wallet) internal {
        bytes32 uid = resolver.uidOf(wallet);
        vm.prank(issuer);
        eas.revoke(RevocationRequest({schema: schemaUID, data: RevocationRequestData({uid: uid, value: 0})}));
    }

    function sample() internal pure returns (KrsiReceipt.ReceiptInput memory) {
        return sampleWithId(ID);
    }

    function sampleWithId(uint256 tokenId) internal pure returns (KrsiReceipt.ReceiptInput memory) {
        return KrsiReceipt.ReceiptInput({
            tokenId: tokenId,
            receiptNo: "ENWR-000006",
            warehouseSlug: SLUG,
            commodity: "Coffee",
            grade: "Raw",
            quantityKg: QTY,
            storedOn: STORED_ON,
            validTill: VALID_TILL,
            moistureBps: MOISTURE,
            foreignMatterBps: FOREIGN,
            inspectedOn: INSPECTED_ON,
            inspectionHash: KrsiEncoding.inspectionHash("Fine", INSPECTED_ON),
            ledgerHash: LEDGER
        });
    }

    function issueSample() internal {
        vm.prank(auditor);
        receipt.issue(sample(), ref(FARMER_ID));
    }

    function issueAndLock() internal {
        issueSample();
        vm.prank(farmer);
        receipt.lock(ID);
    }

    /// The receipt's own logs, in order, as topic0 values.
    function receiptTopics(Vm.Log[] memory logs) internal view returns (bytes32[] memory topics) {
        uint256 n;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(receipt)) n++;
        }
        topics = new bytes32[](n);
        n = 0;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(receipt)) topics[n++] = logs[i].topics[0];
        }
    }
}
