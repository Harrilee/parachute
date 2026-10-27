import CryptoKit
import Foundation

// Public data only. This verifies that CI's private key actually corresponds to
// the public key embedded in the application before an appcast can be produced.
guard CommandLine.arguments.count == 4,
      let keyText = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8),
      let keyData = Data(base64Encoded: keyText.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
      let archive = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])),
      let signature = Data(base64Encoded: CommandLine.arguments[3]),
      key.isValidSignature(signature, for: archive) else {
    fputs("Update signature does not match the application's public key.\n", stderr)
    exit(1)
}
