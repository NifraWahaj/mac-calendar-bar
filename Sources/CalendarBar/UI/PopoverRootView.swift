import SwiftUI

struct PopoverRootView: View {
    @ObservedObject var store: CalendarStore
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        content
            // Rebuild the whole tree when the palette changes so no nested view keeps a
            // stale accent color (they read Theme.accent, not an observed property).
            .id(theme.revision)
    }

    private var content: some View {
        VStack(spacing: 0) {
            HeaderBar(store: store)

            if store.showsCalendar {
                MiniCalendarView(store: store)
                Divider().overlay(Theme.separator)
                if let message = store.errorMessage {
                    ErrorBanner(message: message) { store.refresh() }
                }
                AgendaListView(store: store)
            } else {
                SignInView(store: store)
            }
        }
        .frame(width: Theme.popoverWidth, height: Theme.popoverHeight)
        .background(Theme.popoverBackground)
    }
}

// MARK: - Header

private struct HeaderBar: View {
    @ObservedObject var store: CalendarStore

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            Text(store.showsCalendar ? store.monthTitle : "Calendar")
                .font(Theme.monthTitleFont)
                .foregroundStyle(Theme.primaryText)

            if store.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .padding(.leading, 2)
            }

            Spacer()

            if store.showsCalendar {
                IconButton(systemName: "plus", size: 17, help: "New event") {
                    store.createEvent()
                }
            }

            OptionsMenuButton(store: store)
        }
        .padding(.leading, Theme.horizontalPadding)
        .padding(.trailing, Theme.horizontalPadding - 4)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}

private struct IconButton: View {
    let systemName: String
    var size: CGFloat = 15
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(Theme.iconTint)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovering ? Theme.hoverFill : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

// MARK: - Error banner

private struct ErrorBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color(hex: "D9822B"))
                .padding(.top, 1)
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .help(message)
            Spacer(minLength: 4)
            Button("Retry", action: retry)
                .font(.system(size: 11.5, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .fixedSize()
        }
        .padding(.horizontal, Theme.horizontalPadding)
        .padding(.vertical, 8)
        .background(Color(hex: "D9822B").opacity(0.10))
    }
}

// MARK: - Sign in

private struct SignInView: View {
    @ObservedObject var store: CalendarStore

    var body: some View {
        VStack(spacing: 14) {
            Spacer()

            Image(systemName: "calendar")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.accent)

            Text("Connect your Google Calendar")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.primaryText)

            Text("Calendar Bar reads your upcoming events over Google's Calendar API. Your tokens stay in the macOS Keychain.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 34)

            Button {
                store.signIn()
            } label: {
                Text(store.auth.isAuthenticating ? "Waiting for the browser…" : "Sign in with Google")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Theme.accent.opacity(store.auth.isAuthenticating ? 0.6 : 1))
                    )
            }
            .buttonStyle(.plain)
            .disabled(store.auth.isAuthenticating)

            if let message = store.errorMessage {
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(hex: "C0392B"))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 28)
            } else if !AppConfig.hasClientID {
                Text("No Client ID found. Add GOOGLE_CLIENT_ID to .env, or paste it into AppConfig.swift.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
