import Foundation
import Observation

public struct RemotePathCompletion: Sendable, Equatable {
    public static let home = "~/"

    public let directory: String
    public let filter: String

    public init(input: String) {
        let text = input.isEmpty ? Self.home : input
        if text == "~" {
            directory = Self.home
            filter = ""
        } else if let slash = text.lastIndex(of: "/") {
            directory = String(text[...slash])
            filter = String(text[text.index(after: slash)...])
        } else {
            directory = Self.home
            filter = text
        }
    }

    public func suggestions(from entries: [RemoteDirectory.Entry]) -> [RemoteDirectory.Entry] {
        let showsHidden = filter.hasPrefix(".")
        let visible = entries.filter { showsHidden || !$0.name.hasPrefix(".") }
        guard !filter.isEmpty else { return visible }
        let prefixed = visible.filter { $0.name.range(of: filter, options: [.caseInsensitive, .anchored]) != nil }
        let containing = visible.filter { entry in
            entry.name.range(of: filter, options: [.caseInsensitive, .anchored]) == nil && entry.name.localizedCaseInsensitiveContains(filter)
        }
        return prefixed + containing
    }

    public func completion(for entry: RemoteDirectory.Entry) -> String {
        directory + entry.name + "/"
    }

    public var namesDirectoryExactly: Bool { filter.isEmpty }
}

@MainActor
@Observable
public final class RemoteFolderBrowser {
    public enum Status: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    public var input: String {
        didSet {
            guard input != oldValue else { return }
            highlighted = nil
            loadIfNeeded()
        }
    }
    public var highlighted: Int?
    public private(set) var status: Status = .idle

    private let lister: any RemoteDirectoryListing
    private var listings: [String: RemoteDirectory] = [:]
    private var pending: [String: Task<Void, Never>] = [:]

    public init(lister: any RemoteDirectoryListing, input: String = RemotePathCompletion.home) {
        self.lister = lister
        self.input = input
        loadIfNeeded()
    }

    public var completion: RemotePathCompletion { RemotePathCompletion(input: input) }

    public var listing: RemoteDirectory? { listings[completion.directory] }

    public var suggestions: [RemoteDirectory.Entry] {
        listing.map { completion.suggestions(from: $0.entries) } ?? []
    }

    public var highlightedEntry: RemoteDirectory.Entry? {
        highlighted.flatMap { suggestions.indices.contains($0) ? suggestions[$0] : nil }
    }

    public var resolvedPath: String {
        let completion = completion
        guard let listing, completion.namesDirectoryExactly else { return input.isEmpty ? RemotePathCompletion.home : input }
        return listing.path
    }

    public func moveHighlight(by offset: Int) {
        let count = suggestions.count
        guard count > 0 else {
            highlighted = nil
            return
        }
        guard let current = highlighted else {
            highlighted = offset >= 0 ? 0 : count - 1
            return
        }
        highlighted = (current + offset + count) % count
    }

    @discardableResult
    public func completeHighlighted() -> Bool {
        guard let entry = highlightedEntry ?? (suggestions.count == 1 || !completion.filter.isEmpty ? suggestions.first : nil) else { return false }
        descend(into: entry)
        return true
    }

    public func descend(into entry: RemoteDirectory.Entry) {
        input = completion.completion(for: entry)
    }

    public func goUp() {
        let directory = completion.directory
        guard directory != "/" else { return }
        if directory == RemotePathCompletion.home, let listing {
            input = Self.parent(of: listing.path)
            return
        }
        input = Self.parent(of: String(directory.dropLast()))
    }

    public func reload() {
        listings[completion.directory] = nil
        loadIfNeeded()
    }

    public func loaded() async {
        await pending[completion.directory]?.value
    }

    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return RemotePathCompletion.home }
        return String(path[...slash])
    }

    private func loadIfNeeded() {
        let directory = completion.directory
        if listings[directory] != nil {
            status = .loaded
            return
        }
        guard pending[directory] == nil else {
            status = .loading
            return
        }
        status = .loading
        let lister = lister
        pending[directory] = Task { [weak self] in
            let result: Result<RemoteDirectory, Error>
            do {
                result = .success(try await lister.list(directory))
            } catch {
                result = .failure(error)
            }
            self?.finish(directory, with: result)
        }
    }

    private func finish(_ directory: String, with result: Result<RemoteDirectory, Error>) {
        pending[directory] = nil
        if case .success(let listing) = result {
            listings[directory] = listing
        }
        guard directory == completion.directory else { return }
        switch result {
        case .success: status = .loaded
        case .failure(let error): status = .failed(error.localizedDescription)
        }
    }
}
