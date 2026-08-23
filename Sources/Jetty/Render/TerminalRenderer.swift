import Foundation
import Metal
import MetalKit
import simd

public final class TerminalRenderer {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    public let pipeline: MTLRenderPipelineState
    public let inkPipeline: MTLRenderPipelineState
    public let overlayPipeline: MTLRenderPipelineState
    public let sampler: MTLSamplerState
    public var atlas: GlyphAtlas

    private static let ringCount = 3
    private var instanceBuffers: [MTLBuffer?] = [nil, nil, nil]
    private var instanceCaps: [Int] = [0, 0, 0]
    private var instanceSlot = 0
    private var presentedSlot: Int?
    private var overlayBuffers: [MTLBuffer?] = [nil, nil, nil]
    private var overlayCaps: [Int] = [0, 0, 0]
    private var overlaySlot = 0
    private var uniformBuffers: [MTLBuffer?] = [nil, nil, nil]
    private var uniformSlot = 0

    public init?(device: MTLDevice, atlas: GlyphAtlas) {
        self.device = device
        guard let q = device.makeCommandQueue() else { return nil }
        self.queue = q
        self.atlas = atlas

        let src = Self.shaderSource
        let lib: MTLLibrary
        do {
            lib = try device.makeLibrary(source: src, options: nil)
        } catch {
            fputs("jetty: Metal library: \(error)\n", stderr)
            return nil
        }
        guard let vfn = lib.makeFunction(name: "cell_vertex"),
              let ffn = lib.makeFunction(name: "cell_fragment") else { return nil }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.colorAttachments[0].isBlendingEnabled = false
        do {
            self.pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            fputs("jetty: pipeline: \(error)\n", stderr)
            return nil
        }
        guard let ifn = lib.makeFunction(name: "ink_fragment") else { return nil }
        let idesc = MTLRenderPipelineDescriptor()
        idesc.vertexFunction = vfn
        idesc.fragmentFunction = ifn
        idesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        idesc.colorAttachments[0].isBlendingEnabled = true
        idesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        idesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        idesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        idesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do {
            self.inkPipeline = try device.makeRenderPipelineState(descriptor: idesc)
        } catch {
            fputs("jetty: ink pipeline: \(error)\n", stderr)
            return nil
        }
        guard let ovfn = lib.makeFunction(name: "overlay_vertex"),
              let offn = lib.makeFunction(name: "overlay_fragment") else { return nil }
        let odesc = MTLRenderPipelineDescriptor()
        odesc.vertexFunction = ovfn
        odesc.fragmentFunction = offn
        odesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        odesc.colorAttachments[0].isBlendingEnabled = true
        odesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        odesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        odesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        odesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do {
            self.overlayPipeline = try device.makeRenderPipelineState(descriptor: odesc)
        } catch {
            fputs("jetty: overlay pipeline: \(error)\n", stderr)
            return nil
        }
        let s = MTLSamplerDescriptor()
        s.minFilter = .nearest
        s.magFilter = .nearest
        s.sAddressMode = .clampToEdge
        s.tAddressMode = .clampToEdge
        guard let samp = device.makeSamplerState(descriptor: s) else { return nil }
        self.sampler = samp
        for i in 0..<Self.ringCount {
            uniformBuffers[i] = device.makeBuffer(length: FrameUniforms.stride, options: .storageModeShared)
        }
    }

    /// CPU pointer into the next ring slot. Fill `count` instances, then `draw`.
    public func prepareInstances(count: Int) -> UnsafeMutablePointer<CellInstance>? {
        instanceSlot = (instanceSlot + 1) % Self.ringCount
        let need = max(count, 1)
        if instanceBuffers[instanceSlot] == nil || instanceCaps[instanceSlot] < need {
            let cap = max(need, 64)
            instanceBuffers[instanceSlot] = device.makeBuffer(
                length: cap * CellInstance.stride,
                options: .storageModeShared
            )
            instanceCaps[instanceSlot] = cap
        }
        guard let buf = instanceBuffers[instanceSlot] else { return nil }
        return buf.contents().assumingMemoryBound(to: CellInstance.self)
    }

    /// Same cap as the current write slot, last successful present, not the write slot itself.
    public func canCopyFromPresented(count: Int) -> Bool {
        guard let p = presentedSlot, p != instanceSlot else { return false }
        let cap = instanceCaps[p]
        return cap == instanceCaps[instanceSlot] && cap >= count
    }

    public func copyPresentedRow(
        to dest: UnsafeMutablePointer<CellInstance>,
        row: Int,
        cols: Int,
        inkBase: Int? = nil
    ) {
        guard cols > 0, row >= 0,
              let p = presentedSlot,
              let buf = instanceBuffers[p]
        else { return }
        let start = row * cols
        if start < 0 || start + cols > instanceCaps[p] { return }
        let src = buf.contents().assumingMemoryBound(to: CellInstance.self)
        (dest + start).update(from: src + start, count: cols)
        if let ink = inkBase {
            let i = ink + start
            if i >= 0, i + cols <= instanceCaps[p] {
                (dest + i).update(from: src + i, count: cols)
            }
        }
    }

    public func prepareOverlays(count: Int) -> UnsafeMutablePointer<OverlayInstance>? {
        overlaySlot = (overlaySlot + 1) % Self.ringCount
        let need = max(count, 1)
        if overlayBuffers[overlaySlot] == nil || overlayCaps[overlaySlot] < need {
            let cap = max(need, 16)
            overlayBuffers[overlaySlot] = device.makeBuffer(
                length: cap * OverlayInstance.stride,
                options: .storageModeShared
            )
            overlayCaps[overlaySlot] = cap
        }
        guard let buf = overlayBuffers[overlaySlot] else { return nil }
        return buf.contents().assumingMemoryBound(to: OverlayInstance.self)
    }

    @MainActor
    @discardableResult
    public func draw(
        view: MTKView,
        instanceCount: Int,
        inkCount: Int = 0,
        overlayCount: Int = 0,
        viewport: SIMD2<Float>,
        contentOffsetY: Float = 0
    ) -> Bool {
        guard let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd)
        else { return false }

        uniformSlot = (uniformSlot + 1) % Self.ringCount
        if let uni = uniformBuffers[uniformSlot] {
            var u = FrameUniforms(
                viewportX: viewport.x,
                viewportY: viewport.y,
                contentOffsetY: contentOffsetY,
                atlasW: Float(atlas.texture.width),
                atlasH: Float(atlas.texture.height),
                colorAtlasW: Float(atlas.colorTexture.width),
                colorAtlasH: Float(atlas.colorTexture.height)
            )
            memcpy(uni.contents(), &u, FrameUniforms.stride)
        }

        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(instanceBuffers[instanceSlot], offset: 0, index: 0)
        enc.setVertexBuffer(uniformBuffers[uniformSlot], offset: 0, index: 1)
        enc.setFragmentTexture(atlas.texture, index: 0)
        enc.setFragmentTexture(atlas.colorTexture, index: 1)
        enc.setFragmentSamplerState(sampler, index: 0)
        if instanceCount > 0 {
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: instanceCount)
        }
        if inkCount > 0 {
            enc.setRenderPipelineState(inkPipeline)
            enc.setVertexBuffer(instanceBuffers[instanceSlot], offset: instanceCount * CellInstance.stride, index: 0)
            enc.setVertexBuffer(uniformBuffers[uniformSlot], offset: 0, index: 1)
            enc.setFragmentTexture(atlas.texture, index: 0)
            enc.setFragmentTexture(atlas.colorTexture, index: 1)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: inkCount)
        }
        if overlayCount > 0, let obuf = overlayBuffers[overlaySlot] {
            enc.setRenderPipelineState(overlayPipeline)
            enc.setVertexBuffer(obuf, offset: 0, index: 0)
            enc.setVertexBuffer(uniformBuffers[uniformSlot], offset: 0, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: overlayCount)
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
        presentedSlot = instanceSlot
        return true
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct CellInstance {
        short ox;
        short oy;
        ushort sx;
        ushort sy;
        ushort u0;
        ushort v0;
        ushort u1;
        ushort v1;
        uint fg;
        uint bg;
        uchar atlas;
        uchar flags;
        ushort _pad0;
        uint _pad1;
    };

    struct FrameUniforms {
        float2 viewport;
        float contentOffsetY;
        float _pad0;
        float atlasW;
        float atlasH;
        float colorAtlasW;
        float colorAtlasH;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
        float4 fg;
        float4 bg;
        float hasGlyph;
        float atlas;
    };

    constant float2 corners[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(1, 0), float2(1, 1), float2(0, 1)
    };

    float4 unpack8(uint c) {
        return float4(float(c & 0xffu), float((c >> 8) & 0xffu),
                      float((c >> 16) & 0xffu), float(c >> 24)) * (1.0 / 255.0);
    }

    vertex VertexOut cell_vertex(uint vid [[vertex_id]],
                                 uint iid [[instance_id]],
                                 const device CellInstance *cells [[buffer(0)]],
                                 constant FrameUniforms &uni [[buffer(1)]]) {
        CellInstance c = cells[iid];
        float2 corner = corners[vid];
        float2 origin = float2(float(c.ox), float(c.oy));
        float2 size = float2(float(c.sx), float(c.sy));
        float2 px = origin + corner * size;
        px.y += uni.contentOffsetY;
        float2 ndc;
        ndc.x = (px.x / uni.viewport.x) * 2.0 - 1.0;
        ndc.y = 1.0 - (px.y / uni.viewport.y) * 2.0;
        float aw = c.atlas != 0 ? uni.colorAtlasW : uni.atlasW;
        float ah = c.atlas != 0 ? uni.colorAtlasH : uni.atlasH;
        VertexOut o;
        o.position = float4(ndc, 0.0, 1.0);
        o.uv = float2(mix(float(c.u0), float(c.u1), corner.x) / aw,
                      mix(float(c.v0), float(c.v1), corner.y) / ah);
        o.fg = unpack8(c.fg);
        o.bg = unpack8(c.bg);
        o.hasGlyph = float(c.flags & 1);
        o.atlas = float(c.atlas);
        return o;
    }

    fragment float4 cell_fragment(VertexOut in [[stage_in]],
                                  texture2d<float> atlas [[texture(0)]],
                                  texture2d<float> colorAtlas [[texture(1)]],
                                  sampler samp [[sampler(0)]]) {
        if (in.atlas > 0.5 && in.hasGlyph > 0.5) {
            float4 c = colorAtlas.sample(samp, in.uv);
            float3 rgb = c.rgb + in.bg.rgb * (1.0 - saturate(c.a));
            return float4(rgb, 1.0);
        }
        float a = 0.0;
        if (in.hasGlyph > 0.5) {
            a = atlas.sample(samp, in.uv).r;
        }
        float3 rgb = mix(in.bg.rgb, in.fg.rgb, saturate(a));
        return float4(rgb, 1.0);
    }

    fragment float4 ink_fragment(VertexOut in [[stage_in]],
                                 texture2d<float> atlas [[texture(0)]],
                                 texture2d<float> colorAtlas [[texture(1)]],
                                 sampler samp [[sampler(0)]]) {
        if (in.hasGlyph < 0.5) {
            return float4(0, 0, 0, 0);
        }
        if (in.atlas > 0.5) {
            return colorAtlas.sample(samp, in.uv);
        }
        float a = atlas.sample(samp, in.uv).r;
        return float4(in.fg.rgb, saturate(a));
    }

    struct OverlayInstance {
        float2 origin;
        float2 size;
        float4 color;
    };

    struct OverlayOut {
        float4 position [[position]];
        float4 color;
    };

    vertex OverlayOut overlay_vertex(uint vid [[vertex_id]],
                                     uint iid [[instance_id]],
                                     const device OverlayInstance *quads [[buffer(0)]],
                                     constant FrameUniforms &uni [[buffer(1)]]) {
        OverlayInstance c = quads[iid];
        float2 corner = corners[vid];
        float2 px = c.origin + corner * c.size;
        px.y += uni.contentOffsetY;
        float2 ndc;
        ndc.x = (px.x / uni.viewport.x) * 2.0 - 1.0;
        ndc.y = 1.0 - (px.y / uni.viewport.y) * 2.0;
        OverlayOut o;
        o.position = float4(ndc, 0.0, 1.0);
        o.color = c.color;
        return o;
    }

    fragment float4 overlay_fragment(OverlayOut in [[stage_in]]) {
        return in.color;
    }
    """
}
