import SwiftUI
import UIKit
import ReadiumShared
import ReadiumStreamer
import ReadiumNavigator

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

    private let fontStep = 0.1
    private let fontRange = 0.5 ... 3.0

    private var relativePath: String { Library.relativePath(of: book.url) }

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
                    relativePath: relativePath
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
                }
            }
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
                RecentsStore.add(relativePath)
                state = .ready(publication)
            }
        }
    }
}

/// Bridges Readium's UIKit `EPUBNavigatorViewController` into SwiftUI and
/// applies the live font-size preference.
private struct EPUBContainer: UIViewControllerRepresentable {
    let publication: Publication
    let fontSize: Double
    let relativePath: String

    func makeCoordinator() -> Coordinator { Coordinator(relativePath: relativePath) }

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
                initialLocation: PositionStore.locator(forRelativePath: relativePath),
                config: .init(preferences: preferences)
            )
            navigator.delegate = context.coordinator
            context.coordinator.navigator = navigator

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

    /// Holds the navigator and persists the reading position as it changes.
    final class Coordinator: EPUBNavigatorDelegate {
        var navigator: EPUBNavigatorViewController?
        var directionalAdapter: DirectionalNavigationAdapter?
        let relativePath: String

        init(relativePath: String) {
            self.relativePath = relativePath
        }

        func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
            PositionStore.save(locator, forRelativePath: relativePath)
        }

        func navigator(_ navigator: any ViewportObservingNavigator, viewportDidChange viewport: NavigatorViewport?) {}

        func navigator(_ navigator: Navigator, presentError error: NavigatorError) {}
    }
}
