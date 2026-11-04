import SwiftUI
import UIKit

struct WatchRowLabel: View {
    let row: WatchHomePresentation.Row
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            WatchRowIcon(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                if let subtitle = row.subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 44)
    }
}

struct WatchRowIcon: View {
    let symbol: String
    let color: Color

    private var image: Image {
        let name = symbol.hasPrefix("where.") ? "wherewolf." + String(symbol.dropFirst("where.".count)) : symbol
        let image = name.hasPrefix("wherewolf.") ? UIImage(named: name) : UIImage(systemName: name)
        if let image {
            return Image(uiImage: image)
        }
        return Image(systemName: WatchTripMode.fallbackSymbol)
    }

    var body: some View {
        image
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 18, height: 18)
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(color, in: Circle())
            .accessibilityHidden(true)
    }
}

extension View {
    func watchCommandProgress(_ busy: Bool) -> some View {
        toolbar {
            if busy {
                ToolbarItem(placement: .topBarTrailing) { ProgressView() }
            }
        }
    }
}
