// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {KrsiEncoding} from "../src/lib/KrsiEncoding.sol";
import {GenerateVectors} from "../script/GenerateVectors.s.sol";

/// Phase 4 test 1: handoff/vectors.json matches KrsiEncoding and holds every vector TESTS.md lists.
contract VectorsTest is Test {
    string internal json;

    function setUp() public {
        json = vm.readFile("handoff/vectors.json");
    }

    function test_Vectors_FileMatchesEncodingLibrary() public {
        // The file is exactly what the script writes today, so it cannot drift from the library.
        assertEq(json, new GenerateVectors().json(), "vectors.json is stale: run script/GenerateVectors.s.sol");

        uint256[5] memory ids = [uint256(1), 42, 101, 102, 2 ** 53];
        for (uint256 i = 0; i < ids.length; ++i) {
            string memory at = string.concat(".userRef[", vm.toString(i), "]");
            assertEq(vm.parseUint(vm.parseJsonString(json, string.concat(at, ".userId"))), ids[i]);
            assertEq(vm.parseJsonBytes32(json, string.concat(at, ".out")), KrsiEncoding.userRef(ids[i]));
        }
        assertFalse(vm.keyExistsJson(json, ".userRef[5]"));

        assertEq(vm.parseJsonString(json, ".provider[0].name"), "SETU_DIGILOCKER");
        assertEq(vm.parseJsonBytes32(json, ".provider[0].out"), KrsiEncoding.PROVIDER_SETU);
        assertEq(vm.parseJsonString(json, ".provider[1].name"), "DEMO");
        assertEq(vm.parseJsonBytes32(json, ".provider[1].out"), KrsiEncoding.PROVIDER_DEMO);

        assertEq(vm.parseJsonString(json, ".warehouseKey[0].slug"), "agri-vault");
        assertEq(vm.parseJsonBytes32(json, ".warehouseKey[0].out"), KrsiEncoding.warehouseKey("agri-vault"));

        checkInspectionHash(0, "Fine", 1792656000);
        checkInspectionHash(1, "", 0);

        checkKycData(0, 101, KrsiEncoding.ROLE_FARMER, "SETU_DIGILOCKER", KrsiEncoding.PROVIDER_SETU);
        checkKycData(1, 102, KrsiEncoding.ROLE_MERCHANT, "DEMO", KrsiEncoding.PROVIDER_DEMO);

        for (uint256 i = 0; vm.keyExistsJson(json, string.concat(".shortString[", vm.toString(i), "]")); ++i) {
            string memory at = string.concat(".shortString[", vm.toString(i), "]");
            string memory input = string(vm.parseJsonBytes(json, string.concat(at, ".inHex")));
            assertEq(vm.parseJsonBool(json, string.concat(at, ".out")), KrsiEncoding.isValidShortString(input));
        }
    }

    function checkInspectionHash(uint256 i, string memory remarks, uint64 at) internal view {
        string memory p = string.concat(".inspectionHash[", vm.toString(i), "]");
        assertEq(vm.parseJsonString(json, string.concat(p, ".remarks")), remarks);
        assertEq(vm.parseUint(vm.parseJsonString(json, string.concat(p, ".inspectedAt"))), at);
        assertEq(vm.parseJsonBytes32(json, string.concat(p, ".out")), KrsiEncoding.inspectionHash(remarks, at));
    }

    function checkKycData(uint256 i, uint256 userId, uint8 role, string memory providerName, bytes32 provider)
        internal
        view
    {
        string memory p = string.concat(".kycData[", vm.toString(i), "]");
        assertEq(vm.parseUint(vm.parseJsonString(json, string.concat(p, ".userId"))), userId);
        bytes32 ref = vm.parseJsonBytes32(json, string.concat(p, ".userRef"));
        assertEq(ref, KrsiEncoding.userRef(userId));
        assertEq(vm.parseJsonUint(json, string.concat(p, ".role")), role);
        assertEq(vm.parseJsonString(json, string.concat(p, ".provider")), providerName);
        uint64 at = uint64(vm.parseUint(vm.parseJsonString(json, string.concat(p, ".kycVerifiedAt"))));
        assertEq(vm.parseJsonBytes(json, string.concat(p, ".out")), KrsiEncoding.kycData(ref, role, provider, at));
    }
}
