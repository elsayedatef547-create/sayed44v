import SwiftUI
import SwiftData

/// سجل حركات المخزون: إيه اللي اتخصم/اتزوّد، من أنهي فاتورة، ومتى.
struct StockMovementsView: View {
    @Query(sort: \StockMovement.date, order: .reverse) private var movements: [StockMovement]
    @State private var search = ""

    private var shown: [StockMovement] {
        let q = search.trimmed.lowercased()
        guard !q.isEmpty else { return movements }
        return movements.filter {
            $0.productName.lowercased().contains(q)
                || $0.invoiceTitle.lowercased().contains(q)
                || $0.productKey.lowercased().contains(q)
        }
    }

    var body: some View {
        List {
            ForEach(shown) { movement in
                HStack(alignment: .top, spacing: 12) {
                    Text(signed(movement.delta))
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(movement.delta < 0 ? Color.red : Color.green)
                        .frame(minWidth: 52, alignment: .leading)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(movement.productName.isEmpty ? movement.productKey : movement.productName)
                            .font(.subheadline.weight(.semibold))
                            .multilineTextAlignment(.leading)
                        Text(StockMovementReason.title(movement.reason))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !movement.invoiceTitle.isEmpty {
                            Label(movement.invoiceTitle, systemImage: "doc.text")
                                .font(.caption)
                                .foregroundStyle(.indigo)
                        }
                        Text(Formatters.date(movement.date))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if movements.isEmpty {
                ContentUnavailableView(
                    "لا توجد حركات بعد",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("أي خصم أو إرجاع أو توريد للمخزون هيتسجّل هنا.")
                )
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .searchable(text: $search, prompt: "ابحث باسم الصنف أو الفاتورة")
        .navigationTitle("سجل حركات المخزون")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func signed(_ value: Double) -> String {
        let text = Formatters.number(abs(value), maxFraction: 3)
        return value < 0 ? "−\(text)" : "+\(text)"
    }
}
