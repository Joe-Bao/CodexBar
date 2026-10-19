import CodexBarCore
import Foundation
import Observation

enum ResponseSpeedWindow: TimeInterval, CaseIterable, Identifiable {
    case minutes15 = 900
    case hour = 3600
    case day = 86400
    case week = 604_800

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .minutes15: "15m"
        case .hour: "1h"
        case .day: "24h"
        case .week: "7d"
        }
    }
}

@MainActor
@Observable
final class ResponseSpeedModel {
    var samples: [ResponseSpeedSample] = []
    var now = Date()
    var window = ResponseSpeedWindow.hour
    var includeShortResponses = false
    var isIndexing = true
    var unreadableFiles = 0
    var historyLimited = false
    var lowPower = false

    var rows: [ResponseSpeedModelRow] {
        ResponseSpeedSummary.rows(
            samples: self.samples,
            now: self.now,
            window: self.window.rawValue,
            minimumOutputTokens: self.includeShortResponses ? 1 : 200)
    }

    var active: ResponseSpeedModelRow? {
        let rows = ResponseSpeedSummary.rows(
            samples: self.samples,
            now: self.now,
            window: ResponseSpeedSummary.staleAfter)
        return ResponseSpeedSummary.activeRow(
            in: rows,
            now: self.now)
    }

    var statusTitle: String {
        guard let statusRate else { return "TPS" }
        return "\(statusRate) TPS"
    }

    var statusRate: String? {
        self.active.map { Self.rate($0.recentMedian) }
    }

    static func rate(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }
}
