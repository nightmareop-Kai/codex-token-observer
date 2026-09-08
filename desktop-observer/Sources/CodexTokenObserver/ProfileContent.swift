import SwiftUI
import AppKit

/// Values and callbacks only, so visual previews never open an identity or database.
struct ProfileContent: View {
    let profile: ZunoProfile?
    let busy: Bool
    let requestError: String?
    let onRegister: (String) -> Void
    let onToggleSync: () -> Void
    let onClose: () -> Void
    @State private var nickname = ""
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var nameFocused: Bool

    private var registered: Bool { profile?.isRegistered == true }
    private var pending: Bool { profile?.status == "pending" }
    private var normalizedName: String? { ZunoProfile.normalizedNickname(nickname) }
    private var error: String? { requestError ?? profile?.errorMessage }
    private var accent: Color { colorScheme == .dark ? Color(red: 0.43, green: 0.70, blue: 1) : Color(red: 0, green: 0.37, blue: 0.79) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: registered ? "checkmark.seal" : "pawprint.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(accent)
                    .frame(width: 48, height: 48)
                    .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text(registered ? "Your Zuno" : "Meet your Zuno.")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text(registered ? "One name. Your own place." : "Give your counter a name.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            if registered {
                VStack(alignment: .leading, spacing: 7) {
                    Text(profile?.nickname ?? "").font(.system(size: 23, weight: .medium, design: .rounded))
                        .textSelection(.enabled).lineLimit(2)
                    Text("PERMANENT NICKNAME").font(.system(size: 8, weight: .semibold)).tracking(1.2)
                        .foregroundStyle(.secondary)
                    Divider().padding(.vertical, 3)
                    Text("Zuno ID").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    Text(profile?.id ?? "").font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))

                Label(profile?.isPaused == true ? "Sharing paused" : error != nil ? "Upload pending" : "Automatic leaderboard sync is on",
                      systemImage: profile?.isPaused == true ? "pause.circle" : error != nil ? "clock" : "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(error != nil ? .orange : accent)
                Text(profile?.isPaused == true
                     ? "Local counting continues. Your existing public profile and earlier rankings remain visible."
                     : "Only usage after joining is shared. Yesterday's ranking uses Beijing time (UTC+08). Your nickname cannot be changed.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nickname").font(.system(size: 11, weight: .medium))
                    TextField("Your name", text: $nickname)
                        .textFieldStyle(.roundedBorder).font(.system(size: 14))
                        .focused($nameFocused).disabled(busy || profile == nil || pending)
                        .accessibilityLabel("Permanent nickname")
                    Text(pending ? "Registration pending · Retry uses this name" : "2–24 letters, numbers, spaces, _ or -")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Label("Your name cannot be changed after joining.", systemImage: "lock")
                    .font(.system(size: 11, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Create & Join makes your nickname, random Zuno ID and daily token totals public. After joining, Zuno syncs automatically when online.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("No chats, project names or account details are shared. You can pause sharing later.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Leaderboard request failed. \(error)")
            }

            HStack(spacing: 9) {
                if busy { ProgressView().controlSize(.small).accessibilityLabel("Contacting leaderboard") }
                Spacer(minLength: 0)
                Button(registered || pending ? "Done" : "Not now", action: onClose)
                    .disabled(busy)
                if registered {
                    Button(profile?.isPaused == true ? "Resume Sync" : "Pause Sync", action: onToggleSync)
                        .disabled(busy)
                } else {
                    Button(pending ? "Retry Join" : "Create & Join") { if let normalizedName { onRegister(normalizedName) } }
                        .buttonStyle(.borderedProminent).tint(accent)
                        .disabled(busy || profile == nil || normalizedName == nil)
                }
            }
            if !registered {
                Text(pending ? "Zuno will retry your confirmed registration when online. Local counting continues."
                     : "Closing this window keeps counting local. Nothing is uploaded before you join.")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24).frame(width: 364)
        .background(.regularMaterial)
        .environment(\.locale, Locale(identifier: "en_US"))
        .onAppear {
            if let saved = profile?.nickname, !registered { nickname = saved }
            nameFocused = !registered
        }
        .onChange(of: profile?.nickname) { _, name in
            if pending, let name { nickname = name }
        }
    }
}
