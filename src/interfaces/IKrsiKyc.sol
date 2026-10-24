// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice What KrsiReceipt needs from the KYC resolver (SPEC 5.2).
interface IKrsiKyc {
    /// @notice True when the wallet's linked attestation exists, is not revoked and has not expired.
    function isVerified(address wallet) external view returns (bool);

    /// @notice The wallet linked to a user reference if that wallet is verified, otherwise address(0).
    function verifiedWalletOf(bytes32 userRef) external view returns (address);
}
