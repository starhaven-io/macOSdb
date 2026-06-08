import macOSdbKit
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self)
    private var appState

    // periphery false-positive: @State read only via its $-projection (bound below).
    // periphery:ignore
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var state = appState

        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)
        } detail: {
            if appState.isComparing, appState.comparison != nil {
                CompareView()
            } else if appState.sidebarMode == .components, let name = appState.selectedComponentName {
                ComponentDetailView(componentName: name)
            } else if appState.sidebarMode == .sdks, let version = appState.selectedSDKVersion {
                SDKDetailView(sdkVersion: version)
            } else if appState.sidebarMode == .releases, appState.selectedRelease != nil {
                ReleaseDetailView()
            } else {
                emptyStateView
            }
        }
        .searchable(text: $state.searchText, prompt: "Filter components")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if appState.sidebarMode == .releases {
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
                .disabled(appState.isLoading)
            }
        }
        .toolbarRole(.editor)
        .alert("Failed to Load Releases", isPresented: $state.hasError) {
            Button("Retry") { Task { await appState.refresh() } }
            Button("Dismiss", role: .cancel) { }
        } message: {
            Text(appState.lastError?.localizedDescription ?? "An unknown error occurred.")
        }
        .task {
            if appState.releases.isEmpty {
                await appState.refresh()
            }
        }
    }

    @ViewBuilder private var emptyStateView: some View {
        switch appState.sidebarMode {
        case .components:
            ContentUnavailableView(
                "Select a Component",
                systemImage: "shippingbox",
                description: Text("Choose a component from the sidebar to view its version history.")
            )
        case .sdks:
            ContentUnavailableView(
                "Select an SDK",
                systemImage: "sdcard",
                description: Text("Choose an SDK from the sidebar to view its build history.")
            )
        case .releases:
            ContentUnavailableView(
                "Select a Release",
                systemImage: "apple.logo",
                description: Text("Choose a release from the sidebar to view its components.")
            )
        }
    }
}
