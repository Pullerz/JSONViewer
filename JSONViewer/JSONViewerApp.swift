//
//  JSONViewerApp.swift
//  JSONViewer
//
//  Created by Alistair Pullen on 01/09/2025.
//

import SwiftUI

@main
struct JSONViewerApp: App {
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            AppShellView()
                .environmentObject(viewModel)
        }
        .commands {
            AppCommands()
        }
    }
}
