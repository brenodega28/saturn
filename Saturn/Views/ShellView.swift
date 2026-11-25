import SaturnCore
import SaturnUI
import SwiftUI

extension EnvironmentValues {
    @Entry var showsScreenHeader = true
}

struct AppScreen<Accessory: View, Content: View>: View {
    @Environment(\.showsScreenHeader) private var showsHeader
    let title: String
    let subtitle: String
    let accessory: Accessory
    let content: Content

    init(title: String, subtitle: String, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: showsHeader ? 20 : 14) {
            if showsHeader {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 17, weight: .bold)).kerning(-0.2)
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    }
                    Spacer(minLength: 0)
                    accessory
                }
                .frame(minHeight: 52, alignment: .leading)
            } else if Accessory.self != EmptyView.self {
                HStack(spacing: 12) {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    Spacer(minLength: 0)
                    accessory
                }
            }
            content
        }
        .padding(showsHeader ? EdgeInsets(top: 10, leading: 26, bottom: 24, trailing: 22) : EdgeInsets(top: 16, leading: 22, bottom: 20, trailing: 20))
    }
}

extension AppScreen where Accessory == EmptyView {
    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, accessory: { EmptyView() }, content: content)
    }
}
