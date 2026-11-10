import Foundation

/// A model Undertow knows how to fetch. All are stock Gemma builds published by the llama.cpp
/// project on Hugging Face.
struct ModelOption: Identifiable {
    let file: String
    let title: String
    let note: String
    let url: URL
    let approxGB: Double
    var id: String { file }

    static let catalog: [ModelOption] = [
        .init(file: "gemma-4-E2B-it-Q4_0.gguf", title: "Gemma 4 E2B", note: "Recommended. Needs about 3 GB of memory.",
            url: URL(string: "https://huggingface.co/ggml-org/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_0.gguf")!, approxGB: 2.8),
        .init(file: "gemma-4-E4B-it-Q4_0.gguf", title: "Gemma 4 E4B", note: "Larger. For Macs with 24 GB or more.",
            url: URL(string: "https://huggingface.co/ggml-org/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-Q4_0.gguf")!, approxGB: 4.6),
        .init(file: "gemma-3-1b-it-Q4_K_M.gguf", title: "Gemma 3 1B", note: "Light. Faster, less accurate; about 1 GB.",
            url: URL(string: "https://huggingface.co/ggml-org/gemma-3-1b-it-GGUF/resolve/main/gemma-3-1b-it-Q4_K_M.gguf")!, approxGB: 0.8),
    ]
}

/// Downloads model files into the Models folder, with progress for the settings window.
final class ModelDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published private(set) var progress: [String: Double] = [:]  // file name -> 0...1 while downloading
    @Published var failure: String?
    var onInstalled: ((String) -> Void)?

    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    private var tasks: [String: URLSessionDownloadTask] = [:]

    func start(_ m: ModelOption) {
        guard tasks[m.file] == nil else { return }
        failure = nil
        let t = session.downloadTask(with: m.url)
        t.taskDescription = m.file
        tasks[m.file] = t
        progress[m.file] = 0
        t.resume()
    }

    func cancel(_ file: String) {
        tasks[file]?.cancel()
        tasks[file] = nil
        progress[file] = nil
    }

    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten done: Int64, totalBytesExpectedToWrite total: Int64) {
        guard let file = t.taskDescription, total > 0 else { return }
        progress[file] = Double(done) / Double(total)
    }

    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let file = t.taskDescription else { return }
        let ok = (t.response as? HTTPURLResponse)?.statusCode == 200
        let size = (try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        // An error page is small; a model is hundreds of megabytes.
        guard ok, size > 200_000_000 else { failure = "The download of \(file) did not complete."; return }
        let dest = Settings.modelsDir.appendingPathComponent(file)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            onInstalled?(file)
        } catch { failure = error.localizedDescription }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let file = task.taskDescription else { return }
        tasks[file] = nil
        progress[file] = nil
        if let error, (error as NSError).code != NSURLErrorCancelled { failure = error.localizedDescription }
    }
}
