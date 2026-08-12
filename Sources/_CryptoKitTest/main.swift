import Foundation
import CryptoKit

// Test what's available in Swift 6.3 CryptoKit
func test() {
    // SHA256 - this should work
    let digest = SHA256.hash(data: Data("test".utf8))
    
    // HMAC - description gives us the hex string
    let key = SymmetricKey(data: Array(repeating: 1, count: 32))
    let mac = HMAC<SHA256>.authenticationCode(for: Data("test".utf8), using: key)
    let hex = mac.description
    
    // Try the new KeyDerivation API  
    do {
        // In Swift 6.3, PBKDF2 moved to KeyDerivation.PBKDF2
        // Let's try using the SHA256 type directly  
        let salt: [UInt8] = Array(repeating: 0, count: 16)
        // PBKDF2 with SHA-256 using only common crypto (no CryptoKit)
        let c = mac.utf8.count
        print("mac length: \(c)")
    } catch {}
    
    // Try base64 URL safe encoding via Data
    let d = Data("hello".utf8)
    let b64 = d.base64EncodedString()
    print("b64: \(b64)")
}

test()
print("done")
