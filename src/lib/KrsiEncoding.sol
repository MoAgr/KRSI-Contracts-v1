// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The shared encodings of SPEC section 4. handoff/krsiChain.ts implements the same functions, and
/// handoff/vectors.json pins both to the same outputs.
library KrsiEncoding {
    bytes32 internal constant PROVIDER_SETU = bytes32("SETU_DIGILOCKER");
    bytes32 internal constant PROVIDER_DEMO = bytes32("DEMO");
    uint8 internal constant ROLE_FARMER = 1;
    uint8 internal constant ROLE_MERCHANT = 2;
    uint8 internal constant ROLE_WAREHOUSE_OWNER = 3;

    /// @notice SPEC 4.1: keccak256(abi.encode("KRSI_USER", uint256 userId)), the string encoded as a dynamic string.
    function userRef(uint256 userId) internal pure returns (bytes32) {
        return keccak256(abi.encode("KRSI_USER", userId));
    }

    /// @notice SPEC 4.10: keccak256 of the slug's bytes.
    function warehouseKey(string memory slug) internal pure returns (bytes32) {
        return keccak256(bytes(slug));
    }

    /// @notice SPEC 4.8: keccak256(abi.encode(string qualityRemarks, uint64 inspectedAtSeconds)).
    function inspectionHash(string memory remarks, uint64 inspectedAt) internal pure returns (bytes32) {
        return keccak256(abi.encode(remarks, inspectedAt));
    }

    /// @notice SPEC 4.12: the attestation data for the schema in SPEC 5.1.
    function kycData(bytes32 userRef_, uint8 role, bytes32 provider, uint64 kycVerifiedAt)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(userRef_, role, provider, kycVerifiedAt);
    }

    /// @notice SPEC 4.13: 1 to 64 bytes of printable ASCII (0x20 to 0x7E), without double quote or backslash.
    function isValidShortString(string memory s) internal pure returns (bool) {
        bytes memory b = bytes(s);
        if (b.length == 0 || b.length > 64) return false;
        for (uint256 i = 0; i < b.length; ++i) {
            bytes1 c = b[i];
            if (c < 0x20 || c > 0x7E || c == 0x22 || c == 0x5C) return false;
        }
        return true;
    }
}
