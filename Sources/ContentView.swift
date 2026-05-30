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
    @State private var favorites: [String] = []

    private var favoriteSet: Set<String> { Set(favorites) }

    private var filteredBooks: [Book] {
        guard !query.isEmpty else { return books }
        return books.filter { book in
            book.title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || book.author.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private var booksByPath: [String: Book] {
        Dictionary(books.map { ($0.relativePath, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        TabView {
            libraryTab
                .tabItem { Label("Biblioteca", systemImage: "books.vertical") }

            NavigationStack {
                RecentsView(
                    booksByPath: booksByPath,
                    coversToken: coversToken,
                    favorites: favoriteSet,
                    onToggleFavorite: toggleFavorite
                )
            }
            .tabItem { Label("Recientes", systemImage: "clock") }

            NavigationStack {
                FavoritesView(
                    booksByPath: booksByPath,
                    order: favorites,
                    coversToken: coversToken,
                    onToggleFavorite: toggleFavorite
                )
            }
            .tabItem { Label("Favoritos", systemImage: "star") }
        }
        .task { await start() }
    }

    private var libraryTab: some View {
        NavigationStack {
            List {
                ForEach(Library.categories, id: \.self) { category in
                    let items = filteredBooks.filter { $0.category == category }
                    if !items.isEmpty {
                        Section("\(category) (\(items.count))") {
                            ForEach(items) { book in
                                BookListRow(
                                    book: book,
                                    coversToken: coversToken,
                                    isFavorite: favoriteSet.contains(book.relativePath),
                                    onToggleFavorite: { toggleFavorite(book) }
                                )
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
    }

    private func toggleFavorite(_ book: Book) {
        FavoritesStore.toggle(book.relativePath)
        favorites = FavoritesStore.items()
    }

    private func start() async {
        hasFolder = Library.hasFolder
        favorites = FavoritesStore.items()
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

/// The "Recientes" tab: recently opened books, removable without deleting them.
private struct RecentsView: View {
    let booksByPath: [String: Book]
    let coversToken: Int
    let favorites: Set<String>
    let onToggleFavorite: (Book) -> Void
    @State private var recents: [Book] = []

    var body: some View {
        List {
            ForEach(recents) { book in
                BookListRow(
                    book: book,
                    coversToken: coversToken,
                    isFavorite: favorites.contains(book.relativePath),
                    onToggleFavorite: { onToggleFavorite(book) },
                    onRemove: { removeFromRecents(book) },
                    removeLabel: "Quitar de recientes"
                )
            }
        }
        .navigationTitle("Recientes")
        .navigationDestination(for: Book.self) { book in
            ReaderView(book: book)
        }
        .overlay {
            if recents.isEmpty {
                ContentUnavailableView(
                    "Sin recientes",
                    systemImage: "clock",
                    description: Text("Los libros que abras aparecerán aquí.")
                )
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        recents = RecentsStore.items().compactMap { booksByPath[$0] }
    }

    private func removeFromRecents(_ book: Book) {
        RecentsStore.remove(book.relativePath)
        recents.removeAll { $0.id == book.id }
    }
}

/// The "Favoritos" tab: manually chosen favorites, sorted by title.
private struct FavoritesView: View {
    let booksByPath: [String: Book]
    let order: [String]
    let coversToken: Int
    let onToggleFavorite: (Book) -> Void

    private var items: [Book] {
        order.compactMap { booksByPath[$0] }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        List {
            ForEach(items) { book in
                BookListRow(
                    book: book,
                    coversToken: coversToken,
                    isFavorite: true,
                    onToggleFavorite: { onToggleFavorite(book) }
                )
            }
        }
        .navigationTitle("Favoritos")
        .navigationDestination(for: Book.self) { book in
            ReaderView(book: book)
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView(
                    "Sin favoritos",
                    systemImage: "star",
                    description: Text("Marca un libro con la estrella para guardarlo aquí.")
                )
            }
        }
    }
}

/// A tappable book row with favorite + optional remove actions (swipe + menu).
private struct BookListRow: View {
    let book: Book
    let coversToken: Int
    let isFavorite: Bool
    let onToggleFavorite: () -> Void
    var onRemove: (() -> Void)?
    var removeLabel: String = "Quitar"

    var body: some View {
        NavigationLink(value: book) {
            BookRow(book: book, coversToken: coversToken, isFavorite: isFavorite)
        }
        .swipeActions(edge: .leading) {
            Button(action: onToggleFavorite) {
                Label(isFavorite ? "Quitar" : "Favorito",
                      systemImage: isFavorite ? "star.slash" : "star")
            }
            .tint(.yellow)
        }
        .swipeActions(edge: .trailing) {
            if let onRemove {
                Button(role: .destructive, action: onRemove) {
                    Label(removeLabel, systemImage: "minus.circle")
                }
            }
        }
        .contextMenu {
            Button(action: onToggleFavorite) {
                Label(isFavorite ? "Quitar de favoritos" : "Añadir a favoritos",
                      systemImage: isFavorite ? "star.slash" : "star")
            }
            if let onRemove {
                Button(role: .destructive, action: onRemove) {
                    Label(removeLabel, systemImage: "minus.circle")
                }
            }
        }
    }
}

/// A book list row: cover thumbnail + title + author (+ favorite star).
private struct BookRow: View {
    let book: Book
    let coversToken: Int
    var isFavorite: Bool = false

    var body: some View {
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
            if isFavorite {
                Spacer(minLength: 8)
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .font(.caption)
            }
        }
        .padding(.vertical, 3)
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
