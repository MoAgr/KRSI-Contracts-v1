// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {KrsiEncoding} from "../src/lib/KrsiEncoding.sol";
import {IERC7943NonFungible} from "../src/interfaces/IERC7943NonFungible.sol";

/// Pins KrsiEncoding to the literal definitions of SPEC section 4, and the ERC 7943 interface id (SPEC 3.5).
contract KrsiEncodingTest is Test {
    function test_IERC7943NonFungible_InterfaceId() public pure {
        assertEq(type(IERC7943NonFungible).interfaceId, bytes4(0xbf1ef5fe));
    }

    function test_Constants_MatchSpec() public pure {
        assertEq(KrsiEncoding.PROVIDER_SETU, bytes32(bytes("SETU_DIGILOCKER")));
        assertEq(KrsiEncoding.PROVIDER_SETU, 0x534554555f444947494c4f434b45520000000000000000000000000000000000);
        assertEq(KrsiEncoding.PROVIDER_DEMO, 0x44454d4f00000000000000000000000000000000000000000000000000000000);
        assertEq(KrsiEncoding.ROLE_FARMER, 1);
        assertEq(KrsiEncoding.ROLE_MERCHANT, 2);
        assertEq(KrsiEncoding.ROLE_WAREHOUSE_OWNER, 3);
    }

    function test_WarehouseKey_IsKeccakOfSlugBytes() public pure {
        assertEq(KrsiEncoding.warehouseKey("agri-vault"), keccak256(bytes("agri-vault")));
    }

    function test_InspectionHash_MatchesSpec() public pure {
        assertEq(
            KrsiEncoding.inspectionHash("Fine", 1792656000), keccak256(abi.encode(string("Fine"), uint64(1792656000)))
        );
        assertEq(KrsiEncoding.inspectionHash("", 0), keccak256(abi.encode(string(""), uint64(0))));
    }

    function test_KycData_RoundTrips() public pure {
        bytes32 r = KrsiEncoding.userRef(101);
        bytes memory encoded = KrsiEncoding.kycData(r, 1, KrsiEncoding.PROVIDER_SETU, 1792689759);
        assertEq(encoded, abi.encode(r, uint8(1), KrsiEncoding.PROVIDER_SETU, uint64(1792689759)));
        assertEq(encoded.length, 128);
        (bytes32 r2, uint8 role, bytes32 provider, uint64 at) = abi.decode(encoded, (bytes32, uint8, bytes32, uint64));
        assertEq(r2, r);
        assertEq(role, 1);
        assertEq(provider, KrsiEncoding.PROVIDER_SETU);
        assertEq(at, 1792689759);
    }

    function test_IsValidShortString() public pure {
        assertTrue(KrsiEncoding.isValidShortString("ENWR-000006"));
        assertTrue(KrsiEncoding.isValidShortString("agri-vault"));
        assertTrue(KrsiEncoding.isValidShortString(" ~"));
        assertTrue(KrsiEncoding.isValidShortString(string(_repeat("a", 64))));
        assertFalse(KrsiEncoding.isValidShortString(""));
        assertFalse(KrsiEncoding.isValidShortString(string(_repeat("a", 65))));
        assertFalse(KrsiEncoding.isValidShortString("say \"hi\""));
        assertFalse(KrsiEncoding.isValidShortString("back\\slash"));
        assertFalse(KrsiEncoding.isValidShortString("new\nline"));
        assertFalse(KrsiEncoding.isValidShortString("tab\t"));
        assertFalse(KrsiEncoding.isValidShortString(string(hex"7f")));
        assertFalse(KrsiEncoding.isValidShortString(unicode"café"));
    }

    function _repeat(bytes1 c, uint256 n) private pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i = 0; i < n; ++i) {
            out[i] = c;
        }
    }
}
