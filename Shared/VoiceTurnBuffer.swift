import Foundation

/// Keeps the start of a held utterance while Realtime is connecting. All access is
/// on the phone's main queue. Audio stays in RAM and is cleared on sleep/failure.
public struct VoiceTurnBuffer {
    public private(set) var recordedBytes = 0
    public private(set) var overflowed = false
    private var pending: [Data] = []
    private var pendingBytes = 0
    public init() {}
    public mutating func begin() { self = Self() }
    public var canCommit: Bool { !overflowed && recordedBytes >= 4800 } // 100 ms, 24 kHz PCM16 mono
    public mutating func append(_ data: Data, ready: Bool) -> Data? {
        guard !overflowed else { return nil }
        recordedBytes += data.count
        if ready { return data }
        guard pendingBytes + data.count <= 960_000 else { overflowed = true; pending = []; return nil }
        pending.append(data); pendingBytes += data.count
        return nil
    }
    public mutating func connected() -> [Data] {
        let data = pending; pending = []; pendingBytes = 0
        return overflowed ? [] : data
    }
}
