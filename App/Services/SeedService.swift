import Foundation
import SwiftData

/// تجهيز التطبيق من أول تشغيل. كل حاجة هنا اختيارية: لو الملفات مش موجودة جوه التطبيق مفيش حاجة بتحصل.
///  - Seed/SeedInventory.json : المخزون الجاهز (الاسم، الباركود، SKU، الكمية، السعر، التكلفة، رابط الصورة)
///  - Seed/SeedInventory.xlsx : بديل: ملف Excel بنفس صيغة «استيراد من Excel»
///  - Seed/SeedConfig.json    : {"sheetURL": "...", "sheetPassword": "..."} لضبط مزامنة الشيت
enum SeedService {
    static let doneKey = "seed_done_v2"

    private struct Config: Decodable {
        var sheetURL: String?
        var sheetPassword: String?
    }

    /// كل الحقول اختيارية: صف ناقص حقل مبيفشّلش قراءة الملف كله.
    private struct SeedProduct: Decodable {
        var name = ""
        var code = ""
        var sku = ""
        var qty = 0.0
        var price = 0.0
        var cost = 0.0
        var image = ""

        enum CodingKeys: String, CodingKey { case name, code, sku, qty, price, cost, image }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func text(_ key: CodingKeys) -> String {
                if let s = try? c.decodeIfPresent(String.self, forKey: key) { return s }
                if let n = try? c.decodeIfPresent(Double.self, forKey: key) { return Formatters.number(n, maxFraction: 0, grouping: false) }
                return ""
            }
            func number(_ key: CodingKeys) -> Double {
                if let n = try? c.decodeIfPresent(Double.self, forKey: key) { return n }
                if let s = try? c.decodeIfPresent(String.self, forKey: key) { return s.parsedDouble ?? 0 }
                return 0
            }
            name = text(.name); code = text(.code); sku = text(.sku); image = text(.image)
            qty = number(.qty); price = number(.price); cost = number(.cost)
        }
    }

    private static func bundleURL(_ name: String, _ ext: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext)
            ?? Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Seed")
    }

    @MainActor
    static func runIfNeeded(in context: ModelContext) async {
        // الوضع التجريبي: مفيش بيانات حقيقية ولا إعدادات شيت
        guard !DemoMode.isOn else { return }
        let defaults = UserDefaults.standard

        // 1) إعدادات الشيت: بتملأ الخانات الفاضية بس (مبتمسحش اللي المستخدم كتبه)
        var sheetURL = (defaults.string(forKey: SheetSyncService.urlKey) ?? "").trimmed
        var sheetPassword = KeychainHelper.read(account: SheetSyncService.passwordAccount) ?? ""
        if let configURL = bundleURL("SeedConfig", "json"),
           let data = try? Data(contentsOf: configURL),
           let config = try? JSONDecoder().decode(Config.self, from: data) {
            let url = (config.sheetURL ?? "").trimmed
            let password = config.sheetPassword ?? ""
            if sheetURL.isEmpty && !url.isEmpty {
                defaults.set(url, forKey: SheetSyncService.urlKey)
                sheetURL = url
            }
            if sheetPassword.isEmpty && !password.isEmpty {
                KeychainHelper.save(password, account: SheetSyncService.passwordAccount)
                sheetPassword = password
            }
        }

        // 2) المخزون الجاهز: مرة واحدة، وبس لو المخزون فاضي
        guard !defaults.bool(forKey: doneKey) else { return }
        let jsonURL = bundleURL("SeedInventory", "json")
        let xlsxURL = bundleURL("SeedInventory", "xlsx")
        if jsonURL == nil && xlsxURL == nil { return }

        let existingProducts = (try? context.fetch(FetchDescriptor<Product>())) ?? []
        let isFresh = existingProducts.isEmpty
        var seeded = false

        if let jsonURL,
           let data = try? Data(contentsOf: jsonURL),
           let items = try? JSONDecoder().decode([SeedProduct].self, from: data) {
            // إضافة الناقص فقط (بالـ SKU أولًا). لو التطبيق متسطّب قبل كده بنضيف المنتجات الناقصة من غير ما نلمس الموجود.
            var index = ProductIndex(products: existingProducts)
            for item in items {
                if index.find(sku: item.sku, code: item.code, name: "") != nil { continue }
                let fallbackName = item.code.isEmpty ? item.sku : item.code
                let product = Product(
                    name: item.name.isEmpty ? fallbackName : item.name,
                    code: item.code,
                    qty: item.qty,
                    price: item.price
                )
                if !isFresh {
                    // منتج ناقص اتضاف متأخر: ما نعتبروش تعديل محلي عشان المزامنة تسحب كميته من الشيت
                    product.createdAt = Date.distantPast
                    product.updatedAt = Date.distantPast
                }
                product.sku = item.sku
                product.cost = item.cost
                product.imageURL = item.image
                context.insert(product)
                index.add(product)
            }
            try? context.save()
            seeded = true
        } else if isFresh,
                  let xlsxURL,
                  let data = try? Data(contentsOf: xlsxURL),
                  let entries = try? XLSXService.readEntries(from: data) {
            InventoryService.merge(entries, mode: .replaceQuantity, in: context)
            seeded = true
        }

        // منعلّمش «اتعمل» غير لو الملف اتقرا فعلًا، عشان لو فشل يتعاد في التشغيل الجاي
        if seeded { defaults.set(true, forKey: doneKey) }

        // 3) مزامنة مرة واحدة مع الشيت لو الرابط وكلمة السر جاهزين (لو فشلت تقدر تزامن من الإعدادات)
        if !sheetURL.isEmpty && !sheetPassword.isEmpty {
            _ = try? await SheetSyncService.sync(in: context)
        }
    }
}
