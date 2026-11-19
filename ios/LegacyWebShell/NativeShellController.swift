import SwiftUI
import UIKit

extension UIColor {
    // Matches the web page's --bg token in both system appearances.
    static let healthPageBackground = UIColor { traits in
        let rgb = traits.userInterfaceStyle == .dark ? 0x111214 : 0xf4f5f7
        return UIColor(red: CGFloat((rgb >> 16) & 255) / 255,
                       green: CGFloat((rgb >> 8) & 255) / 255,
                       blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}

// One WKWebView, moved between native tab containers without page reloads.
// The native tab bar overlays the web content when the page can pad its scroll end.
@MainActor
final class NativeShellController: UITabBarController, UITabBarControllerDelegate {
    private let browser: HealthBrowser
    private var pages: [HealthTab: UIViewController] = [:]
    private var navigation: [HealthTab: UINavigationController] = [:]
    private var lastState: NativeChromeState?
    private var lastReady = false
    private var lastShowsResume = false
    private var attachedPage: UIViewController?
    private var safeBottom: NSLayoutConstraint?
    private var fullBottom: NSLayoutConstraint?
    private var extendsUnderTabs = false
    private var sentInset: Int?

    init(browser: HealthBrowser) { self.browser = browser; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Use init(browser:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        view.backgroundColor = .healthPageBackground
        for tab in HealthTab.allCases {
            let page = UIViewController()
            page.view.backgroundColor = .healthPageBackground
            page.navigationItem.title = tab.title
            page.navigationItem.largeTitleDisplayMode = .never
            let nav = UINavigationController(rootViewController: page)
            nav.view.backgroundColor = .healthPageBackground
            nav.navigationBar.prefersLargeTitles = false
            nav.setNavigationBarHidden(true, animated: false)
            nav.tabBarItem = UITabBarItem(title: tab.title, image: UIImage(systemName: tab.symbol), selectedImage: UIImage(systemName: tab.symbol + ".fill") ?? UIImage(systemName: tab.symbol))
            pages[tab] = page; navigation[tab] = nav
        }
        viewControllers = HealthTab.allCases.compactMap { navigation[$0] }
        selectedIndex = 0
        setTabsHidden(true)
        browser.prompts.host = self
        attach(to: .dashboard)
        Task { browser.load() }
    }

    func apply(_ state: NativeChromeState, ready: Bool, activeWorkoutID: String?) {
        loadViewIfNeeded()
        let showsResume = ready && state.showsNavigation && activeWorkoutID != nil
            && (state.tab != .strength || state.screen == .report)
        guard state != lastState || ready != lastReady || showsResume != lastShowsResume else { return }
        lastState = state; lastReady = ready; lastShowsResume = showsResume
        let tab = state.tab
        selectedIndex = HealthTab.allCases.firstIndex(of: tab)!
        attach(to: tab)
        setTabsHidden(!ready || !state.showsTabs)
        if #available(iOS 26.0, *) {
            extendsUnderTabs = ready && state.showsTabs && state.bottomOverlay == true
        }
        setWebBottom()
        sentInset = nil
        for (key, nav) in navigation {
            nav.setNavigationBarHidden(!ready || !state.showsNavigation || key != tab, animated: false)
        }
        guard let item = pages[tab]?.navigationItem else { return }
        item.title = state.title
        if state.screen != .home {
            let back = UIBarButtonItem(image: UIImage(systemName: "chevron.backward"), style: .plain, target: self, action: #selector(goBack))
            back.accessibilityLabel = "返回训练"
            item.leftBarButtonItem = back
        } else { item.leftBarButtonItem = nil }
        if state.screen == .workout {
            let finish = UIBarButtonItem(title: "结束", style: .done, target: self, action: #selector(finishWorkout))
            finish.accessibilityLabel = "结束训练"
            let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), style: .plain, target: nil, action: nil)
            more.accessibilityLabel = "更多训练操作"
            more.menu = workoutMenu()
            item.rightBarButtonItems = [finish, more]
        } else {
            let settings = UIBarButtonItem(image: UIImage(systemName: "gearshape"), style: .plain, target: self, action: #selector(openSettings))
            settings.accessibilityLabel = "设置"
            if showsResume {
                let resume = UIBarButtonItem(title: "继续训练", style: .plain, target: self, action: #selector(resumeWorkout))
                resume.accessibilityHint = "打开正在记录的训练"
                item.rightBarButtonItems = [settings, resume]
            } else {
                item.rightBarButtonItems = [settings]
            }
        }
        view.setNeedsLayout()
    }

    private func attach(to tab: HealthTab) {
        guard let page = pages[tab], attachedPage !== page else { return }
        let web = browser.webView
        safeBottom?.isActive = false
        fullBottom?.isActive = false
        attachedPage?.setContentScrollView(nil, for: .bottom)
        web.removeFromSuperview()
        page.view.addSubview(web)
        web.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: page.view.safeAreaLayoutGuide.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: page.view.safeAreaLayoutGuide.trailingAnchor),
            web.topAnchor.constraint(equalTo: page.view.safeAreaLayoutGuide.topAnchor),
        ])
        safeBottom = web.bottomAnchor.constraint(equalTo: page.view.safeAreaLayoutGuide.bottomAnchor)
        fullBottom = web.bottomAnchor.constraint(equalTo: page.view.bottomAnchor)
        page.setContentScrollView(web.scrollView, for: .bottom)
        attachedPage = page
        setWebBottom()
    }

    private func setWebBottom() {
        if extendsUnderTabs {
            safeBottom?.isActive = false
            fullBottom?.isActive = true
        } else {
            fullBottom?.isActive = false
            safeBottom?.isActive = true
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard browser.pageState == .ready, let page = attachedPage else { return }
        let inset = extendsUnderTabs ? Int(ceil(page.view.safeAreaInsets.bottom)) : 0
        guard sentInset != inset else { return }
        sentInset = inset
        browser.setTabBarInset(inset)
    }
    private func setTabsHidden(_ hidden: Bool) {
        if #available(iOS 26.0, *) { setTabBarHidden(hidden, animated: false) }
        else { tabBar.isHidden = hidden; view.setNeedsLayout() }
    }
    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        guard let tab = navigation.first(where: { $0.value === viewController })?.key else { return false }
        browser.sendAction("selectTab", values: ["tab": tab.rawValue])
        // Commit the native tab after React acknowledges its selected page.
        return false
    }
    @objc private func goBack() { browser.sendWorkoutAction("back") }
    @objc private func finishWorkout() { browser.sendWorkoutAction("finishWorkout") }
    @objc private func openSettings() { browser.showingSettings = true }
    @objc private func resumeWorkout() { browser.openActiveWorkout() }

    private func workoutMenu() -> UIMenu {
        let edit = UIAction(title: "重命名训练", image: UIImage(systemName: "pencil")) { [weak browser = self.browser] _ in browser?.renameWorkout() }
        let notes = UIAction(title: "训练笔记", image: UIImage(systemName: "square.and.pencil")) { [weak browser = self.browser] _ in browser?.sendWorkoutAction("workoutNotes") }
        let movement = UIAction(title: "动作设置", image: UIImage(systemName: "slider.horizontal.3")) { [weak browser = self.browser] _ in browser?.sendWorkoutAction("movementSettings") }
        let settings = UIAction(title: "设置", image: UIImage(systemName: "gearshape")) { [weak browser = self.browser] _ in browser?.showingSettings = true }
        let discard = UIAction(title: "放弃本次训练", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak browser = self.browser] _ in browser?.sendWorkoutAction("discardWorkout") }
        return UIMenu(children: [UIMenu(options: .displayInline, children: [edit, notes, movement]),
                                 UIMenu(options: .displayInline, children: [settings]),
                                 UIMenu(options: .displayInline, children: [discard])])
    }
}

@MainActor
struct NativeShellView: UIViewControllerRepresentable {
    @ObservedObject var browser: HealthBrowser
    func makeUIViewController(context: Context) -> NativeShellController { NativeShellController(browser: browser) }
    func updateUIViewController(_ controller: NativeShellController, context: Context) {
        controller.apply(browser.chrome, ready: browser.chromeReady && browser.pageState == .ready, activeWorkoutID: browser.activeWorkoutID)
    }
}
