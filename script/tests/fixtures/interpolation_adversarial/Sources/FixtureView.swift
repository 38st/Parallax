import SwiftUI

struct UsageModel {
    let itemCount: Int

    func opaqueMetric() -> Int {
        itemCount
    }
}

struct FixtureView: View {
    let model: UsageModel

    var body: some View {
        VStack {
            Text("Items \(model.itemCount)")
            Text("Unknown \(model.opaqueMetric())")
        }
    }
}
