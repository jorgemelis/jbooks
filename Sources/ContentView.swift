import SwiftUI

struct ContentView: View {
    @State private var books: [Book] = []
    @State private var loaded = false
    @State private var indexProgress: (done: Int, total: Int)?
    @State private var query = ""

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
                if loaded && books.isEmpty {
                    ContentUnavailableView(
                        "Sin libros",
                        systemImage: "books.vertical",
                        description: Text("No se encontraron EPUB en _books/2read")
                    )
                } else if !query.isEmpty && filteredBooks.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .task { await start() }
    }

    @ViewBuilder
    private func row(for book: Book) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(book.title)
                .font(.title3)
            if !book.author.isEmpty {
                Text(book.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private func start() async {
        // Fast: show whatever the cached index + disk already know.
        books = Library.cachedBooks()
        loaded = true

        // Only the Mac (full library downloaded) refreshes the shared index.
        #if targetEnvironment(macCatalyst)
        let result = await BookIndexer.refresh { done, total in
            indexProgress = (done, total)
        }
        books = Library.books(from: result.books)
        indexProgress = nil
        #endif
    }
}

#Preview {
    ContentView()
}
