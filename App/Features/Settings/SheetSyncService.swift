import Foundation
import SwiftData
import SwiftUI

enum SheetSyncError: LocalizedError {
    case missingConfig
    case badURL
    case notJSON
    case demo
    case server(String)

    var errorDescription: String? {
        switch self {
        case .missingConfig:
            return "أدخل رابط الشيت وكلمة السر أولاً."
        case .badURL:
            return "رابط الشيت غير صالح."
        case .demo:
            return "الوضع التجريبي: المزامنة مع الشيت معطّلة."
        case .notJSON:
            return "الرد مش صحيح. تأكد إن السكربت منشور (Web app) وصلاحية الوصول Anyone."
        case .server(let message):
            return message == "unauthorized" ? "كلمة السر غير صحيحة." : "خطأ من الشيت: \(message)"
        }
    }
}

struct SheetRow {
    var barcode: String
    var sku: String
    var name: String
    var price: Double      // Sales Price
    var cost: Double       // Cost
    var qty: Double?       // Existencias (nil لو الخانة نص مثل "Sin dato")
    var image: String
    var base: Double? = nil   // آخر كمية معروفة في الشيت (للرفع بالفرق). nil = ارفع بالكمية المطلقة
}

/// منتج اتمسح من التطبيق ولسه مااتمسحش من الشيت (بيتعاد لحد ما يتمسح فعلًا).
struct ProductTombstone: Codable, Hashable {
    var sku: String
    var barcode: String
}

struct SheetSyncResult {
    var added = 0
    var updated = 0
    var pushed = 0
    var invoicesPushed = 0
    var invoicesPulled = 0
    var invoiceError: String?
    var removed = 0            // منتجات اتشالت من التطبيق لأنها اتمسحت من الشيت
    var deleteError: String?   // فشل مسح منتج من الشيت
}

enum SheetSyncService {
    static let urlKey = "sheet_sync_url"
    static let passwordAccount = "sheet_sync_password"
    static let lastSyncKey = "sheet_last_sync"
    static let lastPushKey = "sheet_last_push"
    static let tombstonesKey = "sheet_pending_deletes"
    static let syncedKeysKey = "sheet_synced_keys"
    static let syncedURLKey = "sheet_synced_url"

    // MARK: Pull

    static func pull(url: URL, password: String) async throws -> [SheetRow] {
        if DemoMode.isOn { throw SheetSyncError.demo }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw SheetSyncError.badURL
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encodedPassword = password.addingPercentEncoding(withAllowedCharacters: allowed) ?? password
        var query = components.percentEncodedQuery.map { $0 + "&" } ?? ""
        query += "key=\(encodedPassword)"
        components.percentEncodedQuery = query
        guard let finalURL = components.url else { throw SheetSyncError.badURL }

        var request = URLRequest(url: finalURL)
        request.timeoutInterval = 90
        let (data, _) = try await URLSession.shared.data(for: request)

        let json = try object(from: data)
        guard let rawRows = json["rows"] as? [[String: Any]] else { return [] }

        return rawRows.compactMap { raw -> SheetRow? in
            let barcode = string(raw["barcode"]).trimmed
            let sku = string(raw["sku"]).trimmed
            if barcode.isEmpty && sku.isEmpty { return nil }
            return SheetRow(
                barcode: barcode,
                sku: sku,
                name: string(raw["name"]).trimmed,
                price: double(raw["price"]) ?? 0,
                cost: double(raw["cost"]) ?? 0,
                qty: double(raw["qty"]),
                image: string(raw["image"]).trimmed
            )
        }
    }

    // MARK: Push

    /// بيرفع الأصناف ويرجّع الكمية النهائية في الشيت لكل صنف (بعد دمج تعديلات الأجهزة التانية). فاضي لو السكربت قديم.
    @discardableResult
    static func push(url: URL, password: String, rows: [SheetRow]) async throws -> [String: Double] {
        if DemoMode.isOn { throw SheetSyncError.demo }
        let payloadRows: [[String: Any]] = rows.map { row -> [String: Any] in
            var entry: [String: Any] = [
                "barcode": row.barcode,
                "sku": row.sku,
                "name": row.name,
                "price": row.price,
                "cost": row.cost,
                "qty": row.qty ?? 0,
                "image": row.image
            ]
            if let base = row.base { entry["base"] = base }
            return entry
        }
        let body: [String: Any] = ["key": password, "rows": payloadRows]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("text/plain;charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try object(from: data)
        var quantities: [String: Double] = [:]
        if let raw = json["qtys"] as? [String: Any] {
            for (key, value) in raw {
                if let number = double(value) { quantities[key.codeKey] = number }
            }
        }
        return quantities
    }

    // MARK: Full sync (pull then push)

    @MainActor
    static func sync(in context: ModelContext) async throws -> SheetSyncResult {
        if DemoMode.isOn { throw SheetSyncError.demo }
        let urlString = (UserDefaults.standard.string(forKey: urlKey) ?? "").trimmed
        let password = KeychainHelper.read(account: passwordAccount) ?? ""
        guard !urlString.isEmpty, !password.isEmpty else { throw SheetSyncError.missingConfig }
        guard let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true else {
            throw SheetSyncError.badURL
        }
        resetIfSheetChanged(urlString)

        // وقت البداية: أي تعديل بيحصل أثناء المزامنة (زي خصم تجهيز) يفضل أحدث منه فيتسجّل ويتبعت المرة الجاية
        let syncStartedAt = Date()
        var result = SheetSyncResult()

        // 1) سحب من الشيت ودمجه محلياً. الصنف اللي اتعدّل في التطبيق بعد آخر مزامنة
        //    بنحافظ على تعديلاته المحلية (كمية/سعر/اسم) وبنرفعها للشيت بدل ما تتمسح.
        let lastSync = UserDefaults.standard.object(forKey: lastSyncKey) as? Date
        let tombstones = pendingDeletes()
        let remote = try await pull(url: url, password: password).filter { !isTombstoned($0, in: tombstones) }
        let existing = (try? context.fetch(FetchDescriptor<Product>())) ?? []

        var index = ProductIndex(products: existing)

        for row in remote {
            let match = index.find(sku: row.sku, code: row.barcode, name: "")

            if let product = match {
                // لو دي أول مزامنة، أي منتج اتعدّل محليًا بعد إنشائه (زي خصم التجهيز) يتحسب تعديل محلي
                let localChanged = lastSync.map { product.updatedAt > $0 }
                    ?? (product.updatedAt.timeIntervalSince(product.createdAt) > 1)
                if !localChanged {
                    if !row.name.isEmpty { product.name = row.name }
                    if row.price > 0 { product.price = row.price }
                    if row.cost > 0 { product.cost = row.cost }
                    if let qty = row.qty {
                        product.qty = qty
                        product.sheetQty = qty
                        product.sheetQtyKnown = true
                    }
                }
                if product.code.trimmed.isEmpty && !row.barcode.isEmpty { product.code = row.barcode }
                if !row.sku.isEmpty { product.sku = row.sku }
                if !row.image.isEmpty { product.imageURL = row.image }
                index.add(product)
                result.updated += 1
            } else {
                let product = Product(
                    name: row.name.isEmpty ? (row.sku.isEmpty ? row.barcode : row.sku) : row.name,
                    code: row.barcode,
                    qty: row.qty ?? 0,
                    price: row.price
                )
                product.sku = row.sku
                product.cost = row.cost
                product.imageURL = row.image
                if let qty = row.qty {
                    product.sheetQty = qty
                    product.sheetQtyKnown = true
                }
                context.insert(product)
                index.add(product)
                result.added += 1
            }
        }
        // اللي اتمسح من الشيت (من جهاز تاني) يتشال من هنا كمان، إلا لو اتعدّل عندك بعد آخر مزامنة.
        let remoteKeys = Set(remote.map { ($0.sku.isEmpty ? $0.barcode : $0.sku).codeKey })
        result.removed = removeProductsDeletedElsewhere(remoteKeys: remoteKeys, existing: existing, lastSync: lastSync, context: context)
        if !remote.isEmpty { UserDefaults.standard.set(Array(remoteKeys), forKey: syncedKeysKey) }
        try? context.save()

        // 2) رفع المنتجات (اللي ليها باركود أو SKU) للشيت
        let all = (try? context.fetch(FetchDescriptor<Product>())) ?? []
        let rows = all.compactMap { SheetSyncService.sheetRow(for: $0) }
        if !rows.isEmpty {
            let quantities = try await push(url: url, password: password, rows: rows)
            applyPushedQuantities(quantities, pushed: rows, in: context)
        }
        result.pushed = rows.count

        // 2.5) مسح المنتجات اللي اتمسحت من التطبيق (لو فشل بيتعاد بعدين، ومبيوقفش المزامنة)
        do {
            try await flushDeletes(url: url, password: password, products: all)
        } catch {
            result.deleteError = error.localizedDescription
        }
        UserDefaults.standard.set(syncStartedAt, forKey: lastSyncKey)
        UserDefaults.standard.set(syncStartedAt, forKey: lastPushKey)

        // 3) الفواتير (لو فشلت مبتوقفش مزامنة المخزون)
        do {
            let invoiceResult = try await InvoiceSyncService.sync(url: url, password: password, context: context)
            result.invoicesPushed = invoiceResult.pushed
            result.invoicesPulled = invoiceResult.pulled
        } catch {
            result.invoiceError = error.localizedDescription
        }
        return result
    }

    // MARK: Auto push (يرفع الأصناف اللي اتعدّلت بس)

    static func sheetRow(for product: Product) -> SheetRow? {
        let barcode = product.code.trimmed
        let sku = product.sku.trimmed
        if barcode.isEmpty && sku.isEmpty { return nil }
        return SheetRow(
            barcode: barcode,
            sku: sku,
            name: product.name,
            price: product.price,
            cost: product.cost,
            qty: product.qty,
            image: product.imageURL,
            base: product.sheetQtyKnown ? product.sheetQty : nil
        )
    }

    /// يرفع للشيت الأصناف اللي اتعدّلت من آخر رفع. لو فشل (مفيش نت مثلًا) بيتعاد في أول تعديل أو فتح للتطبيق.
    @MainActor
    static func pushChanged(in context: ModelContext) async {
        if DemoMode.isOn { return }
        let defaults = UserDefaults.standard
        let urlString = (defaults.string(forKey: urlKey) ?? "").trimmed
        let password = KeychainHelper.read(account: passwordAccount) ?? ""
        guard !urlString.isEmpty, !password.isEmpty,
              let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true else { return }
        resetIfSheetChanged(urlString)

        // لسه ما اتعملتش مزامنة أولى: نعمل مزامنة كاملة (سحب + دمج + رفع). التعديلات المحلية بتتحفظ ومبتتمسحش.
        guard let since = (defaults.object(forKey: lastPushKey) as? Date)
                ?? (defaults.object(forKey: lastSyncKey) as? Date) else {
            do {
                let result = try await sync(in: context)
                defaults.set("تمت أول مزامنة تلقائيًا: \(result.added) جديد، \(result.updated) محدّث، \(result.pushed) اترفع (\(Formatters.date(Date())))", forKey: AutoSync.statusKey)
            } catch {
                defaults.set("تعذّرت المزامنة الأولى: \(error.localizedDescription)", forKey: AutoSync.statusKey)
            }
            return
        }

        try? context.save()
        let all = (try? context.fetch(FetchDescriptor<Product>())) ?? []
        do {
            try await flushDeletes(url: url, password: password, products: all)
        } catch {
            defaults.set("تعذّر مسح منتج من الشيت، هيتعاد تلقائيًا: \(error.localizedDescription)", forKey: AutoSync.statusKey)
        }
        let rows = all
            .filter { $0.updatedAt > since }
            .compactMap { SheetSyncService.sheetRow(for: $0) }
        if !rows.isEmpty {
            let stamp = Date()
            do {
                let quantities = try await push(url: url, password: password, rows: rows)
                applyPushedQuantities(quantities, pushed: rows, in: context)
                defaults.set(stamp, forKey: lastPushKey)
                defaults.set("اترفع للشيت تلقائيًا: \(rows.count) صنف (\(Formatters.date(stamp)))", forKey: AutoSync.statusKey)
            } catch {
                defaults.set("تعذّر الرفع التلقائي، هيتعاد تلقائيًا: \(error.localizedDescription)", forKey: AutoSync.statusKey)
            }
        }

        // الفواتير: رفع التعديلات ونزول فواتير الزميل
        await InvoiceSyncService.autoSync(url: url, password: password, context: context)
    }

    // MARK: Deletes (التطبيق ← الشيت)

    static func pendingDeletes() -> [ProductTombstone] {
        guard let data = UserDefaults.standard.data(forKey: tombstonesKey),
              let list = try? JSONDecoder().decode([ProductTombstone].self, from: data) else { return [] }
        return list
    }

    private static func savePendingDeletes(_ list: [ProductTombstone]) {
        if list.isEmpty {
            UserDefaults.standard.removeObject(forKey: tombstonesKey)
        } else if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: tombstonesKey)
        }
    }

    /// نادِها قبل ما تمسح منتج من التطبيق. بتفتكر إنه لازم يتمسح من الشيت كمان (ومينزلش تاني في المزامنة).
    static func recordDeletion(of product: Product) {
        let configured = !(UserDefaults.standard.string(forKey: urlKey) ?? "").trimmed.isEmpty
        let sku = product.sku.trimmed
        let barcode = product.code.trimmed
        guard configured, !sku.isEmpty || !barcode.isEmpty else { return }
        var list = pendingDeletes()
        let entry = ProductTombstone(sku: sku, barcode: barcode)
        if !list.contains(entry) { list.append(entry) }
        savePendingDeletes(list)
    }

    static func isTombstoned(_ row: SheetRow, in list: [ProductTombstone]) -> Bool {
        list.contains { entry in
            if !entry.sku.isEmpty {
                return !row.sku.isEmpty && row.sku.codeKey == entry.sku.codeKey
            }
            return !entry.barcode.isEmpty && row.sku.isEmpty && row.barcode.codeKey == entry.barcode.codeKey
        }
    }

    private static func matches(_ product: Product, _ entry: ProductTombstone) -> Bool {
        if !entry.sku.isEmpty { return product.sku.codeKey == entry.sku.codeKey }
        return !entry.barcode.isEmpty && product.sku.trimmed.isEmpty && product.code.codeKey == entry.barcode.codeKey
    }

    static func flushDeletes(url: URL, password: String, products: [Product]) async throws {
        if DemoMode.isOn { throw SheetSyncError.demo }
        var list = pendingDeletes()
        guard !list.isEmpty else { return }

        // لو المنتج اتضاف تاني بنفس الـ SKU/الباركود، منمسحوش من الشيت.
        let readded = list.filter { entry in products.contains { matches($0, entry) } }
        if !readded.isEmpty {
            list.removeAll { readded.contains($0) }
            savePendingDeletes(list)
        }
        guard !list.isEmpty else { return }

        let items: [[String: Any]] = list.map { ["sku": $0.sku, "barcode": $0.barcode] }
        let body: [String: Any] = ["key": password, "action": "products_delete", "items": items]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("text/plain;charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        let reply = try object(from: data)
        guard reply["deleted"] != nil else {
            throw SheetSyncError.server("كود الشيت (Code.gs) قديم ومفيهوش مسح المنتجات. الصق النسخة الجديدة وانشرها (Deploy) تاني.")
        }

        var remaining = pendingDeletes()
        remaining.removeAll { list.contains($0) }
        savePendingDeletes(remaining)
    }

    // MARK: Deletes (الشيت ← التطبيق)

    /// منتج كان في الشيت في آخر مزامنة ومبقاش موجود = اتمسح من جهاز تاني. بنشيله هنا.
    /// حماية: لو العدد كبير جدًا (ممكن يكون الشيت اتقرا ناقص) منعملش حاجة.
    private static func removeProductsDeletedElsewhere(
        remoteKeys: Set<String>, existing: [Product], lastSync: Date?, context: ModelContext
    ) -> Int {
        guard !remoteKeys.isEmpty,
              let previous = UserDefaults.standard.stringArray(forKey: syncedKeysKey) else { return 0 }
        let gone = Set(previous).subtracting(remoteKeys)
        guard !gone.isEmpty, gone.count <= max(20, previous.count / 2) else { return 0 }
        var removed = 0
        for product in existing where gone.contains(product.matchKey) {
            if let lastSync, product.updatedAt > lastSync { continue }   // اتعدّل عندك: يفضل ويتعاد رفعه
            context.delete(product)
            removed += 1
        }
        return removed
    }

    /// لو غيّرت رابط الشيت من الإعدادات: بننسى حالة الشيت القديم (عشان منمسحش منتجات بالغلط ولا نبعت مسح للشيت الجديد).
    static func resetIfSheetChanged(_ urlString: String) {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: syncedURLKey)
        guard previous != urlString else { return }
        if previous != nil {
            defaults.removeObject(forKey: syncedKeysKey)
            defaults.removeObject(forKey: tombstonesKey)
            defaults.removeObject(forKey: lastSyncKey)
            defaults.removeObject(forKey: lastPushKey)
            defaults.removeObject(forKey: InvoiceSyncService.fingerprintsKey)
            defaults.removeObject(forKey: InvoiceSyncService.lastSyncKey)
        }
        defaults.set(urlString, forKey: syncedURLKey)
    }

    // MARK: Quantity merge (الرفع بالفرق)

    /// بعد الرفع الشيت بيرجّع الكمية النهائية (بعد دمج الأجهزة التانية). بنضيف الفرق على كميتنا الحالية
    /// (فلو خصمت حاجة أثناء الرفع متضيعش) ونحفظ كمية الشيت كأساس للمرة الجاية.
    @MainActor
    static func applyPushedQuantities(_ quantities: [String: Double], pushed rows: [SheetRow], in context: ModelContext) {
        guard !quantities.isEmpty else { return }
        var sentQty: [String: Double] = [:]
        for row in rows {
            sentQty[(row.sku.isEmpty ? row.barcode : row.sku).codeKey] = row.qty ?? 0
        }
        let all = (try? context.fetch(FetchDescriptor<Product>())) ?? []
        for product in all {
            let key = product.matchKey
            guard let merged = quantities[key], let sent = sentQty[key] else { continue }
            product.qty = max(product.qty + (merged - sent), 0)
            product.sheetQty = merged
            product.sheetQtyKnown = true
        }
        try? context.save()
    }

    // MARK: Helpers

    private static func object(from data: Data) throws -> [String: Any] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SheetSyncError.notJSON
        }
        if let ok = json["ok"] as? Bool, !ok {
            throw SheetSyncError.server((json["error"] as? String) ?? "unknown")
        }
        return json
    }

    private static func string(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return ""
    }

    private static func double(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return s.parsedDouble }
        return nil
    }
}

// MARK: - Settings section (داخل Form في SettingsView)

struct SheetSyncSection: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage(SheetSyncService.urlKey) private var sheetURL = ""
    @AppStorage(AutoSync.enabledKey) private var autoPush = true
    @AppStorage(AutoSync.statusKey) private var autoStatus = ""
    @AppStorage(InvoiceSyncService.statusKey) private var invoiceStatus = ""

    @State private var password = ""
    @State private var isSyncing = false
    @State private var status = ""
    @State private var isError = false

    var body: some View {
        Section {
            TextField("رابط السكربت (Web app URL)", text: $sheetURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            SecureField("كلمة السر", text: $password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Toggle("رفع التعديلات للشيت تلقائيًا", isOn: $autoPush)

            if autoPush && !autoStatus.isEmpty {
                Text(autoStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if autoPush && !invoiceStatus.isEmpty {
                Text(invoiceStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await run() }
            } label: {
                HStack {
                    Label("حفظ ومزامنة الآن", systemImage: "arrow.triangle.2.circlepath")
                    if isSyncing {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isSyncing || sheetURL.trimmed.isEmpty || password.isEmpty)

            if !status.isEmpty {
                Label(status, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .font(.footnote)
                    .foregroundStyle(isError ? Color.red : Color.green)
            }
        } header: {
            Text("مزامنة مع Google Sheets")
        } footer: {
            Text("الأعمدة المستخدمة: B الاسم، D المرجع الداخلي (SKU)، E الباركود، F سعر البيع، G التكلفة، M المخزون، J رابط الصورة (قراءة فقط). باقي الأعمدة ما بتتغيرش. الفواتير بتتزامن في تابّين منفصلين: Facturas و Facturas_Items.")
        }
        .onAppear {
            password = KeychainHelper.read(account: SheetSyncService.passwordAccount) ?? ""
        }
    }

    @MainActor
    private func run() async {
        isSyncing = true
        defer { isSyncing = false }
        KeychainHelper.save(password, account: SheetSyncService.passwordAccount)
        do {
            let result = try await SheetSyncService.sync(in: modelContext)
            isError = false
            status = "تمت المزامنة: \(result.added) جديد، \(result.updated) محدّث، \(result.pushed) اترفع للشيت."
            status += " الفواتير: اترفع \(result.invoicesPushed)، نزل \(result.invoicesPulled)."
            if result.removed > 0 {
                status += " اتشال \(result.removed) منتج اتمسح من الشيت."
            }
            if let deleteError = result.deleteError {
                isError = true
                status += " ⚠️ \(deleteError)"
            }
            if let invoiceError = result.invoiceError {
                isError = true
                status += " ⚠️ \(invoiceError)"
            }
        } catch {
            isError = true
            status = error.localizedDescription
        }
    }
}

// MARK: - Auto push trigger

enum AutoSync {
    static let enabledKey = "sheet_auto_push"
    static let statusKey = "sheet_auto_status"

    @MainActor private static var pending: Task<Void, Never>?

    /// آمن للاستدعاء من أي مكان بعد أي تعديل في المخزون. بيستنى ثانيتين ونص (يجمّع التعديلات) وبعدين يرفع.
    static func request(_ context: ModelContext) {
        Task { @MainActor in
            let enabled = UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
            guard enabled, !DemoMode.isOn else { return }
            pending?.cancel()
            pending = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if Task.isCancelled { return }
                await SheetSyncService.pushChanged(in: context)
            }
        }
    }
}
