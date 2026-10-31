import SwiftUI
import SwiftData

// MARK: - Model

/// عميل محفوظ في قايمة العملاء. الفواتير بتتربط بالعميل عن طريق اسم العميل المكتوب في الفاتورة.
@Model
final class Customer {
    var name: String = ""
    var createdAt: Date = Date()
    /// محل تابع ليا (بيتحوّله بضاعة). الباقي عملاء عاديين.
    var isShop: Bool = false

    init(name: String, isShop: Bool = false) {
        self.name = name
        self.isShop = isShop
    }
}

// MARK: - Helpers

extension String {
    /// مفتاح مقارنة اسم العميل: من غير حساسية للحروف أو التشكيل أو المسافات الزايدة.
    var customerKey: String {
        folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

enum MonthHelper {
    static func start(of date: Date) -> Date {
        Calendar.current.dateInterval(of: .month, for: date)?.start ?? date
    }

    static func shift(_ monthStart: Date, by months: Int) -> Date {
        Calendar.current.date(byAdding: .month, value: months, to: monthStart) ?? monthStart
    }

    static func range(_ monthStart: Date) -> Range<Date> {
        let end = Calendar.current.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart
        return monthStart..<end
    }

    /// "2026-10" لاسم الملف
    static func fileStamp(_ monthStart: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: monthStart)
    }

    static func title(_ monthStart: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ar@numbers=latn")
        formatter.dateFormat = "LLLL yyyy"
        return formatter.string(from: monthStart)
    }
}

enum CustomerDirectory {
    /// العملاء المحفوظين من غير تكرار (بنفس الاسم)، مرتبين أبجديًا.
    static func unique(_ customers: [Customer]) -> [Customer] {
        var seen = Set<String>()
        var result: [Customer] = []
        for customer in customers.sorted(by: { $0.name.localizedCompare($1.name) == .orderedAscending }) {
            let key = customer.name.customerKey
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(customer)
        }
        return result
    }

    /// فواتير البيع بتاعة عميل في شهر معيّن، الأحدث أولًا.
    static func invoices(of key: String, in monthStart: Date, from invoices: [Invoice], preparedOnly: Bool) -> [Invoice] {
        let range = MonthHelper.range(monthStart)
        return invoices
            .filter {
                !$0.isSupply
                    && $0.supplier.customerKey == key
                    && range.contains($0.date)
                    && (!preparedOnly || $0.status == InvoiceStatus.done)
            }
            .sorted { $0.date > $1.date }
    }

    /// يحفظ الاسم كعميل لو مش موجود قبل كده.
    @MainActor
    static func ensureSaved(_ name: String, isShop: Bool = false, in context: ModelContext) {
        let trimmed = name.trimmed
        let key = trimmed.customerKey
        guard !key.isEmpty else { return }
        let existing = (try? context.fetch(FetchDescriptor<Customer>())) ?? []
        if existing.contains(where: { $0.name.customerKey == key }) { return }
        context.insert(Customer(name: trimmed, isShop: isShop))
        try? context.save()
    }
}

extension InvoiceTotals {
    /// إجمالي فاتورة البيع بأسعار البيع الحالية (سعر مخصص أو سعر الشيت)، بعد الخصم وبعد الضريبة.
    static func saleTotal(of invoice: Invoice, matcher: StockMatcher) -> Double {
        let base = invoice.items.reduce(0) { $0 + $1.qty * (matcher.salePrice(for: $1) ?? 0) }
        return finalTotal(base: base, percent: invoice.discountPercent, mode: invoice.taxMode)
    }
}

// MARK: - Pieces

struct MonthSwitcher: View {
    @Binding var monthStart: Date

    var body: some View {
        HStack {
            Button {
                monthStart = MonthHelper.shift(monthStart, by: -1)
            } label: {
                Image(systemName: "chevron.backward")
                    .frame(width: 36, height: 30)
            }
            .buttonStyle(.borderless)

            Spacer()
            Text(MonthHelper.title(monthStart))
                .font(.headline)
            Spacer()

            Button {
                monthStart = MonthHelper.shift(monthStart, by: 1)
            } label: {
                Image(systemName: "chevron.forward")
                    .frame(width: 36, height: 30)
            }
            .buttonStyle(.borderless)
        }
    }
}

/// قايمة منسدلة لاختيار عميل محفوظ وكتابة اسمه في خانة الاسم.
struct CustomerPickerMenu: View {
    @Binding var text: String
    @Query(sort: \Customer.name) private var customers: [Customer]

    var body: some View {
        let list = CustomerDirectory.unique(customers)
        Menu {
            if list.isEmpty {
                Text("مفيش عملاء محفوظين. ضيفهم من تبويب العملاء.")
            }
            ForEach(list) { customer in
                Button(customer.name) { text = customer.name }
            }
        } label: {
            Image(systemName: "person.crop.circle.badge.plus")
        }
    }
}

private struct StatusBadge: View {
    let status: String

    private var info: (String, Color) {
        switch status {
        case InvoiceStatus.done: return ("مجهّزة", .green)
        case InvoiceStatus.preparing: return ("قيد التجهيز", .orange)
        default: return ("جديدة", .gray)
        }
    }

    var body: some View {
        Text(info.0)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(info.1.opacity(0.15), in: Capsule())
            .foregroundStyle(info.1)
    }
}

// MARK: - Customers tab

struct CustomersView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Customer.name) private var customers: [Customer]
    @Query private var invoices: [Invoice]
    @Query private var products: [Product]

    @State private var monthStart = MonthHelper.start(of: Date())
    @State private var search = ""
    @State private var preparedOnly = false
    @State private var showAdd = false
    @State private var newName = ""
    @State private var newIsShop = false

    private struct Row: Identifiable {
        let customer: Customer
        let count: Int
        let total: Double
        var id: PersistentIdentifier { customer.persistentModelID }
    }

    private func rows(_ matcher: StockMatcher) -> [Row] {
        let query = search.trimmed.customerKey
        return CustomerDirectory.unique(customers)
            .filter { query.isEmpty || $0.name.customerKey.contains(query) }
            .map { customer in
                let list = CustomerDirectory.invoices(
                    of: customer.name.customerKey, in: monthStart, from: invoices, preparedOnly: preparedOnly
                )
                let total = list.reduce(0) { $0 + InvoiceTotals.saleTotal(of: $1, matcher: matcher) }
                return Row(customer: customer, count: list.count, total: total)
            }
    }

    var body: some View {
        let matcher = StockMatcher(products: products)
        let all = rows(matcher)
        let shops = all.filter { $0.customer.isShop }.sorted { $0.total > $1.total }
        let others = all.filter { !$0.customer.isShop }
        let active = others.filter { $0.count > 0 }.sorted { $0.total > $1.total }
        let idle = others.filter { $0.count == 0 }
        let shopsTotal = shops.reduce(0) { $0 + $1.total }
        let monthTotal = active.reduce(0) { $0 + $1.total } + shopsTotal

        NavigationStack {
            List {
                Section {
                    MonthSwitcher(monthStart: $monthStart)
                    Toggle("المجهّزة فقط", isOn: $preparedOnly)
                    HStack {
                        Text("إجمالي الشهر")
                        Spacer()
                        Text(Formatters.number(monthTotal, minFraction: 2))
                            .font(.headline)
                            .foregroundStyle(.indigo)
                    }
                } footer: {
                    Text("الفاتورة بتتحسب للعميل لما اسم العميل المكتوب فيها يطابق الاسم المحفوظ هنا.")
                }

                if !shops.isEmpty {
                    Section {
                        ForEach(shops) { row in link(row) }
                            .onDelete { delete(shops, at: $0) }
                    } header: {
                        Text("المحلات (\(shops.count))")
                    } footer: {
                        Text("إجمالي تحويلات المحلات في الشهر: \(Formatters.number(shopsTotal, minFraction: 2))")
                    }
                }

                if !active.isEmpty {
                    Section("عليهم فواتير في الشهر (\(active.count))") {
                        ForEach(active) { row in link(row) }
                            .onDelete { delete(active, at: $0) }
                    }
                }

                if !idle.isEmpty {
                    Section("من غير فواتير في الشهر ده") {
                        ForEach(idle) { row in link(row) }
                            .onDelete { delete(idle, at: $0) }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if customers.isEmpty {
                    ContentUnavailableView(
                        "لا يوجد عملاء",
                        systemImage: "person.2",
                        description: Text("اضغط على الزرار فوق وضيف أول عميل.")
                    )
                }
            }
            .searchable(text: $search, prompt: "ابحث باسم العميل")
            .navigationTitle("العملاء")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            newName = ""
                            newIsShop = false
                            showAdd = true
                        } label: {
                            Label("عميل جديد", systemImage: "person.badge.plus")
                        }
                        Button {
                            newName = ""
                            newIsShop = true
                            showAdd = true
                        } label: {
                            Label("محل جديد", systemImage: "storefront")
                        }
                    } label: {
                        Image(systemName: "person.badge.plus")
                    }
                }
            }
            .alert(newIsShop ? "محل جديد" : "عميل جديد", isPresented: $showAdd) {
                TextField(newIsShop ? "اسم المحل" : "اسم العميل", text: $newName)
                Button("إضافة") {
                    CustomerDirectory.ensureSaved(newName, isShop: newIsShop, in: modelContext)
                }
                Button("إلغاء", role: .cancel) {}
            }
        }
    }

    private func link(_ row: Row) -> some View {
        NavigationLink {
            CustomerDetailView(name: row.customer.name, initialMonth: monthStart, preparedOnly: preparedOnly)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        if row.customer.isShop {
                            Image(systemName: "storefront")
                                .font(.caption)
                                .foregroundStyle(.teal)
                        }
                        Text(row.customer.name)
                            .font(.subheadline.weight(.semibold))
                    }
                    Text(row.count == 0 ? "لا توجد فواتير" : "\(row.count) فاتورة")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if row.count > 0 {
                    Text(Formatters.number(row.total, minFraction: 2))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.indigo)
                }
            }
        }
    }

    private func delete(_ rows: [Row], at offsets: IndexSet) {
        for index in offsets { modelContext.delete(rows[index].customer) }
        try? modelContext.save()
    }
}

// MARK: - Customer detail (one month)

struct CustomerDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Customer.name) private var customers: [Customer]
    @Query private var invoices: [Invoice]
    @Query private var products: [Product]

    @State private var name: String
    @State private var monthStart: Date
    @State private var preparedOnly: Bool
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showTransfer = false
    @State private var transferMessage = ""
    @State private var showTransferMessage = false
    @State private var shareItem: ShareItem?

    init(name: String, initialMonth: Date, preparedOnly: Bool) {
        _name = State(initialValue: name)
        _monthStart = State(initialValue: initialMonth)
        _preparedOnly = State(initialValue: preparedOnly)
    }

    var body: some View {
        let matcher = StockMatcher(products: products)
        let list = CustomerDirectory.invoices(
            of: name.customerKey, in: monthStart, from: invoices, preparedOnly: preparedOnly
        )
        let totals = list.map { InvoiceTotals.saleTotal(of: $0, matcher: matcher) }
        let monthTotal = totals.reduce(0, +)
        let isShop = customers.first(where: { $0.name.customerKey == name.customerKey })?.isShop ?? false
        let lines = isShop ? ShopReport.lines(for: list, matcher: matcher) : []
        let costInfo = isShop ? ShopReport.ownerCost(for: list, matcher: matcher) : (cost: 0, missing: 0)

        List {
            Section {
                MonthSwitcher(monthStart: $monthStart)
                Toggle("المجهّزة فقط", isOn: $preparedOnly)
                HStack {
                    Text("عدد الفواتير")
                    Spacer()
                    Text("\(list.count)")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("إجمالي الشهر")
                        .font(.headline)
                    Spacer()
                    Text(Formatters.number(monthTotal, minFraction: 2))
                        .font(.title3.bold())
                        .foregroundStyle(.indigo)
                }
            }

            if isShop {
                Section {
                    Button {
                        showTransfer = true
                    } label: {
                        Label("تحويل بضاعة للمحل", systemImage: "shippingbox")
                    }
                    NavigationLink {
                        ShopMonthCloseView(
                            shopName: name,
                            monthStart: monthStart,
                            transfers: monthTotal,
                            ownerCost: costInfo.cost,
                            missingCost: costInfo.missing
                        )
                    } label: {
                        Label("ختام الشهر والربح", systemImage: "chart.line.uptrend.xyaxis")
                    }
                }

                Section {
                    if lines.isEmpty {
                        Text("مفيش أصناف اتحوّلت في الشهر ده")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(lines) { line in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.name)
                                    .font(.subheadline)
                                    .lineLimit(2)
                                Text("الكمية: \(Formatters.number(line.qty, maxFraction: 3))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Formatters.number(line.value, minFraction: 2))
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    if !lines.isEmpty {
                        Button {
                            exportReport(list: list, matcher: matcher)
                        } label: {
                            Label("تصدير تقرير الشهر (CSV)", systemImage: "square.and.arrow.up")
                        }
                    }
                } header: {
                    Text("أصناف الشهر")
                } footer: {
                    Text("قيمة الأصناف قبل الخصم والضريبة، وإجمالي الشهر فوق بعد الخصم والضريبة.")
                }
            }

            Section("الفواتير") {
                if list.isEmpty {
                    Text("مفيش فواتير للعميل ده في الشهر ده")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(list.enumerated()), id: \.element.persistentModelID) { index, invoice in
                    NavigationLink {
                        InvoiceDetailView(invoice: invoice)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(invoice.title)
                                    .font(.subheadline.weight(.semibold))
                                HStack(spacing: 6) {
                                    Text(Formatters.date(invoice.date, includeTime: false))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    StatusBadge(status: invoice.status)
                                }
                            }
                            Spacer()
                            Text(Formatters.number(totals[index], minFraction: 2))
                                .font(.subheadline.weight(.bold))
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        renameText = name
                        showRename = true
                    } label: {
                        Label("تعديل الاسم", systemImage: "pencil")
                    }
                    Button {
                        toggleShop()
                    } label: {
                        Label(isShop ? "تحويله لعميل عادي" : "اعتباره محل تابع ليا", systemImage: "storefront")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showTransfer) {
            StockInvoiceBuilderView(transferShop: name) { message in
                transferMessage = message
                showTransferMessage = true
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .alert(transferMessage, isPresented: $showTransferMessage) {
            Button("حسنًا", role: .cancel) {}
        }
        .alert("تعديل اسم العميل", isPresented: $showRename) {
            TextField("اسم العميل", text: $renameText)
            Button("حفظ") { rename() }
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text("الاسم الجديد هيتغيّر كمان في فواتير العميل ده.")
        }
    }

    private func toggleShop() {
        let key = name.customerKey
        for customer in customers where customer.name.customerKey == key {
            customer.isShop.toggle()
        }
        try? modelContext.save()
    }

    private func exportReport(list: [Invoice], matcher: StockMatcher) {
        let csv = ShopReport.csv(shop: name, monthStart: monthStart, invoices: list, matcher: matcher)
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safe)-\(MonthHelper.fileStamp(monthStart)).csv")
        do {
            // BOM عشان Excel يقرا العربي صح
            try Data([0xEF, 0xBB, 0xBF] + Array(csv.utf8)).write(to: url, options: .atomic)
            shareItem = ShareItem(url: url)
        } catch {
            transferMessage = "تعذّر إنشاء ملف التقرير."
            showTransferMessage = true
        }
    }

    private func rename() {
        let newName = renameText.trimmed
        guard !newName.isEmpty else { return }
        let oldKey = name.customerKey
        for invoice in invoices where !invoice.isSupply && invoice.supplier.customerKey == oldKey {
            invoice.supplier = newName
        }
        for customer in customers where customer.name.customerKey == oldKey {
            customer.name = newName
        }
        // سجلات ختام الشهر مربوطة باسم المحل، فننقلها للاسم الجديد
        let newKey = newName.customerKey
        for month in (try? modelContext.fetch(FetchDescriptor<ShopMonth>())) ?? [] where month.shopKey == oldKey {
            month.shopKey = newKey
        }
        for expense in (try? modelContext.fetch(FetchDescriptor<ShopExpense>())) ?? [] where expense.shopKey == oldKey {
            expense.shopKey = newKey
        }
        name = newName
        try? modelContext.save()
    }
}
