import macOSdbKit
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self)
    private var appState

    var body: some View {
        @Bindable var state = appState

        NavigationSplitView(columnVisibility: .constant(.all)) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)
        } detail: {
            if appState.isComparing, appState.comparison != nil {
                CompareView()
            } else if appState.selectedRelease != nil {
                ReleaseDetailView()
            } else {
                ContentUnavailableView(
                    "Select a Release",
                    systemImage: "apple.logo",
                    description: Text("Choose a release from the sidebar to view its components.")
                )
            }
        }
        .searchable(text: $state.searchText, prompt: "Filter components")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if appState.isComparing {
                    Button {
                        appState.endCompare()
                    } label: {
                        Label("Done", systemImage: "xmark.circle")
                    }
                    .help("Exit comparison mode")
                } else if appState.selectedRelease != nil {
                    Button {
                        appState.startCompare()
                    } label: {
                        Label("Compare", systemImage: "square.split.2x1")
                    }
                    .help("Compare with another release")
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    Task { await appState.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh release data")
            }
        }
        .toolbarRole(.editor)
        .task {
            if appState.releases.isEmpty {
                await appState.refresh()
            }
        }
    }
}
