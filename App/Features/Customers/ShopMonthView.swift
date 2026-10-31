import SwiftUI
import SwiftData

/// مبيعات المحل في شهر (بيدخلها صاحب المحل آخر الشهر).
@Model
final class ShopMonth {
    var shopKey: String = ""
    var monthKey: String = ""
    var sales: Double = 0

    init(shopKey: String, monthKey: String, sales: Double = 0) {
        self.shopKey = shopKey
        self.monthKey = monthKey
        self.sales = sales
    }
}

/// مصروف للمحل في شهر (إيجار، رواتب، …).
@Model
final class ShopExpense {
    var shopKey: String = ""
    var monthKey: String = ""
    var title: String = ""
    var amount: Double = 0
    var createdAt: Date = Date()

    init(shopKey: String, monthKey: String, title: String, amount: Double) {
        self.shopKey = shopKey
        self.monthKey = monthKey
        self.title = title
        self.amount = amount
    }
}

/// ختام الشهر لمحل: مبيعات + مصاريف ← ربح المحل وربحك.
struct ShopMonthCloseView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var months: [ShopMonth]
    @Query(sort: \ShopExpense.createdAt) private var expenses: [ShopExpense]

    let shopName: String
    let monthStart: Date
    let transfers: Double
    let ownerCost: Double
    let missingCost: Int

    @State private var salesText = ""
    @State private var showAdd = false
    @State private var newTitle = ""
    @State private var newAmount = ""

    private var shopKey: String { shopName.customerKey }
    private var monthKey: String { MonthHelper.fileStamp(monthStart) }
    private var previousMonthKey: String { MonthHelper.fileStamp(MonthHelper.shift(monthStart, by: -1)) }

    private var record: ShopMonth? {
        months.first { $0.shopKey == shopKey && $0.monthKey == monthKey }
    }

    private var monthExpenses: [ShopExpense] {
        expenses.filter { $0.shopKey == shopKey && $0.monthKey == monthKey }
    }

    private var previousExpenses: [ShopExpense] {
        expenses.filter { $0.shopKey == shopKey && $0.monthKey == previousMonthKey }
    }

    private var profit: ShopProfit {
        ShopProfit(
            sales: record?.sales ?? 0,
            transfers: transfers,
            ownerCost: ownerCost,
            expenses: monthExpenses.reduce(0) { $0 + $1.amount }
        )
    }

    var body: some View {
        let result = profit
        List {
            Section {
                MonthTitleRow(monthStart: monthStart)
                HStack {
                    Text("مبيعات المحل")
                    Spacer()
                    TextField("0.00", text: $salesText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.center)
                        .frame(width: 110)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
            } footer: {
                Text("اكتب إجمالي اللي المحل باعه في الشهر ده.")
            }

            Section("المصاريف") {
                ForEach(monthExpenses) { expense in
                    HStack {
                        Text(expense.title)
                        Spacer()
                        Text(Formatters.number(expense.amount, minFraction: 2))
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    let list = monthExpenses
                    for index in offsets { modelContext.delete(list[index]) }
                    try? modelContext.save()
                }
                Button {
                    newTitle = ""
                    newAmount = ""
                    showAdd = true
                } label: {
                    Label("إضافة مصروف", systemImage: "plus.circle")
                }
                if monthExpenses.isEmpty && !previousExpenses.isEmpty {
                    Button {
                        copyPrevious()
                    } label: {
                        Label("نسخ مصاريف الشهر اللي فات", systemImage: "doc.on.doc")
                    }
                }
            }

            Section("النتيجة") {
                row("المبيعات", result.sales)
                row("تمن البضاعة المحوّلة", -result.transfers)
                row("المصاريف", -result.expenses)
                HStack {
                    Text("ربح المحل")
                        .font(.headline)
                    Spacer()
                    Text(Formatters.number(result.shopProfit, minFraction: 2))
                        .font(.title3.bold())
                        .foregroundStyle(result.shopProfit >= 0 ? Color.green : Color.red)
                }
            } footer: {
                Text("تمن البضاعة = اللي اتحوّل للمحل في الشهر ده بسعر التحويل (من غير جرد).")
            }

            Section {
                row("تكلفة البضاعة عليك", -result.ownerCost)
                HStack {
                    Text("ربحك الإجمالي")
                        .font(.headline)
                    Spacer()
                    Text(Formatters.number(result.ownerProfit, minFraction: 2))
                        .font(.title3.bold())
                        .foregroundStyle(result.ownerProfit >= 0 ? Color.green : Color.red)
                }
            } header: {
                Text("ربحك كصاحب المحل")
            } footer: {
                Text(missingCost > 0
                     ? "\(missingCost) صنف من غير تكلفة مسجّلة في المخزون، اتحسب بسعر التحويل، فالرقم ده تقريبي."
                     : "المبيعات − تكلفة البضاعة الفعلية (من المخزون) − المصاريف.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("ختام \(shopName)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let sales = record?.sales, sales > 0 {
                salesText = Formatters.number(sales, minFraction: 2, grouping: false)
            }
        }
        .onChange(of: salesText) { _, new in saveSales(new) }
        .alert("مصروف جديد", isPresented: $showAdd) {
            TextField("البند (إيجار، رواتب…)", text: $newTitle)
            TextField("المبلغ", text: $newAmount)
                .keyboardType(.decimalPad)
            Button("إضافة") { addExpense() }
            Button("إلغاء", role: .cancel) {}
        }
    }

    private func row(_ title: String, _ value: Double) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(Formatters.number(value, minFraction: 2))
                .foregroundStyle(.secondary)
        }
    }

    private func saveSales(_ text: String) {
        let value = max(text.parsedDouble ?? 0, 0)
        if let existing = record {
            existing.sales = value
        } else if value > 0 {
            modelContext.insert(ShopMonth(shopKey: shopKey, monthKey: monthKey, sales: value))
        }
        try? modelContext.save()
    }

    private func addExpense() {
        let title = newTitle.trimmed
        guard !title.isEmpty, let amount = newAmount.parsedDouble, amount > 0 else { return }
        modelContext.insert(ShopExpense(shopKey: shopKey, monthKey: monthKey, title: title, amount: amount))
        try? modelContext.save()
    }

    private func copyPrevious() {
        for old in previousExpenses {
            modelContext.insert(ShopExpense(shopKey: shopKey, monthKey: monthKey, title: old.title, amount: old.amount))
        }
        try? modelContext.save()
    }
}

private struct MonthTitleRow: View {
    let monthStart: Date

    var body: some View {
        HStack {
            Text("الشهر")
            Spacer()
            Text(MonthHelper.title(monthStart))
                .foregroundStyle(.secondary)
        }
    }
}
