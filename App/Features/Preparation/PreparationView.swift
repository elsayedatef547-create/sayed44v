import SwiftUI
import SwiftData

// MARK: - Preparation list (tab)

struct PreparationView: View {
    @Query(sort: \Invoice.date, order: .reverse) private var invoices: [Invoice]

    private var preparing: [Invoice] {
        invoices.filter { $0.status == InvoiceStatus.preparing && !$0.isSupply }
    }

    private var done: [Invoice] {
        invoices.filter { $0.status == InvoiceStatus.done && !$0.isSupply }
    }

    var body: some View {
        NavigationStack {
            Group {
                if preparing.isEmpty {
                    ContentUnavailableView(
                        "لا توجد فواتير قيد التجهيز",
                        systemImage: "checklist",
                        description: Text(done.isEmpty
                            ? "افتح فاتورة واضغط «تجهيز» لتظهر هنا."
                            : "الفواتير اللي خلص تجهيزها في تبويب «المجهّزة».")
                    )
                } else {
                    List {
                        Section("قيد التجهيز") {
                            ForEach(preparing) { invoice in
                                NavigationLink {
                                    PreparationDetailView(invoice: invoice)
                                } label: {
                                    PreparationRow(invoice: invoice)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("التجهيز")
        }
    }
}

// MARK: - Prepared invoices (tab)

/// تبويب الفواتير اللي خلص تجهيزها (محفوظة هنا). بيفتح نفس شاشة التجهيز عشان تعيد الفتح أو تصدّر PDF.
struct PreparedInvoicesView: View {
    @Query(sort: \Invoice.date, order: .reverse) private var invoices: [Invoice]

    private var done: [Invoice] {
        invoices.filter { $0.status == InvoiceStatus.done && !$0.isSupply }
    }

    var body: some View {
        NavigationStack {
            Group {
                if done.isEmpty {
                    ContentUnavailableView(
                        "لا توجد فواتير مجهّزة",
                        systemImage: "checkmark.seal",
                        description: Text("لما تضغط «إنهاء التجهيز» على فاتورة هتتحفظ هنا.")
                    )
                } else {
                    List {
                        Section("\(done.count) فاتورة مجهّزة") {
                            ForEach(done) { invoice in
                                NavigationLink {
                                    PreparationDetailView(invoice: invoice)
                                } label: {
                                    PreparationRow(invoice: invoice)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("المجهّزة")
        }
    }
}

struct PreparationRow: View {
    let invoice: Invoice

    private var preparedCount: Int {
        invoice.items.filter { $0.prepared }.count
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill((invoice.status == InvoiceStatus.done ? Color.green : Color.indigo).opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: invoice.status == InvoiceStatus.done ? "checkmark" : "checklist")
                    .foregroundStyle(invoice.status == InvoiceStatus.done ? .green : .indigo)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(invoice.title)
                    .font(.headline)
                Text("جُهّز \(preparedCount) من \(invoice.items.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Preparation detail

struct PreparationDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var invoice: Invoice
    @Query private var products: [Product]

    @State private var shareItem: ShareItem?
    @State private var alertMessage = ""
    @State private var showAlert = false
    @State private var search = ""
    @State private var showScanner = false
    @State private var qtyItem: InvoiceItem?
    @State private var swapItem: InvoiceItem?
    @State private var stockFilter: StockFilter = .all
    @State private var showReopenConfirm = false

    /// فلتر المخزون أثناء التجهيز: الكل / النواقص لوحدها / المتوفر لوحده
    enum StockFilter: String, CaseIterable, Identifiable {
        case all, missing, available, unmatched
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "الكل"
            case .missing: return "النواقص"
            case .available: return "المتوفر"
            case .unmatched: return "غير مربوط بالمخزون"
            }
        }
    }

    private var sortedItems: [InvoiceItem] {
        invoice.items.sorted { $0.sortIndex < $1.sortIndex }
    }

    private var preparedItems: [InvoiceItem] {
        sortedItems.filter { $0.prepared }
    }

    private var isFinished: Bool {
        invoice.status == InvoiceStatus.done
    }

    /// كود الصنف زي ما هو في الشيت (SKU لو موجود وإلا الباركود)
    private func sheetCode(_ product: Product) -> String {
        let sku = product.sku.trimmed
        return sku.isEmpty ? product.code.trimmed : sku
    }

    /// الكود المعروض: من الشيت لو الصنف متطابق، وإلا اللي في الفاتورة
    private func displayCode(_ item: InvoiceItem, _ info: StockInfo) -> String {
        if let product = info.product {
            let code = sheetCode(product)
            if !code.isEmpty { return code }
        }
        return item.code
    }

    private func passesStockFilter(_ item: InvoiceItem, _ matcher: StockMatcher) -> Bool {
        switch stockFilter {
        case .all: return true
        case .missing: return !matcher.info(for: item).isFullyAvailable
        case .available: return matcher.info(for: item).isFullyAvailable
        case .unmatched: return matcher.info(for: item).state == .notFound
        }
    }

    private func filteredItems(_ matcher: StockMatcher) -> [InvoiceItem] {
        let base = sortedItems.filter { passesStockFilter($0, matcher) }
        let q = search.trimmed.lowercased()
        guard !q.isEmpty else { return base }
        let key = q.codeKey
        return base.filter { item in
            if item.name.lowercased().contains(q) || item.code.lowercased().contains(q) { return true }
            if !key.isEmpty && item.code.codeKey == key { return true }
            guard let product = matcher.info(for: item).product else { return false }
            return product.name.lowercased().contains(q)
                || product.code.lowercased().contains(q)
                || product.sku.lowercased().contains(q)
                || (!key.isEmpty && (product.code.codeKey == key || product.sku.codeKey == key))
        }
    }

    /// يخلّي كود الصنف في الفاتورة هو كود الشيت (بدل الكود المقروء من الصورة)
    private func syncCodesFromSheet() {
        let matcher = StockMatcher(products: products)
        var changed = false
        for item in invoice.items {
            guard let product = matcher.info(for: item).product else { continue }
            let code = sheetCode(product)
            if !code.isEmpty && item.code != code {
                item.code = code
                changed = true
            }
            if item.matchedKey.isEmpty && !product.matchKey.isEmpty {
                item.matchedKey = product.matchKey
                changed = true
            }
        }
        if changed { try? modelContext.save() }
    }

    private func reopenIfFinished() {
        if isFinished { invoice.status = InvoiceStatus.preparing }
    }

    private func togglePrepared(_ item: InvoiceItem) {
        reopenIfFinished()
        item.prepared.toggle()
        if item.prepared {
            InventoryService.deduct(item, products: products)
        } else {
            InventoryService.restore(item, products: products)
        }
        try? modelContext.save()
    }

    /// تعديل العدد: لو الصنف اتجهّز، بنرجّع الخصم القديم وبنخصم بالعدد الجديد.
    private func applyQty(_ item: InvoiceItem, _ newQty: Double) {
        let qty = max(newQty, 0)
        reopenIfFinished()
        let wasPrepared = item.prepared
        if wasPrepared { InventoryService.restore(item, products: products) }
        item.qty = qty
        item.total = qty * item.unitPrice
        if wasPrepared { InventoryService.deduct(item, products: products) }
        invoice.totalAmount = InvoiceTotals.saleTotal(of: invoice, matcher: StockMatcher(products: products))
        try? modelContext.save()
    }

    private func filterLabel(_ filter: StockFilter, _ matcher: StockMatcher) -> String {
        let missing = sortedItems.filter { !matcher.info(for: $0).isFullyAvailable }.count
        switch filter {
        case .all: return "الكل (\(sortedItems.count))"
        case .missing: return "النواقص (\(missing))"
        case .available: return "المتوفر (\(sortedItems.count - missing))"
        case .unmatched:
            let unmatched = sortedItems.filter { matcher.info(for: $0).state == .notFound }.count
            return "غير مربوط (\(unmatched))"
        }
    }

    private var emptyMessage: String {
        if !search.trimmed.isEmpty { return "مفيش صنف مطابق للبحث" }
        switch stockFilter {
        case .all: return "لا توجد أصناف"
        case .missing: return "مفيش نواقص — كل الأصناف متوفرة"
        case .available: return "مفيش أصناف متوفرة بالكامل"
        case .unmatched: return "كل الأصناف مربوطة بالمخزون"
        }
    }

    /// تبديل الصنف بصنف تاني من المخزون (لو الاسم مختلف). بيحفظ المطابقة للمرات الجاية.
    private func swapProduct(_ item: InvoiceItem, with product: Product) {
        reopenIfFinished()
        let wasPrepared = item.prepared
        if wasPrepared { InventoryService.restore(item, products: products) }
        MatchService.accept(item, product: product, in: modelContext)
        item.name = product.name
        item.code = sheetCode(product)
        item.unitPrice = product.price
        item.customPrice = 0
        item.total = item.qty * item.unitPrice
        if wasPrepared { InventoryService.deduct(item, products: products) }
        invoice.totalAmount = InvoiceTotals.saleTotal(of: invoice, matcher: StockMatcher(products: products))
        try? modelContext.save()
    }

    var body: some View {
        let matcher = StockMatcher(products: products)
        return List {
            Section {
                ProgressView(value: Double(preparedItems.count), total: Double(max(sortedItems.count, 1)))
                    .tint(.indigo)
                Text("جُهّز \(preparedItems.count) من \(sortedItems.count)")
                    .font(.subheadline.weight(.semibold))
            }

            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(StockFilter.allCases) { filter in
                            Button {
                                stockFilter = filter
                            } label: {
                                Text(filterLabel(filter, matcher))
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(
                                        stockFilter == filter ? Color.indigo : Color.indigo.opacity(0.12),
                                        in: Capsule()
                                    )
                                    .foregroundStyle(stockFilter == filter ? Color.white : Color.indigo)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .listRowInsets(EdgeInsets())
            }

            Section("الأصناف") {
                let items = filteredItems(matcher)
                if items.isEmpty {
                    Text(emptyMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    let info = matcher.info(for: item)
                    PreparationItemRow(
                        item: item,
                        info: info,
                        code: displayCode(item, info),
                        onToggle: { togglePrepared(item) },
                        onEditQty: { qtyItem = item },
                        onSwap: { swapItem = item }
                    )
                }
            }

            Section {
                if isFinished {
                    Menu {
                        Button {
                            sharePDF(items: preparedItems.isEmpty ? sortedItems : preparedItems, language: .arabic)
                        } label: {
                            Label("الأصناف المجهّزة فقط", systemImage: "checkmark.circle")
                        }
                        Button {
                            sharePDF(items: sortedItems, language: .arabic)
                        } label: {
                            Label("كل أصناف الفاتورة", systemImage: "list.bullet")
                        }
                    } label: {
                        Label("فاتورة PDF بالعربي", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }

                    Menu {
                        Button {
                            sharePDF(items: preparedItems.isEmpty ? sortedItems : preparedItems, language: .spanish)
                        } label: {
                            Label("الأصناف المجهّزة فقط", systemImage: "checkmark.circle")
                        }
                        Button {
                            sharePDF(items: sortedItems, language: .spanish)
                        } label: {
                            Label("كل أصناف الفاتورة", systemImage: "list.bullet")
                        }
                    } label: {
                        Label("فاتورة PDF بالإسباني (Factura)", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }

                    Button(role: .destructive) {
                        showReopenConfirm = true
                    } label: {
                        Label("إعادة فتح التجهيز", systemImage: "arrow.uturn.backward")
                    }
                } else {
                    Button {
                        finish()
                    } label: {
                        Label("إنهاء التجهيز", systemImage: "checkmark.seal.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(preparedItems.isEmpty)
                }
            }
        }
        .navigationTitle(invoice.title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "ابحث بالاسم أو الكود")
        .toolbar {
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
            }
        }
        .sheet(item: $qtyItem) { item in
            PreparationQtySheet(item: item) { applyQty(item, $0) }
        }
        .sheet(item: $swapItem) { item in
            StockPickerSheet { product in swapProduct(item, with: product) }
        }
        .onAppear { syncCodesFromSheet() }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .confirmationDialog(
            "إعادة فتح التجهيز هترجّع الفاتورة لقائمة «قيد التجهيز». الكميات اللي اتخصمت مش هترجع للمخزون غير لو شلت علامة «جُهّز» من الصنف.",
            isPresented: $showReopenConfirm,
            titleVisibility: .visible
        ) {
            Button("إعادة الفتح", role: .destructive) {
                invoice.status = InvoiceStatus.preparing
                try? modelContext.save()
            }
            Button("إلغاء", role: .cancel) {}
        }
        .alert("تنبيه", isPresented: $showAlert) {
            Button("حسناً", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private func finish() {
        invoice.status = InvoiceStatus.done
        try? modelContext.save()
        AutoSync.request(modelContext)
        let matcher = StockMatcher(products: products)
        InvoiceArchive.save(
            invoice,
            items: preparedItems.isEmpty ? sortedItems : preparedItems,
            salePrice: { matcher.salePrice(for: $0) },
            in: modelContext
        )
    }

    private func sharePDF(items: [InvoiceItem], language: PDFLanguage) {
        let matcher = StockMatcher(products: products)
        do {
            let url = try PDFGenerator.writeTemporaryFile(
                for: invoice,
                salePrice: { matcher.salePrice(for: $0) },
                items: items,
                language: language
            )
            InvoiceArchive.save(invoice, items: items, salePrice: { matcher.salePrice(for: $0) }, in: modelContext)
            shareItem = ShareItem(url: url)
        } catch {
            alertMessage = "تعذّر إنشاء ملف PDF: \(error.localizedDescription)"
            showAlert = true
        }
    }
}


// MARK: - Quantity editor

/// تعديل عدد الصنف أثناء التجهيز.
struct PreparationQtySheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: InvoiceItem
    let onSave: (Double) -> Void

    @State private var text: String

    init(item: InvoiceItem, onSave: @escaping (Double) -> Void) {
        self.item = item
        self.onSave = onSave
        _text = State(initialValue: Formatters.number(item.qty, maxFraction: 3, grouping: false))
    }

    private var value: Double? { text.parsedDouble }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(item.name.isEmpty ? "صنف بدون اسم" : item.name)
                        .font(.subheadline.weight(.semibold))
                }
                Section("العدد") {
                    HStack {
                        Button {
                            text = Formatters.number(max((value ?? 0) - 1, 0), maxFraction: 3, grouping: false)
                        } label: {
                            Image(systemName: "minus.circle.fill").font(.title)
                        }
                        .buttonStyle(.borderless)
                        TextField("0", text: $text)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.center)
                            .font(.title2.weight(.semibold))
                        Button {
                            text = Formatters.number((value ?? 0) + 1, maxFraction: 3, grouping: false)
                        } label: {
                            Image(systemName: "plus.circle.fill").font(.title)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .navigationTitle("تعديل العدد")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("حفظ") {
                        if let value { onSave(value) }
                        dismiss()
                    }
                    .disabled(value == nil)
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .presentationDetents([.medium])
    }
}


// MARK: - Item row

/// صف صنف في التجهيز: الاسم فوق، بعده الكود والعدد، بعده حالة المخزون، وتحت أزرار العدد والتبديل.
struct PreparationItemRow: View {
    let item: InvoiceItem
    let info: StockInfo
    let code: String
    let onToggle: () -> Void
    let onEditQty: () -> Void
    let onSwap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: item.prepared ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(item.prepared ? Color.green : Color.secondary)

                ProductThumb(imageURL: info.product?.imageURL, size: 56)

                VStack(alignment: .leading, spacing: 5) {
                    Text(item.name.isEmpty ? "صنف بدون اسم" : item.name)
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.leading)
                        .strikethrough(item.prepared)

                    if let sheetName = info.product?.name, sheetName != item.name {
                        Label(sheetName, systemImage: "link")
                            .font(.caption)
                            .foregroundStyle(.indigo)
                    }

                    HStack(spacing: 8) {
                        if !code.isEmpty {
                            Text(code)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Text("×\(Formatters.number(item.qty, maxFraction: 3))")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.indigo.opacity(0.12), in: Capsule())
                            .foregroundStyle(.indigo)
                    }

                    if item.prepared && item.stockDeducted > 0 {
                        Text("اتخصم من المخزون: \(Formatters.number(item.stockDeducted, maxFraction: 3))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.indigo)
                    } else {
                        StockBadge(info: info)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)

            HStack(spacing: 10) {
                Button(action: onEditQty) {
                    Label("العدد", systemImage: "pencil")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.indigo)

                Button(action: onSwap) {
                    Label("بدّل من المخزون", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}
