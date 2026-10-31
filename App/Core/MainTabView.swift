import SwiftUI
import SwiftData

struct MainTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            HomeView()
                .tabItem {
                    Label("الرئيسية", systemImage: "doc.text.image")
                }
                .tag(0)

            ScannerView()
                .tabItem {
                    Label("الماسح", systemImage: "barcode.viewfinder")
                }
                .tag(1)

            PreparationView()
                .tabItem {
                    Label("التجهيز", systemImage: "checklist")
                }
                .tag(4)

            PreparedInvoicesView()
                .tabItem {
                    Label("المجهّزة", systemImage: "checkmark.seal.fill")
                }
                .tag(5)

            InventoryView()
                .tabItem {
                    Label("المخزون", systemImage: "shippingbox.fill")
                }
                .tag(2)

            CustomersView()
                .tabItem {
                    Label("العملاء", systemImage: "person.2.fill")
                }
                .tag(6)

            SettingsView()
                .tabItem {
                    Label("الإعدادات", systemImage: "gearshape.fill")
                }
                .tag(3)
        }
        .onReceive(NotificationCenter.default.publisher(for: .goToPreparationTab)) { _ in
            selection = 4
        }
        .onReceive(NotificationCenter.default.publisher(for: .goToPreparedTab)) { _ in
            selection = 5
        }
        .task { await SeedService.runIfNeeded(in: modelContext) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { AutoSync.request(modelContext) }
        }
        .tint(.indigo)
        .environment(\.layoutDirection, .rightToLeft)
    }
}
