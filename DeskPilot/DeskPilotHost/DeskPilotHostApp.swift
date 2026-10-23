//
//  DeskPilotHostApp.swift
//  DeskPilotHost
//
//  macOS 主機端入口：讓手機透過區網控制這台電腦。
//

import SwiftUI

@main
struct DeskPilotHostApp: App {
    @State private var controller = HostController()

    var body: some Scene {
        Window("DeskPilot 主機", id: "main") {
            ContentView(controller: controller)
        }
        .windowResizability(.contentSize)
    }
}
