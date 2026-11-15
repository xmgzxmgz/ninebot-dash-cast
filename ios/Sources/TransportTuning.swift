import Foundation

/// 拥塞控制：宁可降码率、降帧率，也不要「一丢包就补关键帧」。
///
/// 原实现在发送缓冲区满时丢帧后立刻补一个关键帧，而关键帧通常是非关键帧的 5~8 倍大，
/// 于是拥塞时反而制造更大的瞬时码率，形成「越卡越卡」的雪崩。
/// 这里改成三步降级：先砍码率，再隔帧，最后才是等仪表自己请求关键帧。
///
/// 所有方法内部加锁，可以从任意线程调用（当前的调用点分别在主线程与发送队列上）。
final class CongestionGovernor {
    private let lock = NSLock()
    private let baseBitrate: Int
    private var level = 0
    private var lastChange = Date.distantPast
    private var stableSince = Date()
    private var skipToggle = false

    /// 每级对应的码率系数：正常 / 轻拥塞 / 中拥塞 / 重拥塞
    private let ratios: [Double] = [1.0, 0.75, 0.5, 0.35]

    init(baseBitrate: Int) {
        self.baseBitrate = max(200, baseBitrate)
    }

    /// 以 RTT 与仪表丢包报告为依据评估拥塞程度。
    /// - Returns: 码率发生变化时返回新的目标码率（bps），否则 nil。
    @discardableResult
    func sample(rttMs: Int, lossReported: Bool = false) -> Int? {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        let bad = lossReported || rttMs > 80
        let good = !lossReported && rttMs > 0 && rttMs < 40

        if bad, now.timeIntervalSince(lastChange) > 2, level < ratios.count - 1 {
            level += 1
            lastChange = now
            stableSince = now
            return targetBitrateLocked()
        }
        if good, level > 0, now.timeIntervalSince(stableSince) > 8 {
            level -= 1
            lastChange = now
            stableSince = now
            return targetBitrateLocked()
        }
        return nil
    }

    var targetBitrate: Int {
        lock.lock()
        defer { lock.unlock() }
        return targetBitrateLocked()
    }

    var currentLevel: Int {
        lock.lock()
        defer { lock.unlock() }
        return level
    }

    /// 中拥塞以上隔帧发送：一帧不发比发一帧糊的好，也能让仪表的解码队列排空。
    func shouldSkipFrame() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard level >= 2 else { return false }
        skipToggle.toggle()
        return skipToggle
    }

    /// 切预设/重启时复位。
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        level = 0
        lastChange = .distantPast
        stableSince = Date()
        skipToggle = false
    }

    private func targetBitrateLocked() -> Int {
        let ratio = ratios[min(level, ratios.count - 1)]
        return max(200, Int(Double(baseBitrate) * ratio))
    }
}

/// 静止画面闸门：同一张图不必每帧重编码。
///
/// 仪表收到新帧才刷新，不发帧它就保持画面，所以静态图按「每 N 帧刷一次」即可，
/// Wi-Fi 占用与仪表解码负载都能降一个数量级。
struct StaticFrameGate {
    /// 多少帧刷一次（20fps + 20 → 每秒 1 次）
    var refreshFrames: Int = 20
    private var lastEncodedFrame: Int64 = .min

    mutating func shouldEncode(frameIndex: Int64) -> Bool {
        if lastEncodedFrame == .min || frameIndex - lastEncodedFrame >= Int64(max(1, refreshFrames)) {
            lastEncodedFrame = frameIndex
            return true
        }
        return false
    }

    mutating func reset() {
        lastEncodedFrame = .min
    }
}
