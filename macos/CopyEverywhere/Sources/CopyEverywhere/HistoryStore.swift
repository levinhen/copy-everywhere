import AppKit
import Foundation

struct HistoryRecord: Codable, Identifiable, Equatable {
    let clipID: String
    let type: String // text, image, file
    let filename: String?
    let timestamp: Date
    let expiresAt: Date
    let status: String // success, failed

    var id: String { clipID }

    var isExpired: Bool {
        Date() > expiresAt
    }

    var typeIcon: String {
        switch type {
        case "text": return "doc.text"
        case "image": return "photo"
        default: return "doc"
        }
    }
}

@MainActor
final class HistoryStore: ObservableObject {
    @Published var records: [HistoryRecord] = []

    private let key = "com.copyeverywhere.history"

    init() {
        load()
    }

    func addRecord(_ record: HistoryRecord) {
        // Remove existing record with same clipID if any
        records.removeAll { $0.clipID == record.clipID }
        records.insert(record, at: 0)
        save()
    }

    func deleteRecord(clipID: String) {
        records.removeAll { $0.clipID == clipID }
        save()
    }

    func deleteRecords(at offsets: IndexSet) {
        records.remove(atOffsets: offsets)
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([HistoryRecord].self, from: data) else {
            return
        }
        records = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
