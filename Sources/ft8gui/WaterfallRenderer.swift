import Foundation
import MetalKit
import AppKit
import simd

enum WaterfallMode { case threeD, twoD }

/// Matches the `Uniforms` struct in the MSL source.
struct WFUniforms {
    var mvp: simd_float4x4
    var headF: Float
    var rows: Float
    var heightScale: Float
    var xExtent: Float
    var zDepth: Float
}

/// Matches `LabelUniforms` in the MSL source.
struct LabelUniforms {
    var center: SIMD2<Float>
    var halfSize: SIMD2<Float>
    var alpha: Float
    var pad: Float = 0
}

/// A decode tag: text+pill pre-rendered to a premultiplied bitmap, drawn as a
/// scrolling quad in the waterfall pass so it stays glued to its trace.
private struct DecodeLabel {
    let texture: MTLTexture
    let pxWidth: Int
    let pxHeight: Int
    let xf: Float                 // frequency fraction across the passband [0,1]
    let birth: CFTimeInterval
    let isCQ: Bool
}

/// Renders the live waterfall from a ring height-texture. Both the 3D displaced
/// mesh and the 2D spectrogram sample the same texture, so toggling modes is
/// free. All access is on the main thread (model pushes rows; `MTKView` draws),
/// so `@unchecked Sendable` is sound.
final class WaterfallRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipeline3D: MTLRenderPipelineState!
    private var pipeline2D: MTLRenderPipelineState!
    private var labelPipeline: MTLRenderPipelineState!
    private var linePipeline: MTLRenderPipelineState!
    private var bgPipeline: MTLRenderPipelineState!
    private var depthState: MTLDepthStencilState!
    private var overlayDepthState: MTLDepthStencilState!   // always-pass, no write

    // 3D surface world extents + last frame's MVP, for projecting label flags.
    private let zDepth: Float = 8.0
    private var xExtent: Float = 4
    private var lastMVP = matrix_identity_float4x4

    // Decode tags, drawn in the 2D pass. Main-thread only.
    private var labels: [DecodeLabel] = []
    private var drawablePx = SIMD2<Float>(0, 0)

    // Mesh grid; rebuilt in configure() to match the height texture's
    // resolution so the 3D surface samples it 1:1 (no time/freq smearing).
    private var meshCols = 320
    private var meshRows = 256
    private var meshBuffer: MTLBuffer!
    private var indexBuffer: MTLBuffer!
    private var indexCount = 0

    private var historyRows = 256
    private var heightTex: MTLTexture?
    private var binCount = 0
    private var writeRow = 0          // ring head: index of newest row
    private var rowsWritten = 0

    // Smooth sub-row scrolling: advance the visible field between data rows at
    // the deterministic data rate (sampleRate/hop), so motion glides instead of
    // stepping on bursty audio callbacks.
    private var lastRowTime: CFTimeInterval = 0
    private var rowsPerSecond: Double = 47

    var mode: WaterfallMode = .threeD
    private var aspect: Float = 16.0 / 9.0

    override init() {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not available on this Mac")
        }
        self.device = dev
        self.queue = dev.makeCommandQueue()!
        super.init()
        buildPipelines()
        buildMesh(cols: meshCols, rows: meshRows)
    }

    // MARK: Setup

    private func buildPipelines() {
        let lib: MTLLibrary
        do { lib = try device.makeLibrary(source: metalShaderSource, options: nil) }
        catch { fatalError("shader compile failed: \(error)") }

        func pipeline(_ vfn: String, _ ffn: String, depth: Bool) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: vfn)
            d.fragmentFunction = lib.makeFunction(name: ffn)
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            if depth { d.depthAttachmentPixelFormat = .depth32Float }
            return try! device.makeRenderPipelineState(descriptor: d)
        }
        pipeline3D = pipeline("vertex3d", "fragment3d", depth: true)
        pipeline2D = pipeline("vertex2d", "fragment2d", depth: false)

        // Premultiplied-alpha overlay pipelines (labels, lines, grid planes).
        func blended(_ vfn: String, _ ffn: String) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: vfn)
            d.fragmentFunction = lib.makeFunction(name: ffn)
            let a = d.colorAttachments[0]!
            a.pixelFormat = .bgra8Unorm
            a.isBlendingEnabled = true
            a.rgbBlendOperation = .add
            a.alphaBlendOperation = .add
            a.sourceRGBBlendFactor = .one
            a.sourceAlphaBlendFactor = .one
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            d.depthAttachmentPixelFormat = .depth32Float
            return try! device.makeRenderPipelineState(descriptor: d)
        }
        labelPipeline = blended("labelVertex", "labelFragment")
        linePipeline = blended("solidVertex", "solidFragment")
        bgPipeline = blended("bgVertex", "bgFragment")

        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .less
        dd.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: dd)

        // Overlays (tags/lines) draw on top regardless of the 3D surface.
        let od = MTLDepthStencilDescriptor()
        od.depthCompareFunction = .always
        od.isDepthWriteEnabled = false
        overlayDepthState = device.makeDepthStencilState(descriptor: od)
    }

    private func buildMesh(cols: Int, rows: Int) {
        meshCols = max(2, cols)
        meshRows = max(2, rows)
        var verts = [SIMD2<Float>]()
        verts.reserveCapacity(meshCols * meshRows)
        for r in 0..<meshRows {
            let gz = Float(r) / Float(meshRows - 1)
            for c in 0..<meshCols {
                let gx = Float(c) / Float(meshCols - 1)
                verts.append(SIMD2(gx, gz))
            }
        }
        var idx = [UInt32]()
        idx.reserveCapacity((meshCols - 1) * (meshRows - 1) * 6)
        for r in 0..<(meshRows - 1) {
            for c in 0..<(meshCols - 1) {
                let i = UInt32(r * meshCols + c)
                let right = i + 1
                let down = i + UInt32(meshCols)
                let diag = down + 1
                idx.append(contentsOf: [i, right, down, right, diag, down])
            }
        }
        indexCount = idx.count
        meshBuffer = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<SIMD2<Float>>.stride)
        indexBuffer = device.makeBuffer(bytes: idx, length: idx.count * MemoryLayout<UInt32>.stride)
    }

    /// (Re)allocate the ring texture for a given passband bin count and time
    /// depth (rows). Call before streaming starts; clears history.
    func configure(binCount: Int, historyRows: Int = 256, rowsPerSecond: Double = 47) {
        guard binCount > 0 else { return }
        self.binCount = binCount
        self.historyRows = max(16, historyRows)
        self.rowsPerSecond = max(1, rowsPerSecond)
        writeRow = 0
        rowsWritten = 0
        labels.removeAll()
        // Match the 3D mesh to the texture so the surface samples it 1:1.
        buildMesh(cols: binCount, rows: self.historyRows)
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: binCount, height: historyRows, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .managed
        heightTex = device.makeTexture(descriptor: desc)
        // Initialise to silence so the field starts dark.
        if let tex = heightTex {
            let zero = [Float](repeating: 0, count: binCount)
            for row in 0..<historyRows {
                tex.replace(region: MTLRegionMake2D(0, row, binCount, 1),
                            mipmapLevel: 0, withBytes: zero, bytesPerRow: binCount * 4)
            }
        }
    }

    /// Write one normalised ([0,1]) magnitude row at the ring head. Main thread.
    func pushRow(_ row: [Float], mediaTime: CFTimeInterval) {
        guard let tex = heightTex, row.count == binCount else { return }
        writeRow = (writeRow + 1) % historyRows
        tex.replace(region: MTLRegionMake2D(0, writeRow, binCount, 1),
                    mipmapLevel: 0, withBytes: row, bytesPerRow: binCount * 4)
        lastRowTime = mediaTime
        rowsWritten += 1
    }

    private var visibleSeconds: Double { Double(historyRows) / rowsPerSecond }

    /// Add a decode tag at frequency fraction `xf` ([0,1] across the passband).
    /// Renders the text+pill to a bitmap once; it then scrolls with the field.
    func addDecodeLabel(_ text: String, xf: Float, isCQ: Bool, mediaTime: CFTimeInterval) {
        guard let (tex, w, h) = makeTextTexture(text, cq: isCQ) else { return }
        labels.append(DecodeLabel(texture: tex, pxWidth: w, pxHeight: h, xf: xf,
                                  birth: mediaTime, isCQ: isCQ))
        if labels.count > 120 { labels.removeFirst(labels.count - 120) }
    }

    /// Render `text` into a premultiplied RGBA bitmap with a dark rounded pill,
    /// at 2× for crisp text, and wrap it in a Metal texture.
    private func makeTextTexture(_ text: String, cq: Bool) -> (MTLTexture, Int, Int)? {
        let scale: CGFloat = 2
        let font = NSFont.monospacedSystemFont(ofSize: 11 * scale, weight: .semibold)
        let color: NSColor = cq ? .systemYellow : .white
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let astr = NSAttributedString(string: text, attributes: attrs)
        let textSize = astr.size()
        let padX = 6 * scale, padY = 2 * scale
        let w = Int(ceil(textSize.width + padX * 2))
        let h = Int(ceil(textSize.height + padY * 2))
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        let rect = CGRect(x: 0.5, y: 0.5, width: CGFloat(w) - 1, height: CGFloat(h) - 1)
        NSColor(white: 0, alpha: 0.6).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5 * scale, yRadius: 5 * scale).fill()
        astr.draw(at: CGPoint(x: padX, y: padY))
        NSGraphicsContext.restoreGraphicsState()

        guard let data = ctx.data else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                    withBytes: data, bytesPerRow: w * 4)
        return (tex, w, h)
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        aspect = size.height > 0 ? Float(size.width / size.height) : 16.0 / 9.0
        drawablePx = SIMD2(Float(size.width), Float(size.height))
    }

    func draw(in view: MTKView) {
        guard let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }

        // Edge-to-edge graph-paper background, behind everything. (In 2D the
        // opaque spectrogram covers it; in 3D it fills the black.)
        if mode == .threeD {
            enc.setRenderPipelineState(bgPipeline)
            enc.setDepthStencilState(overlayDepthState)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        if let tex = heightTex, rowsWritten > 0 {
            // Fractional head for smooth scroll between data rows, advanced at
            // the deterministic data rate. Clamp to 1 so the top edge never
            // samples a row that hasn't been written yet.
            let now = CACurrentMediaTime()
            let frac = Float(min(max((now - lastRowTime) * rowsPerSecond, 0), 1))
            let headF = Float(writeRow) + frac

            // Width the surface to fill the (often very wide) window. Base it on
            // the camera-to-center distance so it fills at the pitched angle; the
            // horizontal field of view grows with aspect.
            let refDist = simd_length(camEye - camCenter)
            xExtent = max(2, 2 * refDist * tan(camFov / 2) * aspect * 0.58)
            lastMVP = makeMVP()

            var u = WFUniforms(mvp: lastMVP, headF: headF, rows: Float(historyRows),
                               heightScale: 0.62, xExtent: xExtent, zDepth: zDepth)

            switch mode {
            case .threeD:
                enc.setRenderPipelineState(pipeline3D)
                enc.setDepthStencilState(depthState)
                enc.setCullMode(.none)
                enc.setVertexBuffer(meshBuffer, offset: 0, index: 0)
                enc.setVertexBytes(&u, length: MemoryLayout<WFUniforms>.stride, index: 1)
                enc.setVertexTexture(tex, index: 0)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: indexCount,
                                          indexType: .uint32, indexBuffer: indexBuffer,
                                          indexBufferOffset: 0)
            case .twoD:
                enc.setRenderPipelineState(pipeline2D)
                enc.setFragmentBytes(&u, length: MemoryLayout<WFUniforms>.stride, index: 0)
                enc.setFragmentTexture(tex, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            drawLabels(enc, now: now)
        }

        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    /// Draw decode tags. `now` is the SAME clock used for the waterfall's
    /// `headF`, so tags advance in perfect lockstep with the field. In 2D each
    /// tag is a pill scrolling straight down; in 3D it's a flag on a leader line
    /// anchored to its point on the surface, riding back as the cycle ages.
    private func drawLabels(_ enc: MTLRenderCommandEncoder, now: CFTimeInterval) {
        guard drawablePx.x > 0, drawablePx.y > 0 else { return }
        let visible = visibleSeconds
        guard visible > 0 else { return }

        labels.removeAll { now - $0.birth > visible }
        guard !labels.isEmpty else { return }

        enc.setDepthStencilState(overlayDepthState)
        let flagHeight: Float = 1.0

        for label in labels {
            let age = now - label.birth
            let depth = Float(age / visible)                 // 0 = newest
            let alpha = Float(min(1, age / 0.4)) * min(1, (1 - depth) / 0.18)
            guard alpha > 0.001 else { continue }

            let halfX = Float(label.pxWidth) / drawablePx.x
            let halfY = Float(label.pxHeight) / drawablePx.y
            var center: SIMD2<Float>

            if mode == .twoD {
                let cx = min(max(label.xf * 2 - 1, -1 + halfX), 1 - halfX)
                center = SIMD2(cx, 1 - depth * 2)
            } else {
                // Anchor on the 3D surface; project floor + flag to clip space.
                let wx = (label.xf - 0.5) * xExtent
                let wz = -depth * zDepth
                let base = lastMVP * SIMD4<Float>(wx, 0, wz, 1)
                let flag = lastMVP * SIMD4<Float>(wx, flagHeight, wz, 1)
                guard base.w > 0.02, flag.w > 0.02 else { continue }
                let baseN = SIMD2(base.x / base.w, base.y / base.w)
                let flagN = SIMD2(flag.x / flag.w, flag.y / flag.w)

                let tint: SIMD3<Float> = label.isCQ ? SIMD3(1.0, 0.85, 0.1) : SIMD3(1, 1, 1)
                let la = alpha * 0.85
                var lineColor = SIMD4<Float>(tint.x * la, tint.y * la, tint.z * la, la)
                var pts = [baseN, flagN]
                enc.setRenderPipelineState(linePipeline)
                enc.setVertexBytes(&pts, length: MemoryLayout<SIMD2<Float>>.stride * 2, index: 0)
                enc.setFragmentBytes(&lineColor, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: 2)

                let cx = min(max(flagN.x, -1 + halfX), 1 - halfX)
                center = SIMD2(cx, flagN.y + halfY)   // pill sits atop the pole
            }

            var lu = LabelUniforms(center: center, halfSize: SIMD2(halfX, halfY), alpha: alpha)
            enc.setRenderPipelineState(labelPipeline)
            enc.setVertexBytes(&lu, length: MemoryLayout<LabelUniforms>.stride, index: 0)
            enc.setFragmentBytes(&lu, length: MemoryLayout<LabelUniforms>.stride, index: 0)
            enc.setFragmentTexture(label.texture, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    // MARK: Camera

    // Pitched well down so the surface sweeps from the bottom edge up toward
    // the top, filling the frame rather than sitting as a low band.
    private let camFov: Float = 60 * .pi / 180
    private let camEye = SIMD3<Float>(0, 2.70, 1.40)
    private let camCenter = SIMD3<Float>(0, 0.00, -3.20)

    private func makeMVP() -> simd_float4x4 {
        let proj = perspective(fovyRadians: camFov, aspect: aspect, near: 0.05, far: 40)
        let view = lookAt(eye: camEye, center: camCenter, up: SIMD3(0, 1, 0))
        return proj * view
    }
}

// MARK: - Matrix helpers (Metal NDC: z in [0,1], right-handed view)

private func perspective(fovyRadians fovy: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let ys = 1 / tan(fovy * 0.5)
    let xs = ys / aspect
    let zs = far / (near - far)
    return simd_float4x4(columns: (
        SIMD4(xs, 0, 0, 0),
        SIMD4(0, ys, 0, 0),
        SIMD4(0, 0, zs, -1),
        SIMD4(0, 0, zs * near, 0)))
}

private func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
    let z = simd_normalize(eye - center)   // points back toward the eye (RH)
    let x = simd_normalize(simd_cross(up, z))
    let y = simd_cross(z, x)
    return simd_float4x4(columns: (
        SIMD4(x.x, y.x, z.x, 0),
        SIMD4(x.y, y.y, z.y, 0),
        SIMD4(x.z, y.z, z.z, 0),
        SIMD4(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)))
}
