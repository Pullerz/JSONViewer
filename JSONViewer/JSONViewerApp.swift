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

    @AppStorage("themePreference") private var themePreference: String = "system"

    private var preferredScheme: ColorScheme? {
        switch themePreference {
        case "light": return .light
        case "dark": return .dark
        default: return nil // follow system
        }
    }

    var body: some Scene {
        WindowGroup("Prism", id: "main") {
            AppShellView()
                .preferredColorScheme(preferredScheme)
        }
        .commands {
            AppCommands()
        }
        #if os(macOS)
        Settings {
            PreferencesView()
                .frame(width: 520, height: 280)
        }
        #endif
    }
}
