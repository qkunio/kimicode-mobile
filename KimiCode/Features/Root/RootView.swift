import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.auth.isSignedIn {
                MainView()
                    .task { await model.bootstrap() }
            } else {
                WelcomeView()
            }
        }
        .animation(.default, value: model.auth.isSignedIn)
    }
}
