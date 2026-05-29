import SwiftUI

struct ContentView: View {
    @State private var books: [Book] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(Library.categories, id: \.self) { category in
                    let items = books.filter { $0.category == category }
                    if !items.isEmpty {
                        Section("\(category) (\(items.count))") {
                            ForEach(items) { book in
                                NavigationLink(book.title, value: book)
                            }
                        }
                    }
                }
            }
            .navigationTitle("jbooks")
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
                }
            }
        }
        .task {
            books = Library.loadBooks()
            loaded = true
        }
    }
}

#Preview {
    ContentView()
}
