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
    @State private var fontSize: Double = 1.0

    private let fontStep = 0.1
    private let fontRange = 0.5 ... 3.0

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
                EPUBContainer(publication: publication, fontSize: fontSize)
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

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        do {
            let navigator = try EPUBNavigatorViewController(
                publication: publication,
                initialLocation: nil,
                config: .init(preferences: EPUBPreferences(fontSize: fontSize))
            )
            context.coordinator.navigator = navigator
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
        context.coordinator.navigator?.submitPreferences(EPUBPreferences(fontSize: fontSize))
    }

    final class Coordinator {
        var navigator: EPUBNavigatorViewController?
    }
}
