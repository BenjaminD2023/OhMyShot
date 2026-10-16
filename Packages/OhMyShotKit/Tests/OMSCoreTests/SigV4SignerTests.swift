import Foundation
import Testing
@testable import OMSCore

/// The worked examples from AWS's S3 documentation ("Signature Calculations for the Authorization Header"
/// and "Authenticating Requests: Using Query Parameters"), with the example credentials printed there.
struct SigV4SignerTests {
    static let signer = SigV4Signer(
        accessKeyID: "AKIAIOSFODNN7EXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        region: "us-east-1"
    )
    /// Fri, 24 May 2013 00:00:00 GMT
    static let date = Date(timeIntervalSince1970: 1_369_353_600)

    @Test func getObjectWithARange() {
        let signed = Self.signer.sign(
            method: "GET",
            canonicalPath: "/test.txt",
            headers: [
                "Host": "examplebucket.s3.amazonaws.com",
                "Range": "bytes=0-9",
                "x-amz-content-sha256": SigV4Signer.emptyPayloadHash,
                "x-amz-date": "20130524T000000Z",
            ],
            payloadHash: SigV4Signer.emptyPayloadHash,
            date: Self.date
        )
        #expect(signed.canonicalRequest == """
        GET
        /test.txt

        host:examplebucket.s3.amazonaws.com
        range:bytes=0-9
        x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        x-amz-date:20130524T000000Z

        host;range;x-amz-content-sha256;x-amz-date
        e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        """)
        #expect(signed.stringToSign == """
        AWS4-HMAC-SHA256
        20130524T000000Z
        20130524/us-east-1/s3/aws4_request
        7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972
        """)
        #expect(signed.signature == "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
        // The documentation prints no space after the commas; so does this signer.
        #expect(signed.authorization == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,SignedHeaders=host;range;x-amz-content-sha256;x-amz-date,Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    @Test func putObjectWithADollarInItsName() {
        let payload = "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072"
        let signed = Self.signer.sign(
            method: "PUT",
            canonicalPath: "/" + SigV4Signer.encodePath("test$file.text"),
            headers: [
                "Date": "Fri, 24 May 2013 00:00:00 GMT",
                "Host": "examplebucket.s3.amazonaws.com",
                "x-amz-date": "20130524T000000Z",
                "x-amz-storage-class": "REDUCED_REDUNDANCY",
                "x-amz-content-sha256": payload,
            ],
            payloadHash: payload,
            date: Self.date
        )
        #expect(signed.canonicalRequest == """
        PUT
        /test%24file.text

        date:Fri, 24 May 2013 00:00:00 GMT
        host:examplebucket.s3.amazonaws.com
        x-amz-content-sha256:44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072
        x-amz-date:20130524T000000Z
        x-amz-storage-class:REDUCED_REDUNDANCY

        date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class
        44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072
        """)
        #expect(signed.stringToSign.hasSuffix("9e0e90d9c76de8fa5b200d8c849cd5b8dc7a3be3951ddb7f6a76b4158342019d"))
        #expect(signed.signature == "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd")
        #expect(signed.authorization.hasSuffix("SignedHeaders=date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class,Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"))
    }

    @Test func theBodyHashOfThePutExampleIsTheHashOfItsText() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "sigv4-\(UUID().uuidString).txt")
        try Data("Welcome to Amazon S3.".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let hash = try await SigV4Signer.sha256(ofFileAt: file)
        #expect(hash == "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072")
    }

    @Test func bucketLifecycleQueryWithAnEmptyValue() {
        let signed = Self.signer.sign(
            method: "GET",
            canonicalPath: "/",
            query: [("lifecycle", "")],
            headers: [
                "host": "examplebucket.s3.amazonaws.com",
                "x-amz-date": "20130524T000000Z",
                "x-amz-content-sha256": SigV4Signer.emptyPayloadHash,
            ],
            payloadHash: SigV4Signer.emptyPayloadHash,
            date: Self.date
        )
        #expect(signed.canonicalRequest.contains("\n/\nlifecycle=\n"))
        #expect(signed.stringToSign.hasSuffix("9766c798316ff2757b517bc739a67f6213b4ab36dd5da2f94eaebf79c77395ca"))
        #expect(signed.signature == "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543")
    }

    @Test func listObjectsSortsItsQuery() {
        let signed = Self.signer.sign(
            method: "GET",
            canonicalPath: "/",
            query: [("prefix", "J"), ("max-keys", "2")],
            headers: [
                "host": "examplebucket.s3.amazonaws.com",
                "x-amz-date": "20130524T000000Z",
                "x-amz-content-sha256": SigV4Signer.emptyPayloadHash,
            ],
            payloadHash: SigV4Signer.emptyPayloadHash,
            date: Self.date
        )
        #expect(signed.canonicalRequest.contains("\n/\nmax-keys=2&prefix=J\n"))
        #expect(signed.stringToSign.hasSuffix("df57d21db20da04d7fa30298dd4488ba3a2b47ca3a489c74750e0f1e7df1b9b7"))
        #expect(signed.signature == "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7")
    }

    @Test func presignedUrl() {
        let presigned = Self.signer.presignedQuery(
            canonicalPath: "/test.txt",
            host: "examplebucket.s3.amazonaws.com",
            expires: 86_400,
            date: Self.date
        )
        #expect(presigned.canonicalRequest == """
        GET
        /test.txt
        X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host
        host:examplebucket.s3.amazonaws.com

        host
        UNSIGNED-PAYLOAD
        """)
        #expect(presigned.stringToSign.hasSuffix("3bfa292879f6447bbcda7001decf97f4a54dc650c8942174ae0a9121cf58ad04"))
        #expect(presigned.signature == "aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404")
        #expect("https://examplebucket.s3.amazonaws.com/test.txt?" + presigned.query == "https://examplebucket.s3.amazonaws.com/test.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404")
    }

    // MARK: Encoding

    @Test func keysAreEncodedOnceWithTheirSlashesKept() {
        let key = "shots/CleanShot 2026-10-16 at 14.02.11 微信+a#b.png"
        #expect(SigV4Signer.encodePath(key) == "shots/CleanShot%202026-10-16%20at%2014.02.11%20%E5%BE%AE%E4%BF%A1%2Ba%23b.png")
        #expect(SigV4Signer.encode("a/b c~d") == "a%2Fb%20c~d")
    }

    @Test func theTimestampIsUTC() {
        #expect(SigV4Signer.timestamp(Self.date) == "20130524T000000Z")
    }
}
