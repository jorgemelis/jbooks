import SwiftUI
import UIKit
import ReadiumShared
import ReadiumStreamer
import ReadiumNavigator

/// Drives a reading session: holds the navigator, tracks the current location,
/// and exposes jump / bookmark actions to the SwiftUI views.
@MainActor final class ReaderController: ObservableObject {
    let relativePath: String
    weak var navigator: EPUBNavigatorViewController?
    @Published var currentLocator: Locator?

    init(relativePath: String) { self.relativePath = relativePath }

    func go(to locator: Locator) {
        let navigator = navigator
        Task { _ = await navigator?.go(to: locator) }
    }

    @discardableResult
    func addBookmark() -> Bool {
        guard let locator = currentLocator, let json = try? locator.jsonString() else { return false }
        BookmarksStore.add(
            Bookmark(id: UUID(), name: Bookmark.defaultName(for: locator), locatorJSON: json),
            forRelativePath: relativePath
        )
        return true
    }
}

/// Opens an EPUB with Readium and renders it with the EPUB navigator.
struct ReaderView: View {
    let book: Book

    enum LoadState {
        case loading
        case failed(String)
        case ready(Publication)
    }

    @State private var state: LoadState = .loading
    @AppStorage("readerFontSize") private var fontSize: Double = 1.0
    @StateObject private var controller: ReaderController
    @State private var showingBookmarks = false

    private let fontStep = 0.1
    private let fontRange = 0.5 ... 3.0

    init(book: Book) {
        self.book = book
        _controller = StateObject(
            wrappedValue: ReaderController(relativePath: Library.relativePath(of: book.url))
        )
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView("Abriendo…")
            case let .failed(message):
                ContentUnavailableView(
                    "No se pudo abrir",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            case let .ready(publication):
                EPUBContainer(
                    publication: publication,
                    fontSize: fontSize,
                    controller: controller
                )
                .ignoresSafeArea(edges: .bottom)
            }
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if case .ready = state {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        fontSize = max(fontRange.lowerBound, fontSize - fontStep)
                    } label: {
                        Image(systemName: "textformat.size.smaller")
                    }
                    .disabled(fontSize <= fontRange.lowerBound)

                    Button {
                        fontSize = min(fontRange.upperBound, fontSize + fontStep)
                    } label: {
                        Image(systemName: "textformat.size.larger")
                    }
                    .disabled(fontSize >= fontRange.upperBound)

                    Button {
                        controller.addBookmark()
                    } label: {
                        Image(systemName: "bookmark")
                    }
                    .disabled(controller.currentLocator == nil)

                    Button {
                        showingBookmarks = true
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                }
            }
        }
        .sheet(isPresented: $showingBookmarks) {
            BookmarksSheet(controller: controller)
        }
        .task { await open() }
    }

    private func open() async {
        guard let fileURL = FileURL(url: book.url) else {
            state = .failed("URL de archivo no válida")
            return
        }

        let httpClient = DefaultHTTPClient()
        let assetRetriever = AssetRetriever(httpClient: httpClient)
        let opener = PublicationOpener(
            parser: DefaultPublicationParser(
                httpClient: httpClient,
                assetRetriever: assetRetriever,
                pdfFactory: DefaultPDFDocumentFactory()
            )
        )

        switch await assetRetriever.retrieve(url: fileURL) {
        case let .failure(error):
            state = .failed("No se pudo leer el archivo: \(error)")
        case let .success(asset):
            switch await opener.open(asset: asset, allowUserInteraction: false) {
            case let .failure(error):
                state = .failed("EPUB no válido: \(error)")
            case let .success(publication):
                RecentsStore.add(controller.relativePath)
                state = .ready(publication)
            }
        }
    }
}

/// Bridges Readium's UIKit `EPUBNavigatorViewController` into SwiftUI, applies
/// the live font-size preference, and reports the location to the controller.
private struct EPUBContainer: UIViewControllerRepresentable {
    let publication: Publication
    let fontSize: Double
    let controller: ReaderController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    /// Preferences for the navigator. When the user scales the font, publisher
    /// styles are disabled so the font size actually changes — some EPUBs hard-
    /// code their font size in CSS, which otherwise only grows the line spacing.
    private var preferences: EPUBPreferences {
        EPUBPreferences(
            fontSize: fontSize,
            publisherStyles: fontSize == 1.0 ? nil : false
        )
    }

    func makeUIViewController(context: Context) -> UIViewController {
        do {
            let navigator = try EPUBNavigatorViewController(
                publication: publication,
                initialLocation: PositionStore.locator(forRelativePath: controller.relativePath),
                config: .init(preferences: preferences)
            )
            navigator.delegate = context.coordinator
            context.coordinator.navigator = navigator
            controller.navigator = navigator

            // Turn pages with arrow keys, space bar and edge taps/clicks.
            let adapter = DirectionalNavigationAdapter()
            adapter.bind(to: navigator)
            context.coordinator.directionalAdapter = adapter

            return navigator
        } catch {
            let label = UILabel()
            label.text = "Error del navegador: \(error)"
            label.numberOfLines = 0
            label.textAlignment = .center
            let vc = UIViewController()
            vc.view.addSubview(label)
            label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: vc.view.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: vc.view.centerYAnchor),
                label.widthAnchor.constraint(lessThanOrEqualTo: vc.view.widthAnchor, multiplier: 0.8),
            ])
            return vc
        }
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        context.coordinator.navigator?.submitPreferences(preferences)
    }

    /// Persists the reading position and appends to the position history.
    final class Coordinator: EPUBNavigatorDelegate {
        let controller: ReaderController
        var navigator: EPUBNavigatorViewController?
        var directionalAdapter: DirectionalNavigationAdapter?
        private var lastHistoryProgress: Double?

        init(controller: ReaderController) { self.controller = controller }

        func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
            let path = controller.relativePath
            PositionStore.save(locator, forRelativePath: path)
            controller.currentLocator = locator

            // Append to history only on a meaningful move, to avoid logging
            // every single page turn.
            if let progress = locator.locations.totalProgression {
                if lastHistoryProgress == nil || abs(progress - lastHistoryProgress!) >= 0.03 {
                    PositionStore.recordHistory(locator, forRelativePath: path)
                    lastHistoryProgress = progress
                }
            }
        }

        func navigator(_ navigator: any ViewportObservingNavigator, viewportDidChange viewport: NavigatorViewport?) {}

        func navigator(_ navigator: Navigator, presentError error: NavigatorError) {}
    }
}
