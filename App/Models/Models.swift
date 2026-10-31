import Foundation
import SwiftData
import SwiftUI

// MARK: - Settings keys

enum AppSettings {
    static let modelKey = "gemini_model"
    static let sheetsURLKey = "google_sheets_url"
    static let defaultModel = "gemini-3.8-flash"
    /// موديل خفيف وسريع يُستخدم لما تكون «القراءة بدقة أعلى» مقفولة (زي نسخة الويب).
    static let liteModel = "gemini-3.5-flash-lite"
    static let languageKey = "invoice_language"
    static let preciseKey = "invoice_precise"
    static let modelMigrationKey = "gemini_model_migrated_3_8"
    static let modelPresets: [String] = [
        "gemini-3.8-flash",
        "gemini-3.5-flash-lite",
        "gemini-2.5-flash",
        "gemini-2.5-pro"
    ]

    /// One-time migration: apps that saved an older model name switch to the new default.
    static func migrateModelIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: modelMigrationKey) else { return }
        defaults.set(defaultModel, forKey: modelKey)
        defaults.set(true, forKey: modelMigrationKey)
    }
}

/// لغة الفاتورة المتوقعة (تُرسل في البرومبت لتحسين القراءة).
enum InvoiceLanguage: String, CaseIterable, Identifiable {
    case both = "esen"
    case spanish = "es"
    case english = "en"
    case arabic = "ar"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .both: return "الإسبانية + الإنجليزية"
        case .spanish: return "الإسبانية"
        case .english: return "الإنجليزية"
        case .arabic: return "العربية"
        }
    }

    var promptName: String {
        switch self {
        case .both: return "Spanish and English (mixed)"
        case .spanish: return "Spanish"
        case .english: return "English"
        case .arabic: return "Arabic"
        }
    }
}

/// لغة ملف الفاتورة (PDF) اللي بيتصدّر.
enum PDFLanguage {
    case arabic
    case spanish

    var localeID: String { self == .arabic ? "ar@numbers=latn" : "es_ES" }
}

// MARK: - SwiftData Models

@Model
final class Invoice {
    var title: String
    var supplier: String
    var date: Date
    var totalAmount: Double
    var notes: String
    /// "new" | "preparing" | "done"
    var status: String = "new"
    /// اتضافت أصناف الفاتورة للمخزون قبل كده؟ (لمنع تكرار الإضافة)
    var addedToInventory: Bool = false
    /// "sale" (فاتورة بيع/طلب يتجهّز ويخصم من المخزون) | "supply" (فاتورة توريد تزوّد المخزون)
    var kind: String = "sale"
    /// "none" (من غير ضريبة) | "iva" (IVA 21% إسبانيا، الأسعار قبل الضريبة) | "exempt" (لا تخضع للضريبة)
    var taxMode: String = "none"
    /// نسبة خصم على إجمالي الفاتورة (0–100). بتتطبّق قبل الضريبة.
    var discountPercent: Double = 0
    /// معرّف ثابت للنسخة المحفوظة في الأرشيف
    var archiveID: String = ""
    @Attribute(.externalStorage) var imageData: Data?

    @Relationship(deleteRule: .cascade, inverse: \InvoiceItem.invoice)
    var items: [InvoiceItem] = []

    init(
        title: String,
        supplier: String = "",
        date: Date = Date(),
        totalAmount: Double = 0,
        notes: String = "",
        imageData: Data? = nil
    ) {
        self.title = title
        self.supplier = supplier
        self.date = date
        self.totalAmount = totalAmount
        self.notes = notes
        self.imageData = imageData
    }

    func recalculateTotal() {
        totalAmount = items.reduce(0) { $0 + $1.total }
    }
}

@Model
final class InvoiceItem {
    var name: String
    var code: String
    var qty: Double
    var unitPrice: Double
    var total: Double
    var sortIndex: Int
    var prepared: Bool = false
    /// الكمية اللي اتخصمت فعلًا من المخزون لما اتعلّم الصنف «جُهّز» (عشان نرجّعها لو اتلغى)
    var stockDeducted: Double = 0
    /// مفتاح الصنف في المخزون اللي اتطابق معاه الصنف ده (SKU أو الكود) لما الاسم يختلف عن الشيت
    var matchedKey: String = ""
    /// اقتراح محتاج تأكيد من المستخدم ("هل تقصد ...؟")
    var suggestedKey: String = ""
    /// اقتراح المستخدم رفضه، منقترحوش تاني
    var rejectedKey: String = ""
    /// المطابقة اتعملت تلقائيًا (مش بتأكيد يدوي)
    var matchAuto: Bool = false
    /// سعر بيع يدوي لهذا الصنف في هذه الفاتورة فقط (0 = استخدم سعر الشيت)
    var customPrice: Double = 0
    var invoice: Invoice?

    init(
        name: String,
        code: String = "",
        qty: Double = 1,
        unitPrice: Double = 0,
        total: Double = 0,
        sortIndex: Int = 0
    ) {
        self.name = name
        self.code = code
        self.qty = qty
        self.unitPrice = unitPrice
        self.total = total
        self.sortIndex = sortIndex
    }
}

/// ذاكرة المطابقة: اسم الصنف في الفاتورة (منظّف) ← صنف في الشيت. بتتحفظ لما المستخدم يؤكد.
@Model
final class ProductAlias {
    var nameKey: String = ""
    var productKey: String = ""

    init(nameKey: String, productKey: String) {
        self.nameKey = nameKey
        self.productKey = productKey
    }
}

/// سجل حركات المخزون: كل خصم/إرجاع/توريد/استيراد بيتسجّل هنا عشان تقدر تتتبّع أي كمية راحت فين.
@Model
final class StockMovement {
    var date: Date = Date()
    var productName: String = ""
    var productKey: String = ""
    /// موجب = زيادة، سالب = خصم
    var delta: Double = 0
    var reason: String = ""
    var invoiceTitle: String = ""
    var invoiceArchiveID: String = ""

    init(
        productName: String,
        productKey: String,
        delta: Double,
        reason: String,
        invoiceTitle: String = "",
        invoiceArchiveID: String = "",
        date: Date = Date()
    ) {
        self.productName = productName
        self.productKey = productKey
        self.delta = delta
        self.reason = reason
        self.invoiceTitle = invoiceTitle
        self.invoiceArchiveID = invoiceArchiveID
        self.date = date
    }
}

enum StockMovementReason {
    static let prepare = "prepare"
    static let restore = "restore"
    static let supply = "supply"
    static let replace = "replace"
    static let manual = "manual"

    static func title(_ reason: String) -> String {
        switch reason {
        case prepare: return "تجهيز (خصم)"
        case restore: return "إرجاع للمخزون"
        case supply: return "توريد / إضافة"
        case replace: return "استبدال الكمية (استيراد)"
        case manual: return "تعديل يدوي"
        default: return reason
        }
    }
}

extension StockMovement {
    /// بيسجّل حركة لصنف موجود في قاعدة البيانات (لو مفيش context مبيعملش حاجة).
    static func log(product: Product, delta: Double, reason: String, invoice: Invoice? = nil) {
        guard delta != 0, let context = product.modelContext else { return }
        context.insert(StockMovement(
            productName: product.name,
            productKey: product.matchKey,
            delta: delta,
            reason: reason,
            invoiceTitle: invoice?.title ?? "",
            invoiceArchiveID: invoice?.archiveID ?? ""
        ))
    }
}

@Model
final class Product {
    var name: String
    var code: String
    var qty: Double
    var price: Double
    var sku: String = ""
    var cost: Double = 0
    var imageURL: String = ""
    /// آخر كمية معروفة في الشيت. بنحسب منها «الفرق» وقت الرفع، عشان لو جهازين خصموا في نفس الوقت الاتنين يتسجّلوا (مش آخر واحد بس).
    var sheetQty: Double = 0
    /// false = لسه منعرفش كمية الشيت (بعد التحديث مثلًا)، فالرفع بيبقى بالكمية المطلقة زي الأول.
    var sheetQtyKnown: Bool = false
    var createdAt: Date
    var updatedAt: Date

    init(
        name: String,
        code: String = "",
        qty: Double = 0,
        price: Double = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.name = name
        self.code = code
        self.qty = qty
        self.price = price
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Automatic SKU

/// يولّد SKU على نفس نمط الشيت: 3 حروف من اسم المنتج + رقم من خانتين (مثلًا HAO01، HAO02).
enum SKUGenerator {
    private static let skipWords: Set<String> = ["al", "el", "the", "de", "la", "le", "of", "and", "eau", "parfum", "perfume"]

    static func prefix(for name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        let words = folded
            .split(whereSeparator: { !($0.isASCII && $0.isLetter) })
            .map { String($0).uppercased() }
        let significant = words.filter { !skipWords.contains($0.lowercased()) }
        let source = significant.isEmpty ? words : significant
        guard let first = source.first else { return "PRD" }
        var letters = String(first.prefix(3))
        if letters.count < 3, source.count > 1 {
            letters += String(source[1].prefix(3 - letters.count))
        }
        while letters.count < 3 { letters += "X" }
        return letters
    }

    /// أول SKU فاضي بنفس البادئة (مبيكررش SKU موجود).
    static func next(forName name: String, existing: [String]) -> String {
        let base = prefix(for: name)
        let used = Set(existing.map { $0.codeKey })
        var number = 1
        while true {
            let candidate = base + (number < 100 ? String(format: "%02d", number) : String(number))
            if !used.contains(candidate.codeKey) { return candidate }
            number += 1
        }
    }
}

// MARK: - Inventory merge service

struct InventoryEntry {
    var name: String
    var code: String
    var qty: Double
    var price: Double      // سعر البيع
    var cost: Double = 0   // سعر الشراء / التكلفة
    var sku: String = ""
    /// false لو خانة الكمية في الملف فاضية أو نص (زي "Sin dato") فمنلمسش كمية المنتج
    var hasQty: Bool = true
}

enum InventoryMergeMode {
    case addQuantity
    case replaceQuantity
}

struct InventoryMergeResult {
    var added: Int = 0
    var updated: Int = 0
}

enum InventoryService {
    @discardableResult
    static func merge(
        _ entries: [InventoryEntry],
        mode: InventoryMergeMode,
        in context: ModelContext
    ) -> InventoryMergeResult {
        let existing = (try? context.fetch(FetchDescriptor<Product>())) ?? []
        var index = ProductIndex(products: existing)

        var result = InventoryMergeResult()

        for entry in entries {
            let name = entry.name.trimmed
            let code = entry.code.trimmed
            if name.isEmpty && code.isEmpty && entry.sku.trimmed.isEmpty { continue }

            let match = index.find(sku: entry.sku, code: code, name: name)

            if let product = match {
                switch mode {
                case .addQuantity:
                    StockMovement.log(product: product, delta: entry.qty, reason: StockMovementReason.supply)
                    product.qty += entry.qty
                case .replaceQuantity:
                    if entry.hasQty {
                        StockMovement.log(product: product, delta: entry.qty - product.qty, reason: StockMovementReason.replace)
                        product.qty = entry.qty
                    }
                }
                if entry.price > 0 {
                    product.price = entry.price
                }
                if entry.cost > 0 {
                    product.cost = entry.cost
                }
                if !name.isEmpty {
                    product.name = name
                }
                if product.code.trimmed.isEmpty && !code.isEmpty {
                    product.code = code
                }
                if product.sku.trimmed.isEmpty && !entry.sku.trimmed.isEmpty {
                    product.sku = entry.sku.trimmed
                }
                product.updatedAt = Date()
                index.add(product)
                result.updated += 1
            } else {
                let product = Product(
                    name: name.isEmpty ? (code.isEmpty ? entry.sku.trimmed : code) : name,
                    code: code,
                    qty: entry.hasQty ? entry.qty : 0,
                    price: entry.price
                )
                product.cost = entry.cost
                product.sku = entry.sku.trimmed
                context.insert(product)
                index.add(product)
                result.added += 1
            }
        }

        try? context.save()
        if result.added + result.updated > 0 {
            AutoSync.request(context)
        }
        return result
    }
}

// MARK: - Formatting & parsing helpers

enum Formatters {
    // إنشاء NumberFormatter/DateFormatter مكلف، وكان بيتعمل من جديد لكل صف في كل رسم للشاشة.
    // بنخزّن النسخ ونعيد استخدامها (والقفل عشان الاستدعاء من أكتر من thread).
    private static let cacheLock = NSLock()
    private static var numberFormatters: [String: NumberFormatter] = [:]
    private static var dateFormatters: [String: DateFormatter] = [:]

    static func number(
        _ value: Double,
        minFraction: Int = 0,
        maxFraction: Int = 2,
        grouping: Bool = true
    ) -> String {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let key = "\(minFraction)|\(maxFraction)|\(grouping)"
        let formatter: NumberFormatter
        if let cached = numberFormatters[key] {
            formatter = cached
        } else {
            let created = NumberFormatter()
            created.locale = Locale(identifier: "en_US")
            created.numberStyle = .decimal
            created.usesGroupingSeparator = grouping
            created.minimumFractionDigits = minFraction
            created.maximumFractionDigits = max(minFraction, maxFraction)
            numberFormatters[key] = created
            formatter = created
        }
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func date(_ date: Date, includeTime: Bool = true, localeID: String = "ar@numbers=latn") -> String {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let key = "\(localeID)|\(includeTime)"
        let formatter: DateFormatter
        if let cached = dateFormatters[key] {
            formatter = cached
        } else {
            let created = DateFormatter()
            created.locale = Locale(identifier: localeID)
            created.dateStyle = .medium
            created.timeStyle = includeTime ? .short : .none
            dateFormatters[key] = created
            formatter = created
        }
        return formatter.string(from: date)
    }
}

extension String {
    /// Extracts the first usable image URL from a sheet cell (handles =IMAGE("..."),
    /// several links separated by comma/space/newline, protocol-relative links and Drive share links).
    var firstImageURL: URL? {
        var text = trimmed
        if text.isEmpty { return nil }
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        if let range = text.range(of: #"https?://[^\s,;"'<>)\\]+"#, options: .regularExpression) {
            text = String(text[range])
        } else if let range = text.range(of: #"//[^\s,;"'<>)\\]+"#, options: .regularExpression) {
            text = "https:" + String(text[range])
        } else {
            return nil
        }
        // Google Drive share links -> direct view links
        if let match = text.range(of: #"drive\.google\.com/file/d/([^/?]+)"#, options: .regularExpression) {
            let id = text[match].replacingOccurrences(of: "drive.google.com/file/d/", with: "")
            text = "https://drive.google.com/uc?export=view&id=\(id)"
        }
        if let url = URL(string: text) { return url }
        if let encoded = text.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed.union(CharacterSet(charactersIn: "%"))) {
            return URL(string: encoded)
        }
        return nil
    }

    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Converts Arabic-Indic and Persian digits to Western digits and normalizes separators.
    var normalizedDigits: String {
        var output = ""
        for scalar in unicodeScalars {
            switch scalar.value {
            case 0x0660...0x0669:
                if let converted = UnicodeScalar(scalar.value - 0x0660 + 48) {
                    output.unicodeScalars.append(converted)
                }
            case 0x06F0...0x06F9:
                if let converted = UnicodeScalar(scalar.value - 0x06F0 + 48) {
                    output.unicodeScalars.append(converted)
                }
            case 0x066B:
                output.append(".")
            case 0x066C, 0x060C:
                break
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        return output
    }

    /// Key used to compare product codes.
    var codeKey: String {
        normalizedDigits.trimmed.lowercased()
    }

    /// Lenient numeric parsing: Arabic digits, "1,234.50", "1.234,50" and "21,5".
    var parsedDouble: Double? {
        var cleaned = ""
        for character in normalizedDigits {
            if character.isASCII && (character.isNumber || character == "." || character == "," || character == "-") {
                cleaned.append(character)
            }
        }
        if cleaned.isEmpty { return nil }

        let lastDot = cleaned.lastIndex(of: ".")
        let lastComma = cleaned.lastIndex(of: ",")
        let dotCount = cleaned.filter { $0 == "." }.count
        let commaCount = cleaned.filter { $0 == "," }.count

        if let dot = lastDot, let comma = lastComma {
            if comma > dot {
                cleaned = cleaned.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else {
                cleaned = cleaned.replacingOccurrences(of: ",", with: "")
            }
        } else if let comma = lastComma {
            let digitsAfter = cleaned.distance(from: comma, to: cleaned.endIndex) - 1
            let integerPart = String(cleaned[cleaned.startIndex..<comma])
            if commaCount == 1 && (digitsAfter != 3 || integerPart == "0") {
                cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
            } else {
                cleaned = cleaned.replacingOccurrences(of: ",", with: "")
            }
        } else if dotCount > 1 {
            cleaned = cleaned.replacingOccurrences(of: ".", with: "")
        }
        return Double(cleaned)
    }
}


// MARK: - Invoice kind

enum InvoiceKind {
    static let sale = "sale"
    static let supply = "supply"
}

extension Invoice {
    var isSupply: Bool { kind == InvoiceKind.supply }
}

enum TaxMode {
    static let none = "none"
    static let iva = "iva"
    static let exempt = "exempt"
    /// ضريبة القيمة المضافة في إسبانيا (IVA)
    static let ivaRate = 0.21

    static func tax(_ base: Double, mode: String) -> Double {
        guard mode == iva else { return 0 }
        return (base * ivaRate * 100).rounded() / 100
    }
}

// MARK: - Invoice totals (discount + tax)

/// حسابات إجمالي الفاتورة: الخصم الأول، وبعدين الضريبة. نفس الترتيب في التطبيق والـ PDF والأرشيف.
enum InvoiceTotals {
    static func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    static func clamp(_ percent: Double) -> Double { min(max(percent, 0), 100) }

    static func discountAmount(base: Double, percent: Double) -> Double {
        round2(base * clamp(percent) / 100)
    }

    /// الإجمالي بعد الخصم وقبل الضريبة
    static func net(base: Double, percent: Double) -> Double {
        base - discountAmount(base: base, percent: percent)
    }

    static func tax(base: Double, percent: Double, mode: String) -> Double {
        TaxMode.tax(net(base: base, percent: percent), mode: mode)
    }

    /// الإجمالي النهائي (بعد الخصم وبعد الضريبة)
    static func finalTotal(base: Double, percent: Double, mode: String) -> Double {
        let netValue = net(base: base, percent: percent)
        return netValue + TaxMode.tax(netValue, mode: mode)
    }

    /// نسبة الخصم اللازمة عشان الإجمالي النهائي (شامل الضريبة) يبقى targetTotal.
    /// مبتزوّدش السعر: لو الهدف أكبر من الإجمالي الحالي بترجّع 0.
    static func percent(forFinalTotal target: Double, base: Double, mode: String) -> Double {
        guard base > 0 else { return 0 }
        let netNeeded = (mode == TaxMode.iva) ? target / (1 + TaxMode.ivaRate) : target
        return clamp((1 - netNeeded / base) * 100)
    }
}

// MARK: - Stock deduction on preparation

extension InventoryService {
    /// يخصم كمية الصنف من المخزون (بحد أقصى الموجود، ومبينزلش عن صفر) ويسجّل المخصوم.
    static func deduct(_ item: InvoiceItem, products: [Product]) {
        guard item.stockDeducted == 0 else { return }
        guard let product = StockMatcher(products: products).info(for: item).product else { return }
        let amount = min(max(product.qty, 0), max(item.qty, 0))
        guard amount > 0 else { return }
        product.qty -= amount
        product.updatedAt = Date()
        item.stockDeducted = amount
        StockMovement.log(product: product, delta: -amount, reason: StockMovementReason.prepare, invoice: item.invoice)
        if let context = product.modelContext { AutoSync.request(context) }
    }

    /// يرجّع للمخزون اللي اتخصم قبل كده لنفس الصنف.
    static func restore(_ item: InvoiceItem, products: [Product]) {
        guard item.stockDeducted > 0 else { return }
        if let product = StockMatcher(products: products).info(for: item).product {
            product.qty += item.stockDeducted
            product.updatedAt = Date()
            StockMovement.log(product: product, delta: item.stockDeducted, reason: StockMovementReason.restore, invoice: item.invoice)
            if let context = product.modelContext { AutoSync.request(context) }
        }
        item.stockDeducted = 0
    }
}

// MARK: - Invoice status

enum InvoiceStatus {
    static let new = "new"
    static let preparing = "preparing"
    static let done = "done"
}

extension Notification.Name {
    static let goToPreparationTab = Notification.Name("goToPreparationTab")
    static let goToPreparedTab = Notification.Name("goToPreparedTab")
}

extension Product {
    /// مفتاح ثابت للصنف: الـ SKU لو موجود وإلا الكود
    var matchKey: String {
        let k = sku.codeKey
        return k.isEmpty ? code.codeKey : k
    }
}

// MARK: - Stock matching

enum StockState {
    case available      // الموجود يكفي
    case partial        // موجود لكن أقل من المطلوب
    case out            // معروف في المخزون لكن الكمية 0
    case notFound       // مش موجود في المخزون
}

struct StockInfo {
    var product: Product?
    var state: StockState
    var stock: Double
    var missing: Double

    var isFullyAvailable: Bool { state == .available }
}

/// فهرس للمنتجات: الـ SKU أولًا (لأنه فريد)، بعدين الباركود، بعدين الاسم.
/// منتجين ممكن يشتركوا في نفس الباركود، فمنعتبرهمش نفس المنتج لو الـ SKU مختلف.
struct ProductIndex {
    private var bySKU: [String: Product] = [:]
    private var byCode: [String: Product] = [:]
    private var byName: [String: Product] = [:]
    private var byKey: [String: Product] = [:]

    func product(matchKey key: String) -> Product? {
        let k = key.codeKey
        return k.isEmpty ? nil : byKey[k]
    }

    init(products: [Product]) {
        for product in products { add(product) }
    }

    mutating func add(_ product: Product) {
        let mk = product.matchKey
        if !mk.isEmpty && byKey[mk] == nil { byKey[mk] = product }
        let sku = product.sku.codeKey
        if !sku.isEmpty { bySKU[sku] = product }
        let code = product.code.codeKey
        if !code.isEmpty && byCode[code] == nil { byCode[code] = product }
        let name = product.name.trimmed.lowercased()
        if !name.isEmpty && byName[name] == nil { byName[name] = product }
    }

    func find(sku: String, code: String, name: String) -> Product? {
        let skuKey = sku.codeKey
        let codeKey = code.codeKey
        let nameKey = name.trimmed.lowercased()

        func compatible(_ product: Product) -> Bool {
            let other = product.sku.codeKey
            return skuKey.isEmpty || other.isEmpty || other == skuKey
        }

        if !skuKey.isEmpty, let product = bySKU[skuKey] { return product }
        if !codeKey.isEmpty, let product = byCode[codeKey], compatible(product) { return product }
        // أحيانًا الكود اللي في الفاتورة هو الـ SKU نفسه
        if !codeKey.isEmpty, let product = bySKU[codeKey] { return product }
        if !nameKey.isEmpty, let product = byName[nameKey], compatible(product) { return product }
        return nil
    }
}

struct StockMatcher {
    private let index: ProductIndex

    init(products: [Product]) {
        index = ProductIndex(products: products)
    }

    /// سعر البيع من المخزون بنفس طريقة مطابقة الصنف (باركود، SKU، ثم الاسم)
    func salePrice(for item: InvoiceItem) -> Double? {
        if item.customPrice > 0 { return item.customPrice }
        guard let price = info(for: item).product?.price, price > 0 else { return nil }
        return price
    }

    func info(for item: InvoiceItem) -> StockInfo {
        // مطابقة اتأكدت (أو اتعملت تلقائيًا) بحيث الاسم يختلف عن الشيت
        let match = index.product(matchKey: item.matchedKey)
            ?? index.find(sku: "", code: item.code, name: item.name)
        guard let product = match else {
            return StockInfo(product: nil, state: .notFound, stock: 0, missing: item.qty)
        }
        let stock = max(product.qty, 0)
        if stock >= item.qty {
            return StockInfo(product: product, state: .available, stock: stock, missing: 0)
        }
        return StockInfo(
            product: product,
            state: stock > 0 ? .partial : .out,
            stock: stock,
            missing: item.qty - stock
        )
    }
}

/// صف يعرض حالة المخزون تحت الصنف
struct StockBadge: View {
    let info: StockInfo

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var text: String {
        switch info.state {
        case .available:
            return "الموجود: \(Formatters.number(info.stock, maxFraction: 3))"
        case .partial:
            return "الموجود: \(Formatters.number(info.stock, maxFraction: 3)) — ناقص \(Formatters.number(info.missing, maxFraction: 3))"
        case .out:
            return "الموجود: 0 — ناقص \(Formatters.number(info.missing, maxFraction: 3))"
        case .notFound:
            return "غير موجود في المخزون"
        }
    }

    private var icon: String {
        switch info.state {
        case .available: return "checkmark.circle.fill"
        case .partial: return "exclamationmark.circle.fill"
        case .out, .notFound: return "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch info.state {
        case .available: return .green
        case .partial: return .orange
        case .out, .notFound: return .red
        }
    }
}


// MARK: - Stock value

/// قيمة المخزون: بالتكلفة (سعر الشراء) وبسعر البيع. الكميات السالبة بتتعامل كصفر.
struct StockValue: Equatable {
    var atCost: Double = 0
    var atPrice: Double = 0
    /// أصناف فيها كمية بس مالهاش تكلفة مسجّلة (قيمتها بالتكلفة صفر)
    var missingCost: Int = 0

    /// الربح المتوقع لو اتباع كل المخزون. بيحسب بس الأصناف اللي ليها تكلفة، عشان صنف من غير تكلفة مبيبانش كله ربح.
    var expectedProfit: Double { atPricedWithCost - atCost }

    private var atPricedWithCost: Double = 0

    init(products: [Product]) {
        for product in products {
            let qty = max(product.qty, 0)
            guard qty > 0 else { continue }
            atPrice += qty * product.price
            if product.cost > 0 {
                atCost += qty * product.cost
                atPricedWithCost += qty * product.price
            } else {
                missingCost += 1
            }
        }
    }
}
