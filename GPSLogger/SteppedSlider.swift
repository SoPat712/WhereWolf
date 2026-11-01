import SwiftUI

struct SliderDetents {
    let values: [Double]

    init(range: ClosedRange<Double>, unit: String) {
        let common: [Double]
        switch unit {
        case "seconds": common = [0, 1, 5, 10, 15, 30, 60, 120, 180, 300, 600, 900, 1800, 3600]
        case "hours": common = [24, 36, 48, 72, 96, 120, 144, 168]
        case "meters": common = [0, 1, 5, 10, 25, 50, 100, 200, 500, 1000, 2000, 3000, 5000]
        default: common = [1, 5, 10, 25, 50, 100, 200, 500, 1000]
        }
        values = Array(Set(common.filter(range.contains) + [range.lowerBound, range.upperBound])).sorted()
    }

    var positions: [Double] { values.indices.map(Double.init) }
    var bounds: ClosedRange<Double> { 0...Double(values.count - 1) }

    func position(for value: Double) -> Double {
        guard value > values[0] else { return 0 }
        for index in 1..<values.count where value <= values[index] {
            return Double(index - 1) + (value - values[index - 1]) / (values[index] - values[index - 1])
        }
        return bounds.upperBound
    }

    func value(at position: Double) -> Double {
        let position = min(bounds.upperBound, max(0, position))
        let lower = min(values.count - 2, Int(position))
        return (values[lower] + (values[lower + 1] - values[lower]) * (position - Double(lower))).rounded()
    }

    func snap(_ position: Double, held: Double?) -> Double? {
        if let held, abs(position - held) <= 0.28 { return held }
        let nearest = position.rounded()
        return abs(position - nearest) <= 0.18 ? min(bounds.upperBound, max(0, nearest)) : nil
    }

    func adjacent(to value: Double, increasing: Bool) -> Double {
        increasing ? values.first(where: { $0 > value }) ?? values.last!
            : values.last(where: { $0 < value }) ?? values[0]
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var offBelow: Double?
    var unit = "locations"
    let format: (Double) -> String

    @State private var editing = false
    @State private var input = ""
    @State private var draft: Double?
    @State private var dragging = false
    @State private var heldDetent: Double?
    @State private var feedback = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var displayedValue: Double { draft ?? value }
    private var detents: SliderDetents { SliderDetents(range: range, unit: unit) }
    private var label: String {
        if let offBelow, displayedValue < offBelow { return "Off" }
        return format(displayedValue)
    }
    private var enteredValue: Double? {
        guard let number = Double(input.trimmingCharacters(in: .whitespacesAndNewlines)),
              number.isFinite, range.contains(number) else { return nil }
        return number.rounded()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                    valueButton
                }
            } else {
                HStack {
                    Text(title)
                    Spacer()
                    valueButton
                }
            }
            slider
            .accessibilityLabel(title)
            .accessibilityValue(label)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: value = detents.adjacent(to: value, increasing: true)
                case .decrement: value = detents.adjacent(to: value, increasing: false)
                @unknown default: break
                }
                draft = nil
            }
            .sensoryFeedback(.selection, trigger: feedback)
        }
        .padding(.vertical, 2)
        .alert(title, isPresented: $editing) {
            TextField("Value in \(unit)", text: $input)
                .keyboardType(.numberPad)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                if let enteredValue { value = enteredValue; draft = nil }
            }
            .disabled(enteredValue == nil)
        } message: {
            Text("Enter \(Int(range.lowerBound))–\(Int(range.upperBound)) \(unit)." + (offBelow == nil ? "" : " Use 0 for Off."))
        }
        .onDisappear { draft = nil; dragging = false; heldDetent = nil }
    }

    private var position: Binding<Double> {
        Binding(get: { detents.position(for: displayedValue) }, set: { position in
            let snapped = detents.snap(position, held: heldDetent)
            if let snapped, snapped != heldDetent, dragging { feedback += 1 }
            heldDetent = snapped
            let next = detents.value(at: snapped ?? position)
            if dragging { draft = next } else { value = next }
        })
    }

    private func editingChanged(_ changing: Bool) {
        dragging = changing
        if changing {
            heldDetent = detents.snap(detents.position(for: value), held: nil)
        } else {
            if let draft { value = draft }
            draft = nil
            heldDetent = nil
        }
    }

    @ViewBuilder private var slider: some View {
        if #available(iOS 26.0, *) {
            Slider(value: position, in: detents.bounds) {
                Text(title)
            } currentValueLabel: {
                Text(label)
            } ticks: {
                SliderTickContentForEach(detents.positions, id: \.self) { SliderTick($0) }
            } onEditingChanged: { editingChanged($0) }
            .labelsHidden()
        } else {
            Slider(value: position, in: detents.bounds, onEditingChanged: editingChanged)
                .overlay(alignment: .bottom) {
                    GeometryReader { geometry in
                        Path { path in
                            for point in detents.positions {
                                let x = 16 + (geometry.size.width - 32) * point / detents.bounds.upperBound
                                path.move(to: CGPoint(x: x, y: geometry.size.height - 3))
                                path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                            }
                        }
                        .stroke(.secondary.opacity(0.4), lineWidth: 1)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
        }
    }

    private var valueButton: some View {
        Button {
            input = String(Int(value.rounded()))
            editing = true
        } label: {
            Text(label)
                .monospacedDigit()
                .padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Edit \(title)")
        .accessibilityValue(label)
    }
}

enum SettingFormat {
    static func meters(_ value: Double) -> String {
        "\(Int(value)) m"
    }

    static func seconds(_ value: Double) -> String {
        let seconds = Int(value)
        if seconds < 60 { return "\(seconds) s" }
        if seconds % 60 == 0 { return "\(seconds / 60) min" }
        return "\(seconds / 60) min \(seconds % 60) s"
    }

    static func count(_ value: Double) -> String {
        "\(Int(value))"
    }
}
