//
//  FleetScanNearestBikeWidget.swift
//  FleetScan
//
//  Created by Florian Rousseau on 13/02/2026.
//

import WidgetKit
import SwiftUI

private let appGroupSuite = "group.com.florian.FleetScan"
private let widgetKind = "com.florian.FleetScan.Widget"

// MARK: - Entry

struct NearestEntry: TimelineEntry {
    let date: Date
    let distanceMeters: Int
    let bikeId: String
    let updatedAt: Date?
}

// MARK: - Provider

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> NearestEntry {
        NearestEntry(date: .now, distanceMeters: 100, bikeId: "E012345", updatedAt: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (NearestEntry) -> Void) {
        completion(load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NearestEntry>) -> Void) {
        let entry = load()
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: .now) ?? .now.addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func load() -> NearestEntry {
        let ud = UserDefaults(suiteName: appGroupSuite)

        let dist = ud?.integer(forKey: "nearest_distance_m") ?? -1
        let bikeId = (ud?.string(forKey: "nearest_bike_id") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let ts = ud?.double(forKey: "nearest_updated_at") ?? 0
        let updatedAt = ts > 0 ? Date(timeIntervalSince1970: ts) : nil

        return NearestEntry(date: .now, distanceMeters: dist, bikeId: bikeId, updatedAt: updatedAt)
    }
}

// MARK: - View

struct FleetScanNearestBikeWidgetView: View {
    let entry: NearestEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryInline:
            // Ex: 🛴 120m • 09:41
            HStack(spacing: 6) {
                Image(systemName: vehicleSymbol(for: entry.bikeId))
                Text(distanceText(entry.distanceMeters))
                if let updated = entry.updatedAt {
                    Text("• \(timeText(updated))")
                }
            }

        case .accessoryCircular:
            // Cercle = place limitée : on met surtout distance + icône
            VStack(spacing: 2) {
                Image(systemName: vehicleSymbol(for: entry.bikeId))
                    .font(.caption)
                Text(shortDistanceText(entry.distanceMeters))
                    .font(.caption2)
                    .minimumScaleFactor(0.7)
            }

        case .accessoryRectangular:
            // Rectangle lockscreen : distance + id + maj
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: vehicleSymbol(for: entry.bikeId))
                    Text("Plus proche")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                Text(distanceText(entry.distanceMeters))
                    .font(.headline)

                HStack(spacing: 6) {
                    if !entry.bikeId.isEmpty {
                        Text(entry.bikeId)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if let updated = entry.updatedAt {
                        Text("Maj \(timeText(updated))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

        default:
            // Home screen (si tu l’as gardé) : on affiche plus d’infos
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: vehicleSymbol(for: entry.bikeId))
                            .font(.title3)
                        Text("Vélo/Trott le plus proche")
                            .font(.headline)
                    }

                    Text(distanceText(entry.distanceMeters))
                        .font(.system(size: 34, weight: .bold))

                    HStack {
                        if !entry.bikeId.isEmpty {
                            Text(entry.bikeId)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let updated = entry.updatedAt {
                            Text("Maj \(dateTimeText(updated))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
            }
            .padding()
        }
    }

    // MARK: - Helpers (UI)

    private func vehicleSymbol(for bikeId: String) -> String {
        let id = bikeId.uppercased()
        if id.hasPrefix("S0") { return "scooter" }   // iOS 17+
        if id.hasPrefix("E0") { return "bicycle" }
        return "qrcode"
    }

    private func distanceText(_ meters: Int) -> String {
        if meters < 0 { return "— m" }
        if meters >= 1000 {
            let km = Double(meters) / 1000.0
            return String(format: "%.1f km", km).replacingOccurrences(of: ".", with: ",")
        }
        return "\(meters) m"
    }

    private func shortDistanceText(_ meters: Int) -> String {
        if meters < 0 { return "—" }
        if meters >= 1000 { return "\(meters/1000)k" }
        return "\(meters)m"
    }

    private func timeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    private func dateTimeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "dd/MM HH:mm"
        return f.string(from: date)
    }
}

// MARK: - Widget

struct FleetScanNearestBikeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: widgetKind, provider: Provider()) { entry in
            FleetScanNearestBikeWidgetView(entry: entry)
        }
        .configurationDisplayName("Vélo le plus proche")
        .description("Affiche la distance au véhicule le plus proche + date de maj.")
        .supportedFamilies([
            .accessoryInline, .accessoryRectangular, .accessoryCircular,
            .systemSmall, .systemMedium
        ])
    }
}
