import SwiftUI
import MetalKit

/// Hosts the `MTKView` and binds it to the model's renderer. Runs at the
/// display's native refresh (60 Hz, or 120 Hz on ProMotion) and scrolls
/// smoothly between data rows.
struct MetalWaterfallView: NSViewRepresentable {
    let renderer: WaterfallRenderer

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.delegate = renderer
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColorMake(0.02, 0.02, 0.06, 1)
        view.preferredFramesPerSecond = 120        // capped to the panel's refresh
        view.isPaused = false
        view.enableSetNeedsDisplay = false          // continuous, vsync-driven
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {}
}
