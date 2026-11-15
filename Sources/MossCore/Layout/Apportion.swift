/// Divides `extent` between parts that would like the `preferred` lengths, which add up to it,
/// giving each at least its minimum. Parts raised to their minimum take the space from the
/// others in proportion to what those would like; when even the minimums do not fit, the extent
/// is shared in proportion to them.
func apportion(_ extent: Double, preferred: [Double], minimums: [Double]) -> [Double] {
    precondition(preferred.count == minimums.count)
    if zip(preferred, minimums).allSatisfy({ $0 >= $1 }) {
        return preferred
    }
    let required = minimums.reduce(0, +)
    if required > extent {
        return minimums.map { extent * $0 / required }
    }

    var atMinimum = Array(repeating: false, count: preferred.count)
    while true {
        let free = preferred.indices.filter { !atMinimum[$0] }
        let remaining = extent - preferred.indices.filter { atMinimum[$0] }.reduce(0) { $0 + minimums[$1] }
        let weight = free.reduce(0) { $0 + preferred[$1] }
        func share(_ index: Int) -> Double {
            weight > 0 ? remaining * preferred[index] / weight : remaining / Double(free.count)
        }
        let tooSmall = free.filter { share($0) < minimums[$0] }
        guard tooSmall.isEmpty else {
            for index in tooSmall { atMinimum[index] = true }
            continue
        }
        return preferred.indices.map { atMinimum[$0] ? minimums[$0] : share($0) }
    }
}
