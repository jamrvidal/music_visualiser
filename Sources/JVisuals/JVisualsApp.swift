import MetalKit
import SwiftUI

@main
struct JVisualsApp: App {
    init() {
        // Only the colour wheel in the system colour panel; must be set before the panel is first created.
        NSColorPanel.setPickerMask(.wheelModeMask)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

struct MetalView: NSViewRepresentable {
    let ring: SampleRing
    let settings: VisualSettings

    func makeCoordinator() -> Renderer {
        do {
            return try Renderer(ring: ring, settings: settings)
        } catch {
            fatalError("Could not start renderer: \(error)")
        }
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 60
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {}
}
