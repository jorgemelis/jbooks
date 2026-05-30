import SwiftUI
import ReadiumShared

/// Per-book bookmarks (editable names) and recent reading positions.
struct BookmarksSheet: View {
    @ObservedObject var controller: ReaderController
    @Environment(\.dismiss) private var dismiss

    @State private var bookmarks: [Bookmark] = []
    @State private var history: [Locator] = []
    @State private var renaming: Bookmark?
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        if controller.addBookmark() { reload() }
                    } label: {
                        Label("Añadir marcador aquí", systemImage: "bookmark")
                    }
                    .disabled(controller.currentLocator == nil)
                }

                if !bookmarks.isEmpty {
                    Section("Marcadores") {
                        ForEach(bookmarks) { bookmark in
                            Button { jump(bookmark.locator) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bookmark.name)
                                        .foregroundStyle(.primary)
                                    if let locator = bookmark.locator {
                                        Text(progressText(locator))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    BookmarksStore.remove(id: bookmark.id, forRelativePath: controller.relativePath)
                                    reload()
                                } label: {
                                    Label("Eliminar", systemImage: "trash")
                                }
                                Button {
                                    renaming = bookmark
                                    newName = bookmark.name
                                } label: {
                                    Label("Renombrar", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                        }
                    }
                }

                if !history.isEmpty {
                    Section("Posiciones recientes") {
                        ForEach(Array(history.enumerated()), id: \.offset) { _, locator in
                            Button { jump(locator) } label: {
                                HStack {
                                    Text(progressText(locator))
                                    if let title = locator.title, !title.isEmpty {
                                        Text("· \(title)")
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Marcadores")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Listo") { dismiss() }
                }
            }
            .overlay {
                if bookmarks.isEmpty && history.isEmpty {
                    ContentUnavailableView(
                        "Sin marcadores",
                        systemImage: "bookmark",
                        description: Text("Añade un marcador en tu posición actual.")
                    )
                }
            }
            .alert("Renombrar marcador", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("Nombre", text: $newName)
                Button("Guardar") {
                    if let bookmark = renaming {
                        BookmarksStore.rename(id: bookmark.id, to: newName, forRelativePath: controller.relativePath)
                        reload()
                    }
                    renaming = nil
                }
                Button("Cancelar", role: .cancel) { renaming = nil }
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        bookmarks = BookmarksStore.bookmarks(forRelativePath: controller.relativePath)
        history = PositionStore.history(forRelativePath: controller.relativePath)
    }

    private func jump(_ locator: Locator?) {
        guard let locator else { return }
        controller.go(to: locator)
        dismiss()
    }

    private func progressText(_ locator: Locator) -> String {
        if let progression = locator.locations.totalProgression {
            return "\(Int((progression * 100).rounded()))%"
        }
        if let position = locator.locations.position {
            return "Página \(position)"
        }
        return "—"
    }
}
