// Checks an update's EdDSA signature against the public key the app carries (SUPublicEDKey), the same check
// installed copies make before they accept an update. Scripts/release.sh runs it on every release: a release
// signed with a key that does not match the app would publish fine and then be refused by every installed copy.
// usage: swift Scripts/verify-update-signature.swift <file> <base64 signature> <base64 public key>
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4,
      let file = FileManager.default.contents(atPath: arguments[1]),
      let signature = Data(base64Encoded: arguments[2]),
      let keyData = Data(base64Encoded: arguments[3]),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
else {
    FileHandle.standardError.write(Data("usage: verify-update-signature.swift <file> <base64 signature> <base64 public key>\n".utf8))
    exit(2)
}
exit(key.isValidSignature(signature, for: file) ? 0 : 1)
