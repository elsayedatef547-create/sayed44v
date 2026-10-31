import Foundation
import SwiftData

// MARK: - DTOs

struct SyncedInvoiceItem {
    var name: String
    var code: String
    var qty: Double
    var unitPrice: Double
    var customPrice: Double
    var total: Double
    var sortIndex: Int
    var prepared: Bool
    var stockDeducted: Double
    var matchedKey: String
}

struct SyncedInvoice {
    var id: String
    var title: String
    var supplier: String
    var date: Date
    var status: String
    var kind: String
    var taxMode: String
    var discountPercent: Double = 0
    var addedToInventory: Bool = false
    var notes: String
    var fingerprint: String
    var items: [SyncedInvoiceItem]
}

struct InvoiceSyncResult {
    var pushed = 0
    var pulled = 0
}

/// مزامنة الفواتير مع Google Sheet (تابّين: Facturas و Facturas_Items) عشان زميلك يشوفها على جهازه.
/// القاعدة: لو الفاتورة اتغيّرت عندك بس → بترفع. لو اتغيّرت عند الزميل بس → بتنزل عندك.
/// لو الاتنين اتغيّروا → نسختك هي اللي تفضل. الصور مبتتزامنش. مسح فاتورة بيمسحها من جهازك بس.
enum InvoiceSyncService {
    static let fingerprintsKey = "invoice_sync_fingerprints"
    static let lastSyncKey = "invoice_sync_last"
    static let statusKey = "invoice_sync_status"
    private static let batchSize = 20

    // MARK: Fingerprint

    /// بصمة ثابتة لمحتوى الفاتورة (FNV-1a). لو أي حاجة اتغيّرت (صنف/كمية/حالة تجهيز...) البصمة بتتغيّر.
    static func fingerprint(of invoice: Invoice) -> String {
        let items = invoice.items.sorted { $0.sortIndex < $1.sortIndex }
        var parts: [String] = [
            invoice.title,
            invoice.supplier,
            String(Int(invoice.date.timeIntervalSince1970.rounded(.down))),
            invoice.notes,
            invoice.status,
            invoice.kind,
            invoice.taxMode
        ]
        // بتتضاف بس لما فيه خصم، عشان بصمات الفواتير القديمة متتغيّرش
        if invoice.discountPercent > 0 { parts.append("d" + number(invoice.discountPercent)) }
        if invoice.addedToInventory { parts.append("a1") }
        for item in items {
            parts.append([
                item.name,
                item.code,
                number(item.qty),
                number(item.unitPrice),
                number(item.customPrice),
                number(item.total),
                String(item.sortIndex),
                item.prepared ? "1" : "0",
                number(item.stockDeducted),
                item.matchedKey
            ].joined(separator: "\u{1E}"))
        }
        return hash(parts.joined(separator: "\u{1F}"))
    }

    static func hash(_ text: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100000001b3
        }
        // البادئة "f" عشان الشيت ميفسّرش البصمة كرقم ويقصّها
        return "f" + String(h, radix: 16)
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    // MARK: Sync

    @MainActor
    static func sync(url: URL, password: String, context: ModelContext) async throws -> InvoiceSyncResult {
        var fingerprints = (UserDefaults.standard.dictionary(forKey: fingerprintsKey) as? [String: String]) ?? [:]

        let response = try await call(url: url, password: password, action: "invoices", body: nil)
        guard let rawInvoices = response["invoices"] as? [[String: Any]] else {
            throw SheetSyncError.server("كود الشيت (Code.gs) قديم ومفيهوش مزامنة الفواتير. الصق النسخة الجديدة وانشرها (Deploy) تاني.")
        }
        let remote = rawInvoices.compactMap(parse)
        var remoteByID: [String: SyncedInvoice] = [:]
        for invoice in remote { remoteByID[invoice.id] = invoice }

        let archived = (try? context.fetch(FetchDescriptor<ArchivedInvoice>())) ?? []
        let locals = (try? context.fetch(FetchDescriptor<Invoice>())) ?? []

        var result = InvoiceSyncResult()
        var toPush: [(invoice: Invoice, fingerprint: String)] = []
        var localIDs = Set<String>()

        for invoice in locals {
            ensureID(invoice, archived: archived)
            let id = invoice.archiveID
            localIDs.insert(id)
            let fp = fingerprint(of: invoice)

            guard let remoteInvoice = remoteByID[id] else {
                toPush.append((invoice, fp))
                continue
            }
            if remoteInvoice.fingerprint == fp {
                fingerprints[id] = fp
                continue
            }
            let last = fingerprints[id]
            let localUnchanged = (last != nil) && (last == fp)
            if localUnchanged {
                apply(remoteInvoice, to: invoice, in: context)
                fingerprints[id] = fingerprint(of: invoice)
                result.pulled += 1
            } else {
                toPush.append((invoice, fp))
            }
        }

        // فواتير جديدة عند الزميل. اللي عدّت مزامنة قبل كده ومش موجودة عندك = إنت مسحتها، فمنرجّعهاش.
        for remoteInvoice in remote where !remoteInvoice.id.isEmpty
            && !localIDs.contains(remoteInvoice.id)
            && fingerprints[remoteInvoice.id] == nil {
            let invoice = Invoice(title: remoteInvoice.title, supplier: remoteInvoice.supplier, date: remoteInvoice.date)
            invoice.archiveID = remoteInvoice.id
            context.insert(invoice)
            apply(remoteInvoice, to: invoice, in: context)
            fingerprints[remoteInvoice.id] = fingerprint(of: invoice)
            result.pulled += 1
        }
        try? context.save()

        var index = 0
        while index < toPush.count {
            let chunk = Array(toPush[index..<min(index + batchSize, toPush.count)])
            let payloads = chunk.map { payload(for: $0.invoice, fingerprint: $0.fingerprint) }
            let reply = try await call(url: url, password: password, action: "invoices_push", body: ["invoices": payloads])
            guard reply["invoicesSaved"] != nil else {
                throw SheetSyncError.server("كود الشيت (Code.gs) قديم ومفيهوش مزامنة الفواتير. الصق النسخة الجديدة وانشرها (Deploy) تاني.")
            }
            for entry in chunk { fingerprints[entry.invoice.archiveID] = entry.fingerprint }
            result.pushed += chunk.count
            index += batchSize
        }

        UserDefaults.standard.set(fingerprints, forKey: fingerprintsKey)
        UserDefaults.standard.set(Date(), forKey: lastSyncKey)
        return result
    }

    /// مزامنة تلقائية بعد أي تعديل (بتتخطّى لو حصلت من أقل من 8 ثواني). مبترميش خطأ — بتسجّل الحالة بس.
    @MainActor
    static func autoSync(url: URL, password: String, context: ModelContext) async {
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: lastSyncKey) as? Date, Date().timeIntervalSince(last) < 8 { return }
        do {
            let result = try await sync(url: url, password: password, context: context)
            if result.pushed + result.pulled > 0 {
                defaults.set("فواتير: اترفع \(result.pushed)، نزل \(result.pulled) (\(Formatters.date(Date())))", forKey: statusKey)
            }
        } catch {
            defaults.set("تعذّرت مزامنة الفواتير: \(error.localizedDescription)", forKey: statusKey)
        }
    }

    // MARK: Helpers

    private static func ensureID(_ invoice: Invoice, archived: [ArchivedInvoice]) {
        guard invoice.archiveID.isEmpty else { return }
        let legacy = "\(invoice.title)|\(Int(invoice.date.timeIntervalSince1970))"
        invoice.archiveID = archived.contains { $0.key == legacy } ? legacy : UUID().uuidString
    }

    @MainActor
    private static func apply(_ remote: SyncedInvoice, to invoice: Invoice, in context: ModelContext) {
        invoice.title = remote.title
        invoice.supplier = remote.supplier
        invoice.date = remote.date
        invoice.notes = remote.notes
        invoice.status = remote.status.isEmpty ? InvoiceStatus.new : remote.status
        invoice.kind = remote.kind.isEmpty ? InvoiceKind.sale : remote.kind
        invoice.taxMode = remote.taxMode.isEmpty ? TaxMode.none : remote.taxMode
        invoice.discountPercent = remote.discountPercent
        // لو اتضافت للمخزون على أي جهاز نعتبرها اتضافت (عشان مانضاعفش الكميات)
        invoice.addedToInventory = invoice.addedToInventory || remote.addedToInventory

        for old in invoice.items { context.delete(old) }
        try? context.save()

        for entry in remote.items.sorted(by: { $0.sortIndex < $1.sortIndex }) {
            let item = InvoiceItem(
                name: entry.name,
                code: entry.code,
                qty: entry.qty,
                unitPrice: entry.unitPrice,
                total: entry.total,
                sortIndex: entry.sortIndex
            )
            item.customPrice = entry.customPrice
            item.prepared = entry.prepared
            item.stockDeducted = entry.stockDeducted   // المخزون بييجي من الشيت، فمبنخصمش تاني
            item.matchedKey = entry.matchedKey
            context.insert(item)
            item.invoice = invoice
        }
        invoice.totalAmount = remote.items.reduce(0) { $0 + $1.total }
        try? context.save()
    }

    private static func payload(for invoice: Invoice, fingerprint fp: String) -> [String: Any] {
        let items = invoice.items.sorted { $0.sortIndex < $1.sortIndex }.map { item -> [String: Any] in
            [
                "sortIndex": item.sortIndex,
                "name": item.name,
                "code": item.code,
                "qty": item.qty,
                "unitPrice": item.unitPrice,
                "customPrice": item.customPrice,
                "total": item.total,
                "prepared": item.prepared,
                "stockDeducted": item.stockDeducted,
                "matchedKey": item.matchedKey
            ]
        }
        return [
            "id": invoice.archiveID,
            "title": invoice.title,
            "supplier": invoice.supplier,
            "date": isoString(invoice.date),
            "status": invoice.status,
            "kind": invoice.kind,
            "taxMode": invoice.taxMode,
            "discountPercent": invoice.discountPercent,
            "addedToInventory": invoice.addedToInventory,
            "total": invoice.totalAmount,
            "notes": invoice.notes,
            "fp": fp,
            "items": items
        ]
    }

    private static func parse(_ raw: [String: Any]) -> SyncedInvoice? {
        let id = string(raw["id"]).trimmed
        guard !id.isEmpty else { return nil }
        let rawItems = raw["items"] as? [[String: Any]] ?? []
        let items = rawItems.map { entry in
            SyncedInvoiceItem(
                name: string(entry["name"]),
                code: string(entry["code"]).trimmed,
                qty: double(entry["qty"]),
                unitPrice: double(entry["unitPrice"]),
                customPrice: double(entry["customPrice"]),
                total: double(entry["total"]),
                sortIndex: Int(double(entry["sortIndex"])),
                prepared: bool(entry["prepared"]),
                stockDeducted: double(entry["stockDeducted"]),
                matchedKey: string(entry["matchedKey"]).trimmed
            )
        }
        return SyncedInvoice(
            id: id,
            title: string(raw["title"]),
            supplier: string(raw["supplier"]),
            date: parseISO(string(raw["date"])) ?? Date(),
            status: string(raw["status"]),
            kind: string(raw["kind"]),
            taxMode: string(raw["taxMode"]),
            discountPercent: double(raw["discountPercent"]),
            addedToInventory: bool(raw["addedToInventory"]),
            notes: string(raw["notes"]),
            fingerprint: string(raw["fp"]).trimmed,
            items: items
        )
    }

    static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func parseISO(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    private static func call(url: URL, password: String, action: String, body: [String: Any]?) async throws -> [String: Any] {
        if DemoMode.isOn { throw SheetSyncError.demo }
        var request: URLRequest
        if let body {
            request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 180
            request.setValue("text/plain;charset=utf-8", forHTTPHeaderField: "Content-Type")
            var full = body
            full["key"] = password
            full["action"] = action
            request.httpBody = try JSONSerialization.data(withJSONObject: full)
        } else {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw SheetSyncError.badURL
            }
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            let encodedPassword = password.addingPercentEncoding(withAllowedCharacters: allowed) ?? password
            var query = components.percentEncodedQuery.map { $0 + "&" } ?? ""
            query += "key=\(encodedPassword)&action=\(action)"
            components.percentEncodedQuery = query
            guard let finalURL = components.url else { throw SheetSyncError.badURL }
            request = URLRequest(url: finalURL)
            request.timeoutInterval = 90
        }
        let (data, _) = try await URLSession.shared.data(for: request)
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

    private static func double(_ value: Any?) -> Double {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return s.parsedDouble ?? 0 }
        return 0
    }

    private static func bool(_ value: Any?) -> Bool {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.intValue == 1 }
        if let s = value as? String { return s == "1" || s.lowercased() == "true" }
        return false
    }
}
