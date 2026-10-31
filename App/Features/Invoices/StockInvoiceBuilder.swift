import SwiftUI
import SwiftData

/// بيعمل فاتورة بيع من أصناف المخزون: تختار الأصناف والكميات، والأسعار بتتاخد من الشيت.
struct StockInvoiceBuilderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Product.name) private var products: [Product]

    /// لو متحدد: ده «تحويل بضاعة» لمحل تابع ليا (العميل ثابت، الضريبة بدون، والأسعار بتتجمّد في الفاتورة)
    var transferShop: String? = nil
    var onCreated: (String) -> Void

    @State private var priceBasis = PriceBasis.sale
    @State private var search = ""
    @State private var quantities: [PersistentIdentifier: Double] = [:]
    @State private var title = StockInvoiceBuilderView.defaultTitle()
    @State private var customer = ""
    @State private var taxMode = TaxMode.iva
    @State private var showScanner = false
    /// أسعار معدّلة يدويًا (بس اللي اتغيّرت عن سعر الشيت)
    @State private var prices: [PersistentIdentifier: Double] = [:]
    @State private var discountPercent: Double = 0
    @State private var showDiscount = false
    @State private var showSelectedOnly = false

    enum PriceBasis: Hashable {
        case sale, cost
    }

    private var isTransfer: Bool { transferShop != nil }

    private static func defaultTitle(prefix: String = "INV-") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return prefix + formatter.string(from: Date())
    }

    /// السعر الأساسي للصنف حسب الأساس المختار (سعر البيع أو التكلفة). لو التكلفة مش مسجّلة بنرجع لسعر البيع.
    private func basePrice(for product: Product) -> Double {
        if isTransfer, priceBasis == .cost, product.cost > 0 { return product.cost }
        return product.price
    }

    private func price(for product: Product) -> Double {
        prices[product.persistentModelID] ?? basePrice(for: product)
    }

    private func isSelected(_ product: Product) -> Bool {
        (quantities[product.persistentModelID] ?? 0) > 0
    }

    private var filtered: [Product] {
        let pool = showSelectedOnly ? products.filter { isSelected($0) } : products
        let q = search.trimmed.lowercased()
        guard !q.isEmpty else { return pool }
        let key = q.codeKey
        return pool.filter {
            $0.name.lowercased().contains(q)
                || $0.code.lowercased().contains(q)
                || $0.sku.lowercased().contains(q)
                // مطابقة الباركود بعد توحيد الأرقام (عشان نتيجة الاسكان تلاقي الصنف)
                || (!key.isEmpty && ($0.code.codeKey == key || $0.sku.codeKey == key))
        }
    }

    private var selected: [Product] {
        products.filter { (quantities[$0.persistentModelID] ?? 0) > 0 }
    }

    private var pieceCount: Double {
        selected.reduce(0) { $0 + (quantities[$1.persistentModelID] ?? 0) }
    }

    private var baseTotal: Double {
        selected.reduce(0) { $0 + (quantities[$1.persistentModelID] ?? 0) * price(for: $1) }
    }

    private var totalSale: Double {
        InvoiceTotals.finalTotal(base: baseTotal, percent: discountPercent, mode: taxMode)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField(isTransfer ? "رقم التحويل" : "رقم الفاتورة", text: $title)
                    if let shop = transferShop {
                        HStack {
                            Label(shop, systemImage: "storefront")
                            Spacer()
                            Text("محل")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Picker("سعر التحويل", selection: $priceBasis) {
                            Text("سعر البيع").tag(PriceBasis.sale)
                            Text("التكلفة").tag(PriceBasis.cost)
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: priceBasis) { _, _ in prices = [:] }
                    } else {
                        HStack {
                            TextField("اسم العميل (اختياري)", text: $customer)
                            CustomerPickerMenu(text: $customer)
                        }
                    }
                    Picker("الضريبة", selection: $taxMode) {
                        Text("من غير ضريبة").tag(TaxMode.none)
                        Text("IVA 21%").tag(TaxMode.iva)
                        Text("لا تخضع للضريبة").tag(TaxMode.exempt)
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Picker("العرض", selection: $showSelectedOnly) {
                        Text("كل الأصناف").tag(false)
                        Text("المختارة (\(selected.count))").tag(true)
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    ForEach(filtered) { product in
                        StockInvoiceRow(
                            product: product,
                            qty: Binding(
                                get: { quantities[product.persistentModelID] ?? 0 },
                                set: { quantities[product.persistentModelID] = max($0, 0) }
                            ),
                            price: Binding(
                                get: { price(for: product) },
                                set: { newValue in
                                    // السعر لازم يكون أكبر من صفر؛ غير كده بنرجع لسعر الشيت
                                    if newValue > 0 && abs(newValue - basePrice(for: product)) > 0.0001 {
                                        prices[product.persistentModelID] = newValue
                                    } else {
                                        prices[product.persistentModelID] = nil
                                    }
                                }
                            ),
                            listPrice: basePrice(for: product)
                        )
                    }
                    if filtered.isEmpty {
                        Text(showSelectedOnly && search.trimmed.isEmpty ? "لسه مختارتش أي صنف" : "مفيش صنف مطابق")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(showSelectedOnly ? "الأصناف اللي اخترتها" : "اختار الأصناف والكميات")
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $search, prompt: "ابحث بالاسم أو الكود")
            .navigationTitle(isTransfer ? "تحويل بضاعة" : "فاتورة من المخزون")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if let shop = transferShop, customer.isEmpty {
                    customer = shop
                    taxMode = TaxMode.none
                    title = StockInvoiceBuilderView.defaultTitle(prefix: "TRF-")
                }
            }
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
                    .accessibilityLabel("بحث بالاسكان")
                }
            }
            .fullScreenCover(isPresented: $showScanner) {
                BarcodeSearchSheet { code in
                    search = code
                }
            }
            .sheet(isPresented: $showDiscount) {
                DiscountSheet(base: baseTotal, taxMode: taxMode, initialPercent: discountPercent) { discountPercent = $0 }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button {
                        showDiscount = true
                    } label: {
                        Label(
                            discountPercent > 0
                                ? "خصم \(Formatters.number(discountPercent, maxFraction: 2))% — تعديل"
                                : "تعديل الإجمالي (خصم)",
                            systemImage: "percent"
                        )
                        .font(.caption.weight(.semibold))
                    }
                    .disabled(selected.isEmpty)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(selected.count) صنف • \(Formatters.number(pieceCount, maxFraction: 3)) قطعة")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(Formatters.number(totalSale, minFraction: 2))
                                .font(.title3.bold())
                                .foregroundStyle(.indigo)
                        }
                        Spacer()
                        Button {
                            create()
                        } label: {
                            Label(isTransfer ? "إنشاء التحويل" : "إنشاء الفاتورة", systemImage: "doc.badge.plus")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)
                        .disabled(selected.isEmpty || title.trimmed.isEmpty)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.bar)
            }
        }
    }

    private func create() {
        let chosen = selected
        guard !chosen.isEmpty else { return }

        let invoice = Invoice(title: title.trimmed, supplier: customer.trimmed, date: Date())
        invoice.kind = InvoiceKind.sale
        invoice.taxMode = taxMode
        invoice.discountPercent = discountPercent
        invoice.status = InvoiceStatus.new
        modelContext.insert(invoice)
        // اسم العميل الجديد بيتحفظ في قايمة العملاء
        CustomerDirectory.ensureSaved(customer, in: modelContext)

        for (index, product) in chosen.enumerated() {
            let qty = quantities[product.persistentModelID] ?? 0
            let sku = product.sku.trimmed
            let used = price(for: product)
            let item = InvoiceItem(
                name: product.name,
                code: sku.isEmpty ? product.code : sku,
                qty: qty,
                unitPrice: used,
                total: qty * used,
                sortIndex: index
            )
            // السعر اليدوي يتحفظ كـ «سعر مخصص» للصنف في الفاتورة دي بس
            // في التحويل بنجمّد السعر دايمًا، عشان تغيير سعر الشيت بعدين ميغيّرش قيمة الشهور اللي فاتت
            item.customPrice = (isTransfer || abs(used - product.price) > 0.0001) ? used : 0
            item.matchedKey = product.matchKey
            modelContext.insert(item)
            item.invoice = invoice
        }
        invoice.totalAmount = totalSale
        try? modelContext.save()
        InvoiceArchive.snapshot(invoice, in: modelContext)

        onCreated(isTransfer
            ? "اتعمل التحويل \(invoice.title). هتلاقيه في الرئيسية، والمخزون بيتخصم لما تجهّزه."
            : "اتعملت الفاتورة \(invoice.title) وهتلاقيها في الرئيسية.")
        dismiss()
    }
}

private struct StockInvoiceRow: View {
    let product: Product
    @Binding var qty: Double
    @Binding var price: Double
    let listPrice: Double
    @FocusState private var focused: Bool

    private var priceEdited: Bool { abs(price - listPrice) > 0.0001 }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(product.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    PriceField(price: $price, listPrice: listPrice)
                    Text("• متاح: \(Formatters.number(product.qty, maxFraction: 3))")
                        .font(.caption)
                        .foregroundStyle(qty > product.qty ? Color.orange : Color.secondary)
                }
                if priceEdited {
                    Text("السعر الأساسي: \(Formatters.number(listPrice, minFraction: 2))")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 4)
            TextField("0", value: $qty, format: .number.locale(Locale(identifier: "en_US")).grouping(.never))
                .keyboardType(.decimalPad)
                .focused($focused)
                .multilineTextAlignment(.center)
                .font(.subheadline.weight(.semibold))
                .frame(width: 58)
                .padding(.vertical, 6)
                .background(
                    (qty > 0 ? Color.indigo.opacity(0.15) : Color.primary.opacity(0.08)),
                    in: RoundedRectangle(cornerRadius: 8)
                )
            Stepper("", value: $qty, in: 0...1_000_000, step: 1)
                .labelsHidden()
                .fixedSize()
        }
        .padding(.vertical, 2)
    }
}


/// خانة سعر الصنف: بتقبل أرقام عربي/إنجليزي وفاصلة أو نقطة. لو اتمسحت أو بقت صفر بيرجع سعر الشيت.
private struct PriceField: View {
    @Binding var price: Double
    let listPrice: Double
    @State private var text: String
    @FocusState private var focused: Bool

    init(price: Binding<Double>, listPrice: Double) {
        _price = price
        self.listPrice = listPrice
        _text = State(initialValue: Formatters.number(price.wrappedValue, minFraction: 2, grouping: false))
    }

    private var edited: Bool { abs(price - listPrice) > 0.0001 }

    var body: some View {
        HStack(spacing: 4) {
            TextField("0.00", text: $text)
                .keyboardType(.decimalPad)
                .focused($focused)
                .multilineTextAlignment(.center)
                .font(.caption.weight(.semibold))
                .frame(width: 66)
                .padding(.vertical, 4)
                .background(
                    edited ? Color.orange.opacity(0.18) : Color.primary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 6)
                )
            if edited {
                Button {
                    focused = false
                    price = listPrice
                    text = Formatters.number(listPrice, minFraction: 2, grouping: false)
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
            }
        }
        .onChange(of: text) { _, new in
            if let value = new.parsedDouble {
                price = value
            } else if new.trimmed.isEmpty {
                price = 0   // الـ binding بيحوّل ده لسعر الشيت
            }
        }
        .onChange(of: price) { _, new in
            if !focused { text = Formatters.number(new, minFraction: 2, grouping: false) }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { text = Formatters.number(price, minFraction: 2, grouping: false) }
        }
    }
}
