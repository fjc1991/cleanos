import SwiftUI

/// The Ko-fi nudge shown at the top of Overview once CleanOS has been used in more than five sessions.
struct SupportBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [Theme.warning, Theme.accentSecondary], startPoint: .top, endPoint: .bottom))
                .frame(width: 48, height: 48)
                .card()
            VStack(alignment: .leading, spacing: 3) {
                Text("Enjoying CleanOS?").font(.headline)
                Text("You have opened CleanOS \(model.support.sessionCount) times. It is free and made by one person; if it has saved you space or time, a small tip on Ko-fi helps keep it going.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Menu {
                Button("Remind me in a month") { withAnimation { model.support.remindLater() } }
                Button("Don't ask again") { withAnimation { model.support.dontAskAgain() } }
            } label: {
                Text("Not now")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button {
                model.support.openSupportPage()
            } label: {
                Label("Tip on Ko-fi", systemImage: "heart.fill")
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .help("Opens your browser at the CleanOS Ko-fi page")
        }
        .padding(16)
        .card()
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}
