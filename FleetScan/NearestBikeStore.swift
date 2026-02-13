//
//  NearestBikeStore.swift
//  FleetScan
//
//  Created by Florian Rousseau on 13/02/2026.
//

import Foundation
import WidgetKit

enum NearestBikeStore {
    // ⚠️ Remplace par TON app group
    static let suite = "group.com.fleetscan.widget"

    static func saveNearest(distanceMeters: Int, bikeId: String?) {
        let ud = UserDefaults(suiteName: suite)
        ud?.set(distanceMeters, forKey: "nearest_distance_m")
        ud?.set(bikeId ?? "", forKey: "nearest_bike_id")
        ud?.set(Date().timeIntervalSince1970, forKey: "nearest_updated_at")

        // Demande au widget de recharger
        WidgetCenter.shared.reloadTimelines(ofKind: "NearestBikeWidget")
    }
}
