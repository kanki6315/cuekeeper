import CoreData
import SwiftUI

/// A focused native form sheet on iPad; a full-height setup flow on iPhone.
struct FirstLaunchPresentation: View {
    let onFinish: () -> Void
    var body: some View {
        // Device idiom stays stable across iPad window resizing and Split View.
        // A size-class branch recreates the flow and loses navigation and form state.
        if UIDevice.current.userInterfaceIdiom == .pad {
            RootView().sheet(isPresented: .constant(true)) {
                FirstLaunchView(onFinish: onFinish)
                    .presentationSizing(.form)
                    .interactiveDismissDisabled()
            }
        } else {
            FirstLaunchView(onFinish: onFinish)
        }
    }
}

/// Setup is device-local; CloudKit continues importing independently of this navigation.
struct FirstLaunchView: View {
    enum Step: Hashable { case preferences, calendar, backups }
    @EnvironmentObject private var persistence: PersistenceController
    @FetchRequest(sortDescriptors: []) private var jobs: FetchedResults<Job>
    @FetchRequest(sortDescriptors: []) private var clients: FetchedResults<Client>
    @State private var path: [Step] = []
    let onFinish: () -> Void
    private var returning: Bool { !jobs.isEmpty || !clients.isEmpty }

    var body: some View {
        NavigationStack(path: $path) {
            welcome
                .navigationDestination(for: Step.self) { step in
                    Group {
                        switch step {
                        case .preferences:
                            LaunchPage {
                                LaunchHeading("Make Cuekeeper yours")
                                PreferenceFields().multilineTextAlignment(.leading)
                            } actions: {
                                Button("Continue") { path.append(.calendar) }
                                    .buttonStyle(LaunchPrimaryButton()).accessibilityIdentifier("setup-preferences-continue")
                            }
                        case .calendar:
                            LaunchPage {
                                Text("See your work in Calendar").font(.title2.bold())
                                Image(systemName: "calendar").font(.system(size: 76, weight: .regular))
                                    .foregroundStyle(Color.accentColor).accessibilityHidden(true).padding(.vertical, 24)
                                Text("Publish event dates and confirmed sessions to a calendar you choose.")
                                    .foregroundStyle(Color("SecondaryText"))
                            } actions: {
                                NavigationLink { LaunchCalendarConnection(onFinish: onFinish) } label: { Text("Set up Calendar") }
                                    .buttonStyle(LaunchPrimaryButton())
                                Button("Not now", action: onFinish).buttonStyle(LaunchSecondaryButton())
                                    .accessibilityIdentifier("setup-skip-calendar")
                            }
                        case .backups:
                            backupRecovery
                        }
                    }
                    .toolbar { ToolbarItem(placement: .principal) { BrandLockup() } }
                }
        }
        .tint(Color("AccentColor"))
    }

    @ViewBuilder private var backupRecovery: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            FirstLaunchBackupView(cloud: FixtureBackups.shared) { path = [.preferences] }
        } else {
            FirstLaunchBackupView { path = [.preferences] }
        }
        #else
        FirstLaunchBackupView { path = [.preferences] }
        #endif
    }

    private var welcome: some View {
        LaunchPage {
            VStack(spacing: 16) {
                CuekeeperMark().fill(Color.accentColor, style: FillStyle(eoFill: true))
                    .frame(width: 100, height: 116).accessibilityHidden(true)
                Text("Cuekeeper").font(.largeTitle.bold()).foregroundStyle(Color.accentColor)
            }.padding(.top, 28).padding(.bottom, 30)
            Text(returning ? "Welcome back" : "Your work,\nkept together.")
                .font(.largeTitle.bold()).accessibilityIdentifier("setup-welcome-heading")
            Spacer(minLength: 32)
            VStack(spacing: 12) {
                HStack(spacing: 16) {
                    Image(systemName: persistence.syncActivity.offline ? "icloud.slash" : "icloud")
                        .font(.title).foregroundStyle(Color.accentColor)
                    if persistence.syncActivity.isBusy { ProgressView() }
                }.accessibilityHidden(true)
                Text(persistence.syncActivity.accountIssue == nil ? persistence.syncActivity.launchMessage(hasRecords: returning) : persistence.accountStatus)
                    .foregroundStyle(Color("SecondaryText")).accessibilityIdentifier("setup-sync-status")
                if !returning && !persistence.syncActivity.needsAttention && !persistence.syncActivity.offline {
                    Text("You can continue while we check.").font(.footnote).foregroundStyle(Color("SecondaryText"))
                }
            }
        } actions: {
            Button(returning ? "Continue setup" : "Get started") { path.append(.preferences) }
                .buttonStyle(LaunchPrimaryButton()).accessibilityIdentifier("setup-start")
            Button("Recover from a backup") { path.append(.backups) }
                .frame(minHeight: 44).accessibilityIdentifier("setup-backups")
        }
    }
}

/// Scrolls at large text sizes, while keeping primary actions in the native safe area.
struct LaunchPage<Content: View, Actions: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) { content }
                    .frame(maxWidth: 480)
                    .frame(minHeight: max(0, geometry.size.height - 48), alignment: .top)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 24)
            }
        }
        .multilineTextAlignment(.center)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) { actions }
                .frame(maxWidth: 480).padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 16)
                .frame(maxWidth: .infinity).background(Color("PageBackground"))
        }
        .background(Color("PageBackground"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LaunchHeading: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title).font(.title.bold()).multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading).accessibilityAddTraits(.isHeader)
    }
}

struct LaunchPrimaryButton: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(action: configuration.trigger) { configuration.label.frame(maxWidth: .infinity, minHeight: 28) }
            .buttonStyle(DaybookPrimaryButton())
    }
}

struct LaunchSecondaryButton: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(action: configuration.trigger) { configuration.label.frame(maxWidth: .infinity, minHeight: 28) }
            .buttonStyle(DaybookSecondaryButton())
    }
}

private struct LaunchCalendarConnection: View {
    let onFinish: () -> Void
    var body: some View {
        CalendarSettingsView()
            .safeAreaInset(edge: .bottom) {
                Button("Continue to daybook", action: onFinish).buttonStyle(LaunchPrimaryButton())
                    .frame(maxWidth: 480).padding().frame(maxWidth: .infinity).background(Color("PageBackground"))
            }
    }
}

extension SyncActivity {
    func launchMessage(hasRecords: Bool) -> String {
        if !enabled { return "Saved on this device" }
        if let accountIssue { return accountIssue }
        if !failures.isEmpty { return "iCloud needs attention" }
        if offline { return "Offline — you can continue on this device" }
        if active.values.contains(.receiving) { return "Syncing your data" }
        if hasRecords { return "Your daybook is ready to open" }
        return "Checking iCloud for existing work"
    }
}
