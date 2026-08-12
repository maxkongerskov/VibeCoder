//
//  MCPPKCE.swift
//
//  PKCE (Proof Key for Code Exchange, RFC 7636) helpers for the MCP
//  OAuth flow. We implement S256 — the only method every spec-compliant
//  authorization server is required to support — using CryptoKit for the
//  SHA-256 hash and URL-safe base64 for encoding.
//
//  Why PKCE: MCP servers that require OAuth are remote HTTP endpoints,
//  and the authorization code is delivered via a browser redirect. Without
//  PKCE, a malicious app watching loopback redirects could steal the code.
//  With S256, the server verifies `BASE64URL(SHA256(verifier))` against
//  what we sent in the authorize URL — only the original client that holds
//  `verifier` can complete the token exchange.
//
//  Ported from Grok Build's rmcp 2.1 `PkceCodeChallenge::new_random_sha256`
//  (auth.rs:1304-1345). Grok uses the `oauth-in-action` crate; we
//  re-implement the two tiny pieces we need in Swift so there's no new
//  dependency.
//

import Foundation
import CryptoKit

/// PKCE (RFC 7636) code challenge + verifier pair, using the S256 method.
///
/// - `verifier`: random 43-char URL-safe string stored client-side only.
///   Sent to the token endpoint with the authorization code.
/// - `challenge`: `BASE64URL(SHA256(verifier))`, sent in the authorize URL
///   so the server can verify `verifier` matches.
public struct MCPPKCEPair: Sendable, Equatable {
    public let verifier: String
    public let challenge: String

    /// Generate a new random PKCE pair (S256 method).
    public static func generate() -> MCPPKCEPair {
        // 32 bytes (256 bits) of randomness → 43 url-safe base64 chars.
        // RFC 7636 §4.1: verifier MUST be 43-128 chars; 32 raw bytes →
        // 43 base64 chars is the minimum safe length.
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        // SecRandomCopyBytes practically never fails; if it does we fall
        // back to Swift.Random, which is cryptographically adequate on
        // Apple platforms (uses arc4random_buf under the hood).
        if status != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        }

        let verifier = base64URLEncode(Data(bytes))
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = base64URLEncode(Data(digest))

        return MCPPKCEPair(verifier: verifier, challenge: challenge)
    }

    /// S256 code challenge method string ("S256") — the only method we
    /// support, matching Grok Build.
    public static let method = "S256"

    /// Validate a PKCE pair — the challenge must equal S256(verifier).
    public func isValid() -> Bool {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest)) == challenge
    }
}

/// URL-safe Base64 encoding (RFC 4648 §5) — replaces `+`/`=` with `-`/
/// (stripped). Used by PKCE and JWT-ish values throughout the OAuth flow.
public func base64URLEncode(_ data: Data) -> String {
    var s = data.base64EncodedString()
    s = s.replacingOccurrences(of: "+", with: "-")
    s = s.replacingOccurrences(of: "/", with: "_")
    // Strip padding — base64url is unpadded per spec.
    while s.hasSuffix("=") { s.removeLast() }
    return s
}

/// Random alphanumeric state token for CSRF protection (OAuth 2.0 state
/// parameter, RFC 6749 §10.12). 32 bytes → 43 url-safe chars.
public func generateStateToken() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    if status != errSecSuccess {
        bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
    }
    return base64URLEncode(Data(bytes))
}