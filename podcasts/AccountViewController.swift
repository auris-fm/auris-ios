import PocketCastsServer
import PocketCastsUtils
import UIKit

class AccountViewController: UIViewController, ChangeEmailDelegate {
    enum TableRow { case voiceSharing, upgradeView, changeAvatar, changeEmail, changePassword, upgradeAccount, newsletter, cancelSubscription, logout, deleteAccount, privacyPolicy, termsOfUse, supporterContributions }
    var tableData: [[TableRow]] = [[.changeEmail, .changePassword, .newsletter], [.privacyPolicy, .termsOfUse], [.logout], [.deleteAccount]]

    static let newsletterCellId = "NewsletterCellId"
    static let actionCellId = "AccountActionCellId"

    let model = PlusAccountPromptViewModel()

    private var isUsernamePasswordLogin: Bool {
        ServerSettings.syncingPassword() != nil
    }

    @IBOutlet var tableView: ThemeableTable! {
        didSet {
            tableView.applyInsetForMiniPlayer()
            tableView.register(UINib(nibName: "NewsletterCell", bundle: nil), forCellReuseIdentifier: AccountViewController.newsletterCellId)
            tableView.register(UINib(nibName: "AccountActionCell", bundle: nil), forCellReuseIdentifier: AccountViewController.actionCellId)
        }
    }

    var upgradePromptViewSize: CGSize? = nil {
        didSet {
            tableView.reloadData()
        }
    }

    lazy var headerViewModel: AccountHeaderViewModel = {
        let viewModel = AccountHeaderViewModel()

        viewModel.viewContentSizeChanged = { [weak self] in
            self?.updatedHeaderContentView.frame = .init(x: 0, y: 0, width: self?.headerViewModel.contentSize?.width ?? 0, height: self?.headerViewModel.contentSize?.height ?? 0)
            self?.tableView.reloadData()
        }

        return viewModel
    }()

    lazy var updatedHeaderContentView: UIView = {
        let headerView = AccountHeaderView(viewModel: headerViewModel)

        let view = headerView.themedUIView
        view.backgroundColor = AppTheme.colorForStyle(.primaryUi03, themeOverride: nil)
        self.tableView.themeStyle =  ThemeStyle.primaryUi03

        return view
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.accountTitle

        NotificationCenter.default.addObserver(self, selector: #selector(iapProductsUpdated), name: ServerNotifications.iapProductsUpdated, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(iapProductsFailed), name: ServerNotifications.iapProductsFailed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(subscriptionStatusChanged), name: ServerNotifications.subscriptionStatusChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: Constants.Notifications.themeChanged, object: nil)

        tableView.tableHeaderView = updatedHeaderContentView
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateDisplayedData()
        title = L10n.accountTitle
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        title = ""
        if FeatureFlag.newAccountUpgradePromptFlow.enabled {
            OnboardingFlow.shared.reset()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        AppTheme.defaultStatusBarStyle()
    }

    @objc private func subscriptionStatusChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            self.updateDisplayedData()
        }
    }

    private func updateDisplayedData() {
        headerViewModel.update()

        // Show the upsell if the users subscription is expiring in the next 30 days
        let isExpiring = (SubscriptionHelper.timeToSubscriptionExpiry() ?? .infinity) < Constants.Limits.maxSubscriptionExpirySeconds

        // Show the 'Upgrade Account' if the user has an active subscription that isn't patron.
        // Hide the cell if we're already showing the big upgrade prompt
        let upgradeRow = (SubscriptionHelper.activeTier == .plus && !isExpiring) ? TableRow.upgradeAccount : nil

        // Only accounts created with username/password can change email/password
        var accountOptions: [TableRow]
        if isUsernamePasswordLogin {
            accountOptions = [.changeEmail, .changePassword, upgradeRow, .newsletter].compactMap { $0 }
        } else {
            accountOptions = [upgradeRow, .newsletter].compactMap { $0 }
        }
        if headerViewModel.profile.isLoggedIn {
            accountOptions.insert(.changeAvatar, safelyAt: 0)
            if VoiceSharingSettingsModel.surfaceEnabled { accountOptions.append(.voiceSharing) }
        }
        if SubscriptionHelper.hasActiveSubscription() {
            var newTableRows: [[TableRow]] = [accountOptions, [.privacyPolicy, .termsOfUse], [.logout], [.deleteAccount]]

            if SubscriptionHelper.hasRenewingSubscription() {
                newTableRows[0].append(.cancelSubscription)
            }

            if !SubscriptionHelper.hasRenewingSubscription() && !SubscriptionHelper.hasLifetimeGift() && isExpiring {
                newTableRows[0].insert(.upgradeView, at: 0)
            }

            updateTableRows(newRows: newTableRows)
        } else {
            var newTableRows: [[TableRow]] = [accountOptions, [.privacyPolicy, .termsOfUse], [.logout], [.deleteAccount]]

            if let subscriptionPodcasts = SubscriptionHelper.subscriptionPodcasts(), !subscriptionPodcasts.isEmpty {
                newTableRows[0].insert(.supporterContributions, at: 0)
            }

            newTableRows[0].insert(.upgradeView, at: 0)

            updateTableRows(newRows: newTableRows)
        }
    }

    @objc func iapProductsUpdated() {
        updateDisplayedData()
    }

    @objc func iapProductsFailed() {
        updateDisplayedData()
    }

    private func updateTableRows(newRows: [[TableRow]]) {
        guard tableData != newRows else { return }

        tableData = newRows
        tableView.reloadData()
    }

    // MARK: - Actions

    @objc func newsletterOptInChanged(_ sender: UISwitch) {
        Analytics.track(.newsletterOptInChanged, properties: ["enabled": sender.isOn, "source": "profile"])

        ServerSettings.setMarketingOptIn(sender.isOn)
        ServerSettings.syncSettings()
    }

    @IBAction func learnMoreTapped(_ sender: Any) {
        NavigationManager.sharedManager.navigateTo(NavigationManager.showPlusMarketingPageKey, data: nil)
    }

    @objc func themeDidChange() {
        updateDisplayedData() // in case the expiry text color neds updating
    }

    // MARK: Change email delegate

    func emailChanged() {
        DispatchQueue.main.async {
            self.headerViewModel.update()
        }
    }
}

extension AccountViewController {
    /// Row selection rechecks permission before constructing account dependencies; never builds voice/queue.
    @MainActor
    static func makeVoiceSharingController(
        surfaceEnabled: @escaping () -> Bool = { VoiceSharingSettingsModel.surfaceEnabled },
        signedIn: () -> Bool = { SyncManager.isUserLoggedIn() },
        accountModel: (() -> VoiceSharingAccountModel)? = nil,
        localModel: () -> VoiceSharingSettingsModel? = { VoiceControlService.shared?.voiceSharingLifetime?.settingsModel }
    ) -> VoiceSharingAccountController? {
        guard surfaceEnabled(), signedIn() else { return nil }
        let local = localModel()
        let account = accountModel?() ?? VoiceSharingAccountModel(
            client: VoiceSharingAccountClient(tokenProvider: CloudTokenProviderRouter.provider()),
            purgeLocal: local.map { model in { model.deletePendingRecordingsOnThisDevice() } })
        return VoiceSharingAccountController(accountModel: account, localModel: local, surfaceEnabled: surfaceEnabled)
    }
}
