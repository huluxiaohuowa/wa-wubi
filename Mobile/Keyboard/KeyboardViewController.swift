import SwiftUI
import UIKit

@MainActor final class KeyboardViewController: UIInputViewController {
    private static let sharedStore = MobileStore(loadSnapshotImmediately: false, keepsLibraryLists: false)
    private var store: MobileStore { Self.sharedStore }
    private lazy var session = KeyboardSession(store: store)
    private var editingDocument = false
    private var heightConstraint: NSLayoutConstraint?

    private var usesSystemBackdrop: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    private var dockedHeight: CGFloat {
        guard KeyboardLayout.usesPhoneInsets(width: view.bounds.width, systemBackdrop: usesSystemBackdrop) else {
            return KeyboardLayout.dockedHeight
        }
        return KeyboardLayout.dockedHeight - KeyboardLayout.topPadding
            - KeyboardLayout.bottomPadding + KeyboardLayout.phoneBottomPadding
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        session.hasFullAccess = { [weak self] in self?.hasFullAccess == true }
        session.insert = { [weak self] text in self?.editDocument { $0.insertText(text) } }
        session.deleteBackward = { [weak self] in self?.editDocument { $0.deleteBackward() } }
        session.adjustCursor = { [weak self] offset in
            self?.editDocument { $0.adjustTextPosition(byCharacterOffset: offset) }
        }
        session.playClick = { [weak self] in
            guard self?.store.keySound == true else { return }
            UIDevice.current.playInputClick()
        }

        let content = KeyboardSurface(session: session, store: store,
                                      globe: { [weak self] in InputModeButton(controller: self) },
                                      dockedHeight: KeyboardLayout.dockedHeight, usesSystemBackdrop: usesSystemBackdrop,
                                      onDismissKeyboard: { [weak self] in self?.dismissKeyboard() })
        let host = UIHostingController(rootView: content)
        host.safeAreaRegions = []
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        let height = view.heightAnchor.constraint(equalToConstant: dockedHeight)
        height.priority = .init(900)
        height.isActive = true
        heightConstraint = height
        host.didMove(toParent: self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Task { [store] in await store.prepareForKeyboard() }
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        if view.window != nil {
            let height = dockedHeight
            if heightConstraint?.constant != height { heightConstraint?.constant = height }
            let showGlobe = needsInputModeSwitchKey
            if session.showGlobe != showGlobe { session.showGlobe = showGlobe }
        }
    }

    override func textWillChange(_ textInput: (any UITextInput)?) {
        super.textWillChange(textInput)
        if !editingDocument { session.reset() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        session.reset()
    }

    private func editDocument(_ action: (any UITextDocumentProxy) -> Void) {
        editingDocument = true
        defer { editingDocument = false }
        action(textDocumentProxy)
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        MobileCandidateGlyphs.clearCache()
    }
}

private struct InputModeButton: UIViewRepresentable {
    weak var controller: KeyboardViewController?

    func makeUIView(context: Context) -> HoldToSwitchButton {
        let button = HoldToSwitchButton(type: .system)
        button.setImage(UIImage(systemName: "globe"), for: .normal)
        button.accessibilityLabel = "切换输入法"
        button.accessibilityHint = "长按切换到下一个输入法"
        let hold = UILongPressGestureRecognizer(target: button, action: #selector(HoldToSwitchButton.switchAfterHold(_:)))
        button.addGestureRecognizer(hold)
        return button
    }

    func updateUIView(_ uiView: HoldToSwitchButton, context: Context) {
        uiView.controller = controller
    }
}

private final class HoldToSwitchButton: UIButton {
    weak var controller: KeyboardViewController?

    @objc func switchAfterHold(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .ended, bounds.contains(gesture.location(in: self)) else { return }
        controller?.advanceToNextInputMode()
    }

    override func accessibilityActivate() -> Bool {
        guard let controller else { return false }
        controller.advanceToNextInputMode()
        return true
    }
}
