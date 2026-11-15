/// Identifies a tab group.
public struct GroupID: Hashable, Comparable, Sendable, Codable {
    public let rawValue: Int

    public init(_ rawValue: Int) { self.rawValue = rawValue }

    public static func < (lhs: GroupID, rhs: GroupID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A tab group: windows sharing one place in the layout, shown one at a time as tabs.
///
/// Only the active member takes part in the layout; the others are kept out of sight until
/// they are activated.
public struct WindowGroup: Hashable, Sendable, Identifiable {
    public let id: GroupID
    /// Members in tab order.
    public var members: [WindowID]
    public var active: WindowID

    public init(id: GroupID, members: [WindowID], active: WindowID) {
        self.id = id
        self.members = members
        self.active = active
    }

    public var activeIndex: Int { members.firstIndex(of: active) ?? 0 }

    /// The member `offset` places after the active one, wrapping around.
    public func member(offsetFromActive offset: Int) -> WindowID {
        let count = members.count
        return members[((activeIndex + offset) % count + count) % count]
    }
}
