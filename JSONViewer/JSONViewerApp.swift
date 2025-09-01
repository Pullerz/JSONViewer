//
//  JSONViewerApp.swift
//  JSONViewer
//
//  Created by Alistair Pullen on 01/09/2025.
//

import SwiftUI

@main
struct JSONViewerApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup("JSONViewer", id: "main") {
            AppShellView()
        }
        .commands {
            AppCommands()
        }
    }
}
