import SwiftUI
import PDFKit

/// PDFKit viewer for the run's report.
struct PDFKitView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> FittingPDFView {
        let view = FittingPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .windowBackgroundColor
        view.load(url)
        return view
    }

    func updateNSView(_ view: FittingPDFView, context: Context) {
        if view.document?.documentURL != url {
            view.load(url)
        }
    }
}

/// `PDFView` that fits the first page to the view once it has a real size.
///
/// When the document arrives before layout (fast local fixtures), PDFKit computes
/// the auto-scale for a zero-size view and the pane shows a zoomed-in corner of
/// page one until the user scrolls. The fit is re-applied on the first layout
/// pass with a non-zero size after every document change.
final class FittingPDFView: PDFView {
    private var needsInitialFit = false

    func load(_ url: URL) {
        document = PDFDocument(url: url)
        needsInitialFit = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard needsInitialFit, let document, document.pageCount > 0, bounds.width > 10, bounds.height > 10 else { return }
        needsInitialFit = false
        autoScales = true
        scaleFactor = scaleFactorForSizeToFit
        if let first = document.page(at: 0) {
            go(to: first)
        }
    }
}
