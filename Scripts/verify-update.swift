import Foundation
import CryptoKit

// Independent check against the key actually embedded in the shipped application.
// No private key, network, credentials, or app execution is needed.
do {
    guard CommandLine.arguments.count == 5 else { throw CocoaError(.fileReadInvalidFileName) }
    let paths = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
    let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: paths[0]), format: nil) as? [String: Any]
    guard let encodedKey = info?["SUPublicEDKey"] as? String, let keyData = Data(base64Encoded: encodedKey) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    let feed = try Data(contentsOf: paths[1])
    // Sparkle 2.9+ signs all XML bytes before this trailing signing block.
    let marker = Data("<!-- sparkle-signatures:\n".utf8)
    guard let block = feed.range(of: marker, options: .backwards),
          let signingText = String(data: feed[block.lowerBound...], encoding: .utf8) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let lines = signingText.split(separator: "\n")
    guard lines.count == 4, lines[0] == "<!-- sparkle-signatures:", lines[3] == "-->",
          lines[1].hasPrefix("edSignature: "), lines[2].hasPrefix("length: "),
          let feedSignature = Data(base64Encoded: String(lines[1].dropFirst(13))),
          Int(lines[2].dropFirst(8)) == block.lowerBound,
          key.isValidSignature(feedSignature, for: feed[..<block.lowerBound]) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let xml = try XMLDocument(data: feed, options: [])
    let enclosures = try xml.nodes(forXPath: "/rss/channel/item/enclosure")
    guard enclosures.count == 1, let enclosure = enclosures.first as? XMLElement,
          let signature = enclosure.attribute(forName: "sparkle:edSignature")?.stringValue.flatMap({ Data(base64Encoded: $0) }),
          enclosure.attribute(forName: "url")?.stringValue == CommandLine.arguments[4],
          let length = enclosure.attribute(forName: "length")?.stringValue.flatMap(Int.init),
          try xml.nodes(forXPath: "/rss/channel/item/sparkle:version").first?.stringValue == info?["CFBundleVersion"] as? String
    else { throw CocoaError(.fileReadCorruptFile) }
    let archive = try Data(contentsOf: paths[2], options: .mappedIfSafe)
    guard length == archive.count, key.isValidSignature(signature, for: archive) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    print("Update feed and archive signatures, version, length and download URL verified.")
} catch {
    fputs("Update verification failed. Refusing to publish.\n", stderr)
    exit(1)
}
