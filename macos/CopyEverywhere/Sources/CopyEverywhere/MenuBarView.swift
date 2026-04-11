import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var configStore: ConfigStore
    @EnvironmentObject var historyStore: HistoryStore

    var body: some View {
        VStack(spacing: 0) {
            if !configStore.isConfigured {
                ConfigView()
            } else {
                MainPanelView()
            }
        }
        .frame(width: 360)
        .onAppear {
            configStore.historyStore = historyStore
        }
    }
}
