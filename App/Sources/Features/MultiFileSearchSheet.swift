import SwiftUI
import UniformTypeIdentifiers

/// Own `WindowGroup` so it stays open while results are routed into
/// editor tabs. Scopes: a picked folder (recursive), the foreground
/// window's tabs, or every tab of every open window. Tapping a row
/// opens the file and jumps to the line. Unsaved-buffer hits surface
/// but aren't tappable — there's no route to jump into a specific
/// in-memory buffer yet.
struct MultiFileSearchSheet: View {

    @Environment(\.dismiss) private var dismiss
    @Bindable private var bus = AppStateBus.shared

    enum Scope: String, CaseIterable, Identifiable {
        case folder
        case tabs
        case windows
        var id: String { rawValue }

        /// Wording shifts on iPhone (single-window) to drop the
        /// redundant "in Foreground Window" suffix.
        var label: String {
            switch self {
            case .folder:  return "Folder…"
            case .tabs:    return DeviceIdiom.isPhone ? "Open Tabs" : "Tabs in Foreground Window"
            case .windows: return "All Open Windows"
            }
        }
    }

    /// iPhone is single-scene, so "All Open Windows" is hidden.
    private static var availableScopes: [Scope] {
        DeviceIdiom.isPhone ? [.folder, .tabs] : Scope.allCases
    }

    @State private var scope: Scope = .folder
    @State private var folder: URL?
    @State private var pickingFolder: Bool = false
    @State private var extensionFilter: String = "swift,m,h,c,cpp,js,ts,tsx,py,rb,go,rs,java,kt,html,css,xml,json,yaml,yml,md,txt"
    @State private var searchTask: Task<Void, Never>?
    @State private var isSearching: Bool = false
    @State private var sourcesScanned: Int = 0
    @State private var results: [SearchResult] = []
    @State private var groups: [ResultGroup] = []
    @State private var errorText: String?
    @State private var seenFirstAppear: Bool = false
    /// -1 = nothing selected yet; Next/Prev wrap.
    @State private var currentResultIndex: Int = -1
    /// Gates a destructive write across every matched source —
    /// requires an explicit second tap.
    @State private var pendingReplaceAllConfirm: Bool = false
    /// Cursor into `results` for the next per-match prompt; `nil`
    /// when query mode is inactive.
    @State private var queryCursor: Int?
    @State private var replaceSummary: String?

    /// Past ~10k matches the list becomes unwieldy and previews grow
    /// linearly in memory.
    private static let maxResults = 10_000
    /// Above 5 MB almost never holds text the user wants to grep —
    /// skips a 200 MB log from stalling the scan.
    private static let maxFileBytes = 5 * 1024 * 1024

    var body: some View {
        NavigationStack {
            Form {
                scopeSection
                querySection
                if scope == .folder {
                    folderSection
                    extensionSection
                }
                controlsSection
                resultsSection
            }
            .navigationTitle("Multi-File Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        searchTask?.cancel()
                        close()
                    }
                }
            }
            .fileImporter(
                isPresented: $pickingFolder,
                allowedContentTypes: [.folder]
            ) { result in
                if case let .success(url) = result {
                    folder = url
                }
            }
            .onAppear {
                if !seenFirstAppear {
                    seenFirstAppear = true
                    // Same dismiss-on-restore guard the palette uses
                    // so iPadOS doesn't relaunch into this window.
                    if !AppStateBus.shared.scenes.consumeOpen(.multiFileSearch) {
                        AppStateBus.shared.scenes.openWindow?(.editor)
                        close()
                        return
                    }
                }
            }
            .onDisappear { searchTask?.cancel() }
            .alert(
                "Replace in all \(uniqueSourceCount) source\(uniqueSourceCount == 1 ? "" : "s")?",
                isPresented: $pendingReplaceAllConfirm
            ) {
                Button("Cancel", role: .cancel) { }
                Button("Replace All", role: .destructive) { performReplaceAll() }
            } message: {
                Text("This rewrites \(results.count) match\(results.count == 1 ? "" : "es") and saves every changed file. Cannot be undone from this sheet — use each editor's undo if you need to back out.")
            }
            .alert(
                queryAlertTitle,
                isPresented: queryAlertBinding,
                presenting: currentQueryResult
            ) { _ in
                Button("Skip") { queryAdvance() }
                Button("Replace") { queryReplaceAndAdvance() }
                Button("Replace All Remaining", role: .destructive) { queryReplaceAllRemaining() }
                Button("Cancel", role: .cancel) { queryCursor = nil }
            } message: { match in
                Text("\(match.groupLabel) line \(match.line):\n\(match.preview)")
            }
        }
    }

    private var queryAlertTitle: String {
        guard let cursor = queryCursor, results.indices.contains(cursor) else { return "" }
        return "Replace match \(cursor + 1) of \(results.count)?"
    }

    private var queryAlertBinding: Binding<Bool> {
        Binding(
            get: { queryCursor != nil && (queryCursor.map { results.indices.contains($0) } ?? false) },
            set: { newValue in if !newValue { queryCursor = nil } }
        )
    }

    private var currentQueryResult: SearchResult? {
        guard let cursor = queryCursor, results.indices.contains(cursor) else { return nil }
        return results[cursor]
    }

    private var uniqueSourceCount: Int {
        Set(results.map { $0.groupKey }).count
    }

    // MARK: - Sections

    @ViewBuilder
    private var scopeSection: some View {
        Section("Scope") {
            Picker("Search in", selection: $scope) {
                ForEach(Self.availableScopes) { s in
                    Text(s.label).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: scope) { _, _ in
                // Clear stale progress so the previous scope's
                // counts don't leak.
                results = []
                groups = []
                sourcesScanned = 0
                currentResultIndex = -1
                errorText = nil
            }
        }
    }

    @ViewBuilder
    private var querySection: some View {
        Section("Query") {
            TextField(
                bus.find.context.useRegex ? "Regular expression" : "Find",
                text: $bus.find.context.query
            )
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .font(bus.find.context.useRegex ? .body.monospaced() : .body)

            TextField("Replace with (optional)", text: $bus.find.context.replacement)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(bus.find.context.useRegex ? .body.monospaced() : .body)

            Toggle("Regular Expression", isOn: $bus.find.context.useRegex)
            Toggle("Case Sensitive",    isOn: $bus.find.context.caseSensitive)
            Toggle("Whole Word",        isOn: $bus.find.context.wholeWord)
                .disabled(bus.find.context.useRegex)
        }
    }

    @ViewBuilder
    private var folderSection: some View {
        Section("Folder") {
            HStack {
                if let folder {
                    Label(folder.lastPathComponent, systemImage: "folder")
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("No folder chosen").foregroundStyle(.secondary)
                }
                Spacer()
                Button(folder == nil ? "Choose…" : "Change…") { pickingFolder = true }
                    .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder
    private var extensionSection: some View {
        Section {
            TextField("Comma-separated (blank = all)", text: $extensionFilter)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.body.monospaced())
        } header: {
            Text("File Extensions")
        } footer: {
            Text("Files above 5 MB are skipped. Binary files are filtered automatically.")
                .font(.footnote)
        }
    }

    @ViewBuilder
    private var controlsSection: some View {
        Section {
            if isSearching {
                HStack {
                    ProgressView()
                    Text("Scanned \(sourcesScanned), \(results.count) match\(results.count == 1 ? "" : "es")…")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop") { searchTask?.cancel() }
                }
            } else {
                Button {
                    startSearch()
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStartSearch)
            }
            if !results.isEmpty {
                HStack(spacing: 12) {
                    Button {
                        stepResult(by: -1)
                    } label: {
                        Label("Previous", systemImage: "chevron.left")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Text(positionLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button {
                        stepResult(by: 1)
                    } label: {
                        Label("Next", systemImage: "chevron.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                // Replace surfaces only after a search returns —
                // user sees the scope of damage first. Query walks
                // per-match; Replace All commits in one pass after
                // the final confirm.
                HStack(spacing: 12) {
                    Button {
                        beginQueryReplace()
                    } label: {
                        Label("Query", systemImage: "questionmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(bus.find.context.query.isEmpty)
                    Button(role: .destructive) {
                        pendingReplaceAllConfirm = true
                    } label: {
                        Label("Replace All", systemImage: "arrow.2.squarepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(bus.find.context.query.isEmpty)
                }
            }
            if let replaceSummary {
                Text(replaceSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let errorText {
                Text(errorText).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private var positionLabel: String {
        guard !results.isEmpty else { return "" }
        let display = currentResultIndex < 0 ? 0 : currentResultIndex + 1
        return "\(display) / \(results.count)"
    }

    @ViewBuilder
    private var resultsSection: some View {
        if !groups.isEmpty {
            Section("Results — \(results.count) match\(results.count == 1 ? "" : "es") in \(groups.count) source\(groups.count == 1 ? "" : "s")") {
                ForEach(groups) { group in
                    DisclosureGroup {
                        ForEach(group.matches) { match in
                            Button {
                                if let idx = results.firstIndex(of: match) {
                                    currentResultIndex = idx
                                    open(match)
                                }
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: "arrow.right")
                                        .font(.caption2)
                                        .foregroundStyle(currentResultIndex >= 0
                                                         && results.indices.contains(currentResultIndex)
                                                         && results[currentResultIndex].id == match.id
                                                         ? AnyShapeStyle(.tint)
                                                         : AnyShapeStyle(Color.clear))
                                        .frame(width: 12)
                                    Text("\(match.line)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 36, alignment: .trailing)
                                    Text(match.preview)
                                        .font(.callout.monospaced())
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(match.url == nil)
                        }
                    } label: {
                        Label("\(group.label) (\(group.matches.count))",
                              systemImage: group.systemImage)
                    }
                }
            }
        } else if !isSearching && sourcesScanned > 0 {
            Section { Text("No matches.").foregroundStyle(.secondary) }
        }
    }

    // MARK: - Actions

    private func close() {
        dismiss()
    }

    private var canStartSearch: Bool {
        guard !bus.find.context.query.isEmpty else { return false }
        switch scope {
        case .folder:  return folder != nil
        case .tabs:    return bus.scenes.currentSession != nil
        case .windows: return !bus.scenes.allOpenSessions.isEmpty
        }
    }

    /// The new scene consumes `newWindow` on first appear; the
    /// `goToLine` lands once the buffer finishes loading.
    private func open(_ match: SearchResult) {
        guard let url = match.url else { return }
        bus.pending.goToLine = match.line
        bus.pending.newWindow = url
        bus.scenes.openWindow?(.editor)
    }

    private func stepResult(by delta: Int) {
        guard !results.isEmpty else { return }
        if currentResultIndex < 0 {
            currentResultIndex = delta > 0 ? 0 : results.count - 1
        } else {
            currentResultIndex = (currentResultIndex + delta + results.count) % results.count
        }
        open(results[currentResultIndex])
    }

    private func startSearch() {
        errorText = nil
        results = []
        groups = []
        sourcesScanned = 0
        currentResultIndex = -1
        isSearching = true

        let ctx = bus.find.context
        let exts = Set(
            extensionFilter
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
        )
        let scopeCopy = scope
        let folderCopy = folder
        // Snapshot before the scan so concurrent edits don't shift
        // offsets out from under us.
        let inMemorySources: [InMemorySource]
        switch scopeCopy {
        case .folder:  inMemorySources = []
        case .tabs:    inMemorySources = Self.tabsSources()
        case .windows: inMemorySources = Self.windowsSources()
        }

        searchTask = Task { @MainActor in
            defer { isSearching = false }
            do {
                let matcher = try Self.compileMatcher(for: ctx)
                if scopeCopy == .folder, let folderCopy {
                    try await runFolderSearch(folder: folderCopy, matcher: matcher, extensions: exts)
                } else {
                    try runInMemorySearch(sources: inMemorySources, matcher: matcher)
                }
            } catch is CancellationError {
                // Stop button.
            } catch {
                errorText = error.localizedDescription
            }
            groups = Self.group(results)
        }
    }

    private func runFolderSearch(folder: URL, matcher: Matcher, extensions: Set<String>) async throws {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        let urls = Self.collectFiles(in: folder, extensions: extensions)
        try Task.checkCancellation()

        for url in urls {
            try Task.checkCancellation()
            sourcesScanned += 1
            if results.count >= Self.maxResults { break }
            guard let text = Self.readText(at: url) else { continue }
            let groupKey = ResultGroupKey.url(url)
            let groupLabel = url.lastPathComponent
            let hits = matcher.matches(
                in: text,
                groupKey: groupKey,
                groupLabel: groupLabel,
                fileURL: url,
                limit: Self.maxResults - results.count
            )
            results.append(contentsOf: hits)
            if sourcesScanned.isMultiple(of: 25) {
                groups = Self.group(results)
                await Task.yield()
            }
        }
    }

    private func runInMemorySearch(sources: [InMemorySource], matcher: Matcher) throws {
        for source in sources {
            try Task.checkCancellation()
            sourcesScanned += 1
            if results.count >= Self.maxResults { break }
            let hits = matcher.matches(
                in: source.text,
                groupKey: source.groupKey,
                groupLabel: source.groupLabel,
                fileURL: source.url,
                limit: Self.maxResults - results.count
            )
            results.append(contentsOf: hits)
        }
    }

    // MARK: - In-memory source collection

    private struct InMemorySource {
        let groupKey: ResultGroupKey
        let groupLabel: String
        let url: URL?
        let text: String
    }

    private static func tabsSources() -> [InMemorySource] {
        guard let session = AppStateBus.shared.scenes.currentSession else { return [] }
        return session.tabs.enumerated().map { idx, tab in
            sourceFor(tab: tab, windowIndex: nil, tabIndex: idx)
        }
    }

    private static func windowsSources() -> [InMemorySource] {
        let sessions = AppStateBus.shared.scenes.allOpenSessions
        var out: [InMemorySource] = []
        for (wi, session) in sessions.enumerated() {
            for (ti, tab) in session.tabs.enumerated() {
                out.append(sourceFor(tab: tab, windowIndex: wi, tabIndex: ti))
            }
        }
        return out
    }

    private static func sourceFor(tab: TabModel, windowIndex: Int?, tabIndex: Int) -> InMemorySource {
        let url = tab.document.fileURL
        let key = ResultGroupKey.tab(tab.id)
        let title = url?.lastPathComponent ?? "Untitled"
        let label: String
        if let wi = windowIndex {
            label = "\(title)  (Window \(wi + 1), Tab \(tabIndex + 1))"
        } else {
            label = "\(title)  (Tab \(tabIndex + 1))"
        }
        return InMemorySource(groupKey: key, groupLabel: label, url: url, text: tab.document.text)
    }

    // MARK: - File walking + reading

    private static func collectFiles(in root: URL, extensions: Set<String>) -> [URL] {
        var collected: [URL] = []
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        for case let url as URL in enumerator {
            if Task.isCancelled { break }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            if !extensions.isEmpty {
                let ext = url.pathExtension.lowercased()
                guard extensions.contains(ext) else { continue }
            }
            collected.append(url)
            if collected.count >= 200_000 { break }
        }
        return collected
    }

    private static func readText(at url: URL) -> String? {
        guard let attrs = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = attrs.fileSize, size <= maxFileBytes
        else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        if data.prefix(4096).contains(0) { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    // MARK: - Matching

    private struct Matcher {
        let regex: NSRegularExpression?
        let literal: String?
        let caseSensitive: Bool

        func matches(
            in text: String,
            groupKey: ResultGroupKey,
            groupLabel: String,
            fileURL: URL?,
            limit: Int
        ) -> [SearchResult] {
            guard limit > 0 else { return [] }
            let ns = text as NSString
            var out: [SearchResult] = []
            // Matches arrive in ascending offset order, so line
            // counting resumes from the previous match instead of
            // rescanning from offset 0 (quadratic on match-heavy files).
            var cursor = LineCursor()
            if let regex {
                let range = NSRange(location: 0, length: ns.length)
                regex.enumerateMatches(in: text, options: [], range: range) { match, _, stop in
                    guard let match else { return }
                    out.append(makeResult(at: match.range, ns: ns, cursor: &cursor,
                                          groupKey: groupKey, groupLabel: groupLabel,
                                          url: fileURL))
                    if out.count >= limit { stop.pointee = true }
                }
            } else if let literal {
                var searchStart = 0
                while searchStart < ns.length {
                    let searchRange = NSRange(location: searchStart, length: ns.length - searchStart)
                    let opts: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
                    let found = ns.range(of: literal, options: opts, range: searchRange)
                    if found.location == NSNotFound { break }
                    out.append(makeResult(at: found, ns: ns, cursor: &cursor,
                                          groupKey: groupKey, groupLabel: groupLabel,
                                          url: fileURL))
                    if out.count >= limit { break }
                    searchStart = found.location + max(1, found.length)
                }
            }
            return out
        }

        /// Running (offset, line) position within one source.
        private struct LineCursor {
            var offset = 0
            var line = 1

            mutating func line(at location: Int, in ns: NSString) -> Int {
                while offset < location {
                    let ch = ns.character(at: offset)
                    if ch == 0x0A {
                        line += 1
                    } else if ch == 0x0D,
                              offset + 1 >= ns.length || ns.character(at: offset + 1) != 0x0A {
                        // Bare CR (classic Mac) — CRLF is counted at the LF.
                        line += 1
                    }
                    offset += 1
                }
                return line
            }
        }

        private func makeResult(
            at range: NSRange,
            ns: NSString,
            cursor: inout LineCursor,
            groupKey: ResultGroupKey,
            groupLabel: String,
            url: URL?
        ) -> SearchResult {
            let line = cursor.line(at: range.location, in: ns)
            let lineRange = ns.lineRange(for: NSRange(location: range.location, length: 0))
            var preview = ns.substring(with: lineRange)
            if let last = preview.last, last == "\n" || last == "\r" { preview.removeLast() }
            preview = preview.trimmingCharacters(in: .whitespaces)
            return SearchResult(
                groupKey: groupKey,
                groupLabel: groupLabel,
                url: url,
                line: line,
                preview: preview
            )
        }
    }

    private static func compileMatcher(for ctx: FindContext) throws -> Matcher {
        if FindCompile.useRegex(for: ctx) {
            return Matcher(
                regex: try FindCompile.regex(for: ctx),
                literal: nil,
                caseSensitive: ctx.caseSensitive
            )
        }
        return Matcher(regex: nil, literal: ctx.query, caseSensitive: ctx.caseSensitive)
    }

    // MARK: - Grouping

    private static func group(_ results: [SearchResult]) -> [ResultGroup] {
        var byKey: [ResultGroupKey: ResultGroup] = [:]
        var order: [ResultGroupKey] = []
        for r in results {
            if byKey[r.groupKey] == nil {
                order.append(r.groupKey)
                byKey[r.groupKey] = ResultGroup(
                    key: r.groupKey,
                    label: r.groupLabel,
                    matches: []
                )
            }
            byKey[r.groupKey]?.matches.append(r)
        }
        return order.compactMap { byKey[$0] }
    }

    // MARK: - Models

    enum ResultGroupKey: Hashable {
        case url(URL)
        case tab(UUID)
    }

    struct SearchResult: Identifiable, Hashable {
        let id = UUID()
        let groupKey: ResultGroupKey
        let groupLabel: String
        let url: URL?
        let line: Int
        let preview: String
    }

    struct ResultGroup: Identifiable {
        var id: ResultGroupKey { key }
        let key: ResultGroupKey
        let label: String
        var matches: [SearchResult]

        var systemImage: String {
            switch key {
            case .url:  "doc.text"
            case .tab:  "rectangle.stack"
            }
        }
    }

    // MARK: - Replace

    /// File-backed sources rewrite via atomic Data.write; open tabs flow
    /// the new text through the live engine buffer then sync the document.
    private func performReplaceAll() {
        let ctx = bus.find.context
        guard !ctx.query.isEmpty else { return }
        var filesChanged = 0
        var totalReplacements = 0
        var errors: [String] = []
        for key in Set(results.map { $0.groupKey }) {
            do {
                let count = try applyReplacement(in: key, query: ctx.query, replacement: ctx.replacement, context: ctx)
                if count > 0 {
                    filesChanged += 1
                    totalReplacements += count
                }
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        replaceSummary = "Replaced \(totalReplacements) match\(totalReplacements == 1 ? "" : "es") in \(filesChanged) file\(filesChanged == 1 ? "" : "s")."
        if !errors.isEmpty {
            errorText = errors.prefix(3).joined(separator: " — ")
        }
        // Results are stale after a replace — line numbers shifted,
        // matches gone. The user re-runs the search or closes.
        results.removeAll()
        groups.removeAll()
        currentResultIndex = -1
    }

    private func beginQueryReplace() {
        guard !results.isEmpty else { return }
        replaceSummary = nil
        queryCursor = 0
    }

    private func queryAdvance() {
        guard let cursor = queryCursor else { return }
        let next = cursor + 1
        if next >= results.count {
            queryCursor = nil
            replaceSummary = "Query mode finished."
        } else {
            queryCursor = next
        }
    }

    private func queryReplaceAndAdvance() {
        guard let cursor = queryCursor, results.indices.contains(cursor) else { return }
        let target = results[cursor]
        let ctx = bus.find.context
        do {
            _ = try applyReplacement(
                in: target.groupKey,
                query: ctx.query,
                replacement: ctx.replacement,
                context: ctx,
                limitToFirst: true
            )
        } catch {
            errorText = error.localizedDescription
        }
        queryAdvance()
    }

    private func queryReplaceAllRemaining() {
        guard let cursor = queryCursor else { return }
        let remainingKeys = Set(results.dropFirst(cursor).map { $0.groupKey })
        let ctx = bus.find.context
        var changedSources = 0
        var replaceCount = 0
        for key in remainingKeys {
            do {
                let n = try applyReplacement(in: key, query: ctx.query, replacement: ctx.replacement, context: ctx)
                if n > 0 { changedSources += 1; replaceCount += n }
            } catch {
                errorText = error.localizedDescription
            }
        }
        replaceSummary = "Replaced \(replaceCount) remaining match\(replaceCount == 1 ? "" : "es") in \(changedSources) source\(changedSources == 1 ? "" : "s")."
        queryCursor = nil
        results.removeAll()
        groups.removeAll()
        currentResultIndex = -1
    }

    /// `limitToFirst` caps to one replacement — Query mode's
    /// per-match confirm.
    private func applyReplacement(
        in key: ResultGroupKey,
        query: String,
        replacement: String,
        context ctx: FindContext,
        limitToFirst: Bool = false
    ) throws -> Int {
        switch key {
        case .url(let url):
            return try applyReplacementToFile(url: url, query: query, replacement: replacement, context: ctx, limitToFirst: limitToFirst)
        case .tab(let id):
            return try applyReplacementToTab(tabID: id, query: query, replacement: replacement, context: ctx, limitToFirst: limitToFirst)
        }
    }

    private func applyReplacementToFile(
        url: URL,
        query: String,
        replacement: String,
        context ctx: FindContext,
        limitToFirst: Bool
    ) throws -> Int {
        // Children of a folder-scope pick don't carry their own
        // security scope (startAccessing… returns false on them) —
        // re-open the picked folder's scope for the write, same as
        // `runFolderSearch` does for the read.
        let folderScoped = scope == .folder && folder?.startAccessingSecurityScopedResource() == true
        defer { if folderScoped, let folder { folder.stopAccessingSecurityScopedResource() } }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        // Re-encode with whichever decode succeeded so an ISO-Latin-1
        // file isn't silently transcoded to UTF-8.
        let text: String
        let encoding: String.Encoding
        if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
            encoding = .utf8
        } else if let latin1 = String(data: data, encoding: .isoLatin1) {
            text = latin1
            encoding = .isoLatin1
        } else {
            return 0
        }
        let (replaced, count) = try replaceInString(text, query: query, replacement: replacement, context: ctx, limitToFirst: limitToFirst)
        guard count > 0 else { return 0 }
        let outData = replaced.data(using: encoding) ?? data
        try outData.write(to: url, options: .atomic)
        return count
    }

    private func applyReplacementToTab(
        tabID: UUID,
        query: String,
        replacement: String,
        context ctx: FindContext,
        limitToFirst: Bool
    ) throws -> Int {
        var foundTab: TabModel?
        for session in AppStateBus.shared.scenes.allOpenSessions {
            if let tab = session.tabs.first(where: { $0.id == tabID }) {
                foundTab = tab
                break
            }
        }
        guard let tab = foundTab else { return 0 }
        let liveText = tab.state.textView?.text ?? tab.document.text
        let (replaced, count) = try replaceInString(liveText, query: query, replacement: replacement, context: ctx, limitToFirst: limitToFirst)
        guard count > 0 else { return 0 }
        if let tv = tab.state.textView {
            tv.text = replaced
        }
        tab.document.text = replaced
        tab.document.isDirty = true
        return count
    }

    /// `query` mirrors `ctx.query` for caller convenience; regex /
    /// whole-word handling still flows through the context.
    private func replaceInString(
        _ text: String,
        query: String,
        replacement: String,
        context ctx: FindContext,
        limitToFirst: Bool
    ) throws -> (String, Int) {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        if FindCompile.useRegex(for: ctx) {
            let regex = try FindCompile.regex(for: ctx)
            if limitToFirst {
                if let match = regex.firstMatch(in: text, options: [], range: fullRange) {
                    let replaced = regex.replacementString(for: match, in: text, offset: 0, template: replacement)
                    let result = (nsText.substring(with: NSRange(location: 0, length: match.range.location)))
                        + replaced
                        + (nsText.substring(with: NSRange(location: NSMaxRange(match.range), length: nsText.length - NSMaxRange(match.range))))
                    return (result, 1)
                }
                return (text, 0)
            }
            let mutable = NSMutableString(string: text)
            let count = regex.replaceMatches(in: mutable, options: [], range: fullRange, withTemplate: replacement)
            return (mutable as String, count)
        } else {
            var opts: NSString.CompareOptions = []
            if !ctx.caseSensitive { opts.insert(.caseInsensitive) }
            if limitToFirst {
                let r = nsText.range(of: query, options: opts, range: fullRange)
                guard r.location != NSNotFound else { return (text, 0) }
                let mutable = NSMutableString(string: text)
                mutable.replaceCharacters(in: r, with: replacement)
                return (mutable as String, 1)
            }
            let mutable = NSMutableString(string: text)
            let count = mutable.replaceOccurrences(of: query, with: replacement, options: opts, range: fullRange)
            return (mutable as String, count)
        }
    }
}
