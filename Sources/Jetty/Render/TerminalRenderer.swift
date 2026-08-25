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
    public let imagePipeline: MTLRenderPipelineState
    public let sampler: MTLSamplerState
    public let linearSampler: MTLSamplerState
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
    private var imageBuffers: [MTLBuffer?] = [nil, nil, nil]
    private var imageCaps: [Int] = [0, 0, 0]
    private var imageSlot = 0
    private var imageUniformBuffers: [MTLBuffer?] = [nil, nil, nil]
    private var imageUniformSlot = 0
    private var imageTextures: [UInt32: (generation: UInt64, tex: MTLTexture)] = [:]
    private var imageDraws: [(tex: MTLTexture, start: Int, count: Int, w: Int, h: Int)] = []

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
        guard let ivfn = lib.makeFunction(name: "image_vertex"),
              let iffn = lib.makeFunction(name: "image_fragment") else { return nil }
        let imgd = MTLRenderPipelineDescriptor()
        imgd.vertexFunction = ivfn
        imgd.fragmentFunction = iffn
        imgd.colorAttachments[0].pixelFormat = .bgra8Unorm
        imgd.colorAttachments[0].isBlendingEnabled = true
        imgd.colorAttachments[0].sourceRGBBlendFactor = .one
        imgd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        imgd.colorAttachments[0].sourceAlphaBlendFactor = .one
        imgd.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do {
            self.imagePipeline = try device.makeRenderPipelineState(descriptor: imgd)
        } catch {
            fputs("jetty: image pipeline: \(error)\n", stderr)
            return nil
        }
        let s = MTLSamplerDescriptor()
        s.minFilter = .nearest
        s.magFilter = .nearest
        s.sAddressMode = .clampToEdge
        s.tAddressMode = .clampToEdge
        guard let samp = device.makeSamplerState(descriptor: s) else { return nil }
        self.sampler = samp
        let ls = MTLSamplerDescriptor()
        ls.minFilter = .linear
        ls.magFilter = .linear
        ls.sAddressMode = .clampToEdge
        ls.tAddressMode = .clampToEdge
        guard let lin = device.makeSamplerState(descriptor: ls) else { return nil }
        self.linearSampler = lin
        for i in 0..<Self.ringCount {
            uniformBuffers[i] = device.makeBuffer(length: FrameUniforms.stride, options: .storageModeShared)
            imageUniformBuffers[i] = device.makeBuffer(length: ImageUniforms.stride, options: .storageModeShared)
        }
    }

    public func needsImageUpload(id: UInt32, generation: UInt64) -> Bool {
        guard let e = imageTextures[id] else { return true }
        return e.generation != generation
    }

    public func pruneImageTextures(keep: Set<UInt32>) {
        imageTextures = imageTextures.filter { keep.contains($0.key) }
    }

    public func uploadImage(id: UInt32, generation: UInt64, width: Int, height: Int, rgba: UnsafeRawPointer) {
        if let e = imageTextures[id], e.generation == generation { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: max(width, 1),
            height: max(height, 1),
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return }
        let bpr = width * 4
        tex.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: rgba,
            bytesPerRow: bpr
        )
        imageTextures[id] = (generation, tex)
    }

    public func texture(id: UInt32) -> MTLTexture? {
        imageTextures[id]?.tex
    }

    public func prepareImages(count: Int) -> UnsafeMutablePointer<ImageInstance>? {
        imageSlot = (imageSlot + 1) % Self.ringCount
        let need = max(count, 1)
        if imageBuffers[imageSlot] == nil || imageCaps[imageSlot] < need {
            let cap = max(need, 8)
            imageBuffers[imageSlot] = device.makeBuffer(
                length: cap * ImageInstance.stride,
                options: .storageModeShared
            )
            imageCaps[imageSlot] = cap
        }
        guard let buf = imageBuffers[imageSlot] else { return nil }
        return buf.contents().assumingMemoryBound(to: ImageInstance.self)
    }

    public func setImageDraws(_ draws: [(tex: MTLTexture, start: Int, count: Int, w: Int, h: Int)]) {
        imageDraws = draws
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
        glyphCount: Int = 0,
        inkCount: Int = 0,
        overlayCount: Int = 0,
        overlayCursorAt: Int = -1,
        imageBelowBgCount: Int = 0,
        imageBelowTextCount: Int = 0,
        imageOverCount: Int = 0,
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

        let imageTotal = imageBelowBgCount + imageBelowTextCount + imageOverCount
        let split = imageTotal > 0 && overlayCursorAt >= 0 && overlayCursorAt <= overlayCount
        let underText = glyphCount > 0
        func drawCells(offset: Int, count: Int, state: MTLRenderPipelineState) {
            guard count > 0 else { return }
            enc.setRenderPipelineState(state)
            enc.setVertexBuffer(
                instanceBuffers[instanceSlot],
                offset: offset * CellInstance.stride,
                index: 0
            )
            enc.setVertexBuffer(uniformBuffers[uniformSlot], offset: 0, index: 1)
            enc.setFragmentTexture(atlas.texture, index: 0)
            enc.setFragmentTexture(atlas.colorTexture, index: 1)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: count)
        }
        func drawImageBand(start: Int, count: Int) {
            guard count > 0 else { return }
            let lo = start
            let hi = start + count
            enc.setRenderPipelineState(imagePipeline)
            enc.setFragmentSamplerState(linearSampler, index: 0)
            for d in imageDraws {
                if d.start + d.count <= lo || d.start >= hi { continue }
                imageUniformSlot = (imageUniformSlot + 1) % Self.ringCount
                if let uni = imageUniformBuffers[imageUniformSlot] {
                    var u = ImageUniforms(
                        viewportX: viewport.x,
                        viewportY: viewport.y,
                        contentOffsetY: contentOffsetY,
                        texW: Float(d.w),
                        texH: Float(d.h)
                    )
                    memcpy(uni.contents(), &u, ImageUniforms.stride)
                    enc.setVertexBuffer(imageBuffers[imageSlot], offset: d.start * ImageInstance.stride, index: 0)
                    enc.setVertexBuffer(uni, offset: 0, index: 1)
                }
                enc.setFragmentTexture(d.tex, index: 0)
                if d.count > 0 {
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: d.count)
                }
            }
        }
        if !underText {
            drawCells(offset: 0, count: instanceCount, state: pipeline)
        }
        drawImageBand(start: 0, count: imageBelowBgCount)
        if underText {
            drawCells(offset: 0, count: instanceCount, state: pipeline)
        }
        drawImageBand(start: imageBelowBgCount, count: imageBelowTextCount)
        if glyphCount > 0 {
            enc.setRenderPipelineState(inkPipeline)
            enc.setVertexBuffer(instanceBuffers[instanceSlot], offset: instanceCount * CellInstance.stride, index: 0)
            enc.setVertexBuffer(uniformBuffers[uniformSlot], offset: 0, index: 1)
            enc.setFragmentTexture(atlas.texture, index: 0)
            enc.setFragmentTexture(atlas.colorTexture, index: 1)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: glyphCount)
        }
        if inkCount > 0 {
            enc.setRenderPipelineState(inkPipeline)
            enc.setVertexBuffer(
                instanceBuffers[instanceSlot],
                offset: (instanceCount + glyphCount) * CellInstance.stride,
                index: 0
            )
            enc.setVertexBuffer(uniformBuffers[uniformSlot], offset: 0, index: 1)
            enc.setFragmentTexture(atlas.texture, index: 0)
            enc.setFragmentTexture(atlas.colorTexture, index: 1)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: inkCount)
        }
        if overlayCount > 0, let obuf = overlayBuffers[overlaySlot] {
            let decoN = split ? overlayCursorAt : overlayCount
            if decoN > 0 {
                enc.setRenderPipelineState(overlayPipeline)
                enc.setVertexBuffer(obuf, offset: 0, index: 0)
                enc.setVertexBuffer(uniformBuffers[uniformSlot], offset: 0, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: decoN)
            }
        }
        drawImageBand(start: imageBelowBgCount + imageBelowTextCount, count: imageOverCount)
        if split, overlayCount > overlayCursorAt, let obuf = overlayBuffers[overlaySlot] {
            let curN = overlayCount - overlayCursorAt
            enc.setRenderPipelineState(overlayPipeline)
            enc.setVertexBuffer(obuf, offset: overlayCursorAt * OverlayInstance.stride, index: 0)
            enc.setVertexBuffer(uniformBuffers[uniformSlot], offset: 0, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: curN)
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
            float cover = saturate(c.a);
            float3 rgb = c.rgb + in.bg.rgb * (1.0 - cover);
            return float4(rgb, mix(in.bg.a, 1.0, cover));
        }
        float a = 0.0;
        if (in.hasGlyph > 0.5) {
            a = atlas.sample(samp, in.uv).r;
        }
        float cover = saturate(a);
        float3 rgb = mix(in.bg.rgb, in.fg.rgb, cover);
        return float4(rgb, mix(in.bg.a, 1.0, cover));
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

    struct ImageInstance {
        short ox;
        short oy;
        ushort sx;
        ushort sy;
        ushort u0;
        ushort v0;
        ushort u1;
        ushort v1;
        uint _pad[4];
    };

    struct ImageUniforms {
        float2 viewport;
        float contentOffsetY;
        float _pad0;
        float texW;
        float texH;
        float2 _pad1;
    };

    struct ImageOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex ImageOut image_vertex(uint vid [[vertex_id]],
                                 uint iid [[instance_id]],
                                 const device ImageInstance *cells [[buffer(0)]],
                                 constant ImageUniforms &uni [[buffer(1)]]) {
        ImageInstance c = cells[iid];
        float2 corner = corners[vid];
        float2 origin = float2(float(c.ox), float(c.oy));
        float2 size = float2(float(c.sx), float(c.sy));
        float2 px = origin + corner * size;
        px.y += uni.contentOffsetY;
        float2 ndc;
        ndc.x = (px.x / uni.viewport.x) * 2.0 - 1.0;
        ndc.y = 1.0 - (px.y / uni.viewport.y) * 2.0;
        ImageOut o;
        o.position = float4(ndc, 0.0, 1.0);
        float tw = uni.texW > 0.5 ? uni.texW : 1.0;
        float th = uni.texH > 0.5 ? uni.texH : 1.0;
        o.uv = float2(mix(float(c.u0), float(c.u1), corner.x) / tw,
                      mix(float(c.v0), float(c.v1), corner.y) / th);
        return o;
    }

    fragment float4 image_fragment(ImageOut in [[stage_in]],
                                   texture2d<float> tex [[texture(0)]],
                                   sampler samp [[sampler(0)]]) {
        return tex.sample(samp, in.uv);
    }
    """
}
