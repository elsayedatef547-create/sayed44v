import SwiftUI
import SwiftData
import PDFKit

// MARK: - Model

/// نسخة مجمّدة من الفاتورة (PDF + ملخص) بتتحفظ في أرشيف منفصل.
/// حتى لو الفاتورة الأصلية اتمسحت من الرئيسية أو المخزون اتغيّر، الأرشيف يفضل زي ما اتصدّر.
@Model
final class ArchivedInvoice {
    var key: String = ""
    var title: String = ""
    var supplier: String = ""
    var invoiceDate: Date = Date()
    var archivedAt: Date = Date()
    var itemCount: Int = 0
    var pieceCount: Double = 0
    var totalSale: Double = 0
    var notes: String = ""
    var taxMode: String = "none"
    var kind: String = "sale"
    var discountPercent: Double = 0
    /// الأصناف (JSON) عشان نقدر نرجّع الفاتورة للرئيسية ونعدّلها
    @Attribute(.externalStorage) var itemsJSON: Data?
    @Attribute(.externalStorage) var pdfData: Data?

    init(key: String, title: String) {
        self.key = key
        self.title = title
    }
}

struct ArchivedRow: Codable {
    var name: String
    var code: String
    var qty: Double
    var unitPrice: Double
    var salePrice: Double?
    var matchedKey: String
    /// سعر العميل اليدوي (اختياري عشان الأرشيفات القديمة تفضل تتفتح)
    var customPrice: Double?
}

// MARK: - Service

enum InvoiceArchive {
    /// يحفظ (أو يحدّث) نسخة الفاتورة في الأرشيف. بنفس الفاتورة مبيتكررش؛ بيتحدّث بس.
    @MainActor
    static func save(
        _ invoice: Invoice,
        items: [InvoiceItem]? = nil,
        salePrice: (InvoiceItem) -> Double?,
        in context: ModelContext
    ) {
        let list = (items ?? invoice.items).sorted { $0.sortIndex < $1.sortIndex }
        guard !list.isEmpty else { return }

        let existing = (try? context.fetch(FetchDescriptor<ArchivedInvoice>())) ?? []
        if invoice.archiveID.isEmpty {
            // فواتير اتحفظت قبل كده بالمفتاح القديم (العنوان + التاريخ)
            let legacy = "\(invoice.title)|\(Int(invoice.date.timeIntervalSince1970))"
            invoice.archiveID = existing.contains { $0.key == legacy } ? legacy : UUID().uuidString
        }
        let key = invoice.archiveID
        let entry = existing.first { $0.key == key } ?? {
            let new = ArchivedInvoice(key: key, title: invoice.title)
            context.insert(new)
            return new
        }()

        entry.title = invoice.title
        entry.supplier = invoice.supplier
        entry.invoiceDate = invoice.date
        entry.archivedAt = Date()
        entry.itemCount = list.count
        entry.pieceCount = list.reduce(0) { $0 + max($1.qty, 0) }
        let base = list.reduce(0) { $0 + $1.qty * (salePrice($1) ?? 0) }
        entry.totalSale = InvoiceTotals.finalTotal(base: base, percent: invoice.discountPercent, mode: invoice.taxMode)
        entry.discountPercent = invoice.discountPercent
        entry.notes = invoice.notes
        entry.taxMode = invoice.taxMode
        entry.kind = invoice.kind
        entry.itemsJSON = try? JSONEncoder().encode(
            list.map {
                ArchivedRow(
                    name: $0.name, code: $0.code, qty: $0.qty, unitPrice: $0.unitPrice,
                    salePrice: salePrice($0), matchedKey: $0.matchedKey,
                    customPrice: $0.customPrice
                )
            }
        )
        entry.pdfData = PDFGenerator.generate(for: invoice, salePrice: salePrice, items: list)
        try? context.save()
    }

    /// يحفظ نسخة من الفاتورة بأسعار الشيت الحالية (من غير ما تحتاج تجيب المخزون بنفسك).
    @MainActor
    static func snapshot(_ invoice: Invoice, in context: ModelContext) {
        let products = (try? context.fetch(FetchDescriptor<Product>())) ?? []
        let matcher = StockMatcher(products: products)
        save(invoice, salePrice: { matcher.salePrice(for: $0) }, in: context)
    }

    /// يرجّع فاتورة من الأرشيف للرئيسية كفاتورة جديدة قابلة للتعديل. false لو موجودة بالفعل.
    @MainActor
    static func restore(_ entry: ArchivedInvoice, in context: ModelContext) -> Bool {
        let invoices = (try? context.fetch(FetchDescriptor<Invoice>())) ?? []
        if invoices.contains(where: { $0.archiveID == entry.key }) { return false }
        guard let data = entry.itemsJSON,
              let rows = try? JSONDecoder().decode([ArchivedRow].self, from: data) else { return false }

        let invoice = Invoice(title: entry.title, supplier: entry.supplier, date: entry.invoiceDate, notes: entry.notes)
        invoice.kind = entry.kind
        invoice.taxMode = entry.taxMode
        invoice.discountPercent = entry.discountPercent
        invoice.status = InvoiceStatus.new
        invoice.archiveID = entry.key
        context.insert(invoice)

        for (index, row) in rows.enumerated() {
            // أرشيف جديد: بنرجّع سعر الوحدة الأصلي وسعر العميل اليدوي زي ما كانوا.
            // أرشيف قديم (من غير customPrice): بنستخدم سعر البيع اللي اتصدّر.
            let price = row.customPrice == nil ? (row.salePrice ?? row.unitPrice) : row.unitPrice
            let item = InvoiceItem(
                name: row.name, code: row.code, qty: row.qty,
                unitPrice: price, total: row.qty * price, sortIndex: index
            )
            item.customPrice = row.customPrice ?? 0
            item.matchedKey = row.matchedKey
            context.insert(item)
            item.invoice = invoice
        }
        invoice.recalculateTotal()
        try? context.save()
        return true
    }
}

// MARK: - Views

struct ArchiveView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ArchivedInvoice.archivedAt, order: .reverse) private var archived: [ArchivedInvoice]
    @State private var search = ""

    private var filtered: [ArchivedInvoice] {
        let q = search.trimmed.lowercased()
        guard !q.isEmpty else { return archived }
        return archived.filter {
            $0.title.lowercased().contains(q) || $0.supplier.lowercased().contains(q)
        }
    }

    var body: some View {
        Group {
            if archived.isEmpty {
                ContentUnavailableView(
                    "الأرشيف فاضي",
                    systemImage: "archivebox",
                    description: Text("كل فاتورة بتتحفظ هنا تلقائيًا، حتى لو مسحتها من الرئيسية، وتقدر ترجّعها.")
                )
            } else {
                List {
                    ForEach(filtered) { entry in
                        NavigationLink {
                            ArchiveDetailView(entry: entry)
                        } label: {
                            ArchiveRow(entry: entry)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { modelContext.delete(filtered[index]) }
                        try? modelContext.save()
                    }
                }
                .listStyle(.insetGrouped)
                .searchable(text: $search, prompt: "بحث برقم الفاتورة أو المورد")
            }
        }
        .navigationTitle("أرشيف الفواتير")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ArchiveRow: View {
    let entry: ArchivedInvoice

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.indigo.opacity(0.15)).frame(width: 44, height: 44)
                Image(systemName: "archivebox.fill").foregroundStyle(.indigo)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title).font(.headline).lineLimit(1)
                Text(Formatters.date(entry.archivedAt))
                    .font(.caption).foregroundStyle(.secondary)
                if !entry.supplier.isEmpty {
                    Text(entry.supplier).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(Formatters.number(entry.totalSale, minFraction: 2)).font(.subheadline.bold())
                Text("\(Formatters.number(entry.pieceCount, maxFraction: 3)) قطعة")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct ArchiveDetailView: View {
    let entry: ArchivedInvoice
    @Environment(\.modelContext) private var modelContext
    @State private var shareItem: ShareItem?
    @State private var message = ""
    @State private var showMessage = false
    @State private var confirmRestore = false

    var body: some View {
        Group {
            if let data = entry.pdfData {
                PDFKitView(data: data)
            } else {
                ContentUnavailableView("الملف غير متاح", systemImage: "doc.questionmark")
            }
        }
        .navigationTitle(entry.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    share()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(entry.pdfData == nil)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    confirmRestore = true
                } label: {
                    Label("استرجاع", systemImage: "arrow.uturn.backward.circle")
                }
                .disabled(entry.itemsJSON == nil)
            }
        }
        .confirmationDialog("ترجّع الفاتورة للرئيسية كفاتورة جديدة تقدر تعدّلها؟", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("استرجاع للرئيسية") {
                message = InvoiceArchive.restore(entry, in: modelContext)
                    ? "اترجعت الفاتورة للرئيسية."
                    : "الفاتورة دي موجودة في الرئيسية بالفعل."
                showMessage = true
            }
            Button("إلغاء", role: .cancel) {}
        }
        .alert(message, isPresented: $showMessage) {
            Button("حسنًا", role: .cancel) {}
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
    }

    private func share() {
        guard let data = entry.pdfData else { return }
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        var name = entry.title.components(separatedBy: forbidden).joined(separator: "-").trimmed
        if name.isEmpty { name = "invoice" }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).pdf")
        if (try? data.write(to: url, options: .atomic)) != nil {
            shareItem = ShareItem(url: url)
        }
    }
}

struct PDFKitView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(data: data)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {}
}
