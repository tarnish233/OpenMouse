import CoreGraphics

/// The three representations macOS carries for one scroll axis.
///
/// Apple documents `DeltaAxis` and `PointDelta` as integer fields. `FixedPtDelta` stores a
/// signed 16.16 value and is exposed losslessly through the double accessor. Keeping these
/// identifiers and accessors together prevents call sites from gradually inventing conflicting
/// field semantics.
struct ScrollAxisFields {
    struct Values {
        let line: Int64
        let point: Int64
        let fixedPoint: Double

        var negated: Values {
            Values(line: -line, point: -point, fixedPoint: -fixedPoint)
        }

        /// Mos's precedence: pixel delta first, fixed-point delta second, line count last.
        var preferred: Double {
            if point != 0 { return Double(point) }
            if fixedPoint != 0 { return fixedPoint }
            return Double(line)
        }
    }

    let line: CGEventField
    let point: CGEventField
    let fixedPoint: CGEventField

    func read(from event: CGEvent) -> Values {
        Values(
            line: event.getIntegerValueField(line),
            point: event.getIntegerValueField(point),
            fixedPoint: event.getDoubleValueField(fixedPoint)
        )
    }

    func reverse(on event: CGEvent) {
        write(read(from: event).negated, on: event)
    }

    func write(_ values: Values, on event: CGEvent) {
        event.setIntegerValueField(line, value: values.line)
        event.setIntegerValueField(point, value: values.point)
        event.setDoubleValueField(fixedPoint, value: values.fixedPoint)
    }

    func clear(on event: CGEvent) {
        write(Values(line: 0, point: 0, fixedPoint: 0), on: event)
    }

    /// PointDelta is the integral pixel representation; FixedPtDelta retains the fractional
    /// remainder. This matches Core Graphics's field types instead of relying on implicit
    /// conversion through the wrong setter.
    func setPixelDelta(_ value: Double, on event: CGEvent) {
        let safeValue = value.isFinite ? value : 0
        let integral: Int64
        if safeValue >= Double(Int64.max) {
            integral = .max
        } else if safeValue <= Double(Int64.min) {
            integral = .min
        } else {
            integral = Int64(safeValue)
        }
        event.setIntegerValueField(point, value: integral)
        event.setDoubleValueField(fixedPoint, value: safeValue)
    }
}

enum ScrollEventFields {
    static let vertical = ScrollAxisFields(
        line: .scrollWheelEventDeltaAxis1,
        point: .scrollWheelEventPointDeltaAxis1,
        fixedPoint: .scrollWheelEventFixedPtDeltaAxis1
    )
    static let horizontal = ScrollAxisFields(
        line: .scrollWheelEventDeltaAxis2,
        point: .scrollWheelEventPointDeltaAxis2,
        fixedPoint: .scrollWheelEventFixedPtDeltaAxis2
    )
}
