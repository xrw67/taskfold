import AppKit

/// 应用级键盘路由（NSEvent local monitor）。
///
/// 为什么不用菜单快捷键 / .onKeyPress：
/// - 无修饰键的 Tab/⇧Tab 会被 macOS 焦点循环（insertTab:/insertBacktab:）消费，
///   CommandMenu 的 key equivalent 收不到；
/// - .onKeyPress 依赖所挂视图恰好是 first responder，焦点在侧边栏/搜索框时收不到。
/// local monitor 在事件分发前统一接管，两条路径的坑都绕开。
@MainActor
final class KeyboardRouter {
    static let shared = KeyboardRouter()

    private var monitor: Any?

    private init() {}

    /// App 生命周期内安装一次（重复调用无害）
    func install(_ appState: AppState) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak appState] event in
            guard let appState else { return event }
            // local monitor 固定在主线程回调
            let swallowed = MainActor.assumeIsolated {
                appState.swallowKeyEvent(event)
            }
            return swallowed ? nil : event
        }
    }
}
