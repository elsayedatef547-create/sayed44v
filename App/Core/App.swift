import SwiftUI
import SwiftData
import UIKit

@main
struct InvoiceScannerApp: App {
    let sharedModelContainer: ModelContainer
    private let storageFailed: Bool
    private static let schema = Schema([Invoice.self, InvoiceItem.self, Product.self, ArchivedInvoice.self, ProductAlias.self, StockMovement.self, Customer.self, ShopMonth.self, ShopExpense.self])
    @State private var demoContainer: ModelContainer
    @AppStorage(DemoMode.key) private var demoOn = false
    @State private var showStorageAlert = false
    @AppStorage(AppLogin.key) private var loggedIn = false

    init() {
        UIView.appearance().semanticContentAttribute = .forceRightToLeft
        AppSettings.migrateModelIfNeeded()

        let schema = InvoiceScannerApp.schema
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        let container: ModelContainer
        var failed = false
        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            failed = true
            let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do {
                container = try ModelContainer(for: schema, configurations: [fallback])
            } catch {
                fatalError("Could not create ModelContainer: \(error)")
            }
        }
        sharedModelContainer = container
        storageFailed = failed
        _demoContainer = State(initialValue: DemoData.makeContainer(schema: schema))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if demoOn {
                    MainTabView()
                        .safeAreaInset(edge: .top, spacing: 0) { DemoBanner() }
                } else if loggedIn {
                    MainTabView()
                } else {
                    LoginView()
                }
            }
                .modelContainer(demoOn ? demoContainer : sharedModelContainer)
                .id(demoOn)
                .onChange(of: demoOn) { _, isOn in
                    // لما تخرج من الوضع التجريبي نجهّز بيانات جديدة للمرة الجاية
                    if !isOn { demoContainer = DemoData.makeContainer(schema: InvoiceScannerApp.schema) }
                }
                .environment(\.layoutDirection, .rightToLeft)
                .onAppear { showStorageAlert = storageFailed }
                .alert("تعذّر فتح قاعدة البيانات", isPresented: $showStorageAlert) {
                    Button("حسناً", role: .cancel) {}
                } message: {
                    Text("التطبيق شغّال بقاعدة مؤقتة، يعني أي فاتورة أو تعديل هيضيع لما تقفل التطبيق. حدّث التطبيق أو أعد تثبيته، وزامن المخزون مع الشيت.")
                }
        }
    }
}
