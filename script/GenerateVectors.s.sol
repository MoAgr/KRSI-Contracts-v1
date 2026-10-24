// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {KrsiEncoding} from "../src/lib/KrsiEncoding.sol";

/// SPEC 7.5 and 8.4: writes handoff/vectors.json, the golden outputs of KrsiEncoding that the Solidity and the
/// TypeScript suites both check. Integers are decimal strings, because 2^53 is not a safe JavaScript number.
/// forge script script/GenerateVectors.s.sol
contract GenerateVectors is Script {
    string public constant OUTPUT = "handoff/vectors.json";
    string public constant DEMO_SLUG = "agri-vault"; // FINDINGS F10, DEVIATIONS D5

    function run() external {
        vm.writeFile(OUTPUT, json());
    }

    function json() public pure returns (string memory) {
        return string.concat(
            '{"generatedBy":"script/GenerateVectors.s.sol","userRef":[',
            _userRefs(),
            '],"provider":[',
            _provider("SETU_DIGILOCKER", KrsiEncoding.PROVIDER_SETU),
            ",",
            _provider("DEMO", KrsiEncoding.PROVIDER_DEMO),
            '],"warehouseKey":[',
            _warehouseKey(DEMO_SLUG),
            '],"inspectionHash":[',
            _inspectionHash("Fine", 1792656000),
            ",",
            _inspectionHash("", 0),
            '],"kycData":[',
            _kycData(101, KrsiEncoding.ROLE_FARMER, "SETU_DIGILOCKER", KrsiEncoding.PROVIDER_SETU, 1792689759),
            ",",
            _kycData(102, KrsiEncoding.ROLE_MERCHANT, "DEMO", KrsiEncoding.PROVIDER_DEMO, 1792540800),
            '],"shortString":[',
            _shortStrings(),
            "]}"
        );
    }

    function _userRefs() private pure returns (string memory out) {
        uint256[5] memory ids = [uint256(1), 42, 101, 102, 2 ** 53];
        for (uint256 i = 0; i < ids.length; ++i) {
            out = string.concat(
                out,
                i == 0 ? "" : ",",
                '{"userId":"',
                vm.toString(ids[i]),
                '","out":"',
                vm.toString(KrsiEncoding.userRef(ids[i])),
                '"}'
            );
        }
    }

    function _provider(string memory name, bytes32 value) private pure returns (string memory) {
        return string.concat('{"name":"', name, '","out":"', vm.toString(value), '"}');
    }

    function _warehouseKey(string memory slug) private pure returns (string memory) {
        return string.concat('{"slug":"', slug, '","out":"', vm.toString(KrsiEncoding.warehouseKey(slug)), '"}');
    }

    function _inspectionHash(string memory remarks, uint64 at) private pure returns (string memory) {
        return string.concat(
            '{"remarks":"',
            remarks,
            '","inspectedAt":"',
            vm.toString(uint256(at)),
            '","out":"',
            vm.toString(KrsiEncoding.inspectionHash(remarks, at)),
            '"}'
        );
    }

    function _kycData(uint256 userId, uint8 role, string memory providerName, bytes32 provider, uint64 verifiedAt)
        private
        pure
        returns (string memory)
    {
        bytes32 ref = KrsiEncoding.userRef(userId);
        return string.concat(
            '{"userId":"',
            vm.toString(userId),
            '","userRef":"',
            vm.toString(ref),
            '","role":',
            vm.toString(uint256(role)),
            ',"provider":"',
            providerName,
            '","kycVerifiedAt":"',
            vm.toString(uint256(verifiedAt)),
            '","out":"',
            vm.toString(KrsiEncoding.kycData(ref, role, provider, verifiedAt)),
            '"}'
        );
    }

    /// Inputs as hex so quotes, backslashes and control bytes survive the JSON.
    function _shortStrings() private pure returns (string memory out) {
        string[9] memory inputs = [
            "ENWR-000006",
            "agri-vault",
            "Grade A",
            "",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            'Grade "A"',
            "back\\slash",
            "new\nline"
        ];
        for (uint256 i = 0; i < inputs.length; ++i) {
            out = string.concat(
                out,
                i == 0 ? "" : ",",
                '{"inHex":"',
                vm.toString(bytes(inputs[i])),
                '","out":',
                KrsiEncoding.isValidShortString(inputs[i]) ? "true" : "false",
                "}"
            );
        }
    }
}
