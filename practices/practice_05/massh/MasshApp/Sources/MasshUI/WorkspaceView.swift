import MasshCore
import SwiftUI

struct WorkspaceView: View {
    var model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label("Нет открытых терминалов", systemImage: "terminal")
        } description: {
            Text("Дважды щёлкните Server в списке или нажмите «Подключиться».")
        }
    }
}
