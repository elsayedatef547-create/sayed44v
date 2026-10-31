import Foundation

/// سطر في تقرير المحل الشهري: صنف واحد مجمّع من كل فواتير الشهر.
struct ShopReportLine: Identifiable, Equatable {
    let id: String
    var name: String
    var qty: Double
    var value: Double
}

enum ShopReport {
    /// بيجمّع أصناف كل الفواتير حسب الصنف (مفتاح المخزون لو موجود، وإلا الكود، وإلا الاسم)،
    /// بالكمية والقيمة (الكمية × سعر البيع/التحويل) قبل الخصم والضريبة. الأعلى قيمة أولًا.
    static func lines(for invoices: [Invoice], matcher: StockMatcher) -> [ShopReportLine] {
        var byKey: [String: ShopReportLine] = [:]
        for invoice in invoices {
            for item in invoice.items {
                let key: String
                if !item.matchedKey.isEmpty {
                    key = item.matchedKey
                } else if !item.code.trimmed.isEmpty {
                    key = item.code.codeKey
                } else {
                    key = item.name.customerKey
                }
                let price = matcher.salePrice(for: item) ?? 0
                var line = byKey[key] ?? ShopReportLine(id: key, name: item.name, qty: 0, value: 0)
                line.qty += item.qty
                line.value += item.qty * price
                byKey[key] = line
            }
        }
        return byKey.values.sorted {
            $0.value == $1.value ? $0.name.localizedCompare($1.name) == .orderedAscending : $0.value > $1.value
        }
    }

    private static func cell(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private static func num(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), InvoiceTotals.round2(value))
    }

    /// تقرير CSV للشهر: ملخص الفواتير ثم تجميع الأصناف.
    static func csv(shop: String, monthStart: Date, invoices: [Invoice], matcher: StockMatcher) -> String {
        var rows: [String] = []
        rows.append([cell("المحل"), cell(shop)].joined(separator: ","))
        rows.append([cell("الشهر"), cell(MonthHelper.fileStamp(monthStart))].joined(separator: ","))
        rows.append("")
        rows.append([cell("الفاتورة"), cell("التاريخ"), cell("الإجمالي")].joined(separator: ","))
        var grand = 0.0
        for invoice in invoices.sorted(by: { $0.date < $1.date }) {
            let total = InvoiceTotals.saleTotal(of: invoice, matcher: matcher)
            grand += total
            rows.append([
                cell(invoice.title),
                cell(Formatters.date(invoice.date, includeTime: false, localeID: "en_US_POSIX")),
                num(total)
            ].joined(separator: ","))
        }
        rows.append([cell("إجمالي الشهر"), "", num(grand)].joined(separator: ","))
        rows.append("")
        rows.append([cell("الصنف"), cell("الكمية"), cell("القيمة قبل الخصم والضريبة")].joined(separator: ","))
        for line in lines(for: invoices, matcher: matcher) {
            rows.append([cell(line.name), num(line.qty), num(line.value)].joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }
}

/// حساب ربح المحل في شهر: المبيعات − تمن البضاعة المحوّلة − المصاريف.
/// تمن البضاعة = اللي اتحوّل في الشهر (من غير جرد).
struct ShopProfit: Equatable {
    var sales: Double
    /// قيمة التحويلات بسعر التحويل (اللي المحل «اشترى» بيه منك)
    var transfers: Double
    /// قيمة نفس البضاعة بتكلفتها الفعلية عليك
    var ownerCost: Double
    var expenses: Double

    /// ربح المحل لوحده بعد ما دفع تمن البضاعة بسعر التحويل
    var shopProfit: Double { sales - transfers - expenses }
    /// ربحك الإجمالي بتكلفة البضاعة الفعلية
    var ownerProfit: Double { sales - ownerCost - expenses }
}

extension ShopReport {
    /// تكلفة أصناف الفواتير بتكلفة الصنف المسجّلة في المخزون. لو الصنف مالوش تكلفة بنستخدم سعر التحويل
    /// ونعدّه في `missing` عشان التقرير يقول إن الرقم تقريبي.
    static func ownerCost(for invoices: [Invoice], matcher: StockMatcher) -> (cost: Double, missing: Int) {
        var cost = 0.0
        var missing = 0
        for invoice in invoices {
            for item in invoice.items {
                if let product = matcher.info(for: item).product, product.cost > 0 {
                    cost += item.qty * product.cost
                } else {
                    cost += item.qty * (matcher.salePrice(for: item) ?? 0)
                    missing += 1
                }
            }
        }
        return (InvoiceTotals.round2(cost), missing)
    }
}
