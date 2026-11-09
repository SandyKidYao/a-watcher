import Foundation
import CryptoKit

let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
let key = Curve25519.Signing.PrivateKey()
let bytes = Data("update archive fixture".utf8)
let signature = try key.signature(for: bytes).base64EncodedString()
let download = "https://github.com/SandyKidYao/a-watcher/releases/download/v0.7.0/app.zip"
let plist = folder.appendingPathComponent("Info.plist")
let archive = folder.appendingPathComponent("app.zip")
let feed = folder.appendingPathComponent("appcast.xml")
var failures = 0

func check(_ name: String, valid: Bool, payload: Data = bytes,
           publicKey: Data = key.publicKey.rawRepresentation, version: String = "0.7.0",
           length: Int = bytes.count, url: String = download, signed: Bool = true, tamperFeed: Bool = false) throws {
    try PropertyListSerialization.data(fromPropertyList: ["SUPublicEDKey": publicKey.base64EncodedString(), "CFBundleVersion": "0.7.0"], format: .xml, options: 0).write(to: plist)
    try payload.write(to: archive)
    let signatureAttribute = signed ? "sparkle:edSignature=\"\(signature)\"" : ""
    let xml = """
    <?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
    <sparkle:version>\(version)</sparkle:version><enclosure url="\(url)" length="\(length)" \(signatureAttribute) />
    </item></channel></rss>
    """
    var xmlBytes = Data(xml.utf8)
    let xmlSignature = try key.signature(for: xmlBytes).base64EncodedString()
    let signingBlock = "<!-- sparkle-signatures:\nedSignature: \(xmlSignature)\nlength: \(xmlBytes.count)\n-->\n"
    if tamperFeed { xmlBytes[xmlBytes.count - 1] ^= 1 }
    xmlBytes.append(Data(signingBlock.utf8))
    try xmlBytes.write(to: feed)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
    process.arguments = [plist.path, feed.path, archive.path, download]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run(); process.waitUntilExit()
    let passed = (process.terminationStatus == 0) == valid
    print("\(passed ? "PASS" : "FAIL") \(name)")
    if !passed { failures += 1 }
}
try check("valid signed archive", valid: true)
var tampered = bytes; tampered[0] ^= 1
try check("same-length tampering rejected", valid: false, payload: tampered)
try check("wrong key rejected", valid: false, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
try check("wrong version rejected", valid: false, version: "0.8.0")
try check("wrong length rejected", valid: false, length: 1)
try check("wrong download URL rejected", valid: false, url: "https://example.com/app.zip")
try check("unsigned archive rejected", valid: false, signed: false)
try check("tampered signed feed rejected", valid: false, tamperFeed: true)
exit(failures == 0 ? 0 : 1)
