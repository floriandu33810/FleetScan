import SwiftUI
import CoreData
import MapKit
import CoreLocation
import UIKit
import AudioToolbox
import AVFoundation

struct ContentView: View {
    @Environment(\.managedObjectContext) private var context
    @State private var selectedTab: Int = 1 // ✅ démarre sur "Mes scans"

    // MARK: - Settings (persisted)

    private enum AppTheme: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        var id: String { rawValue }

        var label: String {
            switch self {
            case .system: return "Système"
            case .light: return "Clair"
            case .dark: return "Sombre"
            }
        }

        var preferredColorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    @AppStorage("app_theme") private var appThemeRaw: String = AppTheme.system.rawValue
    @AppStorage("enable_mode_classic") private var enableClassic: Bool = true
    @AppStorage("enable_mode_massive") private var enableMassive: Bool = true
    @AppStorage("enable_mode_association") private var enableAssociation: Bool = true

    private var appTheme: AppTheme { AppTheme(rawValue: appThemeRaw) ?? .system }

    private func ensureAtLeastOneModeEnabled() {
        if !enableClassic && !enableMassive && !enableAssociation {
            enableClassic = true
        }
    }

    private func ensureScanModeIsEnabled() {
        ensureAtLeastOneModeEnabled()

        switch scanMode {
        case .classic:
            if !enableClassic { scanMode = enableMassive ? .massive : (enableAssociation ? .association : .classic) }
        case .massive:
            if !enableMassive { scanMode = enableClassic ? .classic : (enableAssociation ? .association : .massive) }
        case .association:
            if !enableAssociation { scanMode = enableClassic ? .classic : (enableMassive ? .massive : .association) }
        }
    }

    private func ensureScansFilterIsEnabled() {
        ensureAtLeastOneModeEnabled()

        switch scansFilter {
        case .classic:
            if !enableClassic { scansFilter = enableMassive ? .massive : (enableAssociation ? .association : .classic) }
        case .massive:
            if !enableMassive { scansFilter = enableClassic ? .classic : (enableAssociation ? .association : .massive) }
        case .association:
            if !enableAssociation { scansFilter = enableClassic ? .classic : (enableMassive ? .massive : .association) }
        }
    }

    // Modes
    enum ScanMode: Int { case classic = 0, massive = 1, association = 2 }
    @State private var scanMode: ScanMode = .classic

    enum ScansFilter: Int { case classic = 0, massive = 1, association = 2 }
    @State private var scansFilter: ScansFilter = .classic

    // MARK: - Vehicle type (stored per bikeId)

    private enum VehicleType: String, CaseIterable, Identifiable {
        case bike
        case scooter
        case other
        case iot

        var id: String { rawValue }

        var label: String {
            switch self {
            case .bike: return "Vélo"
            case .scooter: return "Trottinette"
            case .other: return "Autre"
            case .iot: return "iOT"
            }
        }

        var icon: String {
            switch self {
            case .bike: return "bicycle"
            case .scooter: return "scooter"
            case .other: return "mappin.circle.fill"
            case .iot: return "cpu"
            }
        }
    }

    private func vehicleTypeKey(for bikeId: String) -> String {
        "vehicle_type_\(bikeId.uppercased())"
    }

    private func storedVehicleType(for bikeId: String) -> VehicleType? {
        let key = vehicleTypeKey(for: bikeId)
        guard let raw = UserDefaults.standard.string(forKey: key) else { return nil }
        return VehicleType(rawValue: raw)
    }

    private func setStoredVehicleType(_ type: VehicleType, for bikeId: String) {
        let key = vehicleTypeKey(for: bikeId)
        UserDefaults.standard.set(type.rawValue, forKey: key)

        // Trigger UI refresh for icons in "Mes scans" and on the map
        vehicleTypeRefreshTick &+= 1
    }

    private func inferVehicleType(from bikeId: String) -> VehicleType {
        let c = bikeId.uppercased()
        if c.hasPrefix("S0") { return .scooter }
        if c.hasPrefix("E0") { return .bike }
        return .other
    }

    @State private var showDeleteClassicConfirm = false
    @State private var showDeleteMassiveConfirm = false
    @State private var showDeleteAssociationConfirm = false
    // Force UI refresh when vehicle type changes (UserDefaults dynamic keys don't auto-refresh SwiftUI)
    @State private var vehicleTypeRefreshTick: Int = 0

    // Association flow (2-step)
    enum AssociationStep { case scanBike, scanIot }
    @State private var associationStep: AssociationStep = .scanBike
    @State private var pendingAssociationBikeId: String?

    // ✅ Association completion popup
    @State private var showAssociationDonePopup: Bool = false
    @State private var lastAssociationSummary: String = ""

    // Data
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \ScanRecord.timestamp, ascending: false)],
        animation: .default
    )
    private var allScans: FetchedResults<ScanRecord>

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Bike.lastTimestamp, ascending: false)],
        animation: .default
    )
    private var bikes: FetchedResults<Bike>

    @StateObject private var location = LocationManager()

    // UI state
    @State private var lastScannedCode: String = ""
    @State private var showSavedToast = false
    @State private var toastMessage: String = "✅ Scan OK"
    @State private var showCopiedToast = false

    private struct ExportItem: Identifiable {
        let id = UUID()
        let url: URL
    }
    @State private var exportItem: ExportItem?

    // Flash (Scan tab)
    @State private var isTorchOn: Bool = false

    // Rename sheet stable
    @State private var scanToEdit: ScanRecord?
    @State private var showRenameSheet = false
    @State private var editText: String = ""
    @State private var editVehicleType: VehicleType = .other

    // Photo (classic only)
    @State private var pendingPhotoScan: ScanRecord?
    @State private var showCamera = false

    // Photo full screen
    @State private var photoViewerImage: UIImage?
    @State private var showPhotoViewer = false
    @State private var savePhotoToast = false

    // Map callout (tap on marker)
    @State private var selectedMapBikeId: String?

    // Map
    @State private var mapPosition: MapCameraPosition = .automatic

    // Massive anti-doublon + anti double-scan instantané
    @State private var massiveSessionSeen: Set<String> = []
    @State private var lastMassiveScanAt: Date = .distantPast

    // Association anti double-scan (sans pause UI)
    @State private var lastAssociationScanAt: Date = .distantPast
    @State private var lastAssociationScannedValue: String = ""

    // MARK: - Custom beep (bundled audio)

    /// Put a short (~1s) WAV in the app bundle named exactly: `metro_beep.wav`
    /// (Add it to Xcode project, check the main app target).
    private final class MetroBeepPlayer {
        static let shared = MetroBeepPlayer()

        private var player: AVAudioPlayer?
        private let queue = DispatchQueue(label: "MetroBeepPlayer.queue")

        func playOnce() {
            queue.async {
                self.playInternal(durationLimit: 1.0)
            }
        }

        func play(times: Int, interval: TimeInterval = 0.22) {
            guard times > 0 else { return }
            for i in 0..<times {
                DispatchQueue.main.asyncAfter(deadline: .now() + (Double(i) * interval)) {
                    self.playOnce()
                }
            }
        }

        private func playInternal(durationLimit: TimeInterval) {
            // Prepare audio session: plays even in Silent mode (Ring/Silent switch), keeps other audio playing if needed.
            do {
                let session = AVAudioSession.sharedInstance()
                // ✅ Plays even in Silent mode (Ring/Silent switch)
                // Keeps other audio playing if needed.
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try session.setActive(true, options: [])
            } catch {
                // If session fails, we still try to play.
            }

            guard let url = Bundle.main.url(forResource: "metro_beep", withExtension: "wav") else {
                // Fallback system sound if the file is not in the bundle
                AudioServicesPlaySystemSound(1108)
                return
            }

            do {
                if player == nil {
                    player = try AVAudioPlayer(contentsOf: url)
                    player?.prepareToPlay()
                } else {
                    // Reset if already loaded
                    player?.stop()
                    player?.currentTime = 0
                }

                player?.play()

                // Hard-stop after durationLimit (even if file is longer)
                DispatchQueue.main.asyncAfter(deadline: .now() + durationLimit) {
                    self.queue.async {
                        self.player?.stop()
                        self.player?.currentTime = 0
                    }
                }
            } catch {
                // Fallback system sound on any decoding error
                AudioServicesPlaySystemSound(1108)
            }
        }
    }

    private func metroBeep() {
        MetroBeepPlayer.shared.playOnce()
    }

    private func metroBeep(times: Int) {
        MetroBeepPlayer.shared.play(times: times)
    }

    // MARK: - Helpers

    /// http://getapony.com/app?id=S020337  ->  S020337
    /// sinon, renvoie le texte complet
    private func normalizeScanned(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed),
           let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let id = comps.queryItems?.first(where: { $0.name.lowercased() == "id" })?.value,
           !id.isEmpty {
            return id
        }
        return trimmed
    }

    // Extract IoT id from various payloads:
    //
    // Trott (Comodule-like):
    // "2010700099-ZK105MGC-864431040521538-8988303..." -> "864431040521538"
    //
    // Vélo (Velco-like):
    // "OEM-RS-001_RBEF7B" -> "RBEF7B"
    //
    // Fallback: return trimmed raw
    private func extractIotId(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Case A (vélo): `OEM-RS-001_RBEF7B` -> `RBEF7B`
        // We prioritize underscore parsing first, because the dash-splitting would otherwise return `001_RBEF7B`.
        if let lastUnderscore = trimmed.lastIndex(of: "_") {
            let after = String(trimmed[trimmed.index(after: lastUnderscore)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !after.isEmpty {
                return after
            }
        }

        // Case B (trott): `2010700099-ZK105MGC-864431040521538-...` -> `864431040521538`
        // Only take the 3rd `-` chunk if it looks like an IMEI (digits, long enough).
        let dashParts = trimmed.split(separator: "-").map(String.init)
        if dashParts.count >= 3 {
            let third = dashParts[2].trimmingCharacters(in: .whitespacesAndNewlines)
            let isDigitsOnly = !third.isEmpty && third.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
            if isDigitsOnly && third.count >= 10 {
                return third
            }
        }

        return trimmed
    }

    // Associations are stored as ScanRecord with address prefixed by "IOT:"
    private func isAssociation(_ s: ScanRecord) -> Bool {
        (s.address ?? "").hasPrefix("IOT:")
    }

    // Prevent duplicate associations (same bikeId + same iotId)
    private func associationAlreadyExists(bikeId: String, iotId: String) -> Bool {
        let req: NSFetchRequest<ScanRecord> = ScanRecord.fetchRequest()
        req.fetchLimit = 1
        req.predicate = NSPredicate(format: "bikeId == %@ AND address == %@", bikeId, "IOT:\(iotId)")
        return ((try? context.fetch(req).first) != nil)
    }

    private var filteredClassicScans: [ScanRecord] {
        allScans.filter { !$0.isMassive && !isAssociation($0) }
    }

    private var filteredMassiveScans: [ScanRecord] {
        allScans.filter { $0.isMassive }
    }

    private var filteredAssociationScans: [ScanRecord] {
        allScans.filter { isAssociation($0) }
    }

    private var filteredScans: [ScanRecord] {
        switch scansFilter {
        case .classic:
            return filteredClassicScans
        case .massive:
            return filteredMassiveScans
        case .association:
            return filteredAssociationScans
        }
    }

    private func associationHintText() -> String {
        if scanMode != .association {
            let last = lastScannedCode.isEmpty ? "—" : lastScannedCode
            return "Dernier scan : \(last)"
        }

        switch associationStep {
        case .scanBike:
            return "Association : scanne le QRcode du véhicule"
        case .scanIot:
            return "Association : scanne le QRcode de l’iOT"
        }
    }

    // ✅ Save association (returns success). Does NOT beep/toast here.
    @discardableResult
    private func saveAssociation(bikeId: String, iotId: String) -> Bool {
        let now = Date()

        let cleanedBike = bikeId.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedIot  = iotId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedBike.isEmpty, !cleanedIot.isEmpty else { return false }

        // ✅ Anti-doublon : empêche 2 associations identiques
        if associationAlreadyExists(bikeId: cleanedBike, iotId: cleanedIot) {
            lastScannedCode = "\(cleanedBike) -> \(cleanedIot) (déjà enregistré)"
            toast("⚠️ Déjà enregistré")
            beep()
            return false
        }

        let rec = ScanRecord(context: context)
        rec.id = UUID()
        rec.bikeId = cleanedBike
        rec.displayName = "\(cleanedBike) -> \(cleanedIot)"
        rec.timestamp = now
        rec.latitude = 0
        rec.longitude = 0
        rec.photoData = nil
        rec.isMassive = false
        rec.address = "IOT:\(cleanedIot)" // marker for association

        do {
            try context.save()
            lastAssociationSummary = "\(cleanedBike) -> \(cleanedIot)"
            return true
        } catch {
            print("Save association error: \(error)")
            toast("❌ Erreur sauvegarde")
            return false
        }
    }

    // BIP système
    private func beep() {
        metroBeep()
    }

    // Plusieurs bips (ex: 2 bips à la fin d’une association)
    private func beep(times: Int, interval: TimeInterval = 0.22) {
        // Use the custom metro beep, spaced a bit more so it's clearly two distinct bips.
        MetroBeepPlayer.shared.play(times: times, interval: interval)
    }

    // Torch / Flashlight (rear camera torch)
    private func setTorch(_ on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            if on {
                try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
            } else {
                device.torchMode = .off
            }
            device.unlockForConfiguration()
        } catch {
            // ignore
        }
    }

    private func toggleTorch() {
        isTorchOn.toggle()
        setTorch(isTorchOn)
    }

    // Copier (1 par ligne) selon filtre
    private func copyFilteredToClipboard() {
        let text: String

        if scansFilter == .association {
            text = filteredAssociationScans
                .map { scanTitle($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        } else {
            text = filteredScans
                .compactMap { ($0.bikeId ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }

        UIPasteboard.general.string = text
        copiedToast()
    }

    private func copiedToast() {
        withAnimation { showCopiedToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation { showCopiedToast = false }
        }
    }

    // ✅ Icône selon préfixe
    private func vehicleIconName(for codeOrName: String) -> String {
        let c = codeOrName.uppercased()

        // If it's a bikeId we know, prefer the stored vehicle type
        if let stored = storedVehicleType(for: c) {
            switch stored {
            case .bike: return "bicycle"
            case .scooter: return "scooter"
            case .other: return "qrcode"
            case .iot: return "cpu"
            }
        }

        // Fallback: infer from prefix
        if c.hasPrefix("S0") { return "scooter" } // iOS 17+
        if c.hasPrefix("E0") { return "bicycle" }
        return "qrcode"
    }

    // ✅ Icône sur la carte selon le type (S0=trott, E0=vélo, sinon pin)
    private func mapMarkerIcon(for bikeId: String) -> String {
        let c = bikeId.uppercased()

        if let stored = storedVehicleType(for: c) {
            switch stored {
            case .bike: return "bicycle"
            case .scooter: return "scooter"
            case .other: return "mappin.circle.fill"
            case .iot: return "cpu"
            }
        }

        if c.hasPrefix("S0") { return "scooter" }      // iOS 17+
        if c.hasPrefix("E0") { return "bicycle" }
        return "mappin.circle.fill"
    }

    // ✅ Récupère la dernière photo + date (scan classique) pour un bikeId
    private func latestScanInfo(for bikeId: String) -> (date: Date?, image: UIImage?) {
        let req: NSFetchRequest<ScanRecord> = ScanRecord.fetchRequest()
        req.fetchLimit = 1
        req.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        req.predicate = NSPredicate(format: "bikeId == %@ AND isMassive == NO AND photoData != nil", bikeId)

        guard let rec = try? context.fetch(req).first else {
            return (nil, nil)
        }

        let img: UIImage?
        if let data = rec.photoData {
            img = UIImage(data: data)
        } else {
            img = nil
        }

        return (rec.timestamp, img)
    }

    // ✅ Récupère seulement la photo (si besoin ailleurs)
    private func latestPhotoImage(for bikeId: String) -> UIImage? {
        latestScanInfo(for: bikeId).image
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            scanTab
                .tabItem { Label("Scan", systemImage: "qrcode.viewfinder") }
                .tag(0)

            historyTab
                .tabItem { Label("Mes scans", systemImage: "list.bullet") }
                .tag(1)

            mapTab
                .tabItem { Label("Carte", systemImage: "map") }
                .tag(2)

            settingsTab
                .tabItem { Label("Paramètres", systemImage: "gearshape") }
                .tag(3)
        }
        .preferredColorScheme(appTheme.preferredColorScheme)
        .onAppear {
            location.request()
            ensureAtLeastOneModeEnabled()
            ensureScanModeIsEnabled()
            ensureScansFilterIsEnabled()
        }

        // Reset session massive quand on passe en massif + reset flow association si on quitte
        .onChange(of: scanMode) { _, newMode in
            if newMode == .massive {
                massiveSessionSeen.removeAll()
                lastMassiveScanAt = .distantPast
            }
            if newMode != .association {
                associationStep = .scanBike
                pendingAssociationBikeId = nil
                lastAssociationScannedValue = ""
            } else {
                associationStep = .scanBike
                pendingAssociationBikeId = nil
                lastAssociationScannedValue = ""
                lastAssociationScanAt = .distantPast
            }
            if isTorchOn {
                isTorchOn = false
                setTorch(false)
            }
        }

        .onChange(of: enableClassic) { _, _ in
            ensureScanModeIsEnabled()
            ensureScansFilterIsEnabled()
        }
        .onChange(of: enableMassive) { _, _ in
            ensureScanModeIsEnabled()
            ensureScansFilterIsEnabled()
        }
        .onChange(of: enableAssociation) { _, _ in
            ensureScanModeIsEnabled()
            ensureScansFilterIsEnabled()
        }

        .onChange(of: selectedTab) { _, newTab in
            if newTab != 0, isTorchOn {
                isTorchOn = false
                setTorch(false)
            }
        }

        // Camera (classique)
        .sheet(isPresented: $showCamera, onDismiss: {
            pendingPhotoScan = nil
        }) {
            ImagePicker(sourceType: .camera) { image in
                guard let scan = pendingPhotoScan else { return }
                scan.photoData = image.jpegData(compressionQuality: 0.75)
                try? context.save()
            }
        }

        // Photo full screen
        .fullScreenCover(isPresented: $showPhotoViewer) {
            PhotoViewer(image: $photoViewerImage, saveToast: $savePhotoToast)
        }

        // Delete classic confirm
        .confirmationDialog("Supprimer tous les scans classiques ?", isPresented: $showDeleteClassicConfirm, titleVisibility: .visible) {
            Button("Tout supprimer (classiques)", role: .destructive) {
                deleteAllClassicScans()
            }
            Button("Annuler", role: .cancel) {}
        }

        // Delete massive confirm
        .confirmationDialog("Supprimer tous les scans massifs ?", isPresented: $showDeleteMassiveConfirm, titleVisibility: .visible) {
            Button("Tout supprimer (massif)", role: .destructive) {
                deleteAllMassiveScans()
            }
            Button("Annuler", role: .cancel) {}
        }

        // Delete association confirm
        .confirmationDialog("Supprimer toutes les associations ?", isPresented: $showDeleteAssociationConfirm, titleVisibility: .visible) {
            Button("Tout supprimer (associations)", role: .destructive) {
                deleteAllAssociationScans()
            }
            Button("Annuler", role: .cancel) {}
        }
        // ✅ Association end popup
        .alert("Association terminé", isPresented: $showAssociationDonePopup) {
            Button("Continuer") {
                // just close
            }
            Button("Terminer") {
                selectedTab = 1
                scansFilter = .association
            }
        } message: {
            Text(lastAssociationSummary)
        }
    }

    // MARK: - TAB 1 : Scan

    private var scanTab: some View {
        ZStack(alignment: .bottom) {
            let cooldown: Double = {
                switch scanMode {
                case .massive: return 0.25
                case .association: return 0.6
                case .classic: return 1.0
                }
            }()

            QRScannerView(isActive: selectedTab == 0 && !showCamera,
                          cooldownSeconds: cooldown) { raw in
                let base = normalizeScanned(raw)
                let cleaned = extractIotId(from: base)

                switch scanMode {
                case .classic:
                    lastScannedCode = cleaned
                    saveClassicScan(code: cleaned)

                case .massive:
                    lastScannedCode = cleaned
                    saveMassiveScan(code: cleaned)

                case .association:
                    let now = Date()

                    // Debounce léger + anti double lecture identique (sans pause UI)
                    if now.timeIntervalSince(lastAssociationScanAt) < 0.25 { return }
                    if base == lastAssociationScannedValue { return }
                    lastAssociationScanAt = now
                    lastAssociationScannedValue = base

                    if associationStep == .scanBike {
                        // On accepte uniquement un QR véhicule (S0/E0)
                        let upper = base.uppercased()
                        if !(upper.hasPrefix("S0") || upper.hasPrefix("E0")) {
                            lastScannedCode = "Association : scanne le QRcode du véhicule"
                            return
                        }

                        pendingAssociationBikeId = base
                        associationStep = .scanIot
                        lastScannedCode = "Véhicule: \(base)"

                        // ✅ Feedback 1er scan (toaster + 1 bip)
                        toast("✅ Scan OK")
                        beep()
                        return
                    }

                    // Étape IoT
                    guard let bikeId = pendingAssociationBikeId, !bikeId.isEmpty else {
                        associationStep = .scanBike
                        pendingAssociationBikeId = nil
                        lastScannedCode = "Association : scanne le QRcode du véhicule"
                        return
                    }

                    // Si le scanner relit le QR du véhicule, on ignore et on reste en étape IoT
                    let upper = base.uppercased()
                    if base == bikeId || upper.hasPrefix("S0") || upper.hasPrefix("E0") {
                        lastScannedCode = "Association : scanne le QRcode de l’iOT"
                        return
                    }

                    // Extraction IoT : trott (3e champ '-') ou vélo (après le dernier '_')
                    let iotId = extractIotId(from: base)
                    let saved = saveAssociation(bikeId: bikeId, iotId: iotId)

                    // Reset flow
                    pendingAssociationBikeId = nil
                    associationStep = .scanBike
                    lastScannedCode = "\(bikeId) -> \(iotId)"

                    if saved {
                        // ✅ Fin association : 1 bip + toaster + popup
                        beep()
                        toast("✅ Association terminé")
                        showAssociationDonePopup = true
                    }
                }
            }
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                if showSavedToast {
                    Text(toastMessage)
                        .foregroundStyle(.white)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                        .background(.green.opacity(0.75))
                        .clipShape(Capsule())
                        .padding(.top, 6)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }

            VStack(spacing: 10) {
                // ✅ Mode (gauche) + Flash (droite)
                HStack(alignment: .center, spacing: 10) {
                    Picker("", selection: $scanMode) {
                        if enableClassic {
                            Text("Classique").tag(ScanMode.classic)
                        }
                        if enableMassive {
                            Text("Massif").tag(ScanMode.massive)
                        }
                        if enableAssociation {
                            Text("Association").tag(ScanMode.association)
                        }
                    }
                    .pickerStyle(.segmented)
                    .tint(.white)
                    .environment(\.colorScheme, .dark)
                    .onAppear { ensureScanModeIsEnabled() }

                    Spacer()

                    Button {
                        toggleTorch()
                    } label: {
                        Image(systemName: isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                            .font(.title3)
                            .foregroundStyle(isTorchOn ? .yellow : .white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.white.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.black.opacity(0.78))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )

                HStack {
                    Text(associationHintText())
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                    Spacer()
                }
                .padding()
                .background(.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding()
        }
    }

    private func saveMassiveScan(code: String) {
        let now = Date()

        // Anti doublon session
        if massiveSessionSeen.contains(code) { return }

        // Anti double-scan instantané
        if now.timeIntervalSince(lastMassiveScanAt) < 0.6 { return }

        massiveSessionSeen.insert(code)
        lastMassiveScanAt = now

        beep()

        let rec = ScanRecord(context: context)
        rec.id = UUID()
        rec.bikeId = code
        rec.displayName = code
        rec.timestamp = now
        rec.latitude = 0
        rec.longitude = 0
        rec.address = nil
        rec.photoData = nil
        rec.isMassive = true

        do {
            try context.save()
            toast("✅ Scan OK")
        } catch {
            print("Save massive error: \(error)")
        }
    }

    private func saveClassicScan(code: String) {
        let now = Date()
        let coord = location.lastLocation?.coordinate
        let lat = coord?.latitude ?? 0
        let lon = coord?.longitude ?? 0

        let rec = ScanRecord(context: context)
        rec.id = UUID()
        rec.bikeId = code
        rec.displayName = code
        rec.timestamp = now
        rec.latitude = lat
        rec.longitude = lon
        rec.isMassive = false

        // update Bike for map
        let bike = fetchBike(by: code) ?? Bike(context: context)
        bike.bikeId = code
        bike.lastTimestamp = now
        bike.lastLatitude = lat
        bike.lastLongitude = lon
        if bike.displayName == nil || bike.displayName?.isEmpty == true {
            bike.displayName = code
        }

        do {
            try context.save()

            // ✅ Son + toaster (mode classique)
            beep()
            toast("✅ Scan OK")

            if lat != 0 || lon != 0 {
                reverseGeocodeAndSaveAddress(for: rec, lat: lat, lon: lon)
            }

            pendingPhotoScan = rec
            showCamera = true
        } catch {
            print("Save classic error: \(error)")
        }
    }

    private func reverseGeocodeAndSaveAddress(for scan: ScanRecord, lat: Double, lon: Double) {
        let loc = CLLocation(latitude: lat, longitude: lon)

        if #available(iOS 26.0, *) {
            // iOS 26+: Use MapKit reverse geocoding (CLGeocoder APIs are deprecated/obsoleted).
            Task {
                guard let request = MKReverseGeocodingRequest(location: loc) else { return }
                do {
                    let items = try await request.mapItems
                    guard let item = items.first else { return }

                    // Prefer full address when available; fallback to the map item name.
                    let address = item.address?.fullAddress ?? item.name ?? ""
                    guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

                    await MainActor.run {
                        scan.address = address
                        try? self.context.save()
                    }
                } catch {
                    // Ignore reverse geocoding errors.
                }
            }
        } else {
            // iOS <= 25: legacy CLGeocoder
            legacyReverseGeocode(loc) { placemarks, error in
                guard error == nil else { return }
                guard let p = placemarks?.first else { return }

                let parts: [String?] = [p.name, p.thoroughfare, p.subLocality, p.locality, p.postalCode]
                let address = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
                if !address.isEmpty {
                    scan.address = address
                    try? self.context.save()
                }
            }
        }
    }

    // Keep CLGeocoder usage isolated so it doesn't trigger iOS 26 deprecation/unavailability warnings
    @available(iOS, introduced: 13.0, deprecated: 26.0)
    private func legacyReverseGeocode(_ location: CLLocation,
                                     completion: @escaping ([CLPlacemark]?, Error?) -> Void) {
        CLGeocoder().reverseGeocodeLocation(location, completionHandler: completion)
    }

    private func toast(_ message: String = "✅ Scan OK") {
        toastMessage = message
        withAnimation { showSavedToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation { showSavedToast = false }
        }
    }

    private func fetchBike(by bikeId: String) -> Bike? {
        let req: NSFetchRequest<Bike> = Bike.fetchRequest()
        req.fetchLimit = 1
        req.predicate = NSPredicate(format: "bikeId == %@", bikeId)
        return try? context.fetch(req).first
    }

    // ✅ Suppression individuelle (swipe)
    private func deleteScansAtOffsets(_ offsets: IndexSet) {
        let rows = filteredScans

        for index in offsets {
            let scan = rows[index]

            if scanToEdit?.objectID == scan.objectID {
                showRenameSheet = false
                scanToEdit = nil
            }

            context.delete(scan)

            // Nettoyage optionnel de la carte si dernier scan classique pour ce bikeId
            if scan.isMassive == false,
               !isAssociation(scan),
               let id = scan.bikeId {
                let req: NSFetchRequest<ScanRecord> = ScanRecord.fetchRequest()
                req.fetchLimit = 1
                req.predicate = NSPredicate(format: "bikeId == %@ AND isMassive == NO", id)
                let stillHasClassic = ((try? context.fetch(req).first) != nil)

                if !stillHasClassic, let bike = fetchBike(by: id) {
                    context.delete(bike)
                }
            }
        }

        try? context.save()
    }

    // MARK: - TAB 2 : Mes scans

    private var historyTab: some View {
        NavigationStack {
            List {
                Section {
                    Picker("", selection: $scansFilter) {
                        if enableClassic {
                            Text("Scans classiques").tag(ScansFilter.classic)
                        }
                        if enableMassive {
                            Text("Scans massifs").tag(ScansFilter.massive)
                        }
                        if enableAssociation {
                            Text("Associations").tag(ScansFilter.association)
                        }
                    }
                    .pickerStyle(.segmented)
                    .tint(.blue)
                    .padding(.vertical, 6)
                    .listRowBackground(Color.black.opacity(0.06))
                    .onAppear { ensureScansFilterIsEnabled() }
                }

                if scansFilter == .association {
                    ForEach(filteredAssociationScans, id: \.id) { a in
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.left.arrow.right")
                                .font(.title3)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 6) {
                                Text(scanTitle(a))
                                    .font(.headline)

                                Text(formatDate(a.timestamp))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()
                        }
                        .padding(.vertical, 6)
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = scanTitle(a)
                                copiedToast()
                            } label: {
                                Label("Copier", systemImage: "doc.on.doc")
                            }
                        }
                    }
                    .onDelete(perform: deleteScansAtOffsets)
                } else {
                    ForEach(filteredScans, id: \.id) { s in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                Image(systemName: vehicleIconName(for: s.bikeId ?? ""))
                                    .font(.title3)
                                    .frame(width: 28)

                                VStack(alignment: .leading, spacing: 6) {
                                    Text(scanTitle(s))
                                        .font(.headline)

                                    Text(formatDate(s.timestamp))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)

                                    if s.isMassive {
                                        Text("Scan massif")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text(formatCoord(s.latitude, s.longitude))
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)

                                        if let addr = s.address, !addr.isEmpty {
                                            Text(addr)
                                                .font(.subheadline)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }

                                Spacer()

                                Button {
                                    scanToEdit = s
                                    editText = scanTitle(s)

                                    if let id = s.bikeId, let stored = storedVehicleType(for: id) {
                                        editVehicleType = stored
                                    } else if let id = s.bikeId {
                                        editVehicleType = inferVehicleType(from: id)
                                    } else {
                                        editVehicleType = .other
                                    }

                                    showRenameSheet = true
                                } label: {
                                    Image(systemName: "pencil")
                                }
                            }

                            if !s.isMassive {
                                if let data = s.photoData, let uiImage = UIImage(data: data) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(height: 160)
                                        .clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                        .contentShape(RoundedRectangle(cornerRadius: 12))
                                        .onTapGesture {
                                            photoViewerImage = uiImage
                                            showPhotoViewer = true
                                        }
                                }

                                HStack {
                                    Spacer()
                                    Button {
                                        openInGoogleMaps(lat: s.latitude, lon: s.longitude)
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: "map.fill")
                                                .symbolRenderingMode(.monochrome)
                                                .foregroundStyle(.white)
                                                .opacity(1)
                                            Text("Ouvrir dans Google Maps")
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.blue)
                                    .disabled(s.latitude == 0 && s.longitude == 0)
                                    Spacer()
                                }
                            }
                        }
                        .padding(.vertical, 6)
                        .contextMenu {
                            Button {
                                let text = (s.bikeId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                                UIPasteboard.general.string = text.isEmpty ? scanTitle(s) : text
                                copiedToast()
                            } label: {
                                Label("Copier", systemImage: "doc.on.doc")
                            }
                        }
                    }
                    .onDelete(perform: deleteScansAtOffsets)
                }
            }
            .id(vehicleTypeRefreshTick)
            .overlay(alignment: .bottom) {
                if showCopiedToast {
                    Text("📋 Copié dans le presse-papiers")
                        .foregroundStyle(.white)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                        .background(.black.opacity(0.75))
                        .clipShape(Capsule())
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .navigationTitle("Mes scans")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // 🗑️ Tout effacer (selon le filtre)
                    Button {
                        switch scansFilter {
                        case .classic:
                            showDeleteClassicConfirm = true
                        case .massive:
                            showDeleteMassiveConfirm = true
                        case .association:
                            showDeleteAssociationConfirm = true
                        }
                    } label: {
                        Image(systemName: "trash")
                    }

                    // ✅ Copier dans le presse-papiers (dispo pour tous les filtres)
                    Button {
                        copyFilteredToClipboard()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }

                    // Export
                    Button {
                        if let url = makeOneColumnExport() {
                            exportItem = ExportItem(url: url)
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .sheet(item: $exportItem) { item in
                ShareSheet(activityItems: [item.url])
            }
            .sheet(isPresented: $showRenameSheet, onDismiss: {
                scanToEdit = nil
            }) {
                NavigationStack {
                    Form {
                        TextField("Nom du véhicule", text: $editText)

                        Picker("Type", selection: $editVehicleType) {
                            ForEach(VehicleType.allCases) { t in
                                Text(t.label).tag(t)
                            }
                        }
                    }
                    .navigationTitle("Modifier")
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Annuler") { showRenameSheet = false }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Enregistrer") {
                                guard let scan = scanToEdit else {
                                    showRenameSheet = false
                                    return
                                }

                                let cleaned = editText.trimmingCharacters(in: .whitespacesAndNewlines)
                                scan.displayName = cleaned.isEmpty ? scan.bikeId : cleaned
                                if let id = scan.bikeId {
                                    setStoredVehicleType(editVehicleType, for: id)
                                }

                                if let id = scan.bikeId, let bike = fetchBike(by: id) {
                                    bike.displayName = scan.displayName
                                }

                                try? context.save()
                                showRenameSheet = false
                            }
                            .bold()
                        }
                    }
                }
            }
        }
    }

    // Export 1 colonne (respecte le filtre)
    private func makeOneColumnExport() -> URL? {
        let rows = filteredScans

        let text: String
        if scansFilter == .association {
            text = rows
                .map { scanTitle($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n") + "\n"
        } else {
            text = rows
                .compactMap { ($0.bikeId ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n") + "\n"
        }

        let modeName: String
        switch scansFilter {
        case .classic: modeName = "classique"
        case .massive: modeName = "massif"
        case .association: modeName = "association"
        }

        let filename = "fleetscan_export_\(modeName)_\(Int(Date().timeIntervalSince1970)).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        do {
            try text.data(using: .utf8)?.write(to: url)
            return url
        } catch {
            print("Export write error: \(error)")
            return nil
        }
    }

    private func deleteAllClassicScans() {
        let req: NSFetchRequest<ScanRecord> = ScanRecord.fetchRequest()
        // Classic = not massive AND not association
        req.predicate = NSPredicate(format: "isMassive == NO AND (address == NIL OR NOT (address BEGINSWITH %@))", "IOT:")
        if let results = try? context.fetch(req) {
            for r in results { context.delete(r) }
            try? context.save()
        }
    }

    private func deleteAllMassiveScans() {
        let req: NSFetchRequest<ScanRecord> = ScanRecord.fetchRequest()
        req.predicate = NSPredicate(format: "isMassive == YES")
        if let results = try? context.fetch(req) {
            for r in results { context.delete(r) }
            try? context.save()
        }
    }

    private func deleteAllAssociationScans() {
        let req: NSFetchRequest<ScanRecord> = ScanRecord.fetchRequest()
        // Associations are stored with address prefixed by "IOT:"
        req.predicate = NSPredicate(format: "address BEGINSWITH %@", "IOT:")
        if let results = try? context.fetch(req) {
            for r in results { context.delete(r) }
            try? context.save()
        }
    }

    private func scanTitle(_ s: ScanRecord) -> String {
        if let dn = s.displayName, !dn.isEmpty { return dn }
        return s.bikeId ?? "—"
    }

    private func openInGoogleMaps(lat: Double, lon: Double) {
        showRenameSheet = false
        scanToEdit = nil

        guard lat != 0 || lon != 0 else { return }

        let appURL = URL(string: "comgooglemaps://?q=\(lat),\(lon)&center=\(lat),\(lon)&zoom=17")!
        if UIApplication.shared.canOpenURL(appURL) {
            UIApplication.shared.open(appURL)
        } else {
            let webURL = URL(string: "https://www.google.com/maps/search/?api=1&query=\(lat),\(lon)")!
            UIApplication.shared.open(webURL)
        }
    }

    // MARK: - TAB 3 : Carte

    private var mapTab: some View {
        NavigationStack {
            Map(position: $mapPosition) {
                UserAnnotation()

                ForEach(bikes, id: \.bikeId) { b in
                    if let id = b.bikeId,
                       (b.lastLatitude != 0 || b.lastLongitude != 0) {
                        let title = bikeTitle(b)
                        let icon = mapMarkerIcon(for: id)

                        // ✅ Titre vide pour éviter le doublon (MapKit affiche parfois le label automatiquement)
                        Annotation("", coordinate: CLLocationCoordinate2D(latitude: b.lastLatitude, longitude: b.lastLongitude)) {
                            VStack(spacing: 6) {
                                // ✅ Petit menu au-dessus du marker quand on clique
                                if selectedMapBikeId == id {
                                    let info = latestScanInfo(for: id)

                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Text(title)
                                                .font(.subheadline)
                                                .bold()
                                            Spacer()
                                            Button {
                                                withAnimation(.easeOut(duration: 0.15)) {
                                                    selectedMapBikeId = nil
                                                }
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .font(.title3)
                                                    .foregroundStyle(.secondary)
                                            }
                                            .buttonStyle(.plain)
                                        }

                                        if let d = info.date {
                                            Text(formatDate(d))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }

                                        if let img = info.image {
                                            Image(uiImage: img)
                                                .resizable()
                                                .scaledToFill()
                                                .frame(width: 170, height: 110)
                                                .clipped()
                                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                                .contentShape(RoundedRectangle(cornerRadius: 12))
                                                .id(vehicleTypeRefreshTick)
                                                .onTapGesture {
                                                    photoViewerImage = img
                                                    showPhotoViewer = true
                                                }
                                        } else {
                                            Text("Aucune photo")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(12)
                                    .background(.thinMaterial)
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14)
                                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                                    )
                                    .shadow(radius: 10)
                                    .transition(.move(edge: .top).combined(with: .opacity))
                                }

                                Button {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        // toggle selection
                                        selectedMapBikeId = (selectedMapBikeId == id) ? nil : id
                                    }
                                } label: {
                                    Image(systemName: icon)
                                        .font(.title2)
                                }
                                .buttonStyle(.plain)

                                // ✅ Nom affiché UNE seule fois
                                Text(title)
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.thinMaterial)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
            }
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.15)) {
                    selectedMapBikeId = nil
                }
            }
            .navigationTitle("Carte")
            .overlay(alignment: .bottomTrailing) {
                Button {
                    if let loc = location.lastLocation {
                        let region = MKCoordinateRegion(
                            center: loc.coordinate,
                            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                        )
                        mapPosition = .region(region)
                    }
                } label: {
                    Image(systemName: "location.fill")
                        .font(.title3)
                        .padding(14)
                        .background(.thinMaterial)
                        .clipShape(Circle())
                }
                .padding()
            }
        }
    }

    private func bikeTitle(_ b: Bike) -> String {
        if let dn = b.displayName, !dn.isEmpty { return dn }
        return b.bikeId ?? "Véhicule"
    }

    // MARK: - TAB 4 : Paramètres

    private var settingsTab: some View {
        NavigationStack {
            Form {
                Section("Apparence") {
                    Picker("Thème", selection: $appThemeRaw) {
                        ForEach(AppTheme.allCases) { t in
                            Text(t.label).tag(t.rawValue)
                        }
                    }
                }

                Section("Modes") {
                    Toggle("Classique", isOn: $enableClassic)
                    Toggle("Massif", isOn: $enableMassive)
                    Toggle("Association", isOn: $enableAssociation)

                    Text("Active ou désactive les modes disponibles dans l’onglet Scan et les filtres dans Mes scans.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Text("Créé par Florian Rousseau")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Paramètres")
            .onAppear {
                ensureAtLeastOneModeEnabled()
                ensureScanModeIsEnabled()
                ensureScansFilterIsEnabled()
            }
        }
    }

    // MARK: - Date / Formatting

    private func formatDate(_ d: Date?) -> String {
        guard let d else { return "—" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }

    private func formatCoord(_ lat: Double, _ lon: Double) -> String {
        String(format: "%.5f, %.5f", lat, lon)
    }
}

// MARK: - Photo viewer (plein écran + save photos)
private struct PhotoViewer: View {
    @Binding var image: UIImage?
    @Binding var saveToast: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .ignoresSafeArea()
            }

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .padding()

                    Spacer()

                    Button {
                        guard let img = image else { return }
                        UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
                        withAnimation { saveToast = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            withAnimation { saveToast = false }
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .padding()
                }

                Spacer()

                if saveToast {
                    Text("✅ Enregistrée dans Photos")
                        .foregroundStyle(.white)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                        .background(.white.opacity(0.15))
                        .clipShape(Capsule())
                        .padding(.bottom, 30)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }
}
