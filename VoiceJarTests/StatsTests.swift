import XCTest
@testable import VoiceBee

/// 单元测试 — StatsStore 持久化统计 + DurationFormat 时长格式化.
///
/// 覆盖范围:
/// - A 节:record() 累加数学 + firstUsedAt set-once 语义
/// - B 节:派生指标 charsPerMinute / timeSavedSeconds(含除零保护 + max(0) 下限)
/// - C 节:UserDefaults 持久化 round-trip + **reset 复活回归**(save() 必须
///   removeObject stats_firstUsedAt,否则 reset 后重启 firstUsedAt 复活)
/// - D 节:DurationFormat.compact 边界表
final class StatsTests: XCTestCase {

    // MARK: - Test isolated UserDefaults

    /// 隔离的 defaults — 每个测试用独立 suite,避免污染主进程
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "StatsTests-\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - A 节:record() 累加

    func testInitialStateIsZero() {
        let store = StatsStore(defaults: defaults)
        XCTAssertEqual(store.totalRecords, 0)
        XCTAssertEqual(store.totalChars, 0)
        XCTAssertEqual(store.totalSeconds, 0)
        XCTAssertNil(store.firstUsedAt)
    }

    func testRecordAccumulatesAcrossCalls() {
        let store = StatsStore(defaults: defaults)
        store.record(chars: 100, seconds: 30)
        store.record(chars: 50, seconds: 10.5)
        store.record(chars: 0, seconds: 2)
        XCTAssertEqual(store.totalRecords, 3)
        XCTAssertEqual(store.totalChars, 150)
        XCTAssertEqual(store.totalSeconds, 42.5, accuracy: 0.0001)
        XCTAssertNotNil(store.firstUsedAt)
    }

    func testFirstUsedAtSetOnce() {
        // firstUsedAt 只在首次 record 时写入,后续 record 不覆盖
        let store = StatsStore(defaults: defaults)
        store.record(chars: 10, seconds: 5)
        let first = store.firstUsedAt
        XCTAssertNotNil(first)
        store.record(chars: 20, seconds: 8)
        store.record(chars: 30, seconds: 12)
        XCTAssertEqual(store.firstUsedAt, first, "后续 record 不应改写 firstUsedAt")
    }

    // MARK: - B 节:派生指标

    func testCharsPerMinuteZeroSecondsGuard() {
        // totalSeconds == 0 → 除零保护,返回 0
        let store = StatsStore(defaults: defaults)
        XCTAssertEqual(store.charsPerMinute, 0)
    }

    func testCharsPerMinuteFormula() {
        // 120 字 / 60 秒 = 120 字/分钟
        let store = StatsStore(defaults: defaults)
        store.record(chars: 120, seconds: 60)
        XCTAssertEqual(store.charsPerMinute, 120, accuracy: 0.0001)
        // 累加后:180 字 / 90 秒 = 120 字/分钟
        store.record(chars: 60, seconds: 30)
        XCTAssertEqual(store.charsPerMinute, 120, accuracy: 0.0001)
    }

    func testTimeSavedSecondsFormula() {
        // 手打 60 字/分钟 → 120 字手打需 120 秒;实际录音 30 秒 → 省 90 秒
        let store = StatsStore(defaults: defaults)
        store.record(chars: 120, seconds: 30)
        XCTAssertEqual(store.timeSavedSeconds, 90, accuracy: 0.0001)
    }

    func testTimeSavedSecondsFlooredAtZero() {
        // 说得比打字还慢(10 字用了 100 秒,手打只需 10 秒)→ max(0) 下限,不出负数
        let store = StatsStore(defaults: defaults)
        store.record(chars: 10, seconds: 100)
        XCTAssertEqual(store.timeSavedSeconds, 0)
    }

    // MARK: - C 节:UserDefaults 持久化

    func testPersistenceRoundTrip() {
        // 第一个实例写入 → 第二个实例(同 suite)load 出同样的值,模拟 app 重启
        let store1 = StatsStore(defaults: defaults)
        store1.record(chars: 100, seconds: 30)
        store1.record(chars: 50, seconds: 15)
        let firstUsed = store1.firstUsedAt

        let store2 = StatsStore(defaults: defaults)
        XCTAssertEqual(store2.totalRecords, 2)
        XCTAssertEqual(store2.totalChars, 150)
        XCTAssertEqual(store2.totalSeconds, 45, accuracy: 0.0001)
        XCTAssertEqual(store2.firstUsedAt, firstUsed)
    }

    func testResetClearsInMemoryState() {
        let store = StatsStore(defaults: defaults)
        store.record(chars: 100, seconds: 30)
        store.reset()
        XCTAssertEqual(store.totalRecords, 0)
        XCTAssertEqual(store.totalChars, 0)
        XCTAssertEqual(store.totalSeconds, 0)
        XCTAssertNil(store.firstUsedAt)
    }

    /// **回归**:reset() 后 save() 必须 removeObject stats_firstUsedAt.
    /// 修复前的 bug:reset 只清内存,defaults 里旧日期残留 → 重启 load() 复活.
    func testResetFirstUsedAtDoesNotResurrectAfterRelaunch() {
        let store1 = StatsStore(defaults: defaults)
        store1.record(chars: 100, seconds: 30)
        XCTAssertNotNil(store1.firstUsedAt)
        store1.reset()

        // 模拟重启:同 suite 新建实例
        let store2 = StatsStore(defaults: defaults)
        XCTAssertNil(store2.firstUsedAt, "reset 后重启 firstUsedAt 不应复活")
        XCTAssertEqual(store2.totalRecords, 0)
        XCTAssertEqual(store2.totalChars, 0)
        XCTAssertEqual(store2.totalSeconds, 0)
    }

    // MARK: - D 节:DurationFormat.compact 边界表

    func testCompactSecondsRounding() {
        // Int(seconds.rounded()) — 四舍五入到整秒
        XCTAssertEqual(DurationFormat.compact(seconds: 0), "0s")
        XCTAssertEqual(DurationFormat.compact(seconds: 45.4), "45s")
        XCTAssertEqual(DurationFormat.compact(seconds: 45.5), "46s")
    }

    func testCompactUnderSixtySeconds() {
        XCTAssertEqual(DurationFormat.compact(seconds: 59), "59s")
    }

    func testCompactFiftyNinePointSixRoundsUpToOneMinute() {
        // 59.6 → rounded 60 → 跨入分钟分支,输出 "1m" 而不是 "60s"
        XCTAssertEqual(DurationFormat.compact(seconds: 59.6), "1m")
    }

    func testCompactExactSixtySeconds() {
        XCTAssertEqual(DurationFormat.compact(seconds: 60), "1m")
    }

    func testCompactMinutesAndSeconds() {
        XCTAssertEqual(DurationFormat.compact(seconds: 312), "5m 12s")  // 5*60+12
        XCTAssertEqual(DurationFormat.compact(seconds: 61), "1m 1s")
    }

    func testCompactExactMinutes() {
        // 整分钟不带 "0s" 尾巴
        XCTAssertEqual(DurationFormat.compact(seconds: 120), "2m")
        XCTAssertEqual(DurationFormat.compact(seconds: 3540), "59m")  // 59m,还没到小时分支
    }

    func testCompactExactHours() {
        XCTAssertEqual(DurationFormat.compact(seconds: 3600), "1h")
        XCTAssertEqual(DurationFormat.compact(seconds: 7200), "2h")
    }

    func testCompactHoursAndMinutes() {
        XCTAssertEqual(DurationFormat.compact(seconds: 4980), "1h 23m")  // 3600+23*60
        XCTAssertEqual(DurationFormat.compact(seconds: 3660), "1h 1m")
    }

    func testCompactHoursBranchDropsSeconds() {
        // 小时分支只显示 h+m,残余秒数丢弃:3659s = 1h 0m 59s → m=0 → "1h"(当前契约如此)
        XCTAssertEqual(DurationFormat.compact(seconds: 3659), "1h")
    }
}
