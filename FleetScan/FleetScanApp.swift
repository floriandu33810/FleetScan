//
//  FleetScanApp.swift
//  FleetScan
//
//  Created by Florian Rousseau on 12/02/2026.
//

import SwiftUI
import CoreData

@main
struct FleetScanApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
