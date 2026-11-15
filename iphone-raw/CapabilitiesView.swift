import SwiftUI

/// Debug screen: what the current lens actually exposes through AVFoundation.
struct CapabilitiesView: View {
    let info: CaptureInfo

    var body: some View {
        NavigationStack {
            List {
                Section("Lens") {
                    LabeledContent("Device", value: info.lensName)
                    LabeledContent("Max photo size", value: info.maxDimensions)
                    LabeledContent("Apple ProRAW", value: info.proRAWSupported ? "Supported (not used)" : "Not supported")
                }

                Section {
                    if info.rawFormats.isEmpty {
                        Text("This lens offers no RAW formats.")
                    }
                    ForEach(info.rawFormats) { format in
                        LabeledContent(format.name, value: format.isBayer ? "Bayer RAW" : "Processed RAW")
                            .font(.callout.monospaced())
                    }
                } header: {
                    Text("RAW pixel formats")
                } footer: {
                    Text("iPhone RAW captures only Bayer formats: undemosaiced sensor data with no multi-frame fusion, Deep Fusion or Smart HDR.")
                }
            }
            .navigationTitle("Capabilities")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
