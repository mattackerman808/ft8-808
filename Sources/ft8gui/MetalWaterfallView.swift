import SwiftUI
import MetalKit

/// Hosts the `MTKView` and binds it to the model's renderer. Scrolls smoothly
/// between data rows at a modest fixed rate — the data arrives at ~47 rows/s, so
/// 30 fps is ample and keeps continuous GPU load (and heat → thermal throttling
/// over long sessions) low rather than redrawing at the panel's 60/120 Hz.
struct MetalWaterfallView: NSViewRepresentable {
    let renderer: WaterfallRenderer

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.delegate = renderer
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColorMake(0.02, 0.02, 0.06, 1)
        view.preferredFramesPerSecond = 30
        view.isPaused = false
        view.enableSetNeedsDisplay = false          // continuous, vsync-driven
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {}
}
