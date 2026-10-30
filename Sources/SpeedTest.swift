import Foundation

struct SpeedTestResult: Equatable {
    let downloadMbps: Double
    let uploadMbps: Double
    let latencyMS: Double
    let completedAt: Date

    var summaryText: String {
        String(format: "Cloudflare Speed Test\nDownload: %.2f Mbps\nUpload: %.2f Mbps\nHTTP latency: %.1f ms\nCompleted: %@",
               downloadMbps, uploadMbps, latencyMS, completedAt.description)
    }
}

enum SpeedTestError: LocalizedError {
    case http(Int)
    case invalidResponse
    case incompleteTransfer
    case invalidMeasurement

    var errorDescription: String? {
        switch self {
        case .http(let code): return "Cloudflare speed test failed (HTTP \(code))."
        case .invalidResponse: return "Cloudflare returned an invalid response."
        case .incompleteTransfer: return "Cloudflare did not confirm the expected number of transferred bytes."
        case .invalidMeasurement: return "The speed test produced an invalid timing measurement."
        }
    }
}

struct SpeedTestProgress {
    let completed: Int
    let total: Int
    let phase: String
    var fraction: Double { Double(completed) / Double(total) }
}

enum SpeedTestMath {
    static func mbps(bytes: Int, seconds: Double) throws -> Double {
        guard bytes > 0, seconds.isFinite, seconds > 0 else { throw SpeedTestError.invalidMeasurement }
        return Double(bytes) * 8 / seconds / 1_000_000
    }

    static func median(_ values: [Double]) throws -> Double {
        guard !values.isEmpty, values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw SpeedTestError.invalidMeasurement
        }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

private final class SpeedTestSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor SpeedTestClient {
    static let downloadBytes = 10_000_000
    static let uploadBytes = 2_000_000
    private let injectedSession: URLSession?

    init(session: URLSession? = nil) { injectedSession = session }

    func run(progress: @escaping @Sendable (SpeedTestProgress) -> Void) async throws -> SpeedTestResult {
        let session: URLSession
        if let injectedSession {
            session = injectedSession
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 30
            session = URLSession(configuration: config, delegate: SpeedTestSessionDelegate(), delegateQueue: nil)
        }
        defer { if injectedSession == nil { session.invalidateAndCancel() } }
        let total = 12 // Warmup, five latency requests, three downloads, three uploads.
        var completed = 0
        func update(_ phase: String) {
            progress(SpeedTestProgress(completed: completed, total: total, phase: phase))
        }
        update("Warming up")
        _ = try await transfer(session, bytes: 1, upload: false)
        completed += 1
        var latencies: [Double] = []
        for sample in 1...5 {
            update("Measuring latency \(sample)/5")
            latencies.append(try await transfer(session, bytes: 1, upload: false) * 1000)
            completed += 1
        }
        var downloadTimes: [Double] = []
        for sample in 1...3 {
            update("Downloading \(sample)/3")
            downloadTimes.append(try await transfer(session, bytes: Self.downloadBytes, upload: false))
            completed += 1
        }
        var uploadTimes: [Double] = []
        for sample in 1...3 {
            update("Uploading \(sample)/3")
            uploadTimes.append(try await transfer(session, bytes: Self.uploadBytes, upload: true))
            completed += 1
        }
        try Task.checkCancellation()
        update("Complete")
        return try SpeedTestResult(
            downloadMbps: SpeedTestMath.mbps(bytes: Self.downloadBytes * 3, seconds: downloadTimes.reduce(0, +)),
            uploadMbps: SpeedTestMath.mbps(bytes: Self.uploadBytes * 3, seconds: uploadTimes.reduce(0, +)),
            latencyMS: SpeedTestMath.median(latencies), completedAt: Date())
    }

    private func transfer(_ session: URLSession, bytes: Int, upload: Bool) async throws -> Double {
        try Task.checkCancellation()
        var url = URLComponents(string: "https://speed.cloudflare.com/\(upload ? "__up" : "__down")")!
        url.queryItems = [URLQueryItem(name: "requestId", value: UUID().uuidString)]
        if !upload { url.queryItems?.append(URLQueryItem(name: "bytes", value: String(bytes))) }
        var request = URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("IPToolkit/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        let payload = upload ? Data(repeating: 0x61, count: bytes) : nil
        if upload {
            request.httpMethod = "POST"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        let start = ProcessInfo.processInfo.systemUptime
        let data: Data
        let response: URLResponse
        if let payload {
            (data, response) = try await session.upload(for: request, from: payload)
        } else {
            (data, response) = try await session.data(for: request)
        }
        let seconds = ProcessInfo.processInfo.systemUptime - start
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw SpeedTestError.invalidResponse }
        guard http.statusCode == 200 else { throw SpeedTestError.http(http.statusCode) }
        if upload {
            guard http.value(forHTTPHeaderField: "cf-meta-upload-bytes").flatMap(Int.init) == bytes else {
                throw SpeedTestError.incompleteTransfer
            }
        } else if data.count != bytes {
            throw SpeedTestError.incompleteTransfer
        }
        guard seconds.isFinite && seconds > 0 else { throw SpeedTestError.invalidMeasurement }
        return seconds
    }
}
