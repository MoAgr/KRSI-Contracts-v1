// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EAS} from "@ethereum-attestation-service/eas-contracts/contracts/EAS.sol";
import {SchemaRegistry} from "@ethereum-attestation-service/eas-contracts/contracts/SchemaRegistry.sol";
import {SchemaRecord} from "@ethereum-attestation-service/eas-contracts/contracts/ISchemaRegistry.sol";
import {AccessDenied} from "@ethereum-attestation-service/eas-contracts/contracts/Common.sol";
import {
    Attestation,
    AttestationRequest,
    AttestationRequestData,
    RevocationRequest,
    RevocationRequestData
} from "@ethereum-attestation-service/eas-contracts/contracts/IEAS.sol";
import {ISchemaResolver} from "@ethereum-attestation-service/eas-contracts/contracts/resolver/ISchemaResolver.sol";
import {KrsiKycResolver} from "../src/KrsiKycResolver.sol";
import {KrsiEncoding} from "../src/lib/KrsiEncoding.sol";

contract KrsiKycResolverTest is Test {
    string internal constant SCHEMA = "bytes32 userRef,uint8 role,bytes32 provider,uint64 kycVerifiedAt";
    uint64 internal constant YEAR = 365 days;

    SchemaRegistry internal registry;
    EAS internal eas;
    KrsiKycResolver internal resolver;
    bytes32 internal schemaUID;

    address internal owner = makeAddr("owner");
    address internal issuer = makeAddr("issuer");
    address internal outsider = makeAddr("outsider");
    address internal farmer = makeAddr("farmer");
    address internal farmer2 = makeAddr("farmer2");
    address internal merchant = makeAddr("merchant");

    function setUp() public {
        vm.warp(1792713600); // 2026 10 23 00:00:00 UTC
        registry = new SchemaRegistry();
        eas = new EAS(registry);
        resolver = new KrsiKycResolver(eas, issuer, owner);
        schemaUID = registry.register(SCHEMA, ISchemaResolver(address(resolver)), true);
        vm.prank(owner);
        resolver.setSchema(schemaUID);
    }

    // ---------- helpers ----------

    function data(uint256 userId, uint8 role) internal view returns (bytes memory) {
        return
            KrsiEncoding.kycData(
                KrsiEncoding.userRef(userId), role, KrsiEncoding.PROVIDER_SETU, uint64(block.timestamp)
            );
    }

    function request(bytes32 schema, address wallet, uint64 expiry, bool revocable, bytes memory payload)
        internal
        pure
        returns (AttestationRequest memory)
    {
        return AttestationRequest({
            schema: schema,
            data: AttestationRequestData({
                recipient: wallet,
                expirationTime: expiry,
                revocable: revocable,
                refUID: bytes32(0),
                data: payload,
                value: 0
            })
        });
    }

    /// Attests from the issuer with expiry block.timestamp + 365 days, data built only through KrsiEncoding.
    function attestFor(address wallet, uint256 userId, uint8 role) internal returns (bytes32) {
        vm.prank(issuer);
        return eas.attest(request(schemaUID, wallet, uint64(block.timestamp) + YEAR, true, data(userId, role)));
    }

    /// Issuer attestation with every field chosen by the test; used for the revert cases.
    function attestRaw(bytes32 schema, address wallet, uint64 expiry, bool revocable, bytes memory payload)
        internal
        returns (bytes32)
    {
        vm.prank(issuer);
        return eas.attest(request(schema, wallet, expiry, revocable, payload));
    }

    function revoke(bytes32 uid) internal {
        vm.prank(issuer);
        eas.revoke(RevocationRequest({schema: schemaUID, data: RevocationRequestData({uid: uid, value: 0})}));
    }

    function inAYear() internal view returns (uint64) {
        return uint64(block.timestamp) + YEAR;
    }

    function ref(uint256 userId) internal pure returns (bytes32) {
        return KrsiEncoding.userRef(userId);
    }

    function countLogs(Vm.Log[] memory logs, bytes32 topic0) internal view returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(resolver) && logs[i].topics[0] == topic0) n++;
        }
    }

    // ---------- 1 to 15: attest ----------

    function test_Attest_ByIssuer_LinksWalletAndVerifies() public {
        bytes32 uid = attestFor(farmer, 101, 1);
        assertTrue(resolver.isVerified(farmer));
        assertEq(resolver.walletOf(ref(101)), farmer);
        assertEq(resolver.uidOf(farmer), uid);
        assertEq(resolver.userRefOf(farmer), ref(101));
        assertEq(resolver.verifiedWalletOf(ref(101)), farmer);
    }

    function test_Attest_EmitsKycLinked() public {
        vm.recordLogs();
        bytes32 uid = attestFor(farmer, 101, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(countLogs(logs, KrsiKycResolver.KycLinked.selector), 1);
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(resolver)) continue;
            assertEq(logs[i].topics.length, 4);
            assertEq(logs[i].topics[0], KrsiKycResolver.KycLinked.selector);
            assertEq(logs[i].topics[1], ref(101));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(farmer))));
            assertEq(logs[i].topics[3], uid);
            assertEq(logs[i].data, abi.encode(uint8(1)));
        }
    }

    function test_Attest_RevertsWhen_NotIssuer() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(KrsiKycResolver.NotIssuer.selector, outsider));
        eas.attest(request(schemaUID, farmer, inAYear(), true, data(101, 1)));
    }

    function test_Attest_RevertsWhen_WrongSchema() public {
        bytes32 other = registry.register(
            "bytes32 userRef,uint8 role,bytes32 provider,uint64 kycVerifiedAt,bool extra",
            ISchemaResolver(address(resolver)),
            true
        );
        vm.expectRevert(abi.encodeWithSelector(KrsiKycResolver.WrongSchema.selector, other));
        attestRaw(other, farmer, inAYear(), true, data(101, 1));
    }

    function test_Attest_RevertsWhen_SchemaNotSet() public {
        KrsiKycResolver fresh = new KrsiKycResolver(eas, issuer, owner);
        bytes32 freshSchema = registry.register(SCHEMA, ISchemaResolver(address(fresh)), true);
        vm.expectRevert(KrsiKycResolver.SchemaNotSet.selector);
        attestRaw(freshSchema, farmer, inAYear(), true, data(101, 1));
    }

    function test_Attest_RevertsWhen_NotRevocable() public {
        vm.expectRevert(KrsiKycResolver.NotRevocable.selector);
        attestRaw(schemaUID, farmer, inAYear(), false, data(101, 1));
    }

    function test_Attest_RevertsWhen_MissingExpiry() public {
        vm.expectRevert(KrsiKycResolver.MissingExpiry.selector);
        attestRaw(schemaUID, farmer, 0, true, data(101, 1));
    }

    function test_Attest_RevertsWhen_ExpiryTooLong() public {
        vm.expectRevert(KrsiKycResolver.ExpiryTooLong.selector);
        attestRaw(schemaUID, farmer, uint64(block.timestamp) + 367 days, true, data(101, 1));
    }

    function test_Attest_AllowsExpiryOfExactlyMaxValidity() public {
        attestRaw(schemaUID, farmer, uint64(block.timestamp) + resolver.MAX_VALIDITY(), true, data(101, 1));
        assertTrue(resolver.isVerified(farmer));
    }

    function test_Attest_RevertsWhen_ZeroUserRef() public {
        bytes memory payload = KrsiEncoding.kycData(bytes32(0), 1, KrsiEncoding.PROVIDER_SETU, uint64(block.timestamp));
        vm.expectRevert(KrsiKycResolver.InvalidUserRef.selector);
        attestRaw(schemaUID, farmer, inAYear(), true, payload);
    }

    function test_Attest_RevertsWhen_InvalidRole() public {
        vm.expectRevert(abi.encodeWithSelector(KrsiKycResolver.InvalidRole.selector, uint8(0)));
        attestRaw(schemaUID, farmer, inAYear(), true, data(101, 0));
        vm.expectRevert(abi.encodeWithSelector(KrsiKycResolver.InvalidRole.selector, uint8(4)));
        attestRaw(schemaUID, farmer, inAYear(), true, data(101, 4));
    }

    function test_Attest_RevertsWhen_UserAlreadyLinkedToAnotherLiveWallet() public {
        attestFor(farmer, 101, 1);
        vm.expectRevert(abi.encodeWithSelector(KrsiKycResolver.UserAlreadyLinked.selector, ref(101), farmer));
        attestRaw(schemaUID, farmer2, inAYear(), true, data(101, 1));
    }

    function test_Attest_RevertsWhen_WalletAlreadyLinkedToAnotherUser() public {
        attestFor(farmer, 101, 1);
        vm.expectRevert(abi.encodeWithSelector(KrsiKycResolver.WalletAlreadyLinked.selector, farmer, ref(101)));
        attestRaw(schemaUID, farmer, inAYear(), true, data(102, 2));
    }

    function test_Attest_AllowsRelinkAfterRevoke() public {
        bytes32 oldUid = attestFor(farmer, 101, 1);
        revoke(oldUid);
        bytes32 uid = attestFor(farmer2, 101, 1);
        assertEq(resolver.walletOf(ref(101)), farmer2);
        assertEq(resolver.uidOf(farmer2), uid);
        assertEq(resolver.verifiedWalletOf(ref(101)), farmer2);
        assertEq(resolver.uidOf(farmer), bytes32(0));
        assertEq(resolver.userRefOf(farmer), bytes32(0));
        assertFalse(resolver.isVerified(farmer));
    }

    function test_Attest_AllowsRelinkAfterExpiry() public {
        bytes32 oldUid = attestFor(farmer, 101, 1);
        vm.warp(block.timestamp + YEAR);
        assertFalse(resolver.isVerified(farmer));
        assertEq(resolver.uidOf(farmer), oldUid); // an expired link stays recorded until the user relinks
        bytes32 uid = attestFor(farmer2, 101, 1);
        assertEq(resolver.walletOf(ref(101)), farmer2);
        assertEq(resolver.uidOf(farmer2), uid);
        assertEq(resolver.uidOf(farmer), bytes32(0));
        assertEq(resolver.userRefOf(farmer), bytes32(0));
    }

    function test_Attest_WalletRelinksToNewUserAfterExpiry_ClearsOldUserLink() public {
        attestFor(farmer, 101, 1);
        vm.warp(block.timestamp + YEAR);
        attestFor(farmer, 102, 2);
        assertEq(resolver.walletOf(ref(101)), address(0));
        assertEq(resolver.walletOf(ref(102)), farmer);
        assertEq(resolver.userRefOf(farmer), ref(102));
        assertEq(resolver.verifiedWalletOf(ref(101)), address(0));
    }

    function test_Attest_RenewalSameUserSameWallet_ReplacesUid() public {
        bytes32 first = attestFor(farmer, 101, 1);
        vm.warp(block.timestamp + 30 days);
        bytes32 second = attestFor(farmer, 101, 1);
        assertTrue(first != second);
        assertEq(resolver.uidOf(farmer), second);
        assertEq(resolver.walletOf(ref(101)), farmer);
        assertTrue(resolver.isVerified(farmer));
    }

    // ---------- 16 and 17: revoke ----------

    function test_Revoke_ClearsLinksAndUnverifies() public {
        bytes32 uid = attestFor(farmer, 101, 1);
        vm.expectEmit(true, true, true, true, address(resolver));
        emit KrsiKycResolver.KycRevoked(ref(101), farmer, uid);
        revoke(uid);
        assertFalse(resolver.isVerified(farmer));
        assertEq(resolver.uidOf(farmer), bytes32(0));
        assertEq(resolver.userRefOf(farmer), bytes32(0));
        assertEq(resolver.walletOf(ref(101)), address(0));
        assertEq(resolver.verifiedWalletOf(ref(101)), address(0));
    }

    function test_Revoke_SupersededAttestation_IsNoop() public {
        bytes32 first = attestFor(farmer, 101, 1);
        bytes32 second = attestFor(farmer, 101, 1);
        vm.recordLogs();
        revoke(first);
        assertEq(countLogs(vm.getRecordedLogs(), KrsiKycResolver.KycRevoked.selector), 0);
        assertTrue(resolver.isVerified(farmer));
        assertEq(resolver.uidOf(farmer), second);
        assertEq(resolver.walletOf(ref(101)), farmer);
    }

    // ---------- 18 to 20: views ----------

    function test_IsVerified_FalseAfterExpiry() public {
        attestFor(farmer, 101, 1);
        uint64 expiresAt = eas.getAttestation(resolver.uidOf(farmer)).expirationTime;
        vm.warp(expiresAt - 1);
        assertTrue(resolver.isVerified(farmer));
        vm.warp(expiresAt);
        assertFalse(resolver.isVerified(farmer));
        assertEq(resolver.verifiedWalletOf(ref(101)), address(0));
    }

    function test_VerifiedWalletOf_ZeroWhenNotVerified() public {
        assertEq(resolver.verifiedWalletOf(ref(999)), address(0));
        assertFalse(resolver.isVerified(outsider));
        bytes32 uid = attestFor(farmer, 101, 1);
        revoke(uid);
        assertEq(resolver.verifiedWalletOf(ref(101)), address(0));
        attestFor(merchant, 102, 2);
        vm.warp(block.timestamp + YEAR);
        assertEq(resolver.verifiedWalletOf(ref(102)), address(0));
    }

    function test_RoleOf_And_GetKyc_ReturnDecodedData() public {
        uint64 farmerVerifiedAt = 1792689759;
        uint64 merchantVerifiedAt = 1792540800;
        vm.startPrank(issuer);
        bytes32 farmerUid = eas.attest(
            request(
                schemaUID,
                farmer,
                inAYear(),
                true,
                KrsiEncoding.kycData(ref(101), KrsiEncoding.ROLE_FARMER, KrsiEncoding.PROVIDER_SETU, farmerVerifiedAt)
            )
        );
        bytes32 merchantUid = eas.attest(
            request(
                schemaUID,
                merchant,
                inAYear(),
                true,
                KrsiEncoding.kycData(
                    ref(102), KrsiEncoding.ROLE_MERCHANT, KrsiEncoding.PROVIDER_DEMO, merchantVerifiedAt
                )
            )
        );
        vm.stopPrank();

        assertEq(resolver.roleOf(farmer), 1);
        assertEq(resolver.roleOf(merchant), 2);
        assertEq(resolver.roleOf(outsider), 0);

        KrsiKycResolver.KycView memory f = resolver.getKyc(farmer);
        assertEq(f.uid, farmerUid);
        assertEq(f.userRef, ref(101));
        assertEq(f.role, 1);
        assertEq(f.provider, bytes32("SETU_DIGILOCKER"));
        assertEq(f.kycVerifiedAt, farmerVerifiedAt);
        assertEq(f.expirationTime, inAYear());
        assertTrue(f.verified);

        KrsiKycResolver.KycView memory m = resolver.getKyc(merchant);
        assertEq(m.uid, merchantUid);
        assertEq(m.userRef, ref(102));
        assertEq(m.role, 2);
        assertEq(m.provider, bytes32("DEMO"));
        assertEq(m.kycVerifiedAt, merchantVerifiedAt);
        assertTrue(m.verified);

        KrsiKycResolver.KycView memory none = resolver.getKyc(outsider);
        assertEq(none.uid, bytes32(0));
        assertEq(none.role, 0);
        assertFalse(none.verified);

        vm.warp(block.timestamp + YEAR);
        assertEq(resolver.roleOf(farmer), 0);
        f = resolver.getKyc(farmer);
        assertEq(f.uid, farmerUid);
        assertEq(f.role, 1);
        assertFalse(f.verified);
    }

    // ---------- 21 to 23: admin and schema ----------

    function test_SetSchema_OnlyOwner_AndOnlyOnce() public {
        KrsiKycResolver fresh = new KrsiKycResolver(eas, issuer, owner);
        bytes32 uid = registry.register(SCHEMA, ISchemaResolver(address(fresh)), true);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        fresh.setSchema(uid);

        vm.prank(owner);
        vm.expectRevert(KrsiKycResolver.SchemaNotSet.selector);
        fresh.setSchema(bytes32(0));

        vm.prank(owner);
        vm.expectEmit(true, false, false, true, address(fresh));
        emit KrsiKycResolver.SchemaSet(uid);
        fresh.setSchema(uid);
        assertEq(fresh.schemaUID(), uid);

        vm.prank(owner);
        vm.expectRevert(KrsiKycResolver.SchemaAlreadySet.selector);
        fresh.setSchema(keccak256("another"));

        vm.prank(owner);
        vm.expectRevert(KrsiKycResolver.SchemaAlreadySet.selector);
        resolver.setSchema(uid);
    }

    function test_SetIssuer_OnlyOwner_RejectsZero() public {
        address newIssuer = makeAddr("newIssuer");

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        resolver.setIssuer(newIssuer);

        vm.prank(owner);
        vm.expectRevert(KrsiKycResolver.ZeroAddress.selector);
        resolver.setIssuer(address(0));

        vm.prank(owner);
        vm.expectEmit(true, true, false, true, address(resolver));
        emit KrsiKycResolver.IssuerChanged(issuer, newIssuer);
        resolver.setIssuer(newIssuer);
        assertEq(resolver.issuer(), newIssuer);

        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(KrsiKycResolver.NotIssuer.selector, issuer));
        eas.attest(request(schemaUID, farmer, inAYear(), true, data(101, 1)));

        vm.prank(newIssuer);
        eas.attest(request(schemaUID, farmer, inAYear(), true, data(101, 1)));
        assertTrue(resolver.isVerified(farmer));
    }

    function test_SchemaUID_MatchesEASFormula() public view {
        assertEq(schemaUID, keccak256(abi.encodePacked(SCHEMA, address(resolver), true)));
        assertEq(resolver.schemaUID(), schemaUID);
        SchemaRecord memory record = registry.getSchema(schemaUID);
        assertEq(record.uid, schemaUID);
        assertEq(address(record.resolver), address(resolver));
        assertTrue(record.revocable);
        assertEq(record.schema, SCHEMA);
    }

    // ---------- 24 to 26: SPEC conformance ----------

    function test_Spec_Signatures() public view {
        assertEq(resolver.isVerified.selector, bytes4(keccak256("isVerified(address)")));
        assertEq(resolver.verifiedWalletOf.selector, bytes4(keccak256("verifiedWalletOf(bytes32)")));
        assertEq(resolver.roleOf.selector, bytes4(keccak256("roleOf(address)")));
        assertEq(resolver.getKyc.selector, bytes4(keccak256("getKyc(address)")));
        assertEq(resolver.uidOf.selector, bytes4(keccak256("uidOf(address)")));
        assertEq(resolver.userRefOf.selector, bytes4(keccak256("userRefOf(address)")));
        assertEq(resolver.walletOf.selector, bytes4(keccak256("walletOf(bytes32)")));
        assertEq(resolver.issuer.selector, bytes4(keccak256("issuer()")));
        assertEq(resolver.schemaUID.selector, bytes4(keccak256("schemaUID()")));
        assertEq(resolver.setIssuer.selector, bytes4(keccak256("setIssuer(address)")));
        assertEq(resolver.setSchema.selector, bytes4(keccak256("setSchema(bytes32)")));
    }

    function test_Spec_EventsAndErrors() public pure {
        assertEq(KrsiKycResolver.KycLinked.selector, keccak256("KycLinked(bytes32,address,bytes32,uint8)"));
        assertEq(KrsiKycResolver.KycRevoked.selector, keccak256("KycRevoked(bytes32,address,bytes32)"));
        assertEq(KrsiKycResolver.IssuerChanged.selector, keccak256("IssuerChanged(address,address)"));
        assertEq(KrsiKycResolver.SchemaSet.selector, keccak256("SchemaSet(bytes32)"));

        assertEq(KrsiKycResolver.ZeroAddress.selector, bytes4(keccak256("ZeroAddress()")));
        assertEq(KrsiKycResolver.SchemaNotSet.selector, bytes4(keccak256("SchemaNotSet()")));
        assertEq(KrsiKycResolver.SchemaAlreadySet.selector, bytes4(keccak256("SchemaAlreadySet()")));
        assertEq(KrsiKycResolver.WrongSchema.selector, bytes4(keccak256("WrongSchema(bytes32)")));
        assertEq(KrsiKycResolver.NotIssuer.selector, bytes4(keccak256("NotIssuer(address)")));
        assertEq(KrsiKycResolver.ZeroRecipient.selector, bytes4(keccak256("ZeroRecipient()")));
        assertEq(KrsiKycResolver.NotRevocable.selector, bytes4(keccak256("NotRevocable()")));
        assertEq(KrsiKycResolver.MissingExpiry.selector, bytes4(keccak256("MissingExpiry()")));
        assertEq(KrsiKycResolver.ExpiryTooLong.selector, bytes4(keccak256("ExpiryTooLong()")));
        assertEq(KrsiKycResolver.InvalidUserRef.selector, bytes4(keccak256("InvalidUserRef()")));
        assertEq(KrsiKycResolver.InvalidRole.selector, bytes4(keccak256("InvalidRole(uint8)")));
        assertEq(KrsiKycResolver.UserAlreadyLinked.selector, bytes4(keccak256("UserAlreadyLinked(bytes32,address)")));
        assertEq(
            KrsiKycResolver.WalletAlreadyLinked.selector, bytes4(keccak256("WalletAlreadyLinked(address,bytes32)"))
        );
    }

    function testFuzz_UserRef_MatchesSpec(uint256 id) public pure {
        assertEq(KrsiEncoding.userRef(id), keccak256(abi.encode("KRSI_USER", id)));
        // The literal must be encoded as a dynamic string, which is what handoff/krsiChain.ts encodes.
        assertEq(KrsiEncoding.userRef(id), keccak256(abi.encode(string("KRSI_USER"), id)));
    }

    // ---------- extra checks beyond the mandatory list ----------

    function test_Constructor_RevertsWhen_ZeroIssuerOrOwner() public {
        vm.expectRevert(KrsiKycResolver.ZeroAddress.selector);
        new KrsiKycResolver(eas, address(0), owner);
        vm.expectRevert(KrsiKycResolver.ZeroAddress.selector);
        new KrsiKycResolver(eas, issuer, address(0));
    }

    function test_Constructor_SetsIssuerAndOwner_NotPayable() public view {
        assertEq(resolver.issuer(), issuer);
        assertEq(resolver.owner(), owner);
        assertFalse(resolver.isPayable());
        assertEq(resolver.MAX_VALIDITY(), 366 days);
    }

    /// SPEC 5.3: when two checks fail, the earlier one decides the error. One case per adjacent pair.
    function test_Attest_CheckOrder_FirstFailingCheckWins() public {
        bytes memory noRef = KrsiEncoding.kycData(bytes32(0), 0, KrsiEncoding.PROVIDER_SETU, uint64(block.timestamp));

        // 1 before 2 and 3: unset schema, outsider attester
        KrsiKycResolver fresh = new KrsiKycResolver(eas, issuer, owner);
        bytes32 freshSchema = registry.register(SCHEMA, ISchemaResolver(address(fresh)), true);
        vm.prank(outsider);
        vm.expectRevert(KrsiKycResolver.SchemaNotSet.selector);
        eas.attest(request(freshSchema, farmer, inAYear(), true, data(101, 1)));

        // 2 before 3: wrong schema, outsider attester
        bytes32 other = registry.register("uint256 other", ISchemaResolver(address(resolver)), true);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(KrsiKycResolver.WrongSchema.selector, other));
        eas.attest(request(other, farmer, inAYear(), true, data(101, 1)));

        // 3 before 4: outsider attester, zero recipient
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(KrsiKycResolver.NotIssuer.selector, outsider));
        eas.attest(request(schemaUID, address(0), inAYear(), true, data(101, 1)));

        // 4 before 5: zero recipient, not revocable
        vm.expectRevert(KrsiKycResolver.ZeroRecipient.selector);
        attestRaw(schemaUID, address(0), inAYear(), false, data(101, 1));

        // 5 before 6: not revocable, no expiry
        vm.expectRevert(KrsiKycResolver.NotRevocable.selector);
        attestRaw(schemaUID, farmer, 0, false, data(101, 1));

        // 6 before 8: no expiry, zero user reference
        vm.expectRevert(KrsiKycResolver.MissingExpiry.selector);
        attestRaw(schemaUID, farmer, 0, true, noRef);

        // 7 before 8: expiry too long, zero user reference
        vm.expectRevert(KrsiKycResolver.ExpiryTooLong.selector);
        attestRaw(schemaUID, farmer, uint64(block.timestamp) + 367 days, true, noRef);

        // 8 before 9: zero user reference, role 0
        vm.expectRevert(KrsiKycResolver.InvalidUserRef.selector);
        attestRaw(schemaUID, farmer, inAYear(), true, noRef);

        // 9 before 10: role 4 for a user already linked to another live wallet
        attestFor(farmer, 101, 1);
        vm.expectRevert(abi.encodeWithSelector(KrsiKycResolver.InvalidRole.selector, uint8(4)));
        attestRaw(schemaUID, farmer2, inAYear(), true, data(101, 4));

        // 10 before 11: user 101 is live on farmer, and farmer2 is live for user 102
        attestFor(farmer2, 102, 2);
        vm.expectRevert(abi.encodeWithSelector(KrsiKycResolver.UserAlreadyLinked.selector, ref(101), farmer));
        attestRaw(schemaUID, farmer2, inAYear(), true, data(101, 1));
    }

    function test_Attest_RevertsWhen_ZeroRecipient() public {
        vm.expectRevert(KrsiKycResolver.ZeroRecipient.selector);
        attestRaw(schemaUID, address(0), inAYear(), true, data(101, 1));
    }

    function test_Hooks_OnlyCallableByEAS() public {
        Attestation memory a;
        vm.prank(issuer);
        vm.expectRevert(AccessDenied.selector);
        resolver.attest(a);
    }
}
