import Testing
import Foundation
import CryptoKit

@Test func explore_crypto_kit() {
    let salt: [UInt8] = Array(repeating: 0, count: 16)
    let pw = "testpassword"
    
    // Try KeyDerivation.PBKDF2 with explicit types and different param styles
    let params: KeyDerivation.PBKDF2<SHA256>.Parameters = .pbkdf2(iterations: 1000)
    
    let derived = PBKDF2<SHA256>.derivedPassword(
        length: .bytes(32),
        type: params,
        using: Password(pw),
        salt: .init(salt)
    )
    
    print("derived count:", derived.count)
}
