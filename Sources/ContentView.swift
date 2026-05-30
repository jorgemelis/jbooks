import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var books: [Book] = []
    @State private var loaded = false
    @State private var indexProgress: (done: Int, total: Int)?
    @State private var query = ""
    /// Bumped when indexing finishes so rows reload covers generated this run.
    @State private var coversToken = 0
    @State private var hasFolder = true
    @State private var showingImporter = false

    private var filteredBooks: [Book] {
        guard !query.isEmpty else { return books }
        return books.filter { book in
            book.title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || book.author.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Library.categories, id: \.self) { category in
                    let items = filteredBooks.filter { $0.category == category }
                    if !items.isEmpty {
                        Section("\(category) (\(items.count))") {
                            ForEach(items) { book in
                                NavigationLink(value: book) {
                                    row(for: book)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("jbooks")
            .searchable(text: $query, prompt: "Buscar título o autor")
            .toolbar {
                if let p = indexProgress, p.done < p.total {
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Indexando \(p.done)/\(p.total)")
                                .font(.headline)
                        }
                    }
                }
            }
            .navigationDestination(for: Book.self) { book in
                ReaderView(book: book)
            }
            .overlay {
                if !hasFolder {
                    ContentUnavailableView {
                        Label("Elige tu carpeta de libros", systemImage: "folder")
                    } description: {
                        Text("Selecciona la carpeta con tus EPUB (p. ej. tu carpeta 2read de OneDrive).")
                    } actions: {
                        Button("Elegir carpeta…") { showingImporter = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else if loaded && books.isEmpty {
                    ContentUnavailableView(
                        "Sin libros",
                        systemImage: "books.vertical",
                        description: Text("No se encontraron EPUB en la carpeta elegida.")
                    )
                } else if !query.isEmpty && filteredBooks.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.folder]
            ) { result in
                if case let .success(url) = result {
                    LibraryFolder.setFolder(url)
                    Task { await start() }
                }
            }
        }
        .task { await start() }
    }

    @ViewBuilder
    private func row(for book: Book) -> some View {
        HStack(spacing: 12) {
            CoverView(relativePath: book.relativePath, reloadToken: coversToken)
            VStack(alignment: .leading, spacing: 3) {
                Text(book.title)
                    .font(.title3)
                if !book.author.isEmpty {
                    Text(book.author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func start() async {
        hasFolder = Library.hasFolder
        guard hasFolder else {
            loaded = true
            return
        }

        // Fast: show whatever the cached index + disk already know.
        books = Library.cachedBooks()
        loaded = true

        // Only the Mac (full library downloaded) refreshes the shared index.
        #if targetEnvironment(macCatalyst)
        let result = await BookIndexer.refresh { done, total in
            indexProgress = (done, total)
        }
        books = Library.books(from: result.books)
        coversToken += 1
        indexProgress = nil
        #endif
    }
}

/// Cover thumbnail for a list row. Loads from `CoverCache` off the main
/// thread; shows a placeholder until (or unless) a cover is available.
private struct CoverView: View {
    let relativePath: String
    let reloadToken: Int
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "book.closed")
                    .imageScale(.large)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 46, height: 66)
        .background(Color(uiColor: .secondarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: "\(relativePath)#\(reloadToken)") {
            if image == nil {
                let path = relativePath
                image = await Task.detached { CoverCache.shared.image(for: path) }.value
            }
        }
    }
}

#Preview {
    ContentView()
}
