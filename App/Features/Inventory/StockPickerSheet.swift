import SwiftUI
import SwiftData

/// شاشة اختيار صنف من المخزون: بحث بالاسم/الكود أو مسح باركود. بترجّع الصنف المختار وتقفل.
struct StockPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Product.name) private var products: [Product]

    let onPick: (Product) -> Void

    @State private var search = ""
    @State private var showScanner = false
    @State private var searchActive = false

    private var filtered: [Product] {
        let q = search.trimmed.lowercased()
        guard !q.isEmpty else { return products }
        let key = q.codeKey
        return products.filter {
            $0.name.lowercased().contains(q)
                || $0.code.lowercased().contains(q)
                || $0.sku.lowercased().contains(q)
                || (!key.isEmpty && ($0.code.codeKey == key || $0.sku.codeKey == key))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered) { product in
                    Button {
                        onPick(product)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(product.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            Text("\(Formatters.number(product.price, minFraction: 2)) • متاح: \(Formatters.number(product.qty, maxFraction: 3))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !product.code.isEmpty {
                                Text(product.code)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .searchable(
                text: $search,
                isPresented: $searchActive,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "ابحث بالاسم أو الكود"
            )
            .onAppear {
                // يفتح شريط البحث والكيبورد على طول أول ما الشاشة تظهر
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    searchActive = true
                }
            }
            .navigationTitle("اختيار من المخزون")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showScanner = true
                    } label: {
                        Image(systemName: "barcode.viewfinder")
                    }
                }
            }
            .fullScreenCover(isPresented: $showScanner) {
                BarcodeSearchSheet { code in
                    search = code
                    searchActive = false
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }
}

/// معاينة الفاتورة كـ PDF (بدون بيع/تجهيز) مع زرار تحميل ومشاركة.
struct InvoicePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let data: Data
    let title: String
    @State private var shareItem: ShareItem?

    var body: some View {
        NavigationStack {
            PDFKitView(data: data)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("إغلاق") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            share()
                        } label: {
                            Label("تحميل / مشاركة", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                .sheet(item: $shareItem) { item in
                    ShareSheet(items: [item.url])
                }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }

    private func share() {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        var name = title.components(separatedBy: forbidden).joined(separator: "-").trimmed
        if name.isEmpty { name = "invoice" }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).pdf")
        if (try? data.write(to: url, options: .atomic)) != nil {
            shareItem = ShareItem(url: url)
        }
    }
}
