import SwiftUI

/// تعديل الإجمالي النهائي أو نسبة الخصم: عدّل واحد منهم والتاني بيتحسب لوحده.
struct DiscountSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// إجمالي الأصناف قبل الخصم وقبل الضريبة
    let base: Double
    let taxMode: String
    let onApply: (Double) -> Void

    private enum Field { case percent, total }

    @State private var percentText: String
    @State private var totalText: String
    /// النسبة الفعلية بدقتها الكاملة (اللي هتتطبّق)، مش النص المقرّب اللي في الخانة
    @State private var percent: Double
    @FocusState private var focus: Field?

    init(base: Double, taxMode: String, initialPercent: Double, onApply: @escaping (Double) -> Void) {
        self.base = base
        self.taxMode = taxMode
        self.onApply = onApply
        let start = InvoiceTotals.clamp(initialPercent)
        _percent = State(initialValue: start)
        _percentText = State(initialValue: start > 0 ? Formatters.number(start, maxFraction: 2, grouping: false) : "")
        let total = InvoiceTotals.finalTotal(base: base, percent: start, mode: taxMode)
        _totalText = State(initialValue: Formatters.number(total, minFraction: 2, grouping: false))
    }

    private var originalTotal: Double {
        InvoiceTotals.finalTotal(base: base, percent: 0, mode: taxMode)
    }

    private var newTotal: Double {
        InvoiceTotals.finalTotal(base: base, percent: percent, mode: taxMode)
    }

    private var typedTotalIsHigher: Bool {
        guard focus == .total, let typed = totalText.parsedDouble else { return false }
        return typed > originalTotal + 0.005
    }

    var body: some View {
        NavigationStack {
            Form {
                if base <= 0 {
                    Section {
                        Text("الأصناف مفيهاش أسعار لسه، فمفيش إجمالي نحسب عليه خصم.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        HStack {
                            Text("الإجمالي الأصلي")
                            Spacer()
                            Text(Formatters.number(originalTotal, minFraction: 2))
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text(taxMode == TaxMode.iva
                             ? "الإجمالي شامل ضريبة IVA 21%، والخصم بيتطبّق قبل الضريبة."
                             : "الإجمالي قبل أي خصم.")
                    }

                    Section {
                        HStack {
                            Text("نسبة الخصم %")
                            Spacer()
                            TextField("0", text: $percentText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .focused($focus, equals: .percent)
                                .frame(maxWidth: 120)
                        }
                        HStack {
                            Text("الإجمالي النهائي")
                            Spacer()
                            TextField("0.00", text: $totalText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .focused($focus, equals: .total)
                                .frame(maxWidth: 120)
                        }
                    } header: {
                        Text("عدّل أي واحدة والتانية بتتحسب لوحدها")
                    } footer: {
                        if typedTotalIsHigher {
                            Text("الإجمالي الجديد أكبر من الأصلي. الخصم بيقلّل السعر بس؛ لو عاوز تزوّد عدّل أسعار الأصناف.")
                                .foregroundStyle(.orange)
                        }
                    }

                    Section {
                        HStack {
                            Text("الإجمالي بعد الخصم")
                                .font(.headline)
                            Spacer()
                            Text(Formatters.number(newTotal, minFraction: 2))
                                .font(.title3.bold())
                                .foregroundStyle(.indigo)
                        }
                        if percent > 0 {
                            HStack {
                                Text("التوفير")
                                Spacer()
                                Text(Formatters.number(originalTotal - newTotal, minFraction: 2))
                                    .foregroundStyle(.green)
                            }
                        }
                    }

                    if percent > 0 {
                        Section {
                            Button("إزالة الخصم", role: .destructive) {
                                onApply(0)
                                dismiss()
                            }
                        }
                    }
                }
            }
            .navigationTitle("تعديل الإجمالي / الخصم")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("تطبيق") {
                        onApply(percent)
                        dismiss()
                    }
                    .disabled(base <= 0)
                }
            }
            .onChange(of: percentText) { _, text in
                guard focus == .percent else { return }
                let value = InvoiceTotals.clamp(text.parsedDouble ?? 0)
                percent = value
                totalText = Formatters.number(
                    InvoiceTotals.finalTotal(base: base, percent: value, mode: taxMode),
                    minFraction: 2, grouping: false
                )
            }
            .onChange(of: totalText) { _, text in
                guard focus == .total, let target = text.parsedDouble else { return }
                let value = InvoiceTotals.percent(forFinalTotal: target, base: base, mode: taxMode)
                percent = value
                percentText = value > 0 ? Formatters.number(value, maxFraction: 2, grouping: false) : ""
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .presentationDetents([.medium, .large])
    }
}
