import SwiftUI
import SwiftData

/// الوضع التجريبي: بيانات وهمية في قاعدة بيانات مؤقتة (في الذاكرة بس). مفيش لمس لبياناتك الحقيقية،
/// ومفيش مزامنة مع الشيت، وكل حاجة بتتمسح لما تقفل التطبيق أو تدخل الوضع التجريبي من جديد.
enum DemoMode {
    static let key = "demo_mode"

    /// حراسة على مستوى الشبكة: مفيش أي اتصال بالشيت في الوضع التجريبي.
    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }
}

enum DemoData {
    private struct Sample {
        let name: String
        let sku: String
        let code: String
        let qty: Double
        let price: Double
        let cost: Double
    }

    private static let samples: [Sample] = [
        Sample(name: "شامبو لافندر 400 مل", sku: "SHA01", code: "8400000000011", qty: 48, price: 6.50, cost: 3.80),
        Sample(name: "شامبو أرجان 400 مل", sku: "SHA02", code: "8400000000028", qty: 36, price: 7.20, cost: 4.10),
        Sample(name: "بلسم شعر كيراتين 300 مل", sku: "BAL01", code: "8400000000035", qty: 30, price: 8.90, cost: 5.20),
        Sample(name: "صابون سائل ليمون 500 مل", sku: "SOA01", code: "8400000000042", qty: 60, price: 3.40, cost: 1.90),
        Sample(name: "صابون سائل ورد 500 مل", sku: "SOA02", code: "8400000000059", qty: 55, price: 3.40, cost: 1.90),
        Sample(name: "كريم ترطيب يدين 100 مل", sku: "CRE01", code: "8400000000066", qty: 40, price: 4.80, cost: 2.60),
        Sample(name: "كريم وجه نهاري SPF30", sku: "CRE02", code: "8400000000073", qty: 25, price: 12.50, cost: 7.40),
        Sample(name: "كريم وجه ليلي 50 مل", sku: "CRE03", code: "8400000000080", qty: 22, price: 13.90, cost: 8.10),
        Sample(name: "غسول وجه بالخيار 200 مل", sku: "WAS01", code: "8400000000097", qty: 34, price: 5.60, cost: 3.00),
        Sample(name: "مزيل عرق رول أون", sku: "DEO01", code: "8400000000103", qty: 70, price: 2.90, cost: 1.50),
        Sample(name: "معجون أسنان تبييض 100 مل", sku: "TOO01", code: "8400000000110", qty: 90, price: 2.40, cost: 1.20),
        Sample(name: "فرشاة أسنان متوسطة", sku: "TOO02", code: "8400000000127", qty: 120, price: 1.80, cost: 0.80),
        Sample(name: "منظف أرضيات 1 لتر", sku: "CLE01", code: "8400000000134", qty: 44, price: 3.10, cost: 1.70),
        Sample(name: "منظف زجاج بخاخ 750 مل", sku: "CLE02", code: "8400000000141", qty: 38, price: 2.95, cost: 1.60),
        Sample(name: "سائل جلي ليمون 750 مل", sku: "DIS01", code: "8400000000158", qty: 66, price: 2.60, cost: 1.30),
        Sample(name: "مناديل مبللة 80 قطعة", sku: "WIP01", code: "8400000000165", qty: 100, price: 1.95, cost: 0.95),
        Sample(name: "مناديل ورقية 6 علب", sku: "TIS01", code: "8400000000172", qty: 52, price: 4.20, cost: 2.50),
        Sample(name: "معطر جو لافندر 300 مل", sku: "AIR01", code: "8400000000189", qty: 33, price: 3.75, cost: 2.00),
        Sample(name: "زيت جسم لوز 250 مل", sku: "OIL01", code: "8400000000196", qty: 18, price: 9.80, cost: 5.50),
        Sample(name: "ماسك شعر زيت جوز الهند", sku: "MAS01", code: "8400000000202", qty: 26, price: 6.30, cost: 3.40),
        Sample(name: "عطر نسائي 50 مل", sku: "PER01", code: "8400000000219", qty: 14, price: 19.90, cost: 11.00),
        Sample(name: "عطر رجالي 50 مل", sku: "PER02", code: "8400000000226", qty: 12, price: 21.50, cost: 12.20),
        Sample(name: "واقي شمس SPF50 200 مل", sku: "SUN01", code: "8400000000233", qty: 20, price: 11.40, cost: 6.60),
        Sample(name: "ملمع شفاه بالفانيليا", sku: "LIP01", code: "8400000000240", qty: 75, price: 2.20, cost: 0.90)
    ]

    /// قاعدة بيانات في الذاكرة فيها بيانات وهمية.
    static func makeContainer(schema: Schema) -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        guard let container = try? ModelContainer(for: schema, configurations: [configuration]) else {
            fatalError("Could not create demo ModelContainer")
        }
        populate(ModelContext(container))
        return container
    }

    private static func populate(_ context: ModelContext) {
        // المنتجات
        var byName: [String: Product] = [:]
        for sample in samples {
            let product = Product(name: sample.name, code: sample.code, qty: sample.qty, price: sample.price)
            product.sku = sample.sku
            product.cost = sample.cost
            context.insert(product)
            byName[sample.name] = product
        }

        // العملاء والمحلات
        let shopA = "محل الورد"
        let shopB = "محل النخيل"
        context.insert(Customer(name: shopA, isShop: true))
        context.insert(Customer(name: shopB, isShop: true))
        context.insert(Customer(name: "مكتب الأمل"))
        context.insert(Customer(name: "سوبر ماركت السلام"))

        let calendar = Calendar.current
        let now = Date()
        let thisMonth = MonthHelper.start(of: now)
        let lastMonth = MonthHelper.shift(thisMonth, by: -1)

        /// تاريخ داخل الشهر (بعد بداية الشهر بـ offset يوم)، ومش في المستقبل.
        func date(_ monthStart: Date, plusDays offset: Int) -> Date {
            min(calendar.date(byAdding: .day, value: offset, to: monthStart) ?? monthStart, now)
        }

        func addInvoice(
            title: String, customer: String, date: Date, status: String,
            lines: [(String, Double)], transfer: Bool
        ) {
            let invoice = Invoice(title: title, supplier: customer, date: date)
            invoice.kind = InvoiceKind.sale
            invoice.taxMode = TaxMode.none
            invoice.status = status
            invoice.archiveID = UUID().uuidString
            context.insert(invoice)
            for (index, line) in lines.enumerated() {
                guard let product = byName[line.0] else { continue }
                let qty = line.1
                let item = InvoiceItem(
                    name: product.name,
                    code: product.sku,
                    qty: qty,
                    unitPrice: product.price,
                    total: qty * product.price,
                    sortIndex: index
                )
                item.matchedKey = product.matchKey
                if transfer { item.customPrice = product.price }
                if status == InvoiceStatus.done {
                    item.prepared = true
                    item.stockDeducted = qty
                }
                context.insert(item)
                item.invoice = invoice
            }
            invoice.recalculateTotal()
        }

        // تحويلات المحلات: الشهر اللي فات والشهر ده
        addInvoice(title: "TRF-DEMO-001", customer: shopA, date: date(lastMonth, plusDays: 4), status: InvoiceStatus.done, lines: [
            ("شامبو لافندر 400 مل", 12), ("صابون سائل ليمون 500 مل", 20), ("مزيل عرق رول أون", 24), ("معجون أسنان تبييض 100 مل", 30)
        ], transfer: true)
        addInvoice(title: "TRF-DEMO-002", customer: shopB, date: date(lastMonth, plusDays: 9), status: InvoiceStatus.done, lines: [
            ("كريم ترطيب يدين 100 مل", 15), ("غسول وجه بالخيار 200 مل", 10), ("مناديل مبللة 80 قطعة", 40)
        ], transfer: true)
        addInvoice(title: "TRF-DEMO-003", customer: shopA, date: date(thisMonth, plusDays: 2), status: InvoiceStatus.done, lines: [
            ("شامبو أرجان 400 مل", 10), ("بلسم شعر كيراتين 300 مل", 8), ("سائل جلي ليمون 750 مل", 18), ("فرشاة أسنان متوسطة", 40)
        ], transfer: true)
        addInvoice(title: "TRF-DEMO-004", customer: shopB, date: date(thisMonth, plusDays: 5), status: InvoiceStatus.done, lines: [
            ("كريم وجه نهاري SPF30", 6), ("واقي شمس SPF50 200 مل", 6), ("ملمع شفاه بالفانيليا", 30), ("عطر نسائي 50 مل", 4)
        ], transfer: true)
        addInvoice(title: "TRF-DEMO-005", customer: shopA, date: date(thisMonth, plusDays: 9), status: InvoiceStatus.done, lines: [
            ("صابون سائل ورد 500 مل", 16), ("معطر جو لافندر 300 مل", 10), ("مناديل ورقية 6 علب", 12)
        ], transfer: true)

        // فواتير بيع لعملاء عاديين (واحدة جديدة لسه متجهّزتش)
        addInvoice(title: "INV-DEMO-101", customer: "مكتب الأمل", date: date(thisMonth, plusDays: 3), status: InvoiceStatus.done, lines: [
            ("مناديل ورقية 6 علب", 10), ("منظف أرضيات 1 لتر", 6)
        ], transfer: false)
        addInvoice(title: "INV-DEMO-102", customer: "سوبر ماركت السلام", date: date(thisMonth, plusDays: 7), status: InvoiceStatus.new, lines: [
            ("منظف زجاج بخاخ 750 مل", 12), ("سائل جلي ليمون 750 مل", 24), ("شامبو لافندر 400 مل", 6)
        ], transfer: false)

        // فاتورة توريد
        let supply = Invoice(title: "SUP-DEMO-001", supplier: "مورد تجريبي", date: date(thisMonth, plusDays: 1))
        supply.kind = InvoiceKind.supply
        supply.status = InvoiceStatus.done
        supply.archiveID = UUID().uuidString
        context.insert(supply)
        let supplyItem = InvoiceItem(name: "شامبو لافندر 400 مل", code: "SHA01", qty: 24, unitPrice: 3.80, total: 24 * 3.80, sortIndex: 0)
        context.insert(supplyItem)
        supplyItem.invoice = supply
        supply.recalculateTotal()

        // ختام الشهر الماضي لمحل الورد (مبيعات ومصاريف) كمثال
        let lastKey = MonthHelper.fileStamp(lastMonth)
        context.insert(ShopMonth(shopKey: shopA.customerKey, monthKey: lastKey, sales: 520))
        context.insert(ShopExpense(shopKey: shopA.customerKey, monthKey: lastKey, title: "إيجار", amount: 150))
        context.insert(ShopExpense(shopKey: shopA.customerKey, monthKey: lastKey, title: "راتب عامل", amount: 120))
        context.insert(ShopMonth(shopKey: shopB.customerKey, monthKey: lastKey, sales: 310))
        context.insert(ShopExpense(shopKey: shopB.customerKey, monthKey: lastKey, title: "إيجار", amount: 100))

        try? context.save()
    }
}

/// شريط تنبيه فوق التطبيق في الوضع التجريبي.
struct DemoBanner: View {
    @AppStorage(DemoMode.key) private var demoOn = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "flask.fill")
            Text("وضع تجريبي: بيانات وهمية ومفيش مزامنة")
                .font(.caption.weight(.semibold))
            Spacer()
            Button("خروج") { demoOn = false }
                .font(.caption.weight(.bold))
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.25))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .foregroundStyle(.white)
        .background(Color.orange)
    }
}
