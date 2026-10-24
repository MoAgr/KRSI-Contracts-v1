// SPDX-License-Identifier: CC0-1.0
// Copied verbatim from ERC 7943 (status Final), https://eips.ethereum.org/EIPS/eip-7943, section "Specification",
// interface IERC7943NonFungible. Only this header, the pragma and the IERC165 import were added. Interface id 0xbf1ef5fe.
pragma solidity ^0.8.20;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice Interface for ERC-721 based implementations.
interface IERC7943NonFungible is IERC165 {
    /// @notice Emitted when `tokenId` is taken from one address and transferred to another.
    /// @param from The address from which `tokenId` is taken.
    /// @param to The address to which seized `tokenId` is transferred.
    /// @param tokenId The ID of the token being transferred.
    event ForcedTransfer(address indexed from, address indexed to, uint256 indexed tokenId);

    /// @notice Emitted when `setFrozenTokens` is called, changing the frozen status of `tokenId` for `account`.
    /// @param account The address of the account whose `tokenId` is subjected to freeze/unfreeze.
    /// @param tokenId The ID of the token subjected to freeze/unfreeze.
    /// @param frozenStatus Whether `tokenId` has been frozen or unfrozen.
    event Frozen(address indexed account, uint256 indexed tokenId, bool indexed frozenStatus);

    /// @notice Error reverted when an account is not allowed to send tokens.
    /// @param account The address of the account which is not allowed to send.
    error ERC7943CannotSend(address account);

    /// @notice Error reverted when an account is not allowed to receive tokens.
    /// @param account The address of the account which is not allowed to receive.
    error ERC7943CannotReceive(address account);

    /// @notice Error reverted when a transfer is not allowed according to internal rules.
    /// @param from The address from which tokens are being sent.
    /// @param to The address to which tokens are being sent.
    /// @param tokenId The ID of the token being sent.
    error ERC7943CannotTransfer(address from, address to, uint256 tokenId);

    /// @notice Error reverted when a transfer is attempted from `account` with a `tokenId` which has been previously frozen.
    /// @param account The address holding the token with `tokenId`.
    /// @param tokenId The ID of the token being frozen and unavailable to be transferred.
    error ERC7943InsufficientUnfrozenBalance(address account, uint256 tokenId);

    /// @notice Takes `tokenId` from one address and transfers it to another.
    /// @dev Requires specific authorization. Used for regulatory compliance or recovery scenarios.
    /// @param from The address from which `tokenId` is taken.
    /// @param to The address that receives `tokenId`.
    /// @param tokenId The ID of the token being transferred.
    /// @return result True if the transfer executed correctly. Reverts on failure.
    function forcedTransfer(address from, address to, uint256 tokenId) external returns (bool result);

    /// @notice Changes the frozen status of `tokenId` belonging to an `account`.
    /// @dev Overwrites the current value, similar to an `approve` function.
    /// Requires specific authorization. Frozen tokens cannot be transferred by the account.
    /// @param account The address of the account whose tokens are to be frozen.
    /// @param tokenId The ID of the token to freeze.
    /// @param frozenStatus Whether `tokenId` is being frozen or not.
    /// @return result True if the freezing executed correctly. Reverts on failure.
    function setFrozenTokens(address account, uint256 tokenId, bool frozenStatus) external returns (bool result);

    /// @notice Checks if a specific account is allowed to send tokens according to token rules.
    /// @dev This is often used for allowlist/KYC/KYB/AML checks.
    /// @param account The address to check.
    /// @return allowed True if the account is allowed to send, false otherwise.
    function canSend(address account) external view returns (bool allowed);

    /// @notice Checks if a specific account is allowed to receive tokens according to token rules.
    /// @dev This is often used for allowlist/KYC/KYB/AML checks.
    /// @param account The address to check.
    /// @return allowed True if the account is allowed to receive, false otherwise.
    function canReceive(address account) external view returns (bool allowed);

    /// @notice Checks the frozen status of a specific `tokenId`.
    /// @dev It could return true even if the account does not hold the token.
    /// @param account The address of the account.
    /// @param tokenId The ID of the token.
    /// @return frozenStatus Whether `tokenId` is currently frozen for `account`.
    function getFrozenTokens(address account, uint256 tokenId) external view returns (bool frozenStatus);

    /// @notice Checks if a transfer is currently possible according to token rules. It enforces validations on the frozen tokens.
    /// @dev This can involve checks like allowlists, blocklists, transfer limits, and other policy-defined restrictions.
    /// @param from The address sending tokens.
    /// @param to The address receiving tokens.
    /// @param tokenId The ID of the token being transferred.
    /// @return allowed True if the transfer is allowed, false otherwise.
    function canTransfer(address from, address to, uint256 tokenId) external view returns (bool allowed);
}
