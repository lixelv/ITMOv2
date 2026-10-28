import MasshCore
import SwiftUI

struct InspectorView: View {
    var model: AppModel

    var body: some View {
        if let server = model.selectedServer {
            Text(server.name)
        } else {
            ContentUnavailableView("Server не выбран", systemImage: "server.rack",
                                   description: Text("Выберите Server в списке, чтобы увидеть сведения о нём."))
        }
    }
}
