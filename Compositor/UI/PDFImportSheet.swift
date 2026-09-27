import SwiftUI
import CoreGraphics

/// The choices Photoshop asks for before it rasterizes a PDF, asked here for the same reason: a PDF
/// page carries no resolution of its own, so the resolution picked is what the layer becomes.
struct PDFImportSheet: View {
    let session: EditorSession
    let url: URL
    @State private var options: PDFImportOptions
    @State private var preview = PDFImportPreview()
    @State private var revision = 0

    init(session: EditorSession, url: URL, options: PDFImportOptions) {
        self.session = session
        self.url = url
        _options = State(initialValue: options)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import “\(url.lastPathComponent)”").font(.title2.bold())
            Text("A PDF page is measured in points, 72 to the inch. The resolution below is what the pages are drawn at.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            row("Pages") {
                TextField("All, or 1-3, 7", text: $options.pages)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .multilineTextAlignment(.trailing)
                Text(pageSummary).foregroundStyle(.secondary)
            }
            row("Crop To") {
                Picker("", selection: $options.box) {
                    ForEach(PDFImportOptions.Box.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 160)
            }
            row("Resolution") {
                Picker("", selection: $options.resolution) {
                    ForEach(PDFImportOptions.presetResolutions, id: \.self) { Text("\(Int($0)) pixels/inch").tag($0) }
                }
                .labelsHidden().frame(width: 160)
            }
            row("Background") {
                Picker("", selection: $options.paper) {
                    ForEach(PDFImportOptions.Paper.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 160)
            }

            HStack(spacing: 6) {
                Image(systemName: warning ? "exclamationmark.triangle.fill" : "info.circle")
                    .foregroundStyle(warning ? .yellow : .secondary)
                Text(readout).foregroundStyle(warning ? Color.primary : .secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { session.finishPDFImport(nil) }.keyboardShortcut(.cancelAction)
                Button("Import") { session.finishPDFImport(options) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview.selected.isEmpty || preview.overBudget || preview.overSideLimit)
            }
        }
        .padding(24).fixedSize()
        .task(id: revision) { preview = PDFImportPreview.read(url, options: options) }
        .onChange(of: options) { _, _ in revision += 1 }
    }

    private var warning: Bool { preview.overBudget || preview.overSideLimit }
    private var pageSummary: String {
        preview.pageCount == 0 ? "This file has no pages"
            : preview.selected.isEmpty ? "No pages match “\(options.pages)”"
            : preview.selected.count == preview.pageCount ? "All \(preview.pageCount) pages"
            : "\(preview.selected.count) of \(preview.pageCount) pages"
    }
    private var readout: String {
        guard let range = preview.pixelRange else { return pageSummary }
        let pages = "\(preview.selected.count) page\(preview.selected.count == 1 ? "" : "s")"
        if preview.overBudget {
            return "\(range) per page · \(pages) · \(preview.megapixels.formatted(.number.precision(.fractionLength(1)))) megapixels — over this project’s \(DocumentLimits.documentBudgetMegapixels)-megapixel budget"
        }
        if preview.overSideLimit {
            return "\(range) per page · over the \(DocumentLimits.maxSide.formatted())-pixel side limit"
        }
        return "\(range) per page · \(pages) · \(preview.megapixels.formatted(.number.precision(.fractionLength(1)))) megapixels"
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 90, alignment: .leading)
            content()
        }
    }
}

extension View {
    func pdfImportSheet(_ session: EditorSession) -> some View {
        sheet(isPresented: Binding(
            get: { session.showsPDFImport },
            set: { if !$0 { session.finishPDFImport(nil) } }
        )) {
            if let request = session.pdfImport {
                PDFImportSheet(session: session, url: request.url, options: request.options)
            }
        }
    }
}
